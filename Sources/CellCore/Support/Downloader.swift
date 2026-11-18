import Foundation
import CryptoKit
import Network

/// One server a file can be downloaded from.
public struct DownloadSource: Codable, Hashable, Sendable {
    public var url: URL
    /// The most parallel connections this server gets. Public mirrors often refuse more than a few per visitor.
    public var maxConnections: Int
    /// A third-party copy (for example a GitHub download proxy). Only used when the file's SHA-256 is known.
    public var isMirror: Bool

    public init(url: URL, maxConnections: Int = 16, isMirror: Bool = false) {
        self.url = url
        self.maxConnections = maxConnections
        self.isMirror = isMirror
    }

    public var label: String { url.host ?? url.absoluteString }
}

/// What the UI shows for one download.
public struct DownloadSnapshot: Identifiable, Hashable, Sendable {
    /// `reconnecting`: the connection was lost; the download carries on by itself (see `retryAt`).
    public enum State: String, Sendable { case queued, connecting, downloading, reconnecting, paused, verifying, completed, failed, cancelled }

    public struct Source: Hashable, Sendable {
        public enum Health: String, Sendable { case checking, fast, slow, resting, unavailable }
        public var label: String
        public var isMirror: Bool
        public var connections: Int
        public var bytesPerSecond: Double
        public var receivedBytes: Int64
        public var health: Health
        public var problem: String?
    }

    public var id: UUID
    public var title: String
    public var url: URL
    public var destination: URL
    public var state: State
    public var totalBytes: Int64
    public var receivedBytes: Int64
    public var bytesPerSecond: Double
    public var activeConnections: Int
    /// How many connections the download may use right now (it raises this while that keeps getting faster).
    public var connectionLimit: Int
    public var sources: [Source]
    public var error: String?
    public var startedAt: Date
    /// When a download that lost its connection tries again.
    public var retryAt: Date?

    public var fraction: Double? { totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : nil }
    public var secondsRemaining: Double? {
        guard totalBytes > 0, bytesPerSecond > 1 else { return nil }
        return Double(totalBytes - receivedBytes) / bytesPerSecond
    }
    public var isActive: Bool { state == .queued || state == .connecting || state == .downloading || state == .reconnecting || state == .verifying }
    public var canResume: Bool { state == .paused || state == .failed }
}

public enum DownloadError: LocalizedError {
    case cancelled
    case failed(String)
    case checksumMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The download was cancelled."
        case .failed(let reason): return "The download failed: \(reason)"
        case .checksumMismatch(let file): return "\(file) is damaged (checksum mismatch). Please download it again."
        }
    }
}

/// Adaptive multi-source, multi-connection downloader.
///
/// A file is fetched in byte ranges over many TCP connections at once (one URLSession per connection,
/// so HTTP/2 can't fold them into one). When a file is available from several servers (the official one
/// plus mirrors), all of them are used together: each connection goes to the server that currently
/// delivers the most per connection, slow servers stop getting new work, and when a fast connection runs
/// out of work it takes over the tail of a range a slower one is still fetching. The number of
/// connections starts at the configured value and (unless that is switched off) keeps rising, up to 32,
/// while that makes the download faster; the value can be changed while downloads run. A server that only
/// takes a few connections from one address (it refuses, ignores or starves the extra ones) keeps the
/// number that works instead of being given up on. Servers that fail are rested. Expired signed links
/// (GitHub) are re-resolved, servers without range support fall back to one stream, files are checked
/// against their SHA-256, paused or interrupted downloads resume where they stopped, and a download that
/// loses its connection reconnects by itself (at once when the network comes back).
public final class DownloadManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let shared = DownloadManager()

    public typealias UpdateHandler = @Sendable ([DownloadSnapshot]) -> Void

    /// Connections a download may grow to.
    public static let maximumConnections = 32
    /// Connections all running downloads may use together.
    static let globalConnectionLimit = 64

    private let queue = DispatchQueue(label: "cell.downloads")
    private lazy var delegateQueue: OperationQueue = {
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        return operations
    }()
    private var sessions: [Int: URLSession] = [:]
    private var freeSlots = Set(0..<(DownloadManager.globalConnectionLimit + 16))
    private var jobs: [Job] = []
    private var routes: [ObjectIdentifier: Route] = [:]
    private var startingConnections = 16
    private var raisesConnections = true
    private var reconnects = true
    private var pathMonitor: NWPathMonitor?
    /// Tries after a lost connection before a download is left as failed (waits grow to a minute).
    static let maximumReconnects = 30
    private var updateHandler: UpdateHandler?
    private var lastNotification = Date.distantPast
    private var notificationScheduled = false
    private var timer: DispatchSourceTimer?

    /// Smallest range worth giving to another connection.
    static let minimumSplit: Int64 = 1024 * 1024
    /// Near the end, ranges are split finer so the last bytes don't wait on one slow connection.
    static let endgameSplit: Int64 = 256 * 1024
    /// A connection that delivers nothing for this long is replaced.
    static let stallTimeout: TimeInterval = 15

    private struct Route {
        let job: Job
        /// nil = a probe that discovers the size, range support and the final (redirected) address.
        let segment: Int?
        let source: Int
        let slot: Int
    }

    struct Segment: Codable {
        var start: Int64
        /// Inclusive. `Int64.max` while the size is unknown.
        var end: Int64
        var current: Int64
        var retries = 0
        var isDone: Bool { current > end }
        var remaining: Int64 { end == Int64.max ? Int64.max : max(0, end - current + 1) }

        private enum CodingKeys: String, CodingKey { case start, end, current }
    }

    struct Running {
        let task: URLSessionDataTask
        let source: Int
        let slot: Int
        var lastData: Date
        let startedAt = Date()
        var received: Int64 = 0
        /// The server answered this connection with data (206).
        var accepted = false
    }

    final class SourceState {
        /// `waiting`: a mirror answered before the official size was known; it is checked against it first.
        enum Phase { case idle, probing, waiting, ready, noRanges, failed }
        let source: DownloadSource
        var resolvedURL: URL?
        var phase: Phase = .idle
        var cap: Int
        var active = 0
        var received: Int64 = 0
        var speed: Double = 0
        var sampleBytes: Int64 = 0
        var consecutiveErrors = 0
        var probeAttempts = 0
        var restUntil = Date.distantPast
        var problem: String?
        /// The server said the file isn't there (404/410): asking again won't help.
        var missing = false
        var reportedTotal: Int64?
        /// The server takes only `cap` connections from one address: don't ask it for more.
        var limited = false
        /// The most connections it served at the same time, and refusals in a row while under that number.
        var peakAccepted = 0
        var limitStrikes = 0
        /// Measured bytes per second of one connection to this server (0 = not measured yet).
        var connectionRate: Double = 0

        init(_ source: DownloadSource) {
            self.source = source
            cap = max(1, source.maxConnections)
        }

        var perConnection: Double { connectionRate > 0 ? connectionRate : speed / Double(max(active, 1)) }

        func noteConnectionRate(_ rate: Double) {
            guard rate > 0 else { return }
            connectionRate = connectionRate == 0 ? rate : connectionRate * 0.5 + rate * 0.5
        }
        var isUsable: Bool { phase == .ready && restUntil <= Date() }
    }

    final class Job {
        let id: UUID
        let title: String
        let destination: URL
        let sha256: String?
        let expectedSize: Int64?
        var sources: [SourceState]
        var state: DownloadSnapshot.State = .queued
        var total: Int64 = -1
        var rangesSupported = false
        var singleStream = false
        /// The size came from the official server (or was known up front), not from a mirror.
        var totalIsTrusted = false
        var segments: [Segment] = []
        var tasks: [Int: Running] = [:]
        var fd: Int32 = -1
        var error: String?
        var startedAt = Date()
        var speed: Double = 0
        var sampleTime = Date()
        var sampleBytes: Int64 = 0
        var lastPersist = Date.distantPast
        var target = 16
        var lastRaise = Date()
        var speedAtRaise: Double = 0
        var errorsSinceRaise = 0
        var mirrorsDisabled = false
        /// Reconnecting can't help (the file is gone, the disk is full).
        var permanentFailure = false
        var reconnectAttempts = 0
        var retryAt: Date?
        var receivedAtReconnect: Int64 = 0
        var waiters: [CheckedContinuation<URL, Error>] = []
        var progressHandlers: [Downloader.Progress] = []

        init(id: UUID = UUID(), title: String, sources: [DownloadSource], destination: URL, sha256: String?, expectedSize: Int64?) {
            self.id = id
            self.title = title
            self.sources = sources.map(SourceState.init)
            self.destination = destination
            self.sha256 = sha256?.lowercased()
            self.expectedSize = expectedSize
        }

        var url: URL { sources.first?.source.url ?? destination }
        var partURL: URL { destination.appendingPathExtension("part") }
        var stateURL: URL { CellPaths.downloads.appendingPathComponent("\(id.uuidString).download.json") }
        var received: Int64 {
            segments.reduce(0) { $0 + max(0, min($1.current, $1.end == Int64.max ? $1.current : $1.end + 1) - $1.start) }
        }

        var snapshot: DownloadSnapshot {
            let running = state == .downloading || state == .connecting
            let best = sources.map(\.perConnection).max() ?? 0
            let sourceSnapshots = sources.map { source -> DownloadSnapshot.Source in
                let health: DownloadSnapshot.Source.Health
                switch source.phase {
                case .failed, .noRanges: health = .unavailable
                case .idle, .probing, .waiting: health = .checking
                case .ready:
                    if source.restUntil > Date() { health = .resting }
                    else if source.speed > 0, best > 0, source.perConnection < best * 0.25 { health = .slow }
                    else { health = .fast }
                }
                return DownloadSnapshot.Source(label: source.source.label, isMirror: source.source.isMirror,
                                               connections: source.active, bytesPerSecond: running ? source.speed : 0,
                                               receivedBytes: source.received, health: health, problem: source.problem)
            }
            return DownloadSnapshot(id: id, title: title, url: url, destination: destination, state: state, totalBytes: total,
                                    receivedBytes: received, bytesPerSecond: running ? speed : 0,
                                    activeConnections: tasks.count, connectionLimit: target, sources: sourceSnapshots,
                                    error: error, startedAt: startedAt, retryAt: state == .reconnecting ? retryAt : nil)
        }
    }

    private struct PersistedJob: Codable {
        var id: UUID
        var title: String
        var url: URL
        var sources: [DownloadSource]?
        var destination: URL
        var sha256: String?
        var expectedSize: Int64?
        var total: Int64
        var rangesSupported: Bool
        var segments: [Segment]
        var failed: String?
    }

    override init() {
        super.init()
        queue.async { self.restore() }
    }

    // MARK: Public API

    /// Connections per download (1–32). Changing it applies to running downloads right away. With
    /// `addsConnectionsAutomatically` on, downloads start with this many and add more while that keeps making
    /// them faster; with it off, this is the exact number they use.
    public var connectionsPerDownload: Int {
        get { queue.sync { startingConnections } }
        set {
            queue.async {
                let value = min(max(newValue, 1), Self.maximumConnections)
                guard value != self.startingConnections else { return }
                self.startingConnections = value
                for job in self.jobs where job.state.isRunning { self.applyConnectionLimit(job, value) }
                self.notify(force: true)
            }
        }
    }

    /// Whether downloads add connections by themselves while that makes them faster.
    public var addsConnectionsAutomatically: Bool {
        get { queue.sync { raisesConnections } }
        set {
            queue.async {
                self.raisesConnections = newValue
                if !newValue { for job in self.jobs where job.state.isRunning { self.applyConnectionLimit(job, self.startingConnections) } }
                self.notify(force: true)
            }
        }
    }

    /// Whether a download that loses its connection tries again by itself.
    public var reconnectsAutomatically: Bool {
        get { queue.sync { reconnects } }
        set { queue.async { self.reconnects = newValue } }
    }

    /// A new limit for a running download: more connections start at once, extra ones (the slowest) are closed
    /// and their ranges go back to the others.
    private func applyConnectionLimit(_ job: Job, _ limit: Int) {
        job.target = limit
        job.speedAtRaise = job.speed
        job.lastRaise = Date()
        guard !job.singleStream else { return }
        let extra = job.tasks.count - limit
        if extra > 0 {
            let slowest = job.tasks.sorted { rate(of: $0.value, in: job) < rate(of: $1.value, in: job) }.prefix(extra)
            for (index, running) in slowest {
                release(job, segment: index)
                running.task.cancel()
            }
        }
        fill(job)
    }

    public func setUpdateHandler(_ handler: UpdateHandler?) {
        queue.async {
            self.updateHandler = handler
            self.notify(force: true)
        }
    }

    public func snapshots() -> [DownloadSnapshot] {
        queue.sync { jobs.map(\.snapshot) }
    }

    /// Downloads (or joins an unfinished download of) a file to `destination`, using every source in parallel.
    public func download(sources: [DownloadSource], to destination: URL, title: String? = nil, sha256: String? = nil,
                         expectedSize: Int64? = nil, progress: Downloader.Progress? = nil) async throws -> URL {
        precondition(!sources.isEmpty, "a download needs at least one source")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async {
                let job: Job
                if let existing = self.jobs.first(where: { $0.destination == destination && $0.state != .completed && $0.state != .cancelled }) {
                    job = existing
                    // A newer request may know more servers (or the checksum) than a restored one.
                    for source in sources where !job.sources.contains(where: { $0.source.url == source.url }) {
                        if source.isMirror && job.sha256 == nil { continue }
                        job.sources.append(SourceState(source))
                    }
                } else {
                    let usable = sources.filter { !$0.isMirror || sha256 != nil }
                    job = Job(title: title ?? destination.lastPathComponent, sources: usable.isEmpty ? [sources[0]] : usable,
                              destination: destination, sha256: sha256, expectedSize: expectedSize)
                    self.jobs.append(job)
                }
                job.waiters.append(continuation)
                if let progress { job.progressHandlers.append(progress) }
                if job.state == .queued || job.state == .paused || job.state == .failed { self.begin(job) }
                self.notify(force: true)
            }
        }
    }

    /// Single-URL convenience.
    public func download(_ url: URL, to destination: URL, title: String? = nil, sha256: String? = nil,
                         progress: Downloader.Progress? = nil) async throws -> URL {
        try await download(sources: [DownloadSource(url: url)], to: destination, title: title, sha256: sha256, progress: progress)
    }

    public func pause(_ id: UUID) {
        queue.async {
            guard let job = self.job(id), job.state.isRunning || job.state == .reconnecting else { return }
            job.state = .paused
            job.retryAt = nil
            self.stopTasks(job)
            self.persist(job)
            self.notify(force: true)
        }
    }

    public func resume(_ id: UUID) {
        queue.async {
            guard let job = self.job(id), job.state == .paused || job.state == .failed || job.state == .reconnecting else { return }
            job.reconnectAttempts = 0
            self.begin(job)
            self.notify(force: true)
        }
    }

    public func cancel(_ id: UUID) {
        queue.async {
            guard let job = self.job(id), job.state != .completed else { return }
            job.state = .cancelled
            self.stopTasks(job)
            self.closeFile(job)
            try? FileManager.default.removeItem(at: job.partURL)
            try? FileManager.default.removeItem(at: job.stateURL)
            self.finishWaiters(job, .failure(DownloadError.cancelled))
            self.notify(force: true)
        }
    }

    /// Takes a download that is no longer wanted off the list (stopping it first), with its partial file.
    public func discard(destination: URL) {
        queue.async {
            for job in self.jobs where job.destination == destination && job.state != .completed {
                job.state = .cancelled
                self.stopTasks(job)
                self.closeFile(job)
                try? FileManager.default.removeItem(at: job.partURL)
                try? FileManager.default.removeItem(at: job.stateURL)
                self.finishWaiters(job, .failure(DownloadError.cancelled))
            }
            self.jobs.removeAll { $0.destination == destination && $0.state == .cancelled }
            self.notify(force: true)
        }
    }

    /// Removes finished, failed or cancelled downloads from the list.
    public func clearFinished() {
        queue.async {
            for job in self.jobs where job.state == .failed {
                try? FileManager.default.removeItem(at: job.partURL)
                try? FileManager.default.removeItem(at: job.stateURL)
            }
            self.jobs.removeAll { $0.state == .completed || $0.state == .cancelled || $0.state == .failed }
            self.notify(force: true)
        }
    }

    // MARK: Engine

    private func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    private var activeConnections: Int { jobs.reduce(0) { $0 + $1.tasks.count } }

    private func takeSlot() -> Int? {
        guard let slot = freeSlots.min() else { return nil }
        freeSlots.remove(slot)
        return slot
    }

    private func session(for slot: Int) -> URLSession {
        if let session = sessions[slot] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Cell/0.3 (macOS)", "Accept-Encoding": "identity"]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        sessions[slot] = session
        return session
    }

    private func begin(_ job: Job) {
        job.error = nil
        job.state = .connecting
        job.retryAt = nil
        job.permanentFailure = false
        job.receivedAtReconnect = job.received
        job.startedAt = Date()
        job.sampleTime = Date()
        job.sampleBytes = job.received
        job.target = min(max(startingConnections, 1), Self.maximumConnections)
        job.lastRaise = Date()
        job.speedAtRaise = 0
        job.errorsSinceRaise = 0
        for index in job.segments.indices { job.segments[index].retries = 0 }
        do {
            try openFile(job)
        } catch {
            fail(job, "Can't write \(job.partURL.lastPathComponent): \(error.localizedDescription)", permanent: true)
            return
        }
        // Always re-resolve: signed download links expire after a few minutes, and mirrors come and go.
        for source in job.sources {
            source.phase = .idle
            source.resolvedURL = nil
            source.problem = nil
            source.consecutiveErrors = 0
            source.probeAttempts = 0
            source.restUntil = .distantPast
            source.cap = max(1, source.source.maxConnections)
            source.speed = 0
            source.reportedTotal = nil
            source.connectionRate = 0
            source.limited = false
            source.peakAccepted = 0
            source.limitStrikes = 0
        }
        job.totalIsTrusted = job.expectedSize != nil
        for index in job.sources.indices where usable(job, index) { probe(job, index) }
        startTimer()
    }

    private func usable(_ job: Job, _ index: Int) -> Bool {
        !(job.mirrorsDisabled && job.sources[index].source.isMirror)
    }

    private func probe(_ job: Job, _ index: Int) {
        let source = job.sources[index]
        guard source.phase != .probing, let slot = takeSlot() else { return }
        source.phase = .probing
        source.probeAttempts += 1
        var request = URLRequest(url: source.source.url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15
        let task = session(for: slot).dataTask(with: request)
        routes[ObjectIdentifier(task)] = Route(job: job, segment: nil, source: index, slot: slot)
        task.resume()
    }

    private func openFile(_ job: Job) throws {
        guard job.fd < 0 else { return }
        try FileManager.default.createDirectory(at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(job.partURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        job.fd = fd
    }

    private func closeFile(_ job: Job) {
        if job.fd >= 0 { close(job.fd) }
        job.fd = -1
    }

    /// Initial ranges: a few per connection, so fast connections can keep pulling work.
    static func makeSegments(total: Int64, connections: Int) -> [Segment] {
        guard total > 0 else { return [Segment(start: 0, end: Int64.max, current: 0)] }
        let count = Int(max(1, min(Int64(connections), total / minimumSplit)))
        let size = total / Int64(count)
        return (0..<count).map { index in
            let start = Int64(index) * size
            let end = index == count - 1 ? total - 1 : start + size - 1
            return Segment(start: start, end: end, current: start)
        }
    }

    /// Total size from `Content-Range: bytes 0-0/12345`.
    static func totalFromContentRange(_ value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// Picks the server for the next connection: one that hasn't been measured yet, otherwise the one that
    /// delivers the most per connection. Servers far slower than the best one get no new connections.
    private func pickSource(_ job: Job) -> Int? {
        // For the first seconds, while servers are still answering, nobody gets more than four connections.
        let warmingUp = Date().timeIntervalSince(job.startedAt) < 2.5
        let candidates = job.sources.indices.filter { index in
            let source = job.sources[index]
            return usable(job, index) && source.isUsable && source.active < (warmingUp ? min(source.cap, 4) : source.cap)
        }
        guard !candidates.isEmpty else { return nil }
        if let unmeasured = candidates.first(where: { job.sources[$0].active == 0 && job.sources[$0].received == 0 }) {
            return unmeasured
        }
        let best = job.sources.indices.filter { usable(job, $0) && job.sources[$0].phase == .ready }
            .map { job.sources[$0].perConnection }.max() ?? 0
        // Fastest per connection first; while servers are unmeasured, spread connections evenly.
        let ranked = candidates.sorted {
            let a = job.sources[$0], b = job.sources[$1]
            return a.perConnection != b.perConnection ? a.perConnection > b.perConnection : a.active < b.active
        }
        guard let first = ranked.first else { return nil }
        let source = job.sources[first]
        // A server already being tried gets no more connections until it has been measured,
        // and a server far slower than the best one gets none at all.
        if source.active > 0 && source.perConnection == 0 { return nil }
        if best > 0, source.perConnection < best * 0.2, source.active > 0 { return nil }
        return first
    }

    private func nextPendingSegment(_ job: Job) -> Int? {
        job.segments.indices.first { !job.segments[$0].isDone && job.tasks[$0] == nil }
    }

    /// Bytes per second a running connection achieves (its own measurement once it has some, otherwise its server's).
    private func rate(of running: Running, in job: Job) -> Double {
        let elapsed = Date().timeIntervalSince(running.startedAt)
        if elapsed > 0.3, running.received > 0 { return Double(running.received) / elapsed }
        if elapsed > 2, running.received == 0 { return 1024 }   // connected (or not) but nothing came: not a fast one
        let source = job.sources[running.source].perConnection
        return source > 0 ? source : 64 * 1024
    }

    /// Gives part of the range that will take longest to finish to a new connection on `sourceIndex`.
    /// The new connection takes the tail, sized by how fast both are; the running connection keeps only
    /// what it can finish in about half a second, so a slow server never holds up the end of a download.
    private func split(_ job: Job, for sourceIndex: Int) -> Int? {
        guard job.rangesSupported, !job.singleStream else { return nil }
        let newSpeed = max(job.sources[sourceIndex].perConnection, 64 * 1024)
        var choice: (index: Int, finish: Double, speed: Double)?
        for (index, running) in job.tasks {
            let segment = job.segments[index]
            guard !segment.isDone, segment.end != Int64.max else { continue }
            let speed = max(rate(of: running, in: job), 8 * 1024)
            let finish = Double(segment.remaining) / speed
            if choice == nil || finish > choice!.finish { choice = (index, finish, speed) }
        }
        guard let choice else { return nil }
        let segment = job.segments[choice.index]
        let keep = max(Int64(choice.speed * 0.5), 16 * 1024)
        var share = Int64(Double(segment.remaining) * newSpeed / (newSpeed + choice.speed))
        share = min(share, segment.remaining - keep)
        // A new request costs a round trip: only for a sizeable piece, or when the old connection would take long.
        guard share >= Self.minimumSplit || (share >= 64 * 1024 && choice.finish > 1.5) else { return nil }
        let newStart = segment.end - share + 1
        job.segments[choice.index].end = newStart - 1
        job.segments.append(Segment(start: newStart, end: segment.end, current: newStart))
        return job.segments.count - 1
    }

    /// Starts connections until the download's limit is reached or there is nothing left to hand out.
    private func fill(_ job: Job) {
        guard job.state.isRunning, job.rangesSupported, !job.singleStream else { return }
        if !job.segments.isEmpty, job.segments.allSatisfy(\.isDone) { finalize(job); return }
        while job.tasks.count < job.target, activeConnections < Self.globalConnectionLimit, !freeSlots.isEmpty {
            guard let source = pickSource(job) else { break }
            if let pending = nextPendingSegment(job) {
                start(job, segment: pending, source: source)
            } else if let piece = split(job, for: source) {
                start(job, segment: piece, source: source)
            } else {
                break
            }
        }
        rebalance(job)
        // Every server that answered gets at least one connection (even above the limit), so a fast
        // server that answered late is measured and can take over work.
        for index in job.sources.indices where usable(job, index) {
            let source = job.sources[index]
            guard source.isUsable, source.active == 0, source.received == 0,
                  job.tasks.count < (raisesConnections ? Self.maximumConnections : job.target),
                  activeConnections < Self.globalConnectionLimit, !freeSlots.isEmpty else { continue }
            if let pending = nextPendingSegment(job) {
                start(job, segment: pending, source: index)
            } else if let piece = split(job, for: index) {
                start(job, segment: piece, source: index)
            }
        }
    }

    /// Sets the file size (once) and lays out the ranges.
    private func adoptTotal(_ job: Job, _ total: Int64, trusted: Bool) {
        if trusted { job.totalIsTrusted = true }
        if !job.rangesSupported || job.total != total || job.segments.isEmpty {
            let resuming = job.rangesSupported && job.total == total && !job.segments.isEmpty
            job.total = total
            job.rangesSupported = true
            job.singleStream = false
            if !resuming {
                job.segments = Self.makeSegments(total: total, connections: job.target)
                ftruncate(job.fd, off_t(total))
            }
        }
        if job.state == .connecting { job.state = .downloading }
    }

    /// Hands work from much slower servers to faster ones that have room, even at the connection limit.
    private func rebalance(_ job: Job) {
        for _ in 0..<8 {
            guard job.tasks.count < (raisesConnections ? Self.maximumConnections : job.target),
                  activeConnections < Self.globalConnectionLimit, !freeSlots.isEmpty else { return }
            let candidates = job.sources.indices.filter { usable(job, $0) && job.sources[$0].isUsable && job.sources[$0].active < job.sources[$0].cap }
            guard let fast = candidates.max(by: { job.sources[$0].perConnection < job.sources[$1].perConnection }) else { return }
            let slowest = job.tasks.values.map { rate(of: $0, in: job) }.min() ?? 0
            let fastRate = job.sources[fast].perConnection
            guard fastRate > 0, slowest > 0, fastRate > slowest * 2, let piece = split(job, for: fast) else { return }
            start(job, segment: piece, source: fast)
        }
    }

    private func start(_ job: Job, segment index: Int, source sourceIndex: Int) {
        let source = job.sources[sourceIndex]
        guard let slot = takeSlot() else { return }
        var request = URLRequest(url: source.resolvedURL ?? source.source.url)
        let segment = job.segments[index]
        if job.rangesSupported && !job.singleStream {
            request.setValue("bytes=\(segment.current)-\(segment.end)", forHTTPHeaderField: "Range")
        }
        let task = session(for: slot).dataTask(with: request)
        job.tasks[index] = Running(task: task, source: sourceIndex, slot: slot, lastData: Date())
        source.active += 1
        routes[ObjectIdentifier(task)] = Route(job: job, segment: index, source: sourceIndex, slot: slot)
        task.resume()
    }

    /// Frees a connection's slot and bookkeeping (the task itself is cancelled or finished by the caller).
    private func release(_ job: Job, segment index: Int) {
        guard let running = job.tasks.removeValue(forKey: index) else { return }
        let elapsed = Date().timeIntervalSince(running.startedAt)
        // Short connections are dominated by TCP slow start and the first burst: only count real samples.
        if running.received >= 1024 * 1024 || (elapsed >= 0.5 && running.received >= 64 * 1024) {
            job.sources[running.source].noteConnectionRate(Double(running.received) / elapsed)
        }
        routes[ObjectIdentifier(running.task)] = nil
        job.sources[running.source].active = max(0, job.sources[running.source].active - 1)
        freeSlots.insert(running.slot)
    }

    private func stopTasks(_ job: Job) {
        for (index, running) in job.tasks {
            release(job, segment: index)
            running.task.cancel()
        }
        for (key, route) in routes where route.job === job {
            routes[key] = nil
            freeSlots.insert(route.slot)
        }
        for source in job.sources where source.phase == .probing { source.phase = .idle }
    }

    /// A connection to a server failed. When its other connections keep delivering, the server is fine and
    /// just doesn't take more connections from one address (it refuses, ignores or starves the extra ones):
    /// it keeps the number that works. Otherwise it is rested and gets fewer connections, and after repeated
    /// failures with nothing left running it is dropped.
    private func penalize(_ job: Job, _ index: Int, _ reason: String, hard: Bool = false) {
        let source = job.sources[index]
        job.errorsSinceRaise += 1
        if hard { job.permanentFailure = true }
        let now = Date()
        let delivering = job.tasks.values.filter { $0.source == index && $0.received > 0 && now.timeIntervalSince($0.lastData) < 5 }.count
        if !hard, delivering > 0 {
            // The number it has served at once is what it allows. A refusal below that is usually a connection
            // it hasn't closed yet: wait a moment; only after three in a row is the number lowered.
            source.limitStrikes += 1
            if source.limitStrikes >= 3 {
                source.peakAccepted = max(1, source.active)
                source.limitStrikes = 0
            }
            source.cap = max(1, source.active, source.peakAccepted)
            source.limited = true
            source.consecutiveErrors = 0
            source.restUntil = now.addingTimeInterval(1.5)
            source.problem = "takes \(source.cap) connection\(source.cap == 1 ? "" : "s") at a time"
            return
        }
        source.problem = reason
        source.consecutiveErrors += 1
        source.cap = max(1, min(source.cap, source.active + 1) - 1)
        source.restUntil = now.addingTimeInterval(min(pow(2, Double(source.consecutiveErrors)), 30))
        // Connections still waiting for their answer may yet work (a burst of refusals at the start).
        let pending = job.tasks.values.contains { $0.source == index }
        if hard || (source.consecutiveErrors >= 6 && !pending) {
            source.phase = .failed
        }
        checkSourcesLeft(job, reason: reason)
    }

    /// Fails the download when no server is left; falls back to one stream when none supports ranges.
    private func checkSourcesLeft(_ job: Job, reason: String) {
        guard job.state.isRunning else { return }
        let indices = job.sources.indices.filter { usable(job, $0) }
        let officialAlive = indices.contains { !job.sources[$0].source.isMirror && [.ready, .probing, .idle].contains(job.sources[$0].phase) }
        if !officialAlive {
            // No official server: trust the size most mirrors agree on (the checksum still guards the file).
            let waiting = indices.filter { job.sources[$0].phase == .waiting }
            let sizes = Dictionary(grouping: waiting.compactMap { job.sources[$0].reportedTotal }, by: { $0 })
            if let size = sizes.max(by: { $0.value.count < $1.value.count })?.key {
                for index in waiting { job.sources[index].phase = job.sources[index].reportedTotal == size ? .ready : .failed }
                adoptTotal(job, size, trusted: true)
                fill(job)
                return
            }
        }
        if indices.contains(where: { [.ready, .probing, .idle, .waiting].contains(job.sources[$0].phase) }) { return }
        if let plain = indices.first(where: { job.sources[$0].phase == .noRanges }), !job.singleStream {
            startSingleStream(job, source: plain)
            return
        }
        if !job.singleStream || job.tasks.isEmpty {
            // Every server says the file isn't there: reconnecting would only ask again and again.
            fail(job, reason, permanent: job.sources.allSatisfy(\.missing))
        }
    }

    private func startSingleStream(_ job: Job, source index: Int) {
        stopTasks(job)
        job.singleStream = true
        job.rangesSupported = false
        job.sources[index].phase = .ready
        job.segments = [Segment(start: 0, end: job.total > 0 ? job.total - 1 : Int64.max, current: 0)]
        ftruncate(job.fd, 0)
        job.state = .downloading
        start(job, segment: 0, source: index)
    }

    private func requeue(_ job: Job, _ index: Int, after delay: TimeInterval = 0) {
        guard delay > 0 else { fill(job); return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, job.state.isRunning else { return }
            if job.singleStream {
                if index < job.segments.count, job.tasks[index] == nil, !job.segments[index].isDone,
                   let source = job.sources.indices.first(where: { job.sources[$0].phase == .ready }) {
                    job.segments[index].current = job.segments[index].start
                    self.start(job, segment: index, source: source)
                }
            } else {
                self.fill(job)
            }
        }
    }

    /// The download can't go on right now. Unless reconnecting can't help, it waits a little (longer each
    /// time, up to a minute) and carries on where it stopped; it also carries on the moment the network is back.
    private func fail(_ job: Job, _ message: String, permanent: Bool = false) {
        stopTasks(job)
        if reconnects, !permanent, !job.permanentFailure, job.reconnectAttempts < Self.maximumReconnects {
            if job.received > job.receivedAtReconnect + Self.minimumSplit { job.reconnectAttempts = 0 }
            job.reconnectAttempts += 1
            let delay = min(pow(2, Double(job.reconnectAttempts)), 60)
            let retryAt = Date().addingTimeInterval(delay)
            job.state = .reconnecting
            job.error = message
            job.retryAt = retryAt
            persist(job)
            watchNetwork()
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, job.state == .reconnecting, job.retryAt == retryAt else { return }
                self.begin(job)
                self.notify(force: true)
            }
            notify(force: true)
            return
        }
        job.state = .failed
        job.error = message
        job.retryAt = nil
        closeFile(job)
        persist(job)
        finishWaiters(job, .failure(DownloadError.failed(message)))
        notify(force: true)
    }

    /// Downloads waiting to reconnect carry on as soon as the Mac has a network again.
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        var wasSatisfied = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            defer { wasSatisfied = satisfied }
            guard satisfied, !wasSatisfied else { return }
            for job in self.jobs where job.state == .reconnecting {
                job.retryAt = nil
                self.begin(job)
            }
            self.notify(force: true)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func finishWaiters(_ job: Job, _ result: Result<URL, Error>) {
        let waiters = job.waiters
        job.waiters.removeAll()
        job.progressHandlers.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func finalize(_ job: Job) {
        guard job.state.isRunning else { return }
        stopTasks(job)
        closeFile(job)
        if job.total > 0 { truncate(job.partURL.path, off_t(job.total)) }
        job.state = .verifying
        notify(force: true)
        let part = job.partURL
        let destination = job.destination
        let expected = job.sha256
        let usedMirrors = job.sources.contains { $0.source.isMirror && $0.received > 0 }
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<URL, Error>
            if let expected, Self.sha256(of: part) != expected {
                try? FileManager.default.removeItem(at: part)
                result = .failure(DownloadError.checksumMismatch(destination.lastPathComponent))
            } else {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: part, to: destination)
                    result = .success(destination)
                } catch {
                    result = .failure(error)
                }
            }
            self.queue.async {
                switch result {
                case .success:
                    job.state = .completed
                    try? FileManager.default.removeItem(at: job.stateURL)
                    self.finishWaiters(job, result)
                case .failure(let error):
                    job.segments = []
                    job.total = -1
                    job.rangesSupported = false
                    job.singleStream = false
                    if case DownloadError.checksumMismatch = error, usedMirrors, !job.mirrorsDisabled {
                        // A mirror sent something else. Start over from the official server only.
                        job.mirrorsDisabled = true
                        job.state = .queued
                        self.begin(job)
                    } else {
                        self.fail(job, error.localizedDescription, permanent: true)
                    }
                }
                self.notify(force: true)
            }
        }
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Adapting (every second)

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        let running = jobs.filter { $0.state.isRunning }
        if running.isEmpty {
            timer?.cancel()
            timer = nil
            return
        }
        let now = Date()
        for job in running {
            // Per-server speed.
            for source in job.sources {
                let delta = Double(source.received - source.sampleBytes)
                source.sampleBytes = source.received
                source.speed = source.speed == 0 ? delta : source.speed * 0.6 + delta * 0.4
                if source.phase == .ready, source.restUntil <= now, source.consecutiveErrors > 0, source.active > 0, delta > 0 {
                    source.consecutiveErrors = 0
                    source.problem = nil
                }
            }
            // Rates of connections that are still running.
            for running in job.tasks.values {
                let elapsed = now.timeIntervalSince(running.startedAt)
                if elapsed > 1, running.received > 0 {
                    job.sources[running.source].noteConnectionRate(Double(running.received) / elapsed)
                }
            }
            // Servers far slower than the best one keep a single connection (to keep measuring); their
            // other connections are closed and the work goes to faster servers.
            let best = job.sources.indices.filter { usable(job, $0) && job.sources[$0].phase == .ready }
                .map { job.sources[$0].perConnection }.max() ?? 0
            for (sourceIndex, source) in job.sources.enumerated()
            where best > 0 && source.active > 1 && source.perConnection > 0 && source.perConnection < best * 0.2 {
                let theirs = job.tasks.filter { $0.value.source == sourceIndex }
                    .sorted { job.segments[$0.key].remaining < job.segments[$1.key].remaining }
                for (segmentIndex, running) in theirs.dropFirst() {
                    release(job, segment: segmentIndex)
                    running.task.cancel()
                }
            }
            // Replace stalled connections.
            // (A connection that got nothing at all for five seconds from a server that has been delivering
            // is one the server lets wait: its range goes back right away.)
            for (index, running) in job.tasks {
                let silent = now.timeIntervalSince(running.lastData)
                let starved = running.received == 0 && silent > 5 && job.sources[running.source].received > 0
                guard silent > Self.stallTimeout || starved else { continue }
                release(job, segment: index)
                running.task.cancel()
                penalize(job, running.source, "stopped sending data")
            }
            // More connections while that keeps paying off.
            if job.state == .downloading, !job.singleStream, now.timeIntervalSince(job.lastRaise) >= 3 {
                let capacity = job.sources.indices.filter { usable(job, $0) && job.sources[$0].phase == .ready }
                    .reduce(0) { $0 + job.sources[$1].cap }
                if raisesConnections, job.errorsSinceRaise == 0, job.tasks.count >= job.target, job.target < min(Self.maximumConnections, capacity),
                   job.speed > job.speedAtRaise * 1.08 {
                    job.target = min(job.target + 4, Self.maximumConnections)
                    for source in job.sources where source.phase == .ready && !source.limited && source.cap < source.source.maxConnections * 2 {
                        source.cap = min(source.cap + 1, source.source.maxConnections * 2)
                    }
                    job.speedAtRaise = job.speed
                } else if raisesConnections, job.errorsSinceRaise > 2 {
                    job.target = max(4, job.target - 2)
                    job.speedAtRaise = job.speed
                }
                job.errorsSinceRaise = 0
                job.lastRaise = now
            }
            // Servers back from a rest, or idle ones, get work again; failed probes are retried.
            for index in job.sources.indices where usable(job, index) {
                let source = job.sources[index]
                if source.phase == .idle && source.probeAttempts < 4 && source.restUntil <= now { probe(job, index) }
            }
            fill(job)
            noteProgress(job)
        }
        notify(force: false)
    }

    private func noteProgress(_ job: Job) {
        let now = Date()
        let elapsed = now.timeIntervalSince(job.sampleTime)
        if elapsed >= 0.5 {
            let bytes = job.received
            let instant = Double(bytes - job.sampleBytes) / elapsed
            job.speed = job.speed == 0 ? instant : job.speed * 0.6 + instant * 0.4
            job.sampleTime = now
            job.sampleBytes = bytes
        }
        if now.timeIntervalSince(job.lastPersist) > 3 {
            job.lastPersist = now
            persist(job)
        }
        notify(force: false)
    }

    private func notify(force: Bool) {
        let now = Date()
        if !force && now.timeIntervalSince(lastNotification) < 0.2 {
            if !notificationScheduled {
                notificationScheduled = true
                queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.notificationScheduled = false
                    self?.notify(force: true)
                }
            }
            return
        }
        lastNotification = now
        let snapshots = jobs.map(\.snapshot)
        updateHandler?(snapshots)
        for job in jobs where !job.progressHandlers.isEmpty {
            let snapshot = job.snapshot
            for handler in job.progressHandlers { handler(snapshot.fraction ?? 0, snapshot.receivedBytes, snapshot.totalBytes) }
        }
    }

    // MARK: Persistence (resume after quitting)

    private func persist(_ job: Job) {
        guard job.state != .completed, job.state != .cancelled, !job.segments.isEmpty else { return }
        let record = PersistedJob(id: job.id, title: job.title, url: job.url, sources: job.sources.map(\.source),
                                  destination: job.destination, sha256: job.sha256, expectedSize: job.expectedSize,
                                  total: job.total, rangesSupported: job.rangesSupported && !job.singleStream,
                                  segments: job.segments, failed: job.state == .failed ? job.error : nil)
        try? JSONStore.save(record, to: job.stateURL)
    }

    private func restore() {
        let files = (try? FileManager.default.contentsOfDirectory(at: CellPaths.downloads, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".download.json") {
            guard let record = JSONStore.loadIfPresent(PersistedJob.self, from: file) else { continue }
            let job = Job(id: record.id, title: record.title, sources: record.sources ?? [DownloadSource(url: record.url)],
                          destination: record.destination, sha256: record.sha256, expectedSize: record.expectedSize)
            guard FileManager.default.fileExists(atPath: job.partURL.path) else { try? FileManager.default.removeItem(at: file); continue }
            job.total = record.rangesSupported ? record.total : -1
            job.rangesSupported = record.rangesSupported
            job.segments = record.rangesSupported ? record.segments : []
            job.state = record.failed == nil ? .paused : .failed
            job.error = record.failed
            jobs.append(job)
        }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let key = ObjectIdentifier(dataTask)
        guard let route = routes[key] else { completionHandler(.cancel); return }
        let job = route.job
        let source = job.sources[route.source]
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        guard let index = route.segment else {
            // Probe.
            routes[key] = nil
            freeSlots.insert(route.slot)
            completionHandler(.cancel)
            guard job.state.isRunning else { return }
            source.resolvedURL = response.url ?? source.source.url
            let rangeTotal = status == 206 ? Self.totalFromContentRange(http?.value(forHTTPHeaderField: "Content-Range")) : nil
            if let total = rangeTotal {
                source.reportedTotal = total
                let trusted = !source.source.isMirror
                let known: Int64? = job.expectedSize ?? (job.totalIsTrusted && job.total > 0 ? job.total : nil)
                if let known, known != total {
                    source.phase = .failed
                    source.problem = "has a different file"
                    checkSourcesLeft(job, reason: "\(source.source.label) has a different file")
                    return
                }
                if known == nil && !trusted {
                    // Wait for the official server's answer before trusting a mirror's size.
                    source.phase = .waiting
                    checkSourcesLeft(job, reason: "no server answered")
                    return
                }
                source.phase = .ready
                source.problem = nil
                adoptTotal(job, total, trusted: true)
                for other in job.sources where other.phase == .waiting {
                    other.phase = other.reportedTotal == total ? .ready : .failed
                    if other.phase == .failed { other.problem = "has a different file" }
                }
                fill(job)
            } else if (200..<300).contains(status) {
                source.phase = .noRanges
                source.problem = "can't resume (no range support)"
                if job.total < 0, response.expectedContentLength > 0 { job.total = response.expectedContentLength }
                checkSourcesLeft(job, reason: "no server supports ranges")
            } else {
                source.phase = .failed
                source.problem = "answered \(status)"
                source.missing = status == 404 || status == 410
                checkSourcesLeft(job, reason: source.missing ? "the file isn't on the server (\(status))" : "the server answered \(status)")
            }
            notify(force: true)
            return
        }

        if status == 206 || (job.singleStream && (200..<300).contains(status)) {
            if job.singleStream, job.total <= 0, response.expectedContentLength > 0 {
                job.total = response.expectedContentLength
                job.segments[index].end = job.total - 1
            }
            if job.state == .connecting { job.state = .downloading }
            job.tasks[index]?.accepted = true
            let serving = job.tasks.values.filter { $0.source == route.source && $0.accepted }.count
            if serving > source.peakAccepted { source.peakAccepted = serving }
            source.limitStrikes = 0
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
        release(job, segment: index)
        switch status {
        case 200:
            if job.tasks.values.contains(where: { $0.source == route.source && $0.accepted }) {
                // Its other connections get their ranges: it only ignores them on extra connections.
                penalize(job, route.source, "ignored the byte range")
                requeue(job, index, after: 0.5)
            } else {
                source.phase = .noRanges
                source.problem = "ignored the byte range"
                checkSourcesLeft(job, reason: "no server supports ranges")
                requeue(job, index)
            }
        case 403, 410:
            // Signed link expired (GitHub): resolve a fresh one.
            source.phase = .idle
            source.resolvedURL = nil
            source.probeAttempts = 0
            probe(job, route.source)
        case 404, 416:
            penalize(job, route.source, "answered \(status)", hard: true)
            requeue(job, index)
        default:
            penalize(job, route.source, "answered \(status)")
            requeue(job, index, after: 0.5)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = ObjectIdentifier(dataTask)
        guard let route = routes[key], let index = route.segment else { return }
        let job = route.job
        guard job.state.isRunning, index < job.segments.count, job.fd >= 0 else { return }
        var segment = job.segments[index]
        let room = segment.end == Int64.max ? Int64(data.count) : max(0, segment.end - segment.current + 1)
        let count = Int(min(Int64(data.count), room))
        if count > 0 {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var done = 0
                while done < count {
                    let result = pwrite(job.fd, base + done, count - done, off_t(segment.current) + off_t(done))
                    if result <= 0 { break }
                    done += result
                }
                return done
            }
            segment.current += Int64(written)
            job.sources[route.source].received += Int64(written)
            if written < count {
                job.segments[index] = segment
                fail(job, "writing to disk failed (is the disk full?)", permanent: true)
                return
            }
        }
        job.tasks[index]?.lastData = Date()
        job.tasks[index]?.received += Int64(count)
        if job.state == .connecting { job.state = .downloading }
        job.segments[index] = segment
        if segment.isDone {
            // Reached its end (possibly shortened because another connection took over the tail).
            release(job, segment: index)
            dataTask.cancel()
            job.sources[route.source].consecutiveErrors = 0
            segmentFinished(job)
        }
        noteProgress(job)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = ObjectIdentifier(task)
        guard let route = routes[key] else { return }
        let job = route.job
        guard let index = route.segment else {
            // Probe failed before a response arrived.
            routes[key] = nil
            freeSlots.insert(route.slot)
            guard job.state.isRunning else { return }
            let source = job.sources[route.source]
            source.problem = error?.localizedDescription ?? "no answer"
            if source.probeAttempts >= 4 {
                source.phase = .failed
                checkSourcesLeft(job, reason: error?.localizedDescription ?? "no answer from the server")
            } else {
                source.phase = .idle
                source.restUntil = Date().addingTimeInterval(Double(source.probeAttempts) * 2)
            }
            return
        }
        release(job, segment: index)
        guard job.state.isRunning, index < job.segments.count else { return }
        if job.segments[index].end == Int64.max, error == nil {
            // Unknown-length stream finished.
            job.total = job.segments[index].current
            job.segments[index].end = max(job.total - 1, 0)
        }
        if job.segments[index].isDone || (job.total == 0 && error == nil) {
            job.sources[route.source].consecutiveErrors = 0
            segmentFinished(job)
        } else {
            let reason = error?.localizedDescription ?? "the connection closed early"
            job.segments[index].retries += 1
            if job.singleStream {
                guard job.segments[index].retries <= 8 else { fail(job, reason); return }
                requeue(job, index, after: min(Double(job.segments[index].retries) * 1.5, 10))
            } else {
                penalize(job, route.source, reason)
                requeue(job, index, after: 0.2)
            }
        }
        notify(force: false)
    }

    private func segmentFinished(_ job: Job) {
        if !job.segments.isEmpty, job.segments.allSatisfy(\.isDone) {
            finalize(job)
        } else if job.rangesSupported, !job.singleStream {
            fill(job)
        }
    }
}

private extension DownloadSnapshot.State {
    var isRunning: Bool { self == .connecting || self == .downloading || self == .queued }
}

/// Convenience used by installers. Every download appears in the Downloads page and can be paused.
public enum Downloader {
    public typealias Progress = @Sendable (_ fraction: Double, _ received: Int64, _ total: Int64) -> Void

    /// Downloads `url`, adding verified mirrors automatically (GitHub release files get public download
    /// proxies once their SHA-256 is known).
    public static func download(_ url: URL, to destination: URL, title: String? = nil, sha256: String? = nil,
                                expectedSize: Int64? = nil, progress: Progress? = nil) async throws -> URL {
        let plan = await DownloadMirrors.plan(for: url, sha256: sha256)
        return try await DownloadManager.shared.download(sources: plan.sources, to: destination, title: title,
                                                         sha256: plan.sha256, expectedSize: expectedSize ?? plan.size, progress: progress)
    }

    public static func download(sources: [DownloadSource], to destination: URL, title: String? = nil, sha256: String? = nil,
                                expectedSize: Int64? = nil, progress: Progress? = nil) async throws -> URL {
        try await DownloadManager.shared.download(sources: sources, to: destination, title: title, sha256: sha256,
                                                  expectedSize: expectedSize, progress: progress)
    }
}
