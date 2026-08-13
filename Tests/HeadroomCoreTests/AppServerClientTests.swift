import Foundation
import Testing
@testable import HeadroomCore

@Suite("Codex app-server client")
struct AppServerClientTests {
    @Test("Reads both quota windows from stdio JSON-RPC")
    func readsRateLimits() throws {
        let fixture = try MockCodexFixture(response: #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1800100000}}}}"#)
        defer { fixture.cleanup() }

        let client = try CodexAppServerClient(
            command: CodexCommand(executableURL: fixture.executable),
            timeout: 2
        )
        let snapshot = try client.readRateLimits()
        #expect(snapshot.primary?.usedPercent == 90)
        #expect(snapshot.primary?.displayName == "5-hour")
        #expect(snapshot.secondary?.usedPercent == 42)
        #expect(snapshot.secondary?.displayName == "Weekly")
    }

    @Test("Does not hang when app-server ignores termination")
    func boundsCleanup() throws {
        let fixture = try MockCodexFixture(
            response: #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":null},"secondary":null}}}"#,
            ignoresTermination: true
        )
        defer { fixture.cleanup() }
        let client = try CodexAppServerClient(
            command: CodexCommand(executableURL: fixture.executable),
            timeout: 2
        )
        let started = ContinuousClock.now
        let snapshot = try client.readRateLimits()
        #expect(snapshot.primary?.usedPercent == 12)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Surfaces RPC errors")
    func reportsRPCError() throws {
        let fixture = try MockCodexFixture(response: #"{"id":2,"error":{"code":-32000,"message":"not logged in"}}"#)
        defer { fixture.cleanup() }
        let client = try CodexAppServerClient(
            command: CodexCommand(executableURL: fixture.executable),
            timeout: 2
        )
        #expect(throws: CodexMeterError.rpc("not logged in")) {
            try client.readRateLimits()
        }
    }

    @Test("Fresh status coalesces another hook without launching Codex")
    func coalescesFreshStatus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let statusStore = StatusStore(url: directory.appendingPathComponent("status.json"))
        let expected = RateLimitSnapshot(
            primary: RateLimitWindow(usedPercent: 90, windowDurationMins: 300),
            secondary: nil
        )
        try statusStore.save(HeadroomStatus(snapshot: expected, error: nil))
        let client = try CodexAppServerClient(
            command: CodexCommand(executableURL: directory.appendingPathComponent("missing-codex")),
            timeout: 0.1
        )
        let service = MeterService(
            client: client,
            statusStore: statusStore,
            lock: FileLock(url: directory.appendingPathComponent("meter.lock"))
        )
        #expect(try service.refresh(coalesceWithin: 2) == expected)
    }
}

private struct MockCodexFixture {
    let directory: URL
    let executable: URL

    init(response: String, ignoresTermination: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-tests-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encodedResponse = Data(response.utf8).base64EncodedString()
        let script = """
        #!/usr/bin/python3
        import base64, signal, sys, time
        \(ignoresTermination ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : "")
        sys.stdin.readline()
        sys.stdin.readline()
        sys.stdin.readline()
        print(base64.b64decode("\(encodedResponse)").decode(), flush=True)
        \(ignoresTermination ? "time.sleep(60)" : "")
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
