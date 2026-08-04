import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class CandidateProviderRunnerTests: XCTestCase {
    func testServeArgumentsIncludeNoJoinAndOptionalKnobs() throws {
        XCTAssertEqual(
            try CandidateProviderRunner.serveArguments(
                model: "mlx/test",
                port: 18_080,
                kvBits: nil,
                maxContext: nil,
                maxBatch: nil
            ),
            [
                "serve", "--no-join", "--autotune-candidate",
                "--model", "mlx/test", "--port", "18080",
            ]
        )

        XCTAssertEqual(
            try CandidateProviderRunner.serveArguments(
                model: "mlx/test",
                port: 18_081,
                kvBits: 4,
                maxContext: 4_096,
                maxBatch: 2
            ),
            [
                "serve", "--no-join", "--autotune-candidate",
                "--model", "mlx/test",
                "--port", "18081",
                "--kv-bits", "4",
                "--max-context", "4096",
                "--max-batch", "2",
            ]
        )
    }

    func testServeArgumentsPropagateExplicitConfig() throws {
        XCTAssertEqual(
            try CandidateProviderRunner.serveArguments(
                model: "mlx/test",
                port: 18_082,
                kvBits: nil,
                maxContext: 4_000,
                maxBatch: 1,
                configPath: "~/probe-config.yaml",
                modelArtifactPath: "/tmp/model-snapshot",
                modelArtifactSHA256: String(repeating: "a", count: 64)
            ),
            [
                "serve", "--no-join", "--autotune-candidate",
                "--model", "mlx/test", "--port", "18082",
                "--config", "\(FileManager.default.homeDirectoryForCurrentUser.path)/probe-config.yaml",
                "--model-artifact-path", "/tmp/model-snapshot",
                "--model-artifact-sha256", String(repeating: "a", count: 64),
                "--max-context", "4000", "--max-batch", "1",
            ]
        )
    }

    func testCandidateEnvironmentDropsCredentialAndIncumbentOverrides() {
        let sanitized = CandidateProviderRunner.sanitizedChildEnvironment([
            "MACPROVIDER_PROVIDER_TOKEN": "secret",
            "MACPROVIDER_PROVIDER_TOKEN_FILE": "/tmp/token",
            "MACPROVIDER_PROVIDER_ID": "provider",
            "MACPROVIDER_COORDINATOR_URL": "https://coordinator.example",
            "MACPROVIDER_CTL_SOCKET_PATH": "/tmp/incumbent.sock",
            "MACPROVIDER_CONFIG": "/tmp/probe.yaml",
            "PATH": "/usr/bin",
        ])
        XCTAssertNil(sanitized["MACPROVIDER_PROVIDER_TOKEN"])
        XCTAssertNil(sanitized["MACPROVIDER_PROVIDER_TOKEN_FILE"])
        XCTAssertNil(sanitized["MACPROVIDER_PROVIDER_ID"])
        XCTAssertNil(sanitized["MACPROVIDER_COORDINATOR_URL"])
        XCTAssertNil(sanitized["MACPROVIDER_CTL_SOCKET_PATH"])
        XCTAssertNil(sanitized["MACPROVIDER_CONFIG"])
        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
    }

    func testStartRejectsArtifactBindingWhenSnapshotDigestChanged() throws {
        let artifact = try temporaryDirectory(name: "provider-runner-artifact-binding")
        try Data("weights".utf8).write(to: artifact.appendingPathComponent("weights.bin"))
        let runner = try CandidateProviderRunner(
            providerBinaryPath: "/usr/bin/true",
            logDirectory: try temporaryDirectory(name: "provider-runner-artifact-binding-logs")
        )

        XCTAssertThrowsError(
            try runner.start(
                model: "model-a",
                port: 18_080,
                artifactBinding: CandidateArtifactBinding(
                    path: artifact.path,
                    sha256: String(repeating: "0", count: 64)
                )
            )
        ) { error in
            guard case .invalidArtifactBinding = error as? CandidateProviderRunnerError else {
                return XCTFail("expected invalidArtifactBinding, got \(error)")
            }
        }
        XCTAssertNil(runner.activeProcessIdentifierForTesting())
    }

    // MARK: - Round-1 audit fix tests

    /// Round-1 B.1 closure: `start()` with a missing binary path MUST
    /// throw promptly rather than hang on `readDataToEndOfFile()` for
    /// pipes whose write ends are still open. Prior to the fix, codex
    /// reproduced a 2-second hang locally.
    func testStartFailsPromptlyWithMissingBinary() throws {
        let logDirectory = try temporaryDirectory(name: "provider-runner-missing-binary")
        let runner = try CandidateProviderRunner(
            providerBinaryPath: "/nonexistent/macprovider-cli-stub-\(UUID().uuidString)",
            logDirectory: logDirectory
        )

        let port = try unusedPort()
        let started = Date()
        XCTAssertThrowsError(try runner.start(model: "model-a", port: port))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 1.0,
            "start() must fail promptly when the binary is missing; got \(elapsed)s"
        )
    }

    /// Round-1 C.1 closure: after receiving HTTP 200 on /v1/models,
    /// `waitForReady` MUST re-check `process.isRunning` before
    /// returning `.ready`. A stub that serves 200 once and immediately
    /// exits must produce `.processExited` or `.ready` (NOT `.timeout`).
    /// The non-determinism of which of the two: in CI either outcome
    /// is acceptable; what we lock against is `.timeout` (the pre-fix
    /// silent-hang regression class) or any non-running provider
    /// silently mis-reported as `.ready`.
    func testWaitForReadyHandlesImmediateExitAfterFirstResponse() async throws {
        let fixture = try compileImmediateExitStubProvider()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: fixture.path,
            logDirectory: try temporaryDirectory(name: "provider-runner-immediate-exit")
        )

        let port = try unusedPort()
        try runner.start(model: "model-x", port: port)
        let status = try await runner.waitForReady(timeout: 5)

        switch status {
        case .ready, .processExited:
            break
        case .timeout(let last):
            XCTFail("expected .ready or .processExited, got .timeout(\(last))")
        }
    }

    /// Round-1 A.1 resolution: `stop()` returns `.stopped` for a never-
    /// started runner and for a clean stop, and `.stuck(pid:)` if the
    /// grace expires with the process still alive. This test covers the
    /// happy path; the stuck path is hard to reach deterministically
    /// without a deliberately unkillable subprocess.
    func testStopReturnsStoppedForNeverStartedRunner() throws {
        let runner = try CandidateProviderRunner(
            providerBinaryPath: "/usr/bin/true",
            logDirectory: try temporaryDirectory(name: "provider-runner-stop-empty")
        )
        XCTAssertEqual(runner.stop(graceSeconds: 0), .stopped)
    }

    func testServeArgumentsRejectInvalidPort() throws {
        XCTAssertThrowsError(
            try CandidateProviderRunner.serveArguments(
                model: "model-a", port: 0,
                kvBits: nil, maxContext: nil, maxBatch: nil
            )
        ) { error in
            XCTAssertEqual(error as? CandidateProviderRunnerError, .invalidPort(0))
        }
        XCTAssertThrowsError(
            try CandidateProviderRunner.serveArguments(
                model: "model-a", port: 65_536,
                kvBits: nil, maxContext: nil, maxBatch: nil
            )
        ) { error in
            XCTAssertEqual(error as? CandidateProviderRunnerError, .invalidPort(65_536))
        }
    }

    func testServeArgumentsRejectInvalidMaxContext() throws {
        XCTAssertThrowsError(
            try CandidateProviderRunner.serveArguments(
                model: "model-a", port: 18_080,
                kvBits: nil, maxContext: 0, maxBatch: nil
            )
        ) { error in
            XCTAssertEqual(error as? CandidateProviderRunnerError, .invalidMaxContext(0))
        }
    }

    func testServeArgumentsRejectInvalidMaxBatch() throws {
        XCTAssertThrowsError(
            try CandidateProviderRunner.serveArguments(
                model: "model-a", port: 18_080,
                kvBits: nil, maxContext: nil, maxBatch: 0
            )
        ) { error in
            XCTAssertEqual(error as? CandidateProviderRunnerError, .invalidMaxBatch(0))
        }
    }

    /// Round-1 I.1 closure: log filenames now include a UUID suffix to
    /// avoid same-second collisions. Two builds of the URL for the same
    /// (model, port, directory) produced within one second MUST differ.
    func testLogFileURLsDoNotCollideWithinOneSecond() throws {
        let runner = try CandidateProviderRunner(
            providerBinaryPath: "/usr/bin/true",
            logDirectory: try temporaryDirectory(name: "provider-runner-log-collision")
        )
        // Drive twice in fast succession; UUID suffix makes the paths
        // distinct even when the timestamp matches.
        _ = runner  // silence unused-variable warning
        let urlA = CandidateProviderRunner.logFileURLForTesting(model: "model-a", port: 18_080)
        let urlB = CandidateProviderRunner.logFileURLForTesting(model: "model-a", port: 18_080)
        XCTAssertNotEqual(urlA.lastPathComponent, urlB.lastPathComponent)
    }

    func testServeArgumentsRejectInvalidKnobs() throws {
        XCTAssertThrowsError(
            try CandidateProviderRunner.serveArguments(
                model: "mlx/test",
                port: 18_080,
                kvBits: 5,
                maxContext: nil,
                maxBatch: nil
            )
        ) { error in
            XCTAssertEqual(error as? CandidateProviderRunnerError, .invalidKvBits(5))
        }
    }

    func testStartWaitReadyStopLifecycleWithStubBinary() async throws {
        let fixture = try compileStubProvider()
        let port = try unusedPort()
        let logDirectory = try temporaryDirectory(name: "provider-runner-logs")
        let runner = try CandidateProviderRunner(
            providerBinaryPath: fixture.path,
            logDirectory: logDirectory
        )
        defer {
            runner.stop(graceSeconds: 2)
        }

        try runner.start(model: "mlx-community/Test Model", port: port)
        XCTAssertEqual(
            runner.activeProcessGroupIDForTesting(),
            runner.activeProcessIdentifierForTesting(),
            "candidate must be spawned as its own process-group leader"
        )
        guard let logFileURL = runner.activeLogFileURL() else {
            XCTFail("runner did not expose an active log file")
            return
        }

        let readyStatus = try await runner.waitForReady(timeout: 5)
        XCTAssertEqual(readyStatus, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFileURL.path))

        runner.stop(graceSeconds: 2)
        XCTAssertFalse(try isPortOpen(port), "expected stub provider port to be free after stop")

        let log = try String(contentsOf: logFileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("serve --no-join --autotune-candidate --model mlx-community/Test Model --port \(port)"), log)
        XCTAssertTrue(log.contains("stub ready"), log)
    }

    func testStartRejectsSecondRunningProvider() async throws {
        let fixture = try compileStubProvider()
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: fixture.path,
            logDirectory: try temporaryDirectory(name: "provider-runner-singleton")
        )
        defer {
            runner.stop(graceSeconds: 2)
        }

        try runner.start(model: "model-a", port: port)
        _ = try await runner.waitForReady(timeout: 5)

        XCTAssertThrowsError(try runner.start(model: "model-b", port: try unusedPort())) { error in
            guard case .alreadyRunning = error as? CandidateProviderRunnerError else {
                return XCTFail("expected alreadyRunning, got \(error)")
            }
        }
    }

    func testStopKillsCandidateProcessGroupHelpers() async throws {
        let fixture = try compileStubProvider()
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: fixture.path,
            logDirectory: try temporaryDirectory(name: "provider-runner-process-group")
        )
        defer {
            _ = runner.stop(graceSeconds: 2)
        }

        try runner.start(model: "spawn-helper", port: port)
        let processGroupID = try XCTUnwrap(runner.activeProcessGroupIDForTesting())
        XCTAssertEqual(processGroupID, runner.activeProcessIdentifierForTesting())
        let readyStatus = try await runner.waitForReady(timeout: 5)
        XCTAssertEqual(readyStatus, .ready)

        XCTAssertEqual(runner.stop(graceSeconds: 2), .stopped)
        XCTAssertNotEqual(Darwin.kill(-processGroupID, 0), 0, "candidate helper process group must be gone")
    }

    func testRestartReapsExitedLeaderProcessGroupBeforeReplacingHandle() async throws {
        let fixture = try compileImmediateExitStubProvider()
        let firstPort = try unusedPort()
        let secondPort = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: fixture.path,
            logDirectory: try temporaryDirectory(name: "provider-runner-restart-reap")
        )
        defer { _ = runner.stop(graceSeconds: 2) }

        try runner.start(model: "exits-with-helper", port: firstPort)
        let oldGroupID = try XCTUnwrap(runner.activeProcessGroupIDForTesting())

        // Drive the fixture's one request so its leader exits while the
        // inherited sleep helper remains in the same process group. Calling
        // waitForReady here would eagerly reap that group and would not test
        // the restart path.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(firstPort)/v1/models")!)
        request.timeoutInterval = 2
        var response: URLResponse?
        for _ in 0..<50 {
            do {
                (_, response) = try await URLSession.shared.data(for: request)
                break
            } catch {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        guard let response else {
            return XCTFail("immediate-exit fixture never accepted its request")
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let deadline = Date().addingTimeInterval(2)
        while runner.activeProcessIsRunningForTesting() == true && Date() < deadline {
            usleep(20_000)
        }
        XCTAssertFalse(runner.activeProcessIsRunningForTesting() ?? true, "fixture leader must exit before restart")

        try runner.start(model: "replacement", port: secondPort)
        XCTAssertNotEqual(
            Darwin.kill(-oldGroupID, 0),
            0,
            "restarting must reap helpers from an exited candidate process group"
        )
    }

    func testWaitForReadyReturnsProcessExitAndStderrTail() async throws {
        let fixture = try failingStubScript()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: fixture.path,
            logDirectory: try temporaryDirectory(name: "provider-runner-exit")
        )

        try runner.start(model: "bad-model", port: try unusedPort())
        let status = try await runner.waitForReady(timeout: 5)

        guard case .processExited(let rc, let stderrTail) = status else {
            return XCTFail("expected processExited, got \(status)")
        }
        XCTAssertEqual(rc, 42)
        XCTAssertTrue(stderrTail.contains("fatal load failed"), stderrTail)
    }

    func testIntegrationRealServeLifecycleWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MACPROVIDER_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("set MACPROVIDER_INTEGRATION_TEST=1 to run real serve lifecycle test")
        }
        guard let providerBinary = ProcessInfo.processInfo.environment["MACPROVIDER_INTEGRATION_PROVIDER_BIN"],
              !providerBinary.isEmpty
        else {
            throw XCTSkip("set MACPROVIDER_INTEGRATION_PROVIDER_BIN to a built macprovider-cli binary")
        }
        guard let model = ProcessInfo.processInfo.environment["MACPROVIDER_INTEGRATION_MODEL"],
              !model.isEmpty
        else {
            throw XCTSkip("set MACPROVIDER_INTEGRATION_MODEL to a cached small model id")
        }

        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: providerBinary,
            logDirectory: try temporaryDirectory(name: "provider-runner-integration")
        )
        defer {
            runner.stop(graceSeconds: 30)
        }

        try runner.start(model: model, port: port)
        let readyStatus = try await runner.waitForReady(timeout: 120)
        XCTAssertEqual(readyStatus, .ready)
        runner.stop(graceSeconds: 30)
        XCTAssertFalse(try isPortOpen(port))
    }

    private func compileStubProvider() throws -> URL {
        let directory = try temporaryDirectory(name: "provider-runner-stub")
        let sourceURL = directory.appendingPathComponent("StubProvider.swift")
        let binaryURL = directory.appendingPathComponent("stub-provider")
        try Self.stubProviderSource.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", sourceURL.path, "-o", binaryURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            throw NSError(domain: "CandidateProviderRunnerTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "failed to compile stub provider: \(String(decoding: data, as: UTF8.self))",
            ])
        }
        return binaryURL
    }

    /// Round-1 C.1 closure fixture: a tiny Python HTTP server that
    /// responds to the FIRST request with 200 OK + a /v1/models payload
    /// and immediately exits. Used to exercise the post-200
    /// process-exit race in `waitForReady` (the bug was: the prior
    /// implementation returned `.ready` on 200 without re-checking
    /// process state). Python3 ships with macOS.
    private func compileImmediateExitStubProvider() throws -> URL {
        let directory = try temporaryDirectory(name: "provider-runner-immediate-exit-stub")
        let scriptURL = directory.appendingPathComponent("immediate-exit-provider")
        let script = #"""
        #!/usr/bin/env python3
        import sys, socket, subprocess

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("stub error: expected serve --no-join\n")
            sys.exit(2)

        try:
            port = int(args[args.index("--port") + 1])
        except (ValueError, IndexError):
            sys.stderr.write("stub error: missing --port\n")
            sys.exit(2)

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        s.listen(1)

        # Keep stdout/stderr inherited after the direct child exits. The
        # runner must kill this same-process-group helper and must not block
        # waiting for pipe EOF in waitForReady().
        helper = subprocess.Popen(["/bin/sleep", "60"])

        print(f"stub ready port={port}", flush=True)

        client, _ = s.accept()
        client.recv(2048)
        body = '{"object":"list","data":[]}'
        response = (
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n"
            "\r\n"
            f"{body}"
        )
        client.sendall(response.encode())
        client.close()
        s.close()
        # Exit IMMEDIATELY after responding 200 — this is the race
        # waitForReady's post-HTTP isRunning check must handle.
        sys.exit(0)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func failingStubScript() throws -> URL {
        let directory = try temporaryDirectory(name: "provider-runner-failing-stub")
        let scriptURL = directory.appendingPathComponent("failing-provider")
        let script = """
        #!/bin/sh
        echo "fatal load failed: $*" >&2
        exit 42
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func temporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func unusedPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func isPortOpen(_ port: Int) throws -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static let stubProviderSource = #"""
    import Darwin
    import Foundation

    func fail(_ message: String) -> Never {
        fputs("stub error: \(message)\n", stderr)
        exit(2)
    }

    let args = Array(CommandLine.arguments.dropFirst())
    guard args.first == "serve" else {
        fail("expected serve subcommand")
    }
    guard args.contains("--no-join") else {
        fail("missing --no-join")
    }

    func value(after flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    guard let model = value(after: "--model") else {
        fail("missing --model")
    }
    guard let portText = value(after: "--port"), let port = Int(portText) else {
        fail("missing --port")
    }

    if model == "spawn-helper" {
        let helperPath = strdup("/bin/sleep")
        let helperArg0 = strdup("sleep")
        let helperArg1 = strdup("60")
        defer {
            free(helperPath)
            free(helperArg0)
            free(helperArg1)
        }
        var helperArguments: [UnsafeMutablePointer<CChar>?] = [helperArg0, helperArg1, nil]
        var helperPID = pid_t()
        let spawnResult = posix_spawn(
            &helperPID,
            helperPath,
            nil,
            nil,
            &helperArguments,
            nil
        )
        if spawnResult != 0 {
            fail("helper spawn failed errno=\(spawnResult)")
        }
    }

    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        fail("socket failed")
    }
    var yes: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        fail("bind failed errno=\(errno)")
    }
    guard listen(descriptor, 16) == 0 else {
        fail("listen failed errno=\(errno)")
    }

    print("stub ready model=\(model) port=\(port)")
    fflush(stdout)

    while true {
        let client = accept(descriptor, nil, nil)
        if client < 0 {
            if errno == EINTR {
                continue
            }
            continue
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bufferCount = buffer.count
        _ = buffer.withUnsafeMutableBytes { rawBuffer in
            read(client, rawBuffer.baseAddress, bufferCount)
        }
        let body = "{\"object\":\"list\",\"data\":[{\"id\":\"stub-model\",\"object\":\"model\",\"owned_by\":\"macprovider\"}]}"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        response.withCString { pointer in
            _ = write(client, pointer, strlen(pointer))
        }
        close(client)
    }
    """#
}
