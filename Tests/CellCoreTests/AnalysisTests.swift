import XCTest
@testable import CellCore

/// Builds small but valid PE files in memory.
enum PEFixture {
    /// A 64-bit GUI PE with an import table importing `dlls` and one delay import.
    static func make(machine: UInt16 = 0x8664, imports dlls: [String], delayImports: [String] = [], dotNet: Bool = false) -> Data {
        var data = Data(count: 0x600)
        func put16(_ value: UInt16, _ offset: Int) { data[offset] = UInt8(value & 0xFF); data[offset + 1] = UInt8(value >> 8) }
        func put32(_ value: UInt32, _ offset: Int) { for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) } }
        put16(0x5A4D, 0)                 // MZ
        put32(0x80, 0x3C)                // e_lfanew
        put32(0x0000_4550, 0x80)         // PE\0\0
        let coff = 0x84
        put16(machine, coff)
        put16(1, coff + 2)               // one section
        let is64 = machine != 0x014C
        let optionalSize = is64 ? 240 : 224
        put16(UInt16(optionalSize), coff + 16)
        let optional = coff + 20
        put16(is64 ? 0x20B : 0x10B, optional)
        put16(2, optional + 68)          // GUI subsystem
        put32(16, optional + (is64 ? 108 : 92))
        let directories = optional + (is64 ? 112 : 96)
        // Section: VA 0x1000, raw 0x200, size 0x400
        let section = optional + optionalSize
        put32(0x400, section + 8); put32(0x1000, section + 12); put32(0x400, section + 16); put32(0x200, section + 20)
        func rva(_ fileOffset: Int) -> UInt32 { UInt32(fileOffset - 0x200 + 0x1000) }

        // Import descriptors at 0x200, names at 0x300.
        var nameOffset = 0x300
        for (index, dll) in dlls.enumerated() {
            let descriptor = 0x200 + index * 20
            put32(rva(0x2F0), descriptor)          // OriginalFirstThunk (dummy)
            put32(rva(nameOffset), descriptor + 12)
            put32(rva(0x2F0), descriptor + 16)
            for (i, byte) in dll.utf8.enumerated() { data[nameOffset + i] = byte }
            nameOffset += dll.utf8.count + 1
        }
        put32(rva(0x200), directories + 8)          // import directory
        put32(UInt32((dlls.count + 1) * 20), directories + 12)

        if !delayImports.isEmpty {
            let delayStart = 0x280
            for (index, dll) in delayImports.enumerated() {
                let descriptor = delayStart + index * 32
                put32(1, descriptor)                  // RVA-based
                put32(rva(nameOffset), descriptor + 4)
                for (i, byte) in dll.utf8.enumerated() { data[nameOffset + i] = byte }
                nameOffset += dll.utf8.count + 1
            }
            put32(rva(delayStart), directories + 13 * 8)
            put32(UInt32((delayImports.count + 1) * 32), directories + 13 * 8 + 4)
        }
        if dotNet {
            put32(rva(0x500), directories + 14 * 8)
            put32(72, directories + 14 * 8 + 4)
        }
        return data
    }
}

final class AnalysisTests: XCTestCase {
    func testPEImportsAndArchitecture() throws {
        let data = PEFixture.make(imports: ["KERNEL32.dll", "d3d11.dll", "dxgi.dll"], delayImports: ["d3d12.dll"])
        let pe = try XCTUnwrap(PEFile(data: data))
        XCTAssertEqual(pe.architecture, .x64)
        XCTAssertTrue(pe.isGUI)
        XCTAssertEqual(pe.imports, ["kernel32.dll", "d3d11.dll", "dxgi.dll"])
        XCTAssertEqual(pe.delayImports, ["d3d12.dll"])
        XCTAssertFalse(pe.isDotNet)
    }

    func testPE32AndDotNet() throws {
        let pe = try XCTUnwrap(PEFile(data: PEFixture.make(machine: 0x014C, imports: ["mscoree.dll", "d3d9.dll"], dotNet: true)))
        XCTAssertEqual(pe.architecture, .x86)
        XCTAssertTrue(pe.isDotNet)
        XCTAssertTrue(pe.imports.contains("d3d9.dll"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(PEFile(data: Data("not a program".utf8)))
        XCTAssertNil(PEFile(data: Data(count: 10)))
    }

    func testAnalyzerDetectsUnityLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cell-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("MyGame_Data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("D3D12"), withIntermediateDirectories: true)
        try PEFixture.make(imports: ["kernel32.dll"]).write(to: dir.appendingPathComponent("MyGame.exe"))
        try PEFixture.make(imports: ["d3d11.dll", "dxgi.dll"]).write(to: dir.appendingPathComponent("UnityPlayer.dll"))
        try Data().write(to: dir.appendingPathComponent("D3D12/D3D12Core.dll"))
        try "Studio\nMy Game\n".write(to: dir.appendingPathComponent("MyGame_Data/app.info"), atomically: true, encoding: .utf8)
        try "480\n".write(to: dir.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)

        let analysis = AppAnalyzer.analyze(executable: dir.appendingPathComponent("MyGame.exe"))
        XCTAssertEqual(analysis.engine, .unity)
        XCTAssertTrue(analysis.graphicsAPIs.contains(.d3d11))
        XCTAssertTrue(analysis.hasD3D12AgilitySDK)
        XCTAssertEqual(analysis.unityCompany, "Studio")
        XCTAssertEqual(analysis.unityProduct, "My Game")
        XCTAssertEqual(analysis.steamAppID, "480")
        XCTAssertEqual(CellServices.preferredName(for: dir.appendingPathComponent("MyGame.exe"), analysis: analysis), "My Game")
    }

    func testInstallerHeuristic() {
        XCTAssertTrue(AppAnalyzer.looksLikeInstaller(name: "SteamSetup.exe", description: nil))
        XCTAssertTrue(AppAnalyzer.looksLikeInstaller(name: "unins000.exe", description: nil))
        XCTAssertTrue(AppAnalyzer.looksLikeInstaller(name: "game.exe", description: "Game Installer"))
        XCTAssertFalse(AppAnalyzer.looksLikeInstaller(name: "PEAK.exe", description: "PEAK"))
    }

    func testVDF() throws {
        let text = """
        "AppState"
        {
            "appid"     "3527290"
            "name"      "PEAK"
            "installdir"    "PEAK"
            "StateFlags"    "4"
            // comment
            "UserConfig" { "language" "schinese" }
        }
        """
        let root = try XCTUnwrap(VDFNode.parse(text))
        XCTAssertEqual(root["AppState"]?["appid"]?.string, "3527290")
        XCTAssertEqual(root["appstate"]?["UserConfig"]?["language"]?.string, "schinese")
    }

    func testLnkArguments() {
        XCTAssertEqual(LnkFile.splitArguments(#"-windowed "C:\My Games\cfg.ini" -x"#), ["-windowed", #"C:\My Games\cfg.ini"#, "-x"])
        XCTAssertEqual(LnkFile.splitArguments(""), [])
    }

    func testLnkParsing() throws {
        // Minimal shell link: header + LinkInfo with a local base path + unicode arguments.
        var data = Data(count: 76)
        data[0] = 0x4C
        let flags: UInt32 = 0x2 | 0x20 | 0x80      // HasLinkInfo | HasArguments | IsUnicode
        for i in 0..<4 { data[20 + i] = UInt8((flags >> (8 * UInt32(i))) & 0xFF) }
        let path = Array(#"C:\Games\Hero\hero.exe"#.utf8) + [0]
        let headerSize = 28
        let linkInfoSize = headerSize + path.count
        var linkInfo = Data(count: headerSize)
        func put(_ value: UInt32, _ offset: Int) { for i in 0..<4 { linkInfo[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) } }
        put(UInt32(linkInfoSize), 0); put(UInt32(headerSize), 4); put(1, 8); put(UInt32(headerSize), 16)
        linkInfo.append(contentsOf: path)
        data.append(linkInfo)
        let arguments = "-safe"
        data.append(contentsOf: [UInt8(arguments.utf16.count), 0])
        for unit in arguments.utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }

        let link = try XCTUnwrap(LnkFile(data: data))
        XCTAssertEqual(link.targetPath, #"C:\Games\Hero\hero.exe"#)
        XCTAssertEqual(link.arguments, "-safe")
    }

    func testBinarySearchIsCaseInsensitiveAndFindsWideStrings() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cell-search-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data("xxD3DMetalDLLsBase yy".utf8)
        for unit in "d3d12.dll".utf16 { data.append(UInt8(unit)); data.append(0) }
        try data.write(to: file)
        XCTAssertTrue(FileOps.fileContains(file, token: "d3dmetal"))
        XCTAssertFalse(FileOps.fileContains(file, token: "d3d12.dll"))
        XCTAssertTrue(FileOps.fileContains(file, token: "D3D12.DLL", includeUTF16: true))
        XCTAssertFalse(FileOps.fileContains(file, token: "dxmt", includeUTF16: true))
    }
}
