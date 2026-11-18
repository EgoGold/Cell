import Foundation

/// Reads an executable and its folder to learn what it needs: graphics API, engine, architecture.
public enum AppAnalyzer {
    /// Bumped when the analyzer learns something that changes engine choices; older analyses are redone.
    /// 2: Unreal version from the build string inside the binary.
    /// 3: whether the manifest declares DPI awareness.
    /// 4: Godot's version and renderer.
    /// 5: Chromium-based helper programs (blurry pages in apps such as QQ Music).
    /// 6: dynamically loaded Source renderers and Unity's Direct3D 11 renderer.
    public static let revision = 6

    /// Resolve against the current prefix. Analysis contains a cache, not a durable installation path.
    public static func executable(for app: AppEntry, in container: Container) -> URL? {
        if let path = app.windowsPath,
           let url = WinePathMapper(prefix: container.prefixURL).unixURL(forWindowsPath: path),
           FileManager.default.fileExists(atPath: url.path) {
            return unrealShippingExecutable(near: url) ?? url
        }
        if let path = app.analysis?.analyzedExecutable, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func needsRefresh(_ app: AppEntry, in container: Container) -> Bool {
        guard let executable = executable(for: app, in: container) else { return false }
        return (app.analysis?.revision ?? 0) < revision || app.analysis?.analyzedExecutable != executable.path
    }

    public static func analyze(executable url: URL) -> AppAnalysis {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent

        // Unreal games often ship a small stub launcher in the root that starts
        // <Project>/Binaries/Win64/<Project>-Win64-Shipping.exe. Analyse the real binary.
        let target = unrealShippingExecutable(near: url) ?? url
        let gameRoot = gameRootDirectory(for: target)

        var analysis = AppAnalysis()
        analysis.revision = revision
        analysis.analyzedExecutable = target.path
        analysis.executableSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value

        let pe = PEFile(url: target)
        if let pe {
            analysis.architecture = pe.architecture
            analysis.isGUI = pe.isGUI || pe.subsystem == 0
            analysis.isDotNet = pe.isDotNet
            analysis.declaresDPIAwareness = pe.declaresDPIAwareness
            for dll in pe.allImports { if let api = GraphicsAPI.from(dllName: dll) { analysis.graphicsAPIs.insert(api) } }
            if pe.imports.contains("mscoree.dll") { analysis.isDotNet = true }
            let strings = pe.versionStrings()
            analysis.productName = strings["ProductName"]
            analysis.companyName = strings["CompanyName"]
            analysis.fileDescription = strings["FileDescription"]
            analysis.fileVersion = strings["ProductVersion"] ?? strings["FileVersion"]
        } else {
            analysis.notes.append("Not a readable Windows executable.")
        }

        // Engine detection.
        detectEngine(executable: target, stub: url, directory: target.deletingLastPathComponent(), root: gameRoot,
                     baseName: baseName, pe: pe, analysis: &analysis)

        // Direct3D 12 Agility SDK folder (Unity 2021+, many D3D12 titles).
        for dir in Set([directory, target.deletingLastPathComponent(), gameRoot]) {
            if fm.fileExists(atPath: dir.appendingPathComponent("D3D12/D3D12Core.dll").path) {
                analysis.hasD3D12AgilitySDK = true
            }
        }

        // Steam app id.
        for dir in [target.deletingLastPathComponent(), directory, gameRoot] {
            let file = dir.appendingPathComponent("steam_appid.txt")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber }
                if !digits.isEmpty { analysis.steamAppID = String(digits); break }
            }
        }
        if analysis.steamAppID == nil { analysis.steamAppID = steamAppIDFromPath(target) }

        analysis.antiCheat = detectAntiCheat(in: [directory, gameRoot, target.deletingLastPathComponent()])
        analysis.chromiumHelpers = chromiumHelpers(in: gameRoot)
        analysis.isInstaller = looksLikeInstaller(name: url.lastPathComponent, description: analysis.fileDescription)

        if analysis.architecture == .x86 {
            analysis.notes.append("32-bit program: D3DMetal is not available for 32-bit executables.")
        }
        if !analysis.antiCheat.isEmpty {
            analysis.notes.append("Uses \(analysis.antiCheat.joined(separator: ", ")). Online modes may refuse to run.")
        }
        return analysis
    }

    // MARK: - Engine

    private static func detectEngine(executable: URL, stub: URL, directory: URL, root: URL, baseName: String,
                                     pe: PEFile?, analysis: inout AppAnalysis) {
        let fm = FileManager.default
        func exists(_ dir: URL, _ path: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(path).path) }

        // Unity
        let unityPlayer = directory.appendingPathComponent("UnityPlayer.dll")
        let dataFolder = directory.appendingPathComponent("\(baseName)_Data")
        if fm.fileExists(atPath: unityPlayer.path) || FileOps.isDirectory(dataFolder) {
            analysis.engine = .unity
            if let player = PEFile(url: unityPlayer) {
                for dll in player.allImports { if let api = GraphicsAPI.from(dllName: dll) { analysis.graphicsAPIs.insert(api) } }
                let strings = player.versionStrings()
                analysis.engineVersion = firstUnityVersion(in: [strings["ProductVersion"], strings["FileVersion"]])
            }
            if analysis.engineVersion == nil {
                let manager = dataFolder.appendingPathComponent("globalgamemanagers")
                if let handle = try? FileHandle(forReadingFrom: manager) {
                    let head = (try? handle.read(upToCount: 512)) ?? Data()
                    try? handle.close()
                    analysis.engineVersion = firstUnityVersion(in: [String(decoding: head.map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)])
                }
            }
            if let info = try? String(contentsOf: dataFolder.appendingPathComponent("app.info"), encoding: .utf8) {
                let lines = info.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
                analysis.unityCompany = lines.first
                analysis.unityProduct = lines.count > 1 ? lines[1] : nil
            }
            if exists(directory, "GameAssembly.dll") { analysis.notes.append("Unity IL2CPP build.") }
            // Modern Unity loads Direct3D at runtime; imports alone often report only opengl32.dll.
            if let version = analysis.engineVersion, LooseVersion(version) >= LooseVersion("5") {
                analysis.graphicsAPIs.insert(.d3d11)
            }
            return
        }

        // Unreal Engine
        let isShipping = executable.lastPathComponent.range(of: "-Win64-Shipping", options: .caseInsensitive) != nil
            || executable.lastPathComponent.range(of: "-WinGDK-Shipping", options: .caseInsensitive) != nil
        if isShipping || exists(root, "Engine/Binaries") || exists(root, "Engine/Plugins") {
            analysis.engine = .unreal
            let fileName = executable.deletingPathExtension().lastPathComponent
            if let range = fileName.range(of: "-Win64", options: .caseInsensitive) ?? fileName.range(of: "-WinGDK", options: .caseInsensitive) {
                analysis.unrealProject = String(fileName[..<range.lowerBound])
            } else {
                analysis.unrealProject = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            }
            let version = [analysis.fileVersion, pe?.versionStrings()["ProductVersion"]].compactMap { $0 }.joined(separator: " ")
            if let match = version.range(of: #"(?:Release-|UE)(\d)\.?(\d+)?"#, options: .regularExpression) {
                let digits = version[match].filter { $0.isNumber || $0 == "." }
                analysis.engineVersion = digits.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else if version.contains("UE5") || version.contains("++UE5") {
                analysis.engineVersion = "5"
            } else if version.contains("UE4") {
                analysis.engineVersion = "4"
            }
            // Many games leave the engine out of their version resource; the build string is in the binary
            // ("++UE4+Release-4.26", stored as UTF-16).
            if analysis.engineVersion == nil {
                if FileOps.fileContains(executable, token: "++UE5+", includeUTF16: true) {
                    analysis.engineVersion = "5"
                } else if FileOps.fileContains(executable, token: "++UE4+", includeUTF16: true) {
                    analysis.engineVersion = "4"
                }
            }
            // Unreal loads its RHI dynamically: look for the Direct3D 12 RHI inside the binary.
            if FileOps.fileContains(executable, token: "d3d12.dll", includeUTF16: true) || FileOps.fileContains(executable, token: "D3D12RHI", includeUTF16: true) {
                analysis.graphicsAPIs.insert(.d3d12)
            }
            if FileOps.fileContains(executable, token: "d3d11.dll", includeUTF16: true) { analysis.graphicsAPIs.insert(.d3d11) }
            return
        }

        if exists(directory, "data.win") { analysis.engine = .gameMaker; return }
        if exists(directory, "\(baseName).pck") {
            analysis.engine = .godot
            describeGodot(version: godotVersion(pack: directory.appendingPathComponent("\(baseName).pck"), embedded: false), analysis: &analysis)
            return
        }
        if exists(directory, "game/bin/win64/engine2.dll") || exists(directory, "engine2.dll") { analysis.engine = .source2; return }
        if exists(directory, "bin/engine.dll") {
            analysis.engine = .source
            // Source's launcher imports no renderer. The engine loads these modules dynamically.
            for (module, api) in [("shaderapidx9.dll", GraphicsAPI.d3d9), ("shaderapidx11.dll", .d3d11),
                                  ("shaderapivulkan.dll", .vulkan)] where exists(directory, "bin/\(module)") {
                analysis.graphicsAPIs.insert(api)
            }
            return
        }
        if exists(directory, "Game.rgss3a") || exists(directory, "Game.rgss2a") || exists(directory, "Game.rgssad")
            || exists(directory, "www/js/rpg_core.js") || exists(directory, "js/rmmz_core.js") { analysis.engine = .rpgMaker; return }
        if exists(directory, "renpy") { analysis.engine = .renpy; return }
        if exists(directory, "FNA.dll") { analysis.engine = .fna; return }
        if exists(directory, "MonoGame.Framework.dll") { analysis.engine = .monoGame; return }
        if exists(directory, "Microsoft.Xna.Framework.dll") || exists(directory, "Microsoft.Xna.Framework.Game.dll") { analysis.engine = .xna; return }
        if exists(directory, "resources/app.asar") || exists(directory, "resources/electron.asar") { analysis.engine = .electron; return }
        if exists(directory, "libcef.dll") { analysis.engine = .cef; return }
        if exists(directory, "jre") || exists(directory, "runtime/bin/java.exe") || (pe?.allImports.contains("jvm.dll") ?? false) {
            analysis.engine = .java; return
        }
        // Godot executables can embed their .pck; look for the signature in the last 64 KB.
        if let handle = try? FileHandle(forReadingFrom: executable) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > 65_536 {
                try? handle.seek(toOffset: size - 65_536)
                if let tail = try? handle.read(upToCount: 65_536), tail.range(of: Data("GDPC".utf8)) != nil {
                    analysis.engine = .godot
                    describeGodot(version: godotVersion(pack: executable, embedded: true), analysis: &analysis)
                }
            }
        }
    }

    /// Godot's pack header: "GDPC", format, then the engine's major, minor and patch version. A pack embedded in
    /// the executable ends with its size and "GDPC".
    static func godotVersion(pack: URL, embedded: Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: pack) else { return nil }
        defer { try? handle.close() }
        var start: UInt64 = 0
        if embedded {
            guard let size = try? handle.seekToEnd(), size > 12 else { return nil }
            try? handle.seek(toOffset: size - 12)
            guard let trailer = try? handle.read(upToCount: 12), trailer.count == 12, trailer.suffix(4) == Data("GDPC".utf8) else { return nil }
            let packSize = trailer.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            guard packSize > 0, packSize < size - 12 else { return nil }
            start = size - 12 - packSize
        }
        try? handle.seek(toOffset: start)
        guard let header = try? handle.read(upToCount: 20), header.count == 20, header.prefix(4) == Data("GDPC".utf8) else { return nil }
        let numbers = (1...4).map { index in header.subdata(in: (index * 4)..<(index * 4 + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        guard numbers[1] >= 2, numbers[1] <= 9, numbers[2] < 100, numbers[3] < 100 else { return nil }
        return "\(numbers[1]).\(numbers[2]).\(numbers[3])"
    }

    /// Godot 4 draws with Vulkan (MoltenVK on a Mac) or Direct3D 12; Godot 3 with OpenGL.
    static func describeGodot(version: String?, analysis: inout AppAnalysis) {
        analysis.engineVersion = version
        guard let major = version?.split(separator: ".").first.flatMap({ Int($0) }) else { return }
        if major >= 4 {
            // Vulkan is Godot 4's default on Windows (it falls back to it from Direct3D 12 too).
            analysis.graphicsAPIs.insert(.vulkan)
            analysis.notes.append("Godot \(version!): draws with Vulkan (through MoltenVK). Text in other languages uses your Mac's fonts.")
        } else {
            analysis.graphicsAPIs.insert(.opengl)
            analysis.notes.append("Godot \(version!): draws with OpenGL.")
        }
    }

    /// Programs that ship Chromium (a folder with `icudtl.dat`): CEF and Electron browsers and launchers. Looks a few
    /// folders deep and stops early in very large game folders.
    static func chromiumHelpers(in root: URL, maxDepth: Int = 3) -> [String] {
        let fm = FileManager.default
        var helpers: [String] = []
        var visited = 0
        func walk(_ folder: URL, depth: Int) {
            guard depth <= maxDepth, visited < 3000,
                  let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            visited += items.count
            let names = Set(items.map { $0.lastPathComponent.lowercased() })
            if names.contains("icudtl.dat"), names.contains(where: { $0.hasSuffix(".pak") }) {
                let crashReporters = ["bugreport.exe", "crashpad_handler.exe", "crashreporter.exe", "unitycrashhandler64.exe"]
                helpers += items.map(\.lastPathComponent).filter { $0.lowercased().hasSuffix(".exe") && !crashReporters.contains($0.lowercased()) }
            }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walk(item, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return Array(Set(helpers)).sorted()
    }

    private static func firstUnityVersion(in candidates: [String?]) -> String? {
        for candidate in candidates.compactMap({ $0 }) {
            if let range = candidate.range(of: #"\d{4}\.\d+\.\d+[abfpx]?\d*"#, options: .regularExpression) {
                return String(candidate[range])
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// `<root>/<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe` next to a stub launcher.
    public static func unrealShippingExecutable(near stub: URL) -> URL? {
        let name = stub.lastPathComponent.lowercased()
        if name.contains("-shipping") { return nil }
        let root = stub.deletingLastPathComponent()
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for child in children where FileOps.isDirectory(child) {
            let binaries = child.appendingPathComponent("Binaries/Win64", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: binaries.path) else { continue }
            if let shipping = files.first(where: { $0.lowercased().hasSuffix("-win64-shipping.exe") }) {
                return binaries.appendingPathComponent(shipping)
            }
        }
        return nil
    }

    /// The folder that contains the whole game (handles Unreal's nested Binaries/Win64).
    public static func gameRootDirectory(for executable: URL) -> URL {
        let directory = executable.deletingLastPathComponent()
        let components = directory.pathComponents.map { $0.lowercased() }
        if components.count >= 3, components[components.count - 2] == "binaries" {
            // <root>/<Project>/Binaries/Win64 -> <root>
            return directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return directory
    }

    public static func steamAppIDFromPath(_ url: URL) -> String? {
        // .../steamapps/common/<installdir>/... -> look up appmanifest by installdir.
        let components = url.pathComponents
        guard let commonIndex = components.lastIndex(where: { $0.lowercased() == "common" }), commonIndex >= 1,
              components[commonIndex - 1].lowercased() == "steamapps", commonIndex + 1 < components.count else { return nil }
        let installDir = components[commonIndex + 1]
        let steamapps = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...(commonIndex - 1)])))
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: steamapps.path) else { return nil }
        for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
            guard let node = VDFNode.parse(contentsOf: steamapps.appendingPathComponent(file)),
                  let state = node["AppState"] ?? node.children.first?.value,
                  state["installdir"]?.string?.caseInsensitiveCompare(installDir) == .orderedSame else { continue }
            return state["appid"]?.string
        }
        return nil
    }

    public static func detectAntiCheat(in directories: [URL]) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for dir in Set(directories) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let lower = items.map { $0.lowercased() }
            if lower.contains(where: { $0 == "easyanticheat" || $0.hasPrefix("easyanticheat") || $0 == "start_protected_game.exe" }) {
                found.append("Easy Anti-Cheat")
            }
            if lower.contains(where: { $0 == "battleye" || $0.hasPrefix("beservice") }) { found.append("BattlEye") }
            if lower.contains(where: { $0.hasPrefix("equ8") }) { found.append("EQU8") }
            if lower.contains(where: { $0.hasPrefix("xigncode") }) { found.append("XIGNCODE3") }
        }
        return Array(Set(found)).sorted()
    }

    public static func looksLikeInstaller(name: String, description: String?) -> Bool {
        // Split CamelCase so "SteamSetup.exe" reads as "steam setup.exe".
        var spaced = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        let lower = spaced.lowercased()
        let pattern = #"(^|[^a-z])(setup|install|installer|unins\d*|uninstall|vc_?redist|dxsetup|dotnetfx|ndp\d+)([^a-z]|$)"#
        if lower.range(of: pattern, options: .regularExpression) != nil { return true }
        if lower.hasSuffix(".msi") { return true }
        if let description = description?.lowercased(),
           description.contains("setup") || description.contains("installer") || description.contains("uninstall") {
            return true
        }
        return false
    }
}
