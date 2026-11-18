import Darwin
import Foundation

/// A Windows program running in one of Cell's containers.
public struct WineProcess: Hashable, Sendable {
    public var pid: pid_t
    public var containerID: UUID
    /// Windows path of the program, e.g. `C:\Program Files (x86)\Steam\steam.exe`.
    public var executable: String
    public var startedAt: Date? = nil

    public var executableName: String {
        String(executable.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(executable)).lowercased()
    }
    var folder: String {
        guard let slash = executable.lastIndex(where: { $0 == "\\" }) else { return "" }
        return executable[..<slash].lowercased()
    }
}

/// Finds what is running by looking at processes, so games Steam starts, Steam restarting itself and
/// programs started outside Cell all show up. A Wine process runs one of Cell's engines, has the
/// Windows program's path among its arguments, and its working directory lies inside its container.
public enum WineProcessScanner {
    /// Wine's helpers, not programs anyone started.
    static let helpers: Set<String> = ["wineboot.exe", "winedevice.exe", "services.exe", "cell-webview-bridge.exe", "plugplay.exe", "explorer.exe",
                                       "rpcss.exe", "svchost.exe", "conhost.exe", "start.exe", "winemenubuilder.exe",
                                       "tabtip.exe", "mscorsvw.exe", "unitycrashhandler64.exe", "unitycrashhandler32.exe"]

    public static func scan(containers: [Container], runtimesRoot: URL = CellPaths.runtimes) -> [WineProcess] {
        let root = canonicalPath(runtimesRoot.path)
        let prefixes = containers.filter { $0.platform == .windows }
            .map { ($0.id, canonicalPath($0.prefixURL.path) + "/") }
        var result: [WineProcess] = []
        for pid in allPIDs() where pid > 0 {
            guard let path = executablePath(of: pid), path.hasPrefix(root),
                  let cwd = currentDirectory(of: pid),
                  let container = prefixes.first(where: { cwd.hasPrefix($0.1) || cwd + "/" == $0.1 }),
                  let arguments = arguments(of: pid), let executable = windowsExecutable(in: arguments) else { continue }
            let process = WineProcess(pid: pid, containerID: container.0, executable: executable, startedAt: startTime(of: pid))
            if helpers.contains(process.executableName) { continue }
            result.append(process)
        }
        return result
    }

    /// A process of a container's Wine session, whatever it is: a program, one of Wine's helpers, a crash debugger,
    /// or the wineserver itself.
    public struct SessionProcess: Hashable, Sendable {
        public var pid: pid_t
        public var startedAt: Date
        public var isServer: Bool
    }

    /// Every process of a container's Wine session (also ones Cell didn't start and ones left from an older session).
    public static func sessionProcesses(of container: Container, runtimesRoot: URL = CellPaths.runtimes) -> [SessionProcess] {
        let root = canonicalPath(runtimesRoot.path) + "/"
        let prefix = canonicalPath(container.prefixURL.path)
        let serverDirectory = WineCommands.serverDirectory(for: container).map(canonicalPath)
        var result: [SessionProcess] = []
        for pid in allPIDs() where pid > 0 && pid != getpid() {
            guard let path = executablePath(of: pid), path.hasPrefix(root), let cwd = currentDirectory(of: pid) else { continue }
            let isServer = path.hasSuffix("/wineserver")
            if isServer {
                guard let serverDirectory, cwd == serverDirectory else { continue }
            } else {
                guard cwd == prefix || cwd.hasPrefix(prefix + "/") else { continue }
            }
            result.append(SessionProcess(pid: pid, startedAt: startTime(of: pid) ?? .distantPast, isServer: isServer))
        }
        return result
    }

    /// Processes left over from an earlier session of the container: a Wine program can't outlive its wineserver
    /// on purpose (it can't reach a new one), but crash debuggers and Wine's device helpers hung on for days,
    /// hundreds of them. They are older than the running wineserver, or there is no wineserver at all.
    public static func orphans(in processes: [SessionProcess], now: Date = Date()) -> [pid_t] {
        let servers = processes.filter(\.isServer)
        // The first program of a session starts its wineserver itself, a moment after it started.
        let grace: TimeInterval = 15
        let clients = processes.filter { !$0.isServer }
        guard let serverStart = servers.map(\.startedAt).min() else {
            return clients.filter { now.timeIntervalSince($0.startedAt) > grace }.map(\.pid)
        }
        return clients.filter { $0.startedAt < serverStart.addingTimeInterval(-grace) }.map(\.pid)
    }

    /// Ends leftovers of earlier sessions (see `orphans`). Returns how many were ended.
    @discardableResult
    public static func endOrphans(of container: Container) -> Int {
        let processes = sessionProcesses(of: container)
        // Safety: a wineserver is there (its socket) but wasn't recognised among the processes — then nothing can be
        // told apart, and nothing is ended.
        if !processes.contains(where: \.isServer), WineCommands.isServerRunning(container: container) { return 0 }
        let pids = orphans(in: processes)
        for pid in pids { kill(pid, SIGKILL) }
        return pids.count
    }

    /// Ends every process of the container's Wine session at once, the wineserver included (nothing gets to save).
    @discardableResult
    public static func forceEnd(_ container: Container) -> Int {
        let processes = sessionProcesses(of: container)
        for process in processes where !process.isServer { kill(process.pid, SIGKILL) }
        for process in processes where process.isServer { kill(process.pid, SIGKILL) }
        return processes.count
    }

    /// The path as the kernel reports processes' folders (`/private/tmp/…`). Foundation's own resolving turns
    /// `/private/tmp` back into `/tmp`, which never matched.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The first argument that looks like a Windows program path (Wine puts it after the loader).
    static func windowsExecutable(in arguments: [String]) -> String? {
        for argument in arguments {
            let trimmed = argument.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard trimmed.count > 3, trimmed.dropFirst().hasPrefix(":\\"), let range = trimmed.range(of: ".exe", options: [.caseInsensitive]) else { continue }
            return String(trimmed[..<range.upperBound])
        }
        return nil
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// argv of a process (`KERN_PROCARGS2`: argc, executable path, padding, argv…, environment…).
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size && buffer[index] != 0 { index += 1 }     // executable path
        while index < size && buffer[index] == 0 { index += 1 }     // padding
        var arguments: [String] = []
        while arguments.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Which library entries these processes belong to.
    public static func runningApps(_ processes: [WineProcess], apps: [AppEntry]) -> [UUID: [pid_t]] {
        var result: [UUID: [pid_t]] = [:]
        for app in apps {
            let mine = processes.filter { $0.containerID == app.containerID && belongs($0, to: app) }
            if !mine.isEmpty { result[app.id] = mine.map(\.pid) }
        }
        return result
    }

    static func belongs(_ process: WineProcess, to app: AppEntry) -> Bool {
        let name = process.executableName
        switch app.kind {
        case .steamClient:
            return name == "steam.exe" || name == "steamwebhelper.exe"
        case .steamGame:
            // Anything started from the game's folder (launchers, the game, helpers) counts.
            guard let path = app.windowsPath?.lowercased(), let slash = path.lastIndex(of: "\\") else { return false }
            let folder = String(path[..<slash])
            return process.folder == folder || process.folder.hasPrefix(folder + "\\")
        case .windowsExecutable:
            guard let path = app.windowsPath?.lowercased() else { return false }
            if process.executable.lowercased() == path { return true }
            if let analyzed = app.analysis?.analyzedExecutable {
                return name == URL(fileURLWithPath: analyzed).lastPathComponent.lowercased()
                    && path.hasPrefix(process.folder)
            }
            return false
        }
    }
}
