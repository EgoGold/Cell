import XCTest
import Network
@testable import CellCore

/// Minimal HTTP/1.1 server with byte-range support, used to test the downloader for real.
final class RangeServer: @unchecked Sendable {
    let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.range-server", attributes: .concurrent)
    private let lock = NSLock()
    private let chunkDelay: useconds_t
    private var active = 0
    private(set) var peakConcurrentTransfers = 0
    private(set) var rangeRequests = 0
    private(set) var bytesSent = 0
    var expireFirstRangeRequest = false
    /// Answer every real range request with 429 Too Many Requests.
    var rateLimit = false
    /// Serve wrong bytes (same length).
    var corrupt = false

    init(payload: Data, chunkDelay: useconds_t = 0) throws {
        self.payload = payload
        self.chunkDelay = chunkDelay
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/file.bin")! }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if !done && error == nil {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        var start = 0
        var end = payload.count - 1
        var partial = false
        for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("range: bytes=") {
            let spec = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            start = Int(spec[0]) ?? 0
            if spec.count > 1, let last = Int(spec[1]) { end = min(last, payload.count - 1) }
            partial = true
        }
        lock.lock()
        if partial && end > start { rangeRequests += 1 }
        let expire = partial && end > start && expireFirstRangeRequest
        if expire { expireFirstRangeRequest = false }
        lock.unlock()
        if expire {
            send(connection, Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), close: true)
            return
        }
        if rateLimit && partial && end > start {
            send(connection, Data("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), close: true)
            return
        }
        var head = partial ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(payload.count)\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Length: \(end - start + 1)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        lock.lock(); active += 1; peakConcurrentTransfers = max(peakConcurrentTransfers, active); lock.unlock()
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendBody(connection, from: start, to: end)
        })
    }

    private func sendBody(_ connection: NWConnection, from: Int, to: Int) {
        guard from <= to else {
            lock.lock(); active -= 1; lock.unlock()
            send(connection, nil, close: true)
            return
        }
        let next = min(from + 65_536, to + 1)
        var chunk = payload.subdata(in: from..<next)
        if corrupt { chunk = Data(chunk.map { $0 ^ 0xFF }) }
        lock.lock(); bytesSent += next - from; lock.unlock()
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.lock.lock(); self.active -= 1; self.lock.unlock()
                connection.cancel()
                return
            }
            if self.chunkDelay > 0 { usleep(self.chunkDelay) }
            self.sendBody(connection, from: next, to: to)
        })
    }

    private func send(_ connection: NWConnection, _ data: Data?, close: Bool) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}

final class DownloadTests: XCTestCase {
    private func payload(megabytes: Int) -> Data {
        var data = Data(count: megabytes * 1024 * 1024)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt32.self)
            var state: UInt32 = 0x1234_5678
            for index in bytes.indices {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[index] = state
            }
        }
        return data
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cell-dl-\(UUID().uuidString).bin")
    }

    func testSegmentMath() {
        let segments = DownloadManager.makeSegments(total: 100 * 1024 * 1024, connections: 8)
        XCTAssertEqual(segments.count, 8)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.end, 100 * 1024 * 1024 - 1)
        for (a, b) in zip(segments, segments.dropFirst()) { XCTAssertEqual(a.end + 1, b.start) }
        XCTAssertEqual(DownloadManager.makeSegments(total: 1_000_000, connections: 8).count, 1, "small files use one connection")
        XCTAssertEqual(DownloadManager.totalFromContentRange("bytes 0-0/228148688"), 228_148_688)
        XCTAssertNil(DownloadManager.totalFromContentRange(nil))
    }

    func testParallelDownloadIsByteExact() async throws {
        let data = payload(megabytes: 24)
        let server = try RangeServer(payload: data, chunkDelay: 300)
        let manager = DownloadManager()
        manager.connectionsPerDownload = 6
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let result = try await manager.download(server.url, to: target, title: "test", sha256: DownloadManagerTestsHelper.sha256(data))
        XCTAssertEqual(try Data(contentsOf: result), data)
        XCTAssertGreaterThanOrEqual(server.peakConcurrentTransfers, 3, "several connections transferred at once")
        XCTAssertEqual(manager.snapshots().first { $0.title == "test" }?.state, .completed)
    }

    func testPauseAndResumeContinueWhereTheyStopped() async throws {
        let data = payload(megabytes: 16)
        let server = try RangeServer(payload: data, chunkDelay: 4000)
        let manager = DownloadManager()
        manager.connectionsPerDownload = 4
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let task = Task { try await manager.download(server.url, to: target, title: "pausable") }

        var id: UUID?
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let snapshot = manager.snapshots().first(where: { $0.title == "pausable" }), snapshot.receivedBytes > 1_000_000 { id = snapshot.id; break }
        }
        let jobID = try XCTUnwrap(id, "download made progress")
        manager.pause(jobID)
        try await Task.sleep(nanoseconds: 400_000_000)
        let paused = try XCTUnwrap(manager.snapshots().first { $0.title == "pausable" })
        XCTAssertEqual(paused.state, .paused)
        XCTAssertGreaterThan(paused.receivedBytes, 0)
        manager.resume(jobID)
        let result = try await task.value
        XCTAssertEqual(try Data(contentsOf: result), data)
    }

    func testExpiredLinkIsResolvedAgain() async throws {
        let data = payload(megabytes: 8)
        let server = try RangeServer(payload: data)
        server.expireFirstRangeRequest = true
        let manager = DownloadManager()
        manager.connectionsPerDownload = 4
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let result = try await manager.download(server.url, to: target, title: "expiring")
        XCTAssertEqual(try Data(contentsOf: result), data)
    }

    func testChecksumMismatchFails() async throws {
        let data = payload(megabytes: 1)
        let server = try RangeServer(payload: data)
        let manager = DownloadManager()
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        do {
            _ = try await manager.download(server.url, to: target, title: "bad", sha256: String(repeating: "0", count: 64))
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(manager.snapshots().first { $0.title == "bad" }?.state, .failed)
        }
    }
}

enum DownloadManagerTestsHelper {
    static func sha256(_ data: Data) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return DownloadManager.sha256(of: url) ?? ""
    }
}

final class EngineAndBottleTests: XCTestCase {
    private func runtime(_ id: String, version: String, crossover: Bool) -> WineRuntime {
        var runtime = WineRuntime(id: id, name: id, version: version, origin: .imported, originDescription: "/tmp/\(id)")
        runtime.supportsD3DMetal = crossover ? true : nil
        return runtime
    }

    func testEnginePreference() {
        let crossover = runtime("cx", version: "10.0", crossover: true)
        let staging = runtime("staging", version: "11.21", crossover: false)
        var fixes = ResolvedFixes()
        fixes.enginePreference = ["newest"]
        XCTAssertEqual(LaunchPlanner.preferredRuntime(fixes: fixes, among: [crossover, staging], current: crossover)?.id, "staging")
        fixes.enginePreference = ["crossover"]
        XCTAssertEqual(LaunchPlanner.preferredRuntime(fixes: fixes, among: [crossover, staging], current: staging)?.id, "cx")
        fixes.enginePreference = []
        fixes.minimumWineVersion = "11.0"
        XCTAssertEqual(LaunchPlanner.preferredRuntime(fixes: fixes, among: [crossover, staging], current: crossover)?.id, "staging")
        XCTAssertNil(LaunchPlanner.preferredRuntime(fixes: ResolvedFixes(), among: [crossover, staging], current: crossover))
    }

    func testLearnedFailuresArePerEngine() {
        var learned = LearnedCompat()
        learned.failedCombinations = ["a|dxmt", "a|d3dmetal", "b|wined3d"]
        XCTAssertEqual(Set(learned.failedBackends(on: "a")), [.dxmt, .d3dmetal])
        XCTAssertEqual(learned.failedBackends(on: "b"), [.wined3d])
        XCTAssertTrue(learned.failedBackends(on: "c").isEmpty)
    }

    func testBottleDetection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bottle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Games.app")
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/users/Wineskin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/users/Public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/SharedSupport/wine/lib/wine"), withIntermediateDirectories: true)
        try "WINE REGISTRY Version 2\n".write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try Data().write(to: steam.appendingPathComponent("steam.exe"))
        try """
        "AppState" { "appid" "3527290" "name" "PEAK" "installdir" "PEAK" "StateFlags" "4" }
        """.write(to: steam.appendingPathComponent("steamapps/appmanifest_3527290.acf"), atomically: true, encoding: .utf8)

        let found = try XCTUnwrap(BottleImporter.bottle(containing: steam.appendingPathComponent("steam.exe")))
        XCTAssertEqual(found.source, .wrapper)
        XCTAssertEqual(found.appBundle?.lastPathComponent, "Games.app")
        XCTAssertNotNil(found.engine)
        XCTAssertTrue(found.hasSteam)
        XCTAssertEqual(found.steamGames, ["PEAK"])
        XCTAssertEqual(found.windowsUser, "Wineskin")
        XCTAssertNil(BottleImporter.bottle(containing: root.appendingPathComponent("elsewhere.exe")))
    }

    func testDriveLinksFollowTheClone() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("old")
        let new = base.appendingPathComponent("new")
        try fm.createDirectory(at: new.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: new.appendingPathComponent("dosdevices/d:").path, withDestinationPath: old.path + "/drive_d")
        try fm.createSymbolicLink(atPath: new.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        BottleImporter.repairDriveLinks(in: new, oldPrefix: old)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("dosdevices/d:").path), new.path + "/drive_d")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("dosdevices/c:").path), "../drive_c")
    }

    func testLanguageCacheIsSafeOffMainThread() async {
        await MainActor.run { LanguageResolver.prime() }
        let onMain = await MainActor.run { LanguageResolver.resolve(.automatic).language }
        let offMain = await Task.detached { LanguageResolver.resolve(.automatic).language }.value
        XCTAssertEqual(onMain, offMain)
    }
}
