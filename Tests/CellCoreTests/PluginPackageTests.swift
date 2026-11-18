import XCTest
@testable import CellCore

final class PluginPackageTests: XCTestCase {
    func testPackagePreservesNestedPayloadsAndRejectsSymlinks() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = temp.appendingPathComponent("source")
        let output = temp.appendingPathComponent("output")
        let package = temp.appendingPathComponent("test.cell")
        defer { try? fm.removeItem(at: temp) }
        let assets = source.appendingPathComponent("assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("plugin.json"))
        let sample = Data([0, 255, 80, 75, 0, 42])
        for name in ["mod.dll", "installer.exe", "example.apk"] { try sample.write(to: assets.appendingPathComponent(name)) }
        try PluginPackage.pack(source, to: package)
        try PluginPackage.unpack(package, into: output)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("assets/example.apk")), sample)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("assets/installer.exe")), sample)

        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "../outside")
        XCTAssertThrowsError(try PluginPackage.pack(source, to: package))
        let unsafe = temp.appendingPathComponent("unsafe.zip")
        try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/zip"),
                                     arguments: ["-y", unsafe.path, "link"], currentDirectory: source)
        XCTAssertThrowsError(try PluginPackage.unpack(unsafe, into: output))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("link").path))
    }

    func testVersionComparisonUsesNumericOrderAndPreReleaseStatus() {
        XCTAssertEqual(PluginManager.compareVersions("1.10.0", "1.2.8"), .orderedDescending)
        XCTAssertEqual(PluginManager.compareVersions("1.2.0-beta.3", "1.2.0"), .orderedAscending)
        XCTAssertEqual(PluginManager.compareVersions("1.2.0", "1.2.0+rebuilt"), .orderedSame)
    }

    func testHostRewriteNormalizesNamesAndRejectsTargetsThatContainPorts() throws {
        var rules = HostRewrites()
        rules.rules = ["Example.TEST.": "2001:db8::42"]
        XCTAssertEqual(try rules.validated().rules, ["example.test": "2001:db8::42"])
        rules.rules["example.test"] = "127.0.0.1"
        XCTAssertThrowsError(try rules.validated())
        rules.rules = ["example.test": "localhost:443"]
        XCTAssertThrowsError(try rules.validated())
    }

    func testMinimumWineProfileKeepsBundledDXMTAndFallsBackWhenUnavailable() {
        func engine(_ name: String, version: String, backend: GraphicsBackend) -> LaunchPlanner.EngineOption {
            var runtime = WineRuntime(id: name, name: name, version: version, origin: .imported, originDescription: "")
            runtime.baseBackend = backend
            return .init(runtime: runtime, backend: backend, verified: true, preference: 0, showsText: true)
        }
        let old = engine("old", version: "10.0", backend: .d3dmetal)
        let newer = engine("newer", version: "11.21", backend: .dxvk)
        let tested = engine("tested", version: "11.0", backend: .dxmt)
        var fixes = ResolvedFixes()
        fixes.minimumWineVersion = "11.0"
        fixes.enginePreference = ["bundled-dxmt"]
        XCTAssertEqual(LaunchPlanner.satisfyingRuntimePreference([old, newer, tested], fixes: fixes).map(\.runtime.id), ["tested"])
        XCTAssertEqual(LaunchPlanner.satisfyingRuntimePreference([old, newer], fixes: fixes).map(\.runtime.id), ["newer"])
        XCTAssertEqual(LaunchPlanner.satisfyingRuntimePreference([old], fixes: fixes).map(\.runtime.id), ["old"])
    }
}
