import Foundation
import XCTest
@testable import CellCore

final class EADesktopLinksTests: XCTestCase {
    func testRepairsInstalledPayloadAfterRename() throws {
        let fm = FileManager.default
        let drive = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: drive) }
        let root = drive.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        let original = root.appendingPathComponent("EA Desktop")
        let version = root.appendingPathComponent("13.827.2.6342")
        let relocated = version.appendingPathComponent("EA Desktop")
        try createPayload(original)
        let watcher = EADesktopLinks()
        watcher.watch(drive: drive)

        XCTAssertFalse(FileOps.isSymlink(original))
        try fm.createDirectory(at: version, withIntermediateDirectories: false)
        try fm.moveItem(at: original, to: relocated)

        // A live installer cannot wait for the normal two-second process monitor.
        let deadline = Date().addingTimeInterval(1)
        while !FileOps.isSymlink(original), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: original.path), "13.827.2.6342/EA Desktop")
        XCTAssertTrue(fm.fileExists(atPath: original.appendingPathComponent("EASteamLauncher.exe").path))
        withExtendedLifetime(watcher) {}
    }

    func testPreservesExistingLinkAndAmbiguousVersions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try createPayload(root.appendingPathComponent("1.2.3.4/EA Desktop"))
        try createPayload(root.appendingPathComponent("1.2.3.5/EA Desktop"))
        let alias = root.appendingPathComponent("EA Desktop")
        EADesktopLinks.repair(in: root)
        XCTAssertFalse(FileOps.exists(alias))
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "existing-link")
        EADesktopLinks.repair(in: root)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: alias.path), "existing-link")
    }

    private func createPayload(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["EABackgroundService.exe", "EADesktop.exe", "EASteamLauncher.exe"] {
            try Data([0x4d, 0x5a]).write(to: folder.appendingPathComponent(name))
        }
    }
}
