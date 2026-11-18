import Foundation

public enum JSONStore {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    public static func loadIfPresent<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? load(type, from: url)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// Run a closure while holding an exclusive advisory lock on `url` (shared between the app and the CLI).
public func withFileLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let lockURL = url.appendingPathExtension("lock")
    try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
    }
    return try body()
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `defaultValue` when missing or invalid.
    /// Keeps old settings files readable when new fields are added.
    func value<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue()
    }
}
