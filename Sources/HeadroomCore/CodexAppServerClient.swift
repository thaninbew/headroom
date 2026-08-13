import Darwin
import Foundation

public enum CodexMeterError: LocalizedError, Equatable {
    case codexNotFound
    case launchFailed(String)
    case timeout
    case processExited(Int32, String)
    case rpc(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex was not found. Install Codex CLI or add it to PATH."
        case let .launchFailed(message):
            return "Could not launch Codex app-server: \(message)"
        case .timeout:
            return "Codex did not return quota information in time."
        case let .processExited(code, message):
            return "Codex app-server exited with status \(code): \(message)"
        case let .rpc(message):
            return "Codex app-server returned an error: \(message)"
        case .malformedResponse:
            return "Codex returned quota information in an unsupported format."
        }
    }
}

public struct CodexCommand: Equatable, Sendable {
    public let executableURL: URL
    public let prefixArguments: [String]

    public init(executableURL: URL, prefixArguments: [String] = []) {
        self.executableURL = executableURL
        self.prefixArguments = prefixArguments
    }

    public static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexCommand {
        if let explicit = environment["HEADROOM_CODEX_PATH"], FileManager.default.isExecutableFile(atPath: explicit) {
            return CodexCommand(executableURL: URL(fileURLWithPath: explicit))
        }
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in pathEntries + common {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return CodexCommand(executableURL: candidate)
            }
        }
        throw CodexMeterError.codexNotFound
    }
}

public struct CodexAppServerClient: Sendable {
    public let command: CodexCommand
    public let timeout: TimeInterval

    public init(command: CodexCommand? = nil, timeout: TimeInterval = 10) throws {
        self.command = try command ?? .discover()
        self.timeout = timeout
    }

    public func readRateLimits() throws -> RateLimitSnapshot {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.prefixArguments + ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw CodexMeterError.launchFailed(error.localizedDescription)
        }

        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
            stop(process)
        }

        let requests: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "headroom",
                        "title": "Headroom",
                        "version": "0.1.0",
                    ],
                    "capabilities": [:],
                ],
            ],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 2],
        ]
        for request in requests {
            var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        return try waitForRateLimits(
            outputFD: output.fileHandleForReading.fileDescriptor,
            errorFD: error.fileHandleForReading.fileDescriptor,
            process: process
        )
    }

    private func waitForRateLimits(outputFD: Int32, errorFD: Int32, process: Process) throws -> RateLimitSnapshot {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var descriptor = pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let result = Darwin.poll(&descriptor, 1, min(remaining, 200))
            if result > 0, descriptor.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = Darwin.read(outputFD, &bytes, bytes.count)
                if count > 0 {
                    buffer.append(contentsOf: bytes.prefix(Int(count)))
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        if let snapshot = try parseResponse(Data(line)) { return snapshot }
                    }
                }
            }
            if !process.isRunning {
                let message = readAvailable(fd: errorFD)
                throw CodexMeterError.processExited(process.terminationStatus, message)
            }
        }
        throw CodexMeterError.timeout
    }

    private func parseResponse(_ data: Data) throws -> RateLimitSnapshot? {
        guard !data.isEmpty,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard (object["id"] as? NSNumber)?.intValue == 2 else { return nil }
        if let rpcError = object["error"] as? [String: Any] {
            throw CodexMeterError.rpc(rpcError["message"] as? String ?? "unknown RPC error")
        }
        guard let result = object["result"] as? [String: Any],
              let rateLimits = result["rateLimits"] as? [String: Any]
        else { throw CodexMeterError.malformedResponse }
        return RateLimitSnapshot(
            primary: decodeWindow(rateLimits["primary"]),
            secondary: decodeWindow(rateLimits["secondary"])
        )
    }

    private func decodeWindow(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.intValue
        else { return nil }
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMins: (object["windowDurationMins"] as? NSNumber)?.intValue,
            resetsAt: (object["resetsAt"] as? NSNumber)?.intValue
        )
    }

    private func readAvailable(fd: Int32) -> String {
        let original = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, original | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, original) }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else { return "no diagnostic output" }
        return String(decoding: bytes.prefix(Int(count)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 {
            if !process.isRunning { return }
            usleep(10_000)
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
        for _ in 0..<20 {
            if !process.isRunning { return }
            usleep(10_000)
        }
    }
}

public struct MeterService: Sendable {
    public let client: CodexAppServerClient
    public let statusStore: StatusStore
    public let lock: FileLock

    public init(
        client: CodexAppServerClient,
        statusStore: StatusStore = StatusStore(),
        lock: FileLock = FileLock()
    ) {
        self.client = client
        self.statusStore = statusStore
        self.lock = lock
    }

    public func refresh(coalesceWithin interval: TimeInterval = 0) throws -> RateLimitSnapshot {
        try lock.withExclusiveLock {
            if interval > 0,
               let cached = try? statusStore.load(),
               let snapshot = cached.snapshot,
               cached.error == nil,
               Date().timeIntervalSince(cached.checkedAt) <= interval {
                return snapshot
            }
            do {
                let snapshot = try client.readRateLimits()
                try? statusStore.save(HeadroomStatus(snapshot: snapshot, error: nil))
                return snapshot
            } catch {
                try? statusStore.save(HeadroomStatus(snapshot: nil, error: error.localizedDescription))
                throw error
            }
        }
    }
}
