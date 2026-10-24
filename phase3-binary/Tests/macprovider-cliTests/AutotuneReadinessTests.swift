import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class AutotuneReadinessTests: XCTestCase {
    func testBudgetUsesVerifiedSizeThenSignedRAMWithFloorAndCeiling() {
        XCTAssertEqual(AutotuneReadinessBudget.seconds(model: "unknown"), 120)
        XCTAssertEqual(budget(sizeGB: 4, minRAMGB: 195), 120)
        XCTAssertEqual(budget(sizeGB: 100, minRAMGB: 195), 1000)
        XCTAssertEqual(budget(sizeGB: nil, minRAMGB: 90), 900)
        XCTAssertEqual(budget(sizeGB: nil, minRAMGB: 195), 1800)
        XCTAssertEqual(budget(sizeGB: 300, minRAMGB: 1), 1800)
    }

    func testRealStage1ProbeWaitsBeyond120SecondsForLargeLoadingProvider() async throws {
        let clock = ReadinessTestClock()
        let fixture = try makeProvider(clock: clock, loadingPolls: 130)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await Stage1Prober(clock: clock.now).probe(
            model: "deepseek/deepseek-v4-flash", port: fixture.port, runner: fixture.runner,
            targetContext: 64, gateTTFTMS: 0, replicates: 1
        )
        guard case .feasible = result else { return XCTFail("expected feasible: \(result)") }
        XCTAssertGreaterThan(clock.elapsed, 120)
        XCTAssertLessThan(clock.elapsed, 1800)
    }

    func testRealStage1ProbeStillTimesOutSmallLoadingProviderAt120Seconds() async throws {
        let clock = ReadinessTestClock()
        let fixture = try makeProvider(clock: clock, loadingPolls: 300)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await Stage1Prober(clock: clock.now).probe(
            model: "small-unknown", port: fixture.port, runner: fixture.runner,
            targetContext: 64, gateTTFTMS: 0, replicates: 1
        )
        guard case .infeasible(let reason, _) = result else { return XCTFail("expected timeout") }
        XCTAssertTrue(reason.contains("readiness timeout"), reason)
        XCTAssertEqual(clock.elapsed, 120, accuracy: 0.01)
    }

    func testRealStage1ProbeFailsFastWhenLargeProviderCrashes() async throws {
        let clock = ReadinessTestClock()
        let fixture = try makeProvider(clock: clock, loadingPolls: 0, crash: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await Stage1Prober(clock: clock.now).probe(
            model: "deepseek/deepseek-v4-flash", port: fixture.port, runner: fixture.runner,
            targetContext: 64, gateTTFTMS: 0, replicates: 1
        )
        guard case .infeasible(let reason, _) = result else { return XCTFail("expected crash") }
        XCTAssertTrue(reason.contains("provider exited"), reason)
        XCTAssertTrue(reason.contains("rc=23"), reason)
        XCTAssertLessThan(clock.elapsed, 120)
    }

    func testRealStage1ReadinessHonorsOverallDeadline() async throws {
        let clock = ReadinessTestClock()
        let fixture = try makeProvider(clock: clock, loadingPolls: 300)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let deadline = clock.now().addingTimeInterval(45)
        do {
            _ = try await Stage1Prober(clock: clock.now).probe(
                model: "deepseek/deepseek-v4-flash", port: fixture.port, runner: fixture.runner,
                targetContext: 64, gateTTFTMS: 0, replicates: 1,
                artifactBinding: nil, deadline: deadline
            )
            XCTFail("expected deadline")
        } catch AutotuneContextCalibrationError.deadlineExceeded {
            XCTAssertEqual(clock.elapsed, 45, accuracy: 0.01)
        }
    }

    private func budget(sizeGB: Int?, minRAMGB: Int) -> TimeInterval {
        AutotuneReadinessBudget.seconds(model: "unknown", artifactBinding: CandidateArtifactBinding(
            path: "/unused", sha256: "unused", sizeBytes: sizeGB.map { $0 * 1_073_741_824 },
            minRAMGB: minRAMGB
        ))
    }

    private func makeProvider(
        clock: ReadinessTestClock, loadingPolls: Int, crash: Bool = false
    ) throws -> (runner: CandidateProviderRunner, root: URL, port: Int) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-provider")
        // Only a synthetic HTTP provider is spawned. No model, MLX or live config.
        try """
        #!/usr/bin/env python3
        import json, socket, sys
        if \(crash ? "True" : "False"):
            sys.exit(23)
        port = int(sys.argv[sys.argv.index('--port') + 1])
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('127.0.0.1', port))
        server.listen(16)
        polls = 0
        while True:
            conn, _ = server.accept()
            request = conn.recv(65536).decode('utf-8', 'ignore')
            if 'GET /v1/models ' in request:
                polls += 1
                status = '503 Loading' if polls <= \(loadingPolls) else '200 OK'
                body = '{}'
                conn.sendall((f'HTTP/1.1 {status}\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\n' + body).encode())
            else:
                chunk = json.dumps({'choices':[{'delta':{'content':'hello'}}]})
                usage = json.dumps({'choices':[], 'usage':{'completion_tokens':4}})
                conn.sendall(('HTTP/1.1 200 OK\\r\\nContent-Type: text/event-stream\\r\\nConnection: close\\r\\n\\r\\n'
                    + f'data: {chunk}\\n\\ndata: {usage}\\n\\ndata: [DONE]\\n\\n').encode())
            conn.close()
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addressLength) }
        }
        guard bound == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        let runner = try CandidateProviderRunner(
            providerBinaryPath: script.path, logDirectory: root.appendingPathComponent("logs"),
            readinessClock: clock.now,
            readinessSleep: { seconds in
                // Let the subprocess start while moving only the readiness clock.
                try await Task.sleep(nanoseconds: 5_000_000)
                clock.advance(seconds)
            }
        )
        return (runner, root, Int(UInt16(bigEndian: address.sin_port)))
    }
}

private final class ReadinessTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var seconds: TimeInterval = 0
    var elapsed: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }
    func now() -> Date { start.addingTimeInterval(elapsed) }
    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        seconds += interval
    }
}
