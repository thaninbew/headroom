import Darwin
import Foundation

public enum HeadroomPaths {
    public static var defaultHome: URL {
        if let override = ProcessInfo.processInfo.environment["HEADROOM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func supportDirectory(home: URL = defaultHome) -> URL {
        home.appendingPathComponent("Library/Application Support/Headroom", isDirectory: true)
    }

    public static func configurationURL(home: URL = defaultHome) -> URL {
        supportDirectory(home: home).appendingPathComponent("config.json")
    }

    public static func statusURL(home: URL = defaultHome) -> URL {
        supportDirectory(home: home).appendingPathComponent("status.json")
    }

    public static func hooksURL(home: URL = defaultHome) -> URL {
        home.appendingPathComponent(".codex/hooks.json")
    }

    public static func meterLockURL(home: URL = defaultHome) -> URL {
        supportDirectory(home: home).appendingPathComponent("meter.lock")
    }
}

public struct ConfigurationStore: Sendable {
    public let url: URL

    public init(url: URL = HeadroomPaths.configurationURL()) {
        self.url = url
    }

    public func load() throws -> HeadroomConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        return try JSONDecoder().decode(HeadroomConfiguration.self, from: Data(contentsOf: url))
    }

    public func save(_ configuration: HeadroomConfiguration) throws {
        try AtomicJSON.write(configuration, to: url)
    }
}

public struct StatusStore: Sendable {
    public let url: URL

    public init(url: URL = HeadroomPaths.statusURL()) {
        self.url = url
    }

    public func load() throws -> HeadroomStatus? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HeadroomStatus.self, from: Data(contentsOf: url))
    }

    public func save(_ status: HeadroomStatus) throws {
        try AtomicJSON.write(status, to: url)
    }
}

public struct FileLock: Sendable {
    public let url: URL

    public init(url: URL = HeadroomPaths.meterLockURL()) {
        self.url = url
    }

    public func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw CocoaError(.fileLocking)
        }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation()
    }
}

enum AtomicJSON {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
