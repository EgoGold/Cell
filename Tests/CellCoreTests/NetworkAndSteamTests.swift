import XCTest
@testable import CellCore

final class SteamLauncherDiagnosticsTests: XCTestCase {
    func testManagedDirectoryDiagnosticRequiresTheFatalEnumerationStack() {
        let stack = "System.IO.IOException\r\n  at System.IO.LongDirectory+<EnumerateFileSystemIterator>d__15.MoveNext () [0x00165]"
        let detect: (String) -> Bool = { text in
            LogAnalyzer.analyze(text: text, rules: LogAnalyzer.builtinRules, source: "Player.log")
                .contains(where: { $0.id == "unity.directory-startup" })
        }
        XCTAssertTrue(detect("[SceneFlow] [FATAL]   " + stack))
        XCTAssertFalse(detect("[Steamworks] [ERROR]   " + stack))
        XCTAssertFalse(detect("[SceneFlow] [FATAL]   System.IO.IOException\n  at System.IO.FileStream.Read ()"))
    }

    func testRecentPublisherHandoffFailureIsScopedAndRedacted() {
        let log = """
        [2026-11-15 16:48:53] Failed running GameID 1222670: ""steam2ea://launchgame/1222670?token=private"" (OS Error 0)
        [2026-11-15 16:48:54] Failed running GameID 3404470: "C:\\Games\\AnimalSpa.exe" (OS Error 8)
        """
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let since = date.date(from: "2026-11-15 16:48:52")!
        let finding = LogAnalyzer.steamLauncherFailure(in: log, appID: "1222670", since: since)
        XCTAssertEqual(finding?.title, "Steam could not open the EA app")
        XCTAssertNil(finding?.excerpt)
        XCTAssertNil(LogAnalyzer.steamLauncherFailure(in: log, appID: "3404470", since: since))
        XCTAssertNil(LogAnalyzer.steamLauncherFailure(in: log, appID: "1222670", since: since.addingTimeInterval(10)))
    }
}

/// Downloads from several servers at once.
final class MultiSourceDownloadTests: XCTestCase {
    private func payload(megabytes: Int, seed: UInt32 = 0x1234_5678) -> Data {
        var data = Data(count: megabytes * 1024 * 1024)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt32.self)
            var state = seed
            for index in words.indices {
                state = state &* 1_664_525 &+ 1_013_904_223
                words[index] = state
            }
        }
        return data
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cell-ms-\(UUID().uuidString).bin")
    }

    private func mirror(_ server: RangeServer, connections: Int = 4) -> DownloadSource {
        DownloadSource(url: server.url, maxConnections: connections, isMirror: true)
    }

    func testEveryServerContributes() async throws {
        let data = payload(megabytes: 24)
        let first = try RangeServer(payload: data, chunkDelay: 20_000)
        let second = try RangeServer(payload: data, chunkDelay: 20_000)
        let manager = DownloadManager()
        manager.connectionsPerDownload = 8
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let result = try await manager.download(sources: [DownloadSource(url: first.url), mirror(second)], to: target,
                                                title: "two servers", sha256: DownloadManagerTestsHelper.sha256(data))
        XCTAssertEqual(try Data(contentsOf: result), data)
        XCTAssertGreaterThan(first.bytesSent, 1024 * 1024, "the official server sent part of the file")
        XCTAssertGreaterThan(second.bytesSent, 1024 * 1024, "the mirror sent part of the file")
    }

    func testFastServerDoesMostOfTheWork() async throws {
        let data = payload(megabytes: 32)
        let slow = try RangeServer(payload: data, chunkDelay: 60_000)   // ~1 MB/s per connection
        let fast = try RangeServer(payload: data, chunkDelay: 500)      // ~100 MB/s per connection
        let manager = DownloadManager()
        manager.connectionsPerDownload = 8
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let started = Date()
        let result = try await manager.download(sources: [DownloadSource(url: slow.url), mirror(fast, connections: 8)], to: target,
                                                title: "slow and fast", sha256: DownloadManagerTestsHelper.sha256(data))
        XCTAssertEqual(try Data(contentsOf: result), data)
        XCTAssertGreaterThan(fast.bytesSent, slow.bytesSent * 3, "the fast server should carry most of the file")
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "the slow server must not hold the download back")
    }

    func testMirrorWithAnotherFileIsIgnored() async throws {
        let data = payload(megabytes: 8)
        let official = try RangeServer(payload: data, chunkDelay: 300)
        let wrong = try RangeServer(payload: payload(megabytes: 9, seed: 99))
        let manager = DownloadManager()
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let result = try await manager.download(sources: [DownloadSource(url: official.url), mirror(wrong)], to: target,
                                                title: "size check", sha256: DownloadManagerTestsHelper.sha256(data))
        XCTAssertEqual(try Data(contentsOf: result), data)
        XCTAssertLessThanOrEqual(wrong.bytesSent, 1, "a server with a different file only answers the 1-byte probe")
    }

    func testCorruptMirrorFallsBackToTheOfficialServer() async throws {
        let data = payload(megabytes: 6)
        let official = try RangeServer(payload: data, chunkDelay: 3000)
        let bad = try RangeServer(payload: data)
        bad.corrupt = true
        let manager = DownloadManager()
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let result = try await manager.download(sources: [DownloadSource(url: official.url), mirror(bad, connections: 8)], to: target,
                                                title: "corrupt mirror", sha256: DownloadManagerTestsHelper.sha256(data))
        XCTAssertEqual(try Data(contentsOf: result), data, "the checksum catches the mirror and the official server finishes the job")
        XCTAssertGreaterThan(bad.bytesSent, 0)
    }

    func testRateLimitedServerIsRested() async throws {
        let data = payload(megabytes: 8)
        let limited = try RangeServer(payload: data)
        limited.rateLimit = true
        let good = try RangeServer(payload: data, chunkDelay: 300)
        let manager = DownloadManager()
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let result = try await manager.download(sources: [DownloadSource(url: limited.url), DownloadSource(url: good.url)], to: target,
                                                title: "429", sha256: DownloadManagerTestsHelper.sha256(data))
        XCTAssertEqual(try Data(contentsOf: result), data)
        XCTAssertLessThanOrEqual(limited.bytesSent, 1, "only the 1-byte probe got through")
    }

    func testMirrorsNeedAChecksum() async throws {
        let data = payload(megabytes: 4)
        let official = try RangeServer(payload: data)
        let unverified = try RangeServer(payload: data)
        let manager = DownloadManager()
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        _ = try await manager.download(sources: [DownloadSource(url: official.url), mirror(unverified)], to: target, title: "no checksum")
        XCTAssertEqual(unverified.rangeRequests, 0, "without a checksum a mirror is never asked")
        XCTAssertEqual(manager.snapshots().first?.sources.count, 1)
    }

    func testGitHubMirrorsNeedAChecksum() async {
        let url = URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!
        let asset = DownloadMirrors.GitHubAsset(url)
        XCTAssertEqual(asset?.owner, "3Shain")
        XCTAssertEqual(asset?.tag, "v0.80")
        XCTAssertEqual(asset?.name, "dxmt-v0.80-builtin.tar.gz")
        XCTAssertNil(DownloadMirrors.GitHubAsset(URL(string: "https://github.com/3Shain/dxmt")!))

        let plan = await DownloadMirrors.plan(for: url, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(plan.sources.first?.url, url, "the official server stays first")
        XCTAssertEqual(plan.sources.filter(\.isMirror).count, DownloadMirrors.githubProxies.count)
        XCTAssertTrue(plan.sources.filter(\.isMirror).allSatisfy { $0.url.absoluteString.hasSuffix(url.absoluteString) })

        let other = await DownloadMirrors.plan(for: URL(string: "https://example.com/file.zip")!, sha256: nil)
        XCTAssertEqual(other.sources.count, 1)

        let steam = await DownloadMirrors.plan(for: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!, sha256: nil)
        XCTAssertGreaterThan(steam.sources.count, 3, "every Valve CDN serves the Steam installer")
        XCTAssertEqual(steam.sources.first?.url.host, "cdn.cloudflare.steamstatic.com")
        XCTAssertFalse(steam.sources.contains(where: \.isMirror))
    }
}

/// Steam: update pre-download, download settings, the web helper launcher.
final class SteamClientTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cell-steam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testManifestParsing() throws {
        let text = """
        "win64"
        {
        \t"version"\t\t"1792618285"
        \t"tenfoot_images_all"
        \t{
        \t\t"file"\t\t"tenfoot_images_all.zip.86419c7a56c12dd107b5e0d46f50c8a9b121f3cc"
        \t\t"size"\t\t"6582204"
        \t\t"sha2"\t\t"990676bc29d01736477c6b571b5048258a6156284ef242503112fc68567cbf01"
        \t\t"zipvz"\t\t"tenfoot_images_all.zip.vz.193cb8c4eb4446698ea2c0a9e8c4e6b6a623dac7_5572671"
        \t\t"sha2vz"\t\t"E1FEE3BEFFA9D08A415A35DDC7D3141AF6C44269C67E67AA0A3EEA6E56889BD7"
        \t}
        \t"steam_win64"
        \t{
        \t\t"file"\t\t"steam_win64.zip.4c1f"
        \t\t"size"\t\t"2902336"
        \t\t"zipvz"\t\t"steam_win64.zip.vz.e9430db5afee3e3932b6948af15ad0c4b4f19255_2166823"
        \t\t"sha2vz"\t\t"aa"
        \t\t"IsBootstrapperPackage"\t\t"1"
        \t\t"steamchina"
        \t\t{
        \t\t\t"file"\t\t"steam_win64_steamchina.zip.a645"
        \t\t\t"size"\t\t"2644089"
        \t\t}
        \t}
        \t"strings_en_all"
        \t{
        \t\t"file"\t\t"strings_en_all.zip.e716a67d7fa91ba70490a6417e25d45c5435e393"
        \t\t"size"\t\t"114150"
        \t\t"sha2"\t\t"0c56193fac4fa518eaaac0dc66ecd21a3cee510ece85594b6c308f8d31ee98a3"
        \t}
        }
        """
        let manifest = try XCTUnwrap(SteamClientUpdater.parseManifest(text, name: "steam_client_win64"))
        XCTAssertEqual(manifest.version, "1792618285")
        XCTAssertEqual(manifest.packages.count, 3)
        XCTAssertEqual(manifest.packages[1].fileName, "steam_win64_steamrow.zip.vz.e9430db5afee3e3932b6948af15ad0c4b4f19255_2166823",
                       "realm packages are stored with the global realm's name")
        XCTAssertEqual(manifest.packages[0].fileName, "tenfoot_images_all.zip.vz.193cb8c4eb4446698ea2c0a9e8c4e6b6a623dac7_5572671",
                       "the compressed file is what Steam downloads")
        XCTAssertEqual(manifest.packages[0].size, 5_572_671)
        XCTAssertEqual(manifest.packages[0].sha256, "e1fee3beffa9d08a415a35ddc7d3141af6c44269c67e67aa0a3eea6e56889bd7")
        XCTAssertEqual(manifest.packages[2].fileName, "strings_en_all.zip.e716a67d7fa91ba70490a6417e25d45c5435e393")
        XCTAssertEqual(manifest.packages[2].size, 114_150)
    }

    func testFreshInstallsNeedBothManifests() throws {
        let steam = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: steam) }
        XCTAssertEqual(SteamClientUpdater.manifestNames(steamDirectory: steam), ["steam_client_win32", "steam_client_win64"])
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("package"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: steam.appendingPathComponent("package/steam_client_win64.installed").path, contents: Data())
        XCTAssertEqual(SteamClientUpdater.manifestNames(steamDirectory: steam), ["steam_client_win64"])
    }

    func testDownloadSettingsAreMergedIntoSteamDevCfg() throws {
        let steam = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: steam) }
        let file = steam.appendingPathComponent("steam_dev.cfg")
        try "@ShaderBackgroundProcessingThreads 4\r\n@nClientDownloadEnableHTTP2PlatformWindows 1\r\n".write(to: file, atomically: true, encoding: .utf8)
        SteamClientUpdater.applyDownloadSettings(steamDirectory: steam)
        SteamClientUpdater.applyDownloadSettings(steamDirectory: steam)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["@ShaderBackgroundProcessingThreads 4", "@nClientDownloadEnableHTTP2PlatformWindows 0",
                               "@fDownloadRateImprovementToAddAnotherConnection 1.0"])
    }

    func testOnlyValidUpdateHostListsAreShared() throws {
        let fresh = try temporaryDirectory(), expired = try temporaryDirectory(), valid = try temporaryDirectory()
        defer { for url in [fresh, expired, valid] { try? FileManager.default.removeItem(at: url) } }
        func hosts(validUntil: Int) -> String {
            "\"\"\n{\n\t\"serverlist\"\n\t{\n\t}\n\t\"ClientInfo\"\n\t{\n\t\t\"valid_until\"\t\t\"\(validUntil)\"\n\t}\n}\n"
        }
        let now = Int(Date().timeIntervalSince1970)
        try hosts(validUntil: now - 10).write(to: expired.appendingPathComponent("update_hosts_cached.vdf"), atomically: true, encoding: .utf8)
        try hosts(validUntil: now + 3600).write(to: valid.appendingPathComponent("update_hosts_cached.vdf"), atomically: true, encoding: .utf8)
        SteamClientUpdater.shareUpdateHosts(to: fresh, from: [expired, valid])
        let copied = try String(contentsOf: fresh.appendingPathComponent("update_hosts_cached.vdf"), encoding: .utf8)
        XCTAssertTrue(copied.contains("\(now + 3600)"))
    }

    func testWebHelperLauncherIsAWindowsProgram() {
        let image = SteamWebHelperWrapper.image
        XCTAssertEqual(image.count, SteamWebHelperWrapper.size)
        XCTAssertEqual(Array(image.prefix(2)), Array("MZ".utf8))
        let peOffset = Int(image[0x3C]) | Int(image[0x3D]) << 8
        XCTAssertEqual(Array(image[peOffset..<(peOffset + 4)]), [0x50, 0x45, 0, 0], "PE signature")
        XCTAssertEqual(Int(image[peOffset + 4]) | Int(image[peOffset + 5]) << 8, 0x8664, "x86-64")
        XCTAssertTrue(FileOps.fileContains(writeTemporary(image), token: "CELL_WEBHELPER_FLAGS", includeUTF16: true))
    }

    private func writeTemporary(_ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wrapper-\(UUID().uuidString).exe")
        try? data.write(to: url)
        return url
    }

    func testWebHelperLauncherInstallsSurvivesUpdatesAndUninstalls() throws {
        let steam = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: steam) }
        let folder = steam.appendingPathComponent("bin/cef/cef.win64", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let helper = folder.appendingPathComponent("steamwebhelper.exe")
        let real = folder.appendingPathComponent("steamwebhelper_real.exe")
        let valve = Data(repeating: 0x41, count: 120_000)
        try valve.write(to: helper)

        XCTAssertTrue(SteamWebHelperWrapper.install(steamDirectory: steam))
        XCTAssertTrue(SteamWebHelperWrapper.isWrapper(helper))
        XCTAssertEqual(FileOps.fileSize(helper), 120_000, "padded to the original size so Steam's size check passes")
        XCTAssertEqual(try Data(contentsOf: real), valve)
        XCTAssertTrue(SteamWebHelperWrapper.isInstalled(steamDirectory: steam))
        XCTAssertTrue(SteamWebHelperWrapper.install(steamDirectory: steam), "installing twice changes nothing")
        XCTAssertEqual(try Data(contentsOf: real), valve)

        // A Steam update puts a new Valve binary in place.
        let updated = Data(repeating: 0x42, count: 130_000)
        try updated.write(to: helper)
        XCTAssertFalse(SteamWebHelperWrapper.isInstalled(steamDirectory: steam))
        XCTAssertTrue(SteamWebHelperWrapper.install(steamDirectory: steam))
        XCTAssertEqual(try Data(contentsOf: real), updated, "the new version becomes the real one")
        XCTAssertEqual(FileOps.fileSize(helper), 130_000)

        SteamWebHelperWrapper.uninstall(steamDirectory: steam)
        XCTAssertEqual(try Data(contentsOf: helper), updated)
        XCTAssertFalse(FileOps.exists(real))
    }

    func testClientArgumentsDoNotForceSoftwareCompositing() {
        let arguments = SteamIntegration.clientArguments(settings: ContainerSettings(), silent: false)
        XCTAssertFalse(arguments.contains("-cef-disable-gpu-compositing"), "it turns Steam's window black under Wine")
        XCTAssertTrue(arguments.contains("-noverifyfiles"))
        XCTAssertTrue(arguments.contains("-no-cef-sandbox"))
    }
}

/// Firewall list and network parsers.
final class NetworkParsingTests: XCTestCase {
    func testFirewallListParsing() {
        let output = """
        Total number of apps = 3

        1 : /Applications/Spotify.app
                     (Allow incoming connections)

        2 : /Users/me/Library/Application Support/Cell/Runtimes/wine-11/wine/bin/wineserver
                     (Block incoming connections)

        3 : /Users/me/Library/Application Support/Cell/Runtimes/wine-11/wine/bin/wine
                     (Allow incoming connections)
        """
        let apps = FirewallHelper.parseAppList(output)
        XCTAssertEqual(apps.count, 3)
        XCTAssertEqual(apps["/Applications/Spotify.app"], true)
        XCTAssertEqual(apps["/Users/me/Library/Application Support/Cell/Runtimes/wine-11/wine/bin/wineserver"], false)
        XCTAssertEqual(apps["/Users/me/Library/Application Support/Cell/Runtimes/wine-11/wine/bin/wine"], true)
    }

    func testConnectedVPNIsNamed() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      DBA32149-26D1-4D6D-9043-B225B46465A0 VPN (com.liguangming.Shadowrocket) "Shadowrocket"                   [VPN:com.liguangming.Shadowrocket]
        * (Disconnected)   11111111-26D1-4D6D-9043-B225B46465A0 VPN (com.wireguard.macos) "Work"                   [VPN:com.wireguard.macos]
        """
        let services = NetworkDiagnostics.parseServiceList(output)
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services.first?.name, "Shadowrocket")
        XCTAssertEqual(services.first?.bundleIdentifier, "com.liguangming.Shadowrocket")
        XCTAssertTrue(NetworkDiagnostics.isTunnel("utun4"))
        XCTAssertTrue(NetworkDiagnostics.isPhysical("en0"))
        XCTAssertFalse(NetworkDiagnostics.isPhysical("bridge100"))
    }

    func testStunMappedAddress() {
        // Binding success response with XOR-MAPPED-ADDRESS 112.8.52.224:4513.
        var packet: [UInt8] = [0x01, 0x01, 0x00, 0x0C, 0x21, 0x12, 0xA4, 0x42] + [UInt8](repeating: 7, count: 12)
        let port = UInt16(4513) ^ 0x2112
        let address: [UInt8] = [112, 8, 52, 224]
        let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        packet += [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, UInt8(port >> 8), UInt8(port & 0xFF)]
        packet += (0..<4).map { address[$0] ^ cookie[$0] }
        let mapped = NetworkDiagnostics.mappedAddress(in: packet)
        XCTAssertEqual(mapped?.address, "112.8.52.224")
        XCTAssertEqual(mapped?.port, 4513)
    }

    func testDNSAnswerParsing() {
        // Response for stun.miwifi.com with one CNAME-free A record 111.206.174.2.
        var packet: [UInt8] = [0xAB, 0xCD, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        for label in ["stun", "miwifi", "com"] { packet.append(UInt8(label.count)); packet += Array(label.utf8) }
        packet += [0x00, 0x00, 0x01, 0x00, 0x01]
        packet += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 111, 206, 174, 2]
        let address = NetworkDiagnostics.firstARecord(packet)
        XCTAssertEqual(address.map { String(cString: inet_ntoa($0)) }, "111.206.174.2")
    }

    func testVerdicts() {
        let nothing = NetworkDiagnostics.PathResult(replies: [], plainUDPWorks: false, nat: nil)
        let direct = NetworkDiagnostics.PathResult(replies: [("stun.miwifi.com", "112.8.52.224:4513")], plainUDPWorks: true, nat: .moderate)
        let vpn = NetworkDiagnostics.VPN(name: "Shadowrocket", bundleIdentifier: "com.liguangming.Shadowrocket", interface: "utun4")
        let blocked = NetworkDiagnostics.Report(vpn: vpn, physicalInterface: "en0", games: nothing, direct: direct)
        guard case .vpnBlocksUDP(.moderate) = blocked.verdict else { return XCTFail("\(blocked.verdict)") }
        let fine = NetworkDiagnostics.Report(vpn: nil, physicalInterface: "en0", games: direct, direct: nil)
        guard case .good(.moderate) = fine.verdict else { return XCTFail("\(fine.verdict)") }
        let dead = NetworkDiagnostics.Report(vpn: nil, physicalInterface: "en0", games: nothing, direct: nil)
        guard case .udpBlocked = dead.verdict else { return XCTFail("\(dead.verdict)") }
    }

}

/// Round 3: engines, running programs, uninstalling, language, Steam's game log.
final class RoundThreeTests: XCTestCase {
    func testDXMTNeedsAMatchingWine() {
        let dxmt = GraphicsComponent(kind: .dxmt, version: "0.80", origin: "test", has32Bit: false)
        let wine10 = WineRuntime(id: "sik", name: "Sikarugir", version: "10.0", origin: .imported, originDescription: "/tmp/sik")
        let wine11 = WineRuntime(id: "gcenx", name: "Gcenx", version: "11.21", origin: .catalog, originDescription: "/tmp/g")
        XCTAssertFalse(dxmt.isCompatible(with: wine10), "DXMT 0.80 crashes games on Wine 10")
        XCTAssertTrue(dxmt.isCompatible(with: wine11))
        XCTAssertFalse(GraphicsComponent(kind: .dxmt, version: "bundled", origin: "test", has32Bit: false).isCompatible(with: wine10))
        XCTAssertTrue(GraphicsComponent(kind: .d3dmetal, version: "2.1", origin: "test", has32Bit: false).isCompatible(with: wine10))
    }

    func testWindowsProgramIsFoundInWineArguments() {
        XCTAssertEqual(WineProcessScanner.windowsExecutable(in: ["/x/lib/wine/x86_64-unix/wine", "C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK\\PEAK.exe", "-force-d3d11"]),
                       "C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK\\PEAK.exe")
        XCTAssertEqual(WineProcessScanner.windowsExecutable(in: ["C:\\Program Files (x86)\\Steam\\steam.exe -no-cef-sandbox"]),
                       "C:\\Program Files (x86)\\Steam\\steam.exe")
        XCTAssertNil(WineProcessScanner.windowsExecutable(in: ["/usr/bin/zsh", "-c", "echo"]))
    }

    func testRunningProgramsMatchTheirLibraryEntries() {
        let container = UUID()
        var steam = AppEntry(containerID: container, name: "Steam", kind: .steamClient, source: .startMenu)
        steam.windowsPath = "C:\\Program Files (x86)\\Steam\\steam.exe"
        var peak = AppEntry(containerID: container, name: "PEAK", kind: .steamGame, source: .steam, steamAppID: "3527290")
        peak.windowsPath = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK\\PEAK.exe"
        var other = AppEntry(containerID: UUID(), name: "PEAK elsewhere", kind: .steamGame, source: .steam, steamAppID: "3527290")
        other.windowsPath = peak.windowsPath
        let processes = [
            WineProcess(pid: 10, containerID: container, executable: "C:\\Program Files (x86)\\Steam\\steam.exe"),
            WineProcess(pid: 11, containerID: container, executable: "C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK\\PEAK.exe"),
        ]
        let running = WineProcessScanner.runningApps(processes, apps: [steam, peak, other])
        XCTAssertEqual(running[steam.id], [10])
        XCTAssertEqual(running[peak.id], [11])
        XCTAssertNil(running[other.id], "the same path in another container is another program")
    }

    func testSteamGameLogCrashesAreFound() {
        let log = """
        [2026-11-08 13:52:18] AppID 3527290 adding PID 1720 as a tracked process ""C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK\\PEAK.exe""
        [2026-11-08 13:52:19] AppID 3527290 adding PID 1732 as a tracked process ""C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK\\UnityCrashHandler64.exe" --attach 1720 38014"
        [2026-11-08 13:52:24] AppID 3527290 no longer tracking PID 1732, exit code 0
        [2026-11-08 13:52:24] AppID 3527290 no longer tracking PID 1720, exit code -1073741819
        [2026-11-08 13:49:47] AppID 1943950 adding PID 1444 as a tracked process ""C:\\Games\\Backrooms.exe""
        [2026-11-08 13:50:35] AppID 1943950 no longer tracking PID 1444, exit code 0
        [2026-11-08 14:00:00] AppID 42 adding PID 7 as a tracked process ""C:\\Games\\Long.exe""
        [2026-11-08 14:10:00] AppID 42 no longer tracking PID 7, exit code 1
        """
        XCTAssertEqual(Launcher.earlySteamGameCrashes(in: log), ["3527290"], "only early, failing exits count")
    }

    func testUninstallHelpers() throws {
        XCTAssertEqual(CellServices.executablePath(in: "\"C:\\Games\\X\\unins000.exe\" /SILENT"), "C:\\Games\\X\\unins000.exe")
        XCTAssertEqual(CellServices.executablePath(in: "C:\\Games\\X\\game.exe,0"), "C:\\Games\\X\\game.exe")
        XCTAssertEqual(CellServices.normalizedFolder("C:/Games/X/"), "c:\\games\\x")

        // Path checks only: nothing is read or written.
        let container = Container(name: "Test", platform: .windows)
        let driveC = container.driveC
        XCTAssertTrue(CellServices.isSafeToTrash(driveC.appendingPathComponent("Games/X"), container: container))
        XCTAssertTrue(CellServices.isSafeToTrash(driveC.appendingPathComponent("Program Files/Tool"), container: container))
        XCTAssertFalse(CellServices.isSafeToTrash(driveC.appendingPathComponent("Program Files"), container: container))
        XCTAssertFalse(CellServices.isSafeToTrash(driveC.appendingPathComponent("windows/system32"), container: container))
        XCTAssertFalse(CellServices.isSafeToTrash(driveC.appendingPathComponent("Program Files (x86)/Steam"), container: container))
        XCTAssertFalse(CellServices.isSafeToTrash(driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/PEAK"), container: container))
    }

    func testLanguageSplitKeepsDisplayAndTypingApart() {
        XCTAssertEqual(LanguageResolver.resolve(.english).language, .english)
        XCTAssertEqual(LanguageResolver.textLanguage(for: .japanese).language, .japanese, "a CJK display language types itself")
        let runtime = WineRuntime(id: "w", name: "w", version: "11.21", origin: .catalog, originDescription: "/tmp/w")
        var container = Container(name: "Lang", platform: .windows)
        container.settings.language = .english
        let env = WineEnvironment.build(container: container, runtime: runtime, flavorRoot: runtime.wineRoot, backend: nil,
                                        fixes: nil, app: nil, dllOverrides: [:])
        XCTAssertNil(env["LC_ALL"], "LC_ALL would override the split")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["LC_MESSAGES"], "en_US.UTF-8")
        XCTAssertNotNil(env["LC_CTYPE"])
    }

    func testOlderLauncherIsUpgradedWithoutLosingValvesProgram() throws {
        let steam = FileManager.default.temporaryDirectory.appendingPathComponent("cell-wrapper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: steam) }
        let folder = steam.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let valve = Data(repeating: 0x56, count: 90_000)
        try valve.write(to: folder.appendingPathComponent("steamwebhelper_real.exe"))
        // An older launcher: different code, same marker.
        var old = Data("MZ".utf8) + Data(repeating: 0, count: 200) + SteamWebHelperWrapper.marker
        old.append(Data(count: 90_000 - old.count))
        try old.write(to: folder.appendingPathComponent("steamwebhelper.exe"))
        XCTAssertTrue(SteamWebHelperWrapper.isWrapper(folder.appendingPathComponent("steamwebhelper.exe")))
        XCTAssertFalse(SteamWebHelperWrapper.isInstalled(steamDirectory: steam))
        XCTAssertTrue(SteamWebHelperWrapper.install(steamDirectory: steam))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("steamwebhelper_real.exe")), valve, "Valve's program is kept")
        XCTAssertTrue(SteamWebHelperWrapper.isInstalled(steamDirectory: steam))
    }
}
