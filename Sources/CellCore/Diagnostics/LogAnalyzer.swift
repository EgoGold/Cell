import Foundation

public struct DiagnosticFinding: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable, Comparable {
        case info, warning, error
        private var rank: Int { self == .info ? 0 : (self == .warning ? 1 : 2) }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }
    public var id: String { ruleID }
    public var ruleID: String
    public var severity: Severity
    public var title: String
    public var advice: String?
    public var source: String
    public var excerpt: String?
}

/// Reads Wine launch logs and game logs (e.g. Unity's Player.log) and explains known problems.
public enum LogAnalyzer {
    private static let unityDirectoryFailure = DiagnosticRule(
        id: "unity.directory-startup", log: "{unityPlayerLog}",
        pattern: #"(?m)^\[SceneFlow\] \[FATAL\][^\r\n]*System\.IO\.IOException[^\r\n]*\r?\n\s*at System\.IO\.LongDirectory\+<EnumerateFileSystemIterator(?:Recursive)?>[^\r\n]*\.MoveNext"#,
        severity: "error", title: "The game failed while reading its data folders",
        advice: "Wine 10 can report a wrong end-of-directory result to Unity Mono. Wine 11 fixes that file operation. If you are on Wine 10, test this game in a separate Wine 11 layer; this does not guarantee that the rest of startup will succeed."
    )

    public static let builtinRules: [DiagnosticRule] = [
        DiagnosticRule(id: "wine.missing-dll", log: "wine", pattern: #"err:module:import_dll (?:Library|Loading library) ([\w.-]+\.dll)"#,
                       severity: "error", title: "A required Windows library is missing",
                       advice: "Install the game's redistributables (Visual C++, DirectX, .NET) from its installer folder, or add a plugin that ships the DLL."),
        DiagnosticRule(id: "wine.page-fault", log: "wine", pattern: #"Unhandled (?:page fault|exception)"#,
                       severity: "error", title: "The program crashed",
                       advice: "Cell will try another graphics engine automatically. If it keeps crashing, check the game's plugins."),
        DiagnosticRule(id: "wine.no-display", log: "wine", pattern: #"Application tried to create a window, but no driver could be loaded"#,
                       severity: "error", title: "Wine could not open a window", advice: "Reinstall or switch the container's Wine engine."),
        DiagnosticRule(id: "wine.rosetta", log: "wine", pattern: #"Bad CPU type in executable|Rosetta"#,
                       severity: "error", title: "Rosetta 2 is needed",
                       advice: "Install Rosetta: softwareupdate --install-rosetta --agree-to-license"),
        DiagnosticRule(id: LogAnalyzer.dotNetGap, log: "wine",
                       pattern: #"(?:Unhandled Exception|FATAL UNHANDLED EXCEPTION)[\s\S]{0,400}?(?:MissingMethodException|MissingMemberException|MissingFieldException|TypeLoadException|NotImplementedException|EntryPointNotFoundException)"#,
                       severity: "error", title: "This .NET program needs Microsoft's .NET Framework",
                       advice: "Wine's built-in .NET (Wine Mono) lacks something it uses. Install .NET Framework 4.8 in the container (Settings) and start it again. Changing the graphics engine doesn't help."),
        DiagnosticRule(id: "wine.mono", log: "wine", pattern: #"err:mscoree.*(?:mono|Wine Mono)"#,
                       severity: "warning", title: ".NET support (Wine Mono) is missing", advice: "Use an engine that bundles wine-mono, such as the Gcenx builds."),
        DiagnosticRule(id: "dxmt.unsupported", log: "wine", pattern: #"(?i)dxmt.*(?:unsupported|not implemented)"#,
                       severity: "warning", title: "DXMT reported an unsupported feature", advice: "Try D3DMetal for this game."),
        DiagnosticRule(id: "unity.fence", log: "{unityPlayerLog}", pattern: #"Failed to create ID3D11Fence"#,
                       severity: "info", title: "Direct3D 11 fences are unavailable (harmless)", advice: nil),
        DiagnosticRule(id: "unity.udp-refused", log: "{unityPlayerLog}", pattern: #"SocketErrorCode: (?:10061|ConnectionRefused)"#,
                       severity: "warning", title: "UDP connections are being refused",
                       advice: "Open Network in Cell: allow incoming connections for Wine and test your NAT type. Games usually fall back to slower relays."),
        DiagnosticRule(id: "unity.steam-ticket", log: "{unityPlayerLog}", pattern: #"Encrypted App Ticket|error response from Steam"#,
                       severity: "warning", title: "Steam authentication for multiplayer failed",
                       advice: "Restart Steam from Cell (Container ▸ Steam ▸ Restart) and launch the game from Cell so it starts with Steam's ticket service ready."),
        DiagnosticRule(id: "unity.input", log: "{unityPlayerLog}", pattern: #"EnableMouseInPointer|Pointer input"#,
                       severity: "warning", title: "The game uses Windows pointer input",
                       advice: "Some Wine versions don't deliver pointer (mouse) input to Unity's new input system. Try a newer Wine engine."),
        unityDirectoryFailure,
    ]

    /// A .NET program hit something Wine Mono doesn't have: not a graphics problem.
    public static let dotNetGap = "dotnet.mono-gap"

    /// Steam can start Unity without a long-lived Cell launch session. Read its recent Player.log while
    /// inspecting the game, rather than interpreting the Steam handoff as a successful startup.
    public static func recentUnityDirectoryFailure(for app: AppEntry, in container: Container) -> DiagnosticFinding? {
        let context = PathTemplateContext(container: container, app: app)
        let path = context.expand("{unityPlayerLog}") ?? (app.steamAppID == "949230"
            ? context.expand("{localLow}/Colossal Order/Cities Skylines II/Player.log") : nil)
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        let recent = Date().addingTimeInterval(-3600)
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date.timeIntervalSince(max(app.lastPlayedAt ?? recent, recent)) >= -1,
              let log = tail(of: url, bytes: 2_000_000) else { return nil }
        return analyze(text: log, rules: [unityDirectoryFailure], source: url.lastPathComponent).first
    }

    /// Read Steam's separate log even after Cell's short-lived launch handoff has exited.
    public static func steamLauncherFailure(for app: AppEntry, in container: Container) -> DiagnosticFinding? {
        guard app.kind == .steamGame, let appID = app.steamAppID,
              let steam = SteamIntegration.steamDirectory(in: container),
              let log = tail(of: steam.appendingPathComponent("logs/gameprocess_log.txt"), bytes: 256_000) else { return nil }
        let recent = Date().addingTimeInterval(-3600)
        return steamLauncherFailure(in: log, appID: appID, since: max(app.lastPlayedAt ?? recent, recent))
    }

    /// Keep the URI payload out of diagnostics because it can contain sign-in tokens.
    static func steamLauncherFailure(in log: String, appID: String, since: Date) -> DiagnosticFinding? {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let start = " Failed running GameID \(appID): "
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for line in log.split(whereSeparator: \.isNewline).reversed() {
            guard line.first == "[", let timestampEnd = line.firstIndex(of: "]"),
                  let range = line[line.index(after: timestampEnd)...].range(of: start, options: .anchored),
                  let timestamp = date.date(from: String(line[line.index(after: line.startIndex)..<timestampEnd])),
                  timestamp.timeIntervalSince(since) >= -1 else { continue }
            let command = line[range.upperBound...].drop(while: { $0 == "\"" })
            guard let separator = command.range(of: "://") else { return nil }
            let scheme = command[..<separator.lowerBound].lowercased()
            guard scheme.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: .regularExpression) != nil else { return nil }
            let isEA = scheme == "steam2ea" || scheme == "link2ea"
            return DiagnosticFinding(ruleID: "steam.launcher-handoff", severity: .error,
                                     title: isEA ? "Steam could not open the EA app" : "Steam could not open the publisher’s launcher",
                                     advice: isEA ? "Check whether the EA app installed successfully in this container. If setup rolled back, its Windows link handler is missing." : "Check whether the launcher installed successfully and registered its Windows link handler in this container.",
                                     source: "gameprocess_log.txt", excerpt: nil)
        }
        return nil
    }

    public static func analyze(text: String, rules: [DiagnosticRule], source: String) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        let range = NSRange(text.startIndex..., in: text)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern),
                  let match = regex.firstMatch(in: text, range: range) else { continue }
            var excerpt: String?
            if let matchRange = Range(match.range, in: text) {
                let lineStart = text[..<matchRange.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let lineEnd = text[matchRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
                excerpt = String(text[lineStart..<lineEnd].prefix(300))
            }
            let severity = DiagnosticFinding.Severity(rawValue: rule.severity ?? "warning") ?? .warning
            findings.append(DiagnosticFinding(ruleID: rule.id, severity: severity, title: rule.title, advice: rule.advice,
                                              source: source, excerpt: excerpt))
        }
        return findings.sorted { $0.severity > $1.severity }
    }

    /// Reads the launch log and any game logs referenced by rules.
    public static func analyze(launchLog: URL?, context: PathTemplateContext, extraRules: [DiagnosticRule]) -> [DiagnosticFinding] {
        let rules = builtinRules + extraRules
        var findings: [DiagnosticFinding] = []
        var groups: [String: [DiagnosticRule]] = [:]
        for rule in rules { groups[rule.log, default: []].append(rule) }
        for (log, group) in groups {
            let url: URL?
            if log == "wine" { url = launchLog } else { url = context.expand(log).map { URL(fileURLWithPath: $0) } }
            guard let url, let text = tail(of: url, bytes: 2_000_000) else { continue }
            findings += analyze(text: text, rules: group, source: log == "wine" ? "Launch log" : url.lastPathComponent)
        }
        var seen = Set<String>()
        return findings.filter { seen.insert($0.ruleID).inserted }.sorted { $0.severity > $1.severity }
    }

    static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(bytes) { try? handle.seek(toOffset: size - UInt64(bytes)) } else { try? handle.seek(toOffset: 0) }
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
