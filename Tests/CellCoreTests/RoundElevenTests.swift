import XCTest
@testable import CellCore

/// Round 11: Steam showed no window after every Mac font was linked into C:\windows\Fonts.
final class WindowsFontsFolderTests: XCTestCase {
    private func check(_ path: String, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "\(path) isn't on this Mac")
        XCTAssertEqual(WindowsFontsFolder.addsMissingScript(URL(fileURLWithPath: path)), expected, path, file: file, line: line)
    }

    /// Fonts for scripts Wine's fonts lack are linked; Windows' own families (the Mac's Tahoma has Thai), Latin-only
    /// fonts and the placeholder font are not.
    func testOnlyFontsForMissingScriptsAreLinked() throws {
        try check("/System/Library/Fonts/Hiragino Sans GB.ttc", true)
        try check("/System/Library/Fonts/Supplemental/Tahoma.ttf", false)
        try check("/System/Library/Fonts/Supplemental/Arial.ttf", false)
        try check("/System/Library/Fonts/LastResort.otf", false)
    }

    /// Links Cell made earlier for fonts no longer wanted are removed; other files in the folder stay.
    func testOldLinksAreRemovedAndOtherFontsKept() throws {
        let tahoma = "/System/Library/Fonts/Supplemental/Tahoma.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: tahoma))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let windows = root.appendingPathComponent("windows")
        let fonts = windows.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fonts.appendingPathComponent("Tahoma.ttf"), withDestinationURL: URL(fileURLWithPath: tahoma))
        try Data("mine".utf8).write(to: fonts.appendingPathComponent("users-own.ttf"))
        WindowsFontsFolder.link(windowsFolder: windows)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: fonts.path))
        XCTAssertFalse(names.contains("Tahoma.ttf"))
        XCTAssertTrue(names.contains("users-own.ttf"))
        XCTAssertFalse(names.isEmpty)
    }
}

/// A wineserver ended by force leaves its socket behind; Cell took that for a running session and never prepared
/// another launch (old font links stayed, Steam showed no window). The server's lock on its "lock" file decides.
final class ServerRunningTests: XCTestCase {
    func testOnlyAHeldLockMeansRunning() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("server-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = folder.appendingPathComponent("lock").path
        FileManager.default.createFile(atPath: lock, contents: Data())
        XCTAssertFalse(WineCommands.serverHoldsLock(lock), "a leftover lock file nobody holds")

        // Another process takes the lock the way wineserver does (write lock on byte 0) and keeps it a while.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-I", "-c", "import fcntl, sys, time\nf = open(sys.argv[1], 'w')\nfcntl.lockf(f, fcntl.LOCK_EX, 1, 0)\nprint('locked', flush=True)\ntime.sleep(10)", lock]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { holder.terminate() }
        _ = output.fileHandleForReading.availableData      // waits for "locked"
        XCTAssertTrue(WineCommands.serverHoldsLock(lock), "a running server holds it")
    }
}
