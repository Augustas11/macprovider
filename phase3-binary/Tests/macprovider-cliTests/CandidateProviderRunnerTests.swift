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
            ["serve", "--no-join", "--model", "mlx/test", "--port", "18080"]
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
                "serve", "--no-join",
                "--model", "mlx/test",
                "--port", "18081",
                "--kv-bits", "4",
                "--max-context", "4096",
                "--max-batch", "2",
            ]
        )
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
        XCTAssertTrue(log.contains("serve --no-join --model mlx-community/Test Model --port \(port)"), log)
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
