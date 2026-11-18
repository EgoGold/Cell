import Foundation

/// A whole operating system Cell can run in a virtual machine (Apple's Virtualization framework).
/// Cell doesn't ship any system: you bring the installer image (ISO, IPSW, disk image) yourself.
public enum GuestSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case linux, macOS, windows, android

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .android: return "Android"
        }
    }

    public var symbol: String {
        switch self {
        case .linux: return "terminal"
        case .macOS: return "apple.logo"
        case .windows: return "pc"
        case .android: return "apps.iphone"
        }
    }

    public enum Support: Equatable, Sendable {
        case ready
        case experimental(String)
        case unavailable(String)

        public var canCreate: Bool { if case .unavailable = self { return false }; return true }
    }

    public var support: Support {
        switch self {
        case .linux:
            return .ready
        case .macOS:
            return .ready
        case .windows:
            return .experimental("Windows 11 on Arm starts from your own ISO, but Apple's virtual hardware has no TPM and Windows lacks drivers for its network and graphics, so setup needs workarounds and the picture is basic.")
        case .android:
            return .experimental("Needs an Arm64 Android build that starts with UEFI (such as an AOSP image made for virtual machines).")
        }
    }

    /// Installer images accepted for this system (file extensions, lower case).
    public var installerTypes: [String] {
        switch self {
        case .macOS: return ["ipsw"]
        case .linux, .windows, .android: return ["iso", "img", "raw"]
        }
    }

    public var installerHint: String {
        switch self {
        case .linux: return "An Arm64 (aarch64) installer ISO — Ubuntu, Fedora, Debian, Alpine and others."
        case .macOS: return "A macOS restore image (.ipsw) for Apple silicon, from Apple."
        case .windows: return "A Windows 11 on Arm installer ISO."
        case .android: return "An Arm64 Android image that starts with UEFI."
        }
    }

    /// Reasonable starting sizes.
    public var defaultMemoryMiB: Int { self == .macOS || self == .windows ? 8192 : 4096 }
    public var defaultDiskGiB: Int { self == .macOS || self == .windows ? 80 : 40 }
}

/// A virtual machine: a `.cellvm` folder holding its settings, disk, firmware state and installer image.
/// The folder is self-contained, so it can be moved to another Mac or imported back into Cell.
public struct VirtualMachine: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var guest: GuestSystem
    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskGiB: Int
    public var createdAt: Date
    /// File name of the installer image inside the bundle; nil once it was removed.
    public var installMedia: String?
    /// The system is installed (macOS: Apple's installer finished; others: the installer was removed).
    public var isInstalled: Bool
    public var displayWidth: Int
    public var displayHeight: Int
    /// Experimental: the display the machine's window opens on; its screen takes that display's resolution.
    public var displayID: String?
    /// Advanced: start a Linux kernel directly (file names inside the bundle) instead of UEFI.
    public var kernel: String?
    public var initialRamdisk: String?
    public var kernelCommandLine: String?

    public init(id: UUID = UUID(), name: String, guest: GuestSystem, cpuCount: Int? = nil, memoryMiB: Int? = nil,
                diskGiB: Int? = nil, installMedia: String? = nil) {
        self.id = id
        self.name = name
        self.guest = guest
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.cpuCount = cpuCount ?? max(2, min(cores / 2, 8))
        self.memoryMiB = memoryMiB ?? guest.defaultMemoryMiB
        self.diskGiB = diskGiB ?? guest.defaultDiskGiB
        self.createdAt = Date()
        self.installMedia = installMedia
        self.isInstalled = false
        self.displayWidth = 1920
        self.displayHeight = 1200
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = c.value(.name, default: "Virtual Machine")
        guest = c.value(.guest, default: .linux)
        cpuCount = c.value(.cpuCount, default: 4)
        memoryMiB = c.value(.memoryMiB, default: 4096)
        diskGiB = c.value(.diskGiB, default: 40)
        createdAt = c.value(.createdAt, default: Date())
        installMedia = c.value(.installMedia, default: nil)
        isInstalled = c.value(.isInstalled, default: false)
        displayWidth = c.value(.displayWidth, default: 1920)
        displayHeight = c.value(.displayHeight, default: 1200)
        displayID = c.value(.displayID, default: nil)
        kernel = c.value(.kernel, default: nil)
        initialRamdisk = c.value(.initialRamdisk, default: nil)
        kernelCommandLine = c.value(.kernelCommandLine, default: nil)
    }

    public var bundle: URL {
        let bundle = CellPaths.virtualMachines.appendingPathComponent("\(id.uuidString).cellvm", isDirectory: true)
        // Machines made before Cell was renamed keep their ".chambervm" folder.
        let legacy = CellPaths.virtualMachines.appendingPathComponent("\(id.uuidString).chambervm", isDirectory: true)
        return !FileManager.default.fileExists(atPath: bundle.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : bundle
    }
    public var metadataURL: URL { bundle.appendingPathComponent("vm.json") }
    public var diskURL: URL { bundle.appendingPathComponent("Disk.img") }
    public var efiVariablesURL: URL { bundle.appendingPathComponent("EFI.nvram") }
    public var machineIdentifierURL: URL { bundle.appendingPathComponent("MachineIdentifier") }
    public var hardwareModelURL: URL { bundle.appendingPathComponent("HardwareModel") }
    public var auxiliaryStorageURL: URL { bundle.appendingPathComponent("AuxiliaryStorage") }
    public var consoleLogURL: URL { bundle.appendingPathComponent("console.log") }
    public var mediaURL: URL? { installMedia.map { bundle.appendingPathComponent($0) } }
    public var kernelURL: URL? { kernel.map { bundle.appendingPathComponent($0) } }
    public var initialRamdiskURL: URL? { initialRamdisk.map { bundle.appendingPathComponent($0) } }

    /// What the machine will do when started.
    public var nextStartSummary: String {
        if guest == .macOS { return isInstalled ? "Starts macOS" : "Installs macOS from the restore image" }
        if kernel != nil { return "Starts the Linux kernel directly" }
        if !isInstalled, installMedia != nil { return "Starts the installer" }
        return "Starts from its disk"
    }
}

public enum VirtualMachineError: LocalizedError {
    case unsupported(String)
    case notFound
    case missingInstaller
    case wrongInstaller(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return detail
        case .notFound: return "The virtual machine no longer exists."
        case .missingInstaller: return "Choose an installer image first. Cell doesn't include operating systems: bring your own."
        case .wrongInstaller(let detail): return detail
        }
    }
}

/// The virtual machines in `~/Library/Application Support/Cell/Virtual Machines`.
public final class VirtualMachineLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VirtualMachine] = []

    public init() { reload() }

    public var machines: [VirtualMachine] { lock.withLock { stored } }

    public func machine(id: UUID) -> VirtualMachine? { machines.first { $0.id == id } }

    public func reload() {
        let fm = FileManager.default
        let bundles = (try? fm.contentsOfDirectory(at: CellPaths.virtualMachines, includingPropertiesForKeys: nil)) ?? []
        let loaded = bundles.filter { $0.pathExtension == "cellvm" || $0.pathExtension == "chambervm" }
            .compactMap { JSONStore.loadIfPresent(VirtualMachine.self, from: $0.appendingPathComponent("vm.json")) }
            .sorted { $0.createdAt < $1.createdAt }
        lock.withLock { stored = loaded }
    }

    public func save(_ machine: VirtualMachine) throws {
        try FileManager.default.createDirectory(at: machine.bundle, withIntermediateDirectories: true)
        try JSONStore.save(machine, to: machine.metadataURL)
        reload()
    }

    /// Creates a machine with an empty disk (it only takes space as the system writes to it) and the
    /// installer image cloned into its folder (instant on APFS, no extra space).
    @discardableResult
    public func create(name: String, guest: GuestSystem, installer: URL?, cpuCount: Int? = nil,
                       memoryMiB: Int? = nil, diskGiB: Int? = nil) throws -> VirtualMachine {
        guard guest.support.canCreate else {
            if case .unavailable(let reason) = guest.support { throw VirtualMachineError.unsupported(reason) }
            throw VirtualMachineError.unsupported("\(guest.displayName) can't run in a virtual machine.")
        }
        if let installer {
            let type = installer.pathExtension.lowercased()
            guard guest.installerTypes.contains(type) else {
                throw VirtualMachineError.wrongInstaller("\(guest.displayName) needs \(guest.installerHint.lowercased())")
            }
        } else if guest == .macOS {
            throw VirtualMachineError.missingInstaller
        }
        var machine = VirtualMachine(name: name, guest: guest, cpuCount: cpuCount, memoryMiB: memoryMiB, diskGiB: diskGiB)
        let fm = FileManager.default
        try fm.createDirectory(at: machine.bundle, withIntermediateDirectories: true)
        do {
            if let installer {
                let name = "Installer." + installer.pathExtension.lowercased()
                try FileOps.cloneItem(at: installer, to: machine.bundle.appendingPathComponent(name))
                machine.installMedia = name
            }
            try Self.createDisk(at: machine.diskURL, gibibytes: machine.diskGiB)
            try JSONStore.save(machine, to: machine.metadataURL)
        } catch {
            try? fm.removeItem(at: machine.bundle)
            throw error
        }
        reload()
        return machine
    }

    /// A sparse raw disk image: it takes space only as the guest writes data.
    static func createDisk(at url: URL, gibibytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(gibibytes) << 30)
    }

    /// Adds a `.cellvm` folder made elsewhere (another Mac, a backup) to the library.
    @discardableResult
    public func importBundle(_ url: URL) throws -> VirtualMachine {
        guard var machine = JSONStore.loadIfPresent(VirtualMachine.self, from: url.appendingPathComponent("vm.json")) else {
            throw VirtualMachineError.wrongInstaller("That folder isn't a Cell virtual machine (no vm.json inside).")
        }
        if self.machine(id: machine.id) != nil { machine.id = UUID() }
        let target = machine.bundle
        try FileOps.cloneItem(at: url, to: target)
        try JSONStore.save(machine, to: machine.metadataURL)
        reload()
        return machine
    }

    /// Marks the system as installed and removes the installer image (frees its space if it was copied).
    public func finishInstallation(_ machine: VirtualMachine) throws {
        var updated = machine
        if let media = machine.mediaURL { try? FileManager.default.removeItem(at: media) }
        updated.installMedia = nil
        updated.isInstalled = true
        try save(updated)
    }

    public func delete(_ machine: VirtualMachine) throws {
        try FileManager.default.trashItem(at: machine.bundle, resultingItemURL: nil)
        reload()
    }
}
