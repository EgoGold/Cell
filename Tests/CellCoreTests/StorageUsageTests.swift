import Foundation
import XCTest
@testable import CellCore

final class StorageUsageTests: XCTestCase {
    func testCleanupPreservesSavesInstallsDownloadsAndLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let layer = root.appendingPathComponent("layer")
        let drive = layer.appendingPathComponent("prefix/drive_c")
        let steam = drive.appendingPathComponent("Program Files (x86)/Steam")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        func file(_ url: URL, date: Date = old) throws -> URL {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: 4_096).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let oldLog = try file(drive.appendingPathComponent("windows/temp/diagnostics.log"))
        let replaced = try file(drive.appendingPathComponent("windows/temp/old.tmp"))
        let fresh = try file(drive.appendingPathComponent("windows/temp/fresh.tmp"), date: old.addingTimeInterval(10 * 86_400))
        let installer = try file(drive.appendingPathComponent("windows/temp/setup.msi"))
        let save = try file(drive.appendingPathComponent("users/profile/Documents/save.tmp"))
        let download = try file(steam.appendingPathComponent("steamapps/downloading/10/pending.tmp"))
        let game = try file(steam.appendingPathComponent("steamapps/common/game/main.exe"))
        let data = try file(drive.appendingPathComponent("users/profile/AppData/Local/Steam/htmlcache/Default/Cookies"))
        let cache = try file(drive.appendingPathComponent("users/profile/AppData/Local/Steam/htmlcache/Default/GPUCache/cache"))
        let outside = try file(root.appendingPathComponent("external/outside.tmp"))
        try fm.createSymbolicLink(at: drive.appendingPathComponent("windows/temp/linked.tmp"), withDestinationURL: outside)
        let linkedProfile = drive.appendingPathComponent("users/linked")
        _ = try file(root.appendingPathComponent("external/AppData/Local/Temp/escape.tmp"))
        try fm.createSymbolicLink(at: linkedProfile, withDestinationURL: outside.deletingLastPathComponent())

        let plan = ContainerCleanup.plan(directory: layer, drive: drive, steam: steam, now: old.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(Set(plan.candidates.map { $0.url.lastPathComponent }), Set([oldLog, replaced, cache].map(\.lastPathComponent)))

        try fm.removeItem(at: replaced)
        try fm.createSymbolicLink(at: replaced, withDestinationURL: outside)
        var moved: Set<String> = []
        let result = ContainerCleanup.moveReviewed(plan, directory: layer) { url in
            moved.insert(url.lastPathComponent)
            try fm.removeItem(at: url)
        }
        XCTAssertEqual(moved, Set([oldLog, cache].map(\.lastPathComponent)))
        XCTAssertEqual(result.skipped, 1)
        for protected in [fresh, installer, save, download, game, data, outside] {
            XCTAssertTrue(fm.fileExists(atPath: protected.path))
        }
    }

    func testClientSizeExcludesGameLibrariesAndUserData() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for file in ["steam.exe", "steamapps/common/sample/game.exe", "userdata/10/remote/save"] {
            let url = root.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: 16_384).write(to: url)
        }
        let client = FileOps.allocatedSize(of: root, excludingTopLevel: ["steamapps", "userdata"])
        XCTAssertGreaterThan(client, 0)
        XCTAssertGreaterThan(FileOps.allocatedSize(of: root), client)
    }
}
