import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderPreWarmerTests: XCTestCase {
    func testHuggingFaceCacheCheckerFindsSnapshotWithFile() throws {
        let cacheRoot = try temporaryDirectory(name: "hf-cache")
        try writeCachedModelFixture(
            cacheRoot: cacheRoot,
            modelID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            revision: "abc123",
            filename: "model.safetensors"
        )

        let checker = HuggingFaceCacheChecker(cacheRoot: cacheRoot)
        XCTAssertTrue(checker.isModelCached(modelID: "mlx-community/Llama-3.2-1B-Instruct-4bit"))
        XCTAssertFalse(checker.isModelCached(modelID: "mlx-community/OtherModel-4bit"))
    }

    func testHuggingFaceCacheCheckerRejectsEmptySnapshot() throws {
        let cacheRoot = try temporaryDirectory(name: "hf-empty-cache")
        let snapshot = cacheRoot
            .appendingPathComponent("models--mlx-community--EmptyModel", isDirectory: true)
            .appendingPathComponent("snapshots/empty-revision", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        let checker = HuggingFaceCacheChecker(cacheRoot: cacheRoot)
        XCTAssertFalse(checker.isModelCached(modelID: "mlx-community/EmptyModel"))
    }

    func testPreWarmerHappyPathReturnsAlreadyCachedAndStopsProvider() async throws {
        let cacheRoot = try temporaryDirectory(name: "hf-cached-prewarm")
        let modelID = "mlx-community/CachedModel-4bit"
        try writeCachedModelFixture(
            cacheRoot: cacheRoot,
            modelID: modelID,
            revision: "cached-revision",
            filename: "weights.safetensors"
        )

        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try readyStubProviderScript().path,
            logDirectory: try temporaryDirectory(name: "prewarm-cached-logs")
        )
        let prewarmer = ProviderPreWarmer(
            cacheChecker: HuggingFaceCacheChecker(cacheRoot: cacheRoot),
            stopGraceSeconds: 2
        )

        let result = try await prewarmer.prewarmAndProbe(
            model: modelID,
            port: port,
            runner: runner,
            readyTimeoutSec: 5
        )

        guard case .warmed(let cacheState, let loadDurationSec) = result else {
            return XCTFail("expected warmed result, got \(result)")
        }
        XCTAssertEqual(cacheState, .alreadyCached)
        XCTAssertGreaterThanOrEqual(loadDurationSec, 0)
        XCTAssertFalse(try isPortOpen(port), "prewarmer should stop the provider after readiness probing")
    }

    func testPreWarmerColdCacheReturnsFetchedDuringLoad() async throws {
        let cacheRoot = try temporaryDirectory(name: "hf-cold-prewarm")
        let modelID = "mlx-community/ColdModel-4bit"
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try readyStubProviderScript().path,
            logDirectory: try temporaryDirectory(name: "prewarm-cold-logs")
        )
        let prewarmer = ProviderPreWarmer(
            cacheChecker: HuggingFaceCacheChecker(cacheRoot: cacheRoot),
            stopGraceSeconds: 2
        )

        let result = try await prewarmer.prewarmAndProbe(
            model: modelID,
            port: port,
            runner: runner,
            readyTimeoutSec: 5
        )

        guard case .warmed(let cacheState, let loadDurationSec) = result else {
            return XCTFail("expected warmed result, got \(result)")
        }
        XCTAssertEqual(cacheState, .fetchedDuringLoad)
        XCTAssertGreaterThanOrEqual(loadDurationSec, 0)
        XCTAssertFalse(try isPortOpen(port), "prewarmer should stop the provider after readiness probing")
    }

    func testPreWarmerClassifiesNetworkExitAsTransient() async throws {
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try failingProviderScript(message: "network unreachable", rc: 42).path,
            logDirectory: try temporaryDirectory(name: "prewarm-transient-logs")
        )
        let prewarmer = ProviderPreWarmer(
            cacheChecker: HuggingFaceCacheChecker(cacheRoot: try temporaryDirectory(name: "hf-transient")),
            stopGraceSeconds: 1
        )

        let result = try await prewarmer.prewarmAndProbe(
            model: "mlx-community/TransientModel-4bit",
            port: try unusedPort(),
            runner: runner,
            readyTimeoutSec: 5
        )

        guard case .failed(let failureClass, let reason) = result else {
            return XCTFail("expected failed result, got \(result)")
        }
        XCTAssertEqual(failureClass, .transient)
        XCTAssertTrue(reason.contains("network unreachable"), reason)
    }

    func testPreWarmerClassifiesSignatureMismatchAsIntegrity() async throws {
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try failingProviderScript(message: "signature mismatch in model weights", rc: 42).path,
            logDirectory: try temporaryDirectory(name: "prewarm-integrity-logs")
        )
        let prewarmer = ProviderPreWarmer(
            cacheChecker: HuggingFaceCacheChecker(cacheRoot: try temporaryDirectory(name: "hf-integrity")),
            stopGraceSeconds: 1
        )

        let result = try await prewarmer.prewarmAndProbe(
            model: "mlx-community/IntegrityModel-4bit",
            port: try unusedPort(),
            runner: runner,
            readyTimeoutSec: 5
        )

        guard case .failed(let failureClass, let reason) = result else {
            return XCTFail("expected failed result, got \(result)")
        }
        XCTAssertEqual(failureClass, .integrity)
        XCTAssertTrue(reason.contains("signature mismatch"), reason)
    }

    func testPreWarmerClassifiesReadinessTimeoutAsTransient() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try hangingProviderScript().path,
            logDirectory: try temporaryDirectory(name: "prewarm-timeout-logs")
        )
        let prewarmer = ProviderPreWarmer(
            cacheChecker: HuggingFaceCacheChecker(cacheRoot: try temporaryDirectory(name: "hf-timeout")),
            stopGraceSeconds: 1
        )

        let result = try await prewarmer.prewarmAndProbe(
            model: "mlx-community/TimeoutModel-4bit",
            port: port,
            runner: runner,
            readyTimeoutSec: 0.1
        )

        guard case .failed(let failureClass, let reason) = result else {
            return XCTFail("expected failed result, got \(result)")
        }
        XCTAssertEqual(failureClass, .transient)
        XCTAssertTrue(reason.hasPrefix("load timeout:"), reason)
        XCTAssertFalse(try isPortOpen(port), "timeout cleanup should stop the hanging provider")
    }

    private func writeCachedModelFixture(
        cacheRoot: URL,
        modelID: String,
        revision: String,
        filename: String
    ) throws {
        let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        XCTAssertEqual(parts.count, 2)
        let snapshot = cacheRoot
            .appendingPathComponent("models--\(parts[0])--\(parts[1])", isDirectory: true)
            .appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("stub weights".utf8).write(to: snapshot.appendingPathComponent(filename))
    }

    private func readyStubProviderScript() throws -> URL {
        let directory = try temporaryDirectory(name: "prewarm-ready-stub")
        let scriptURL = directory.appendingPathComponent("ready-provider")
        let script = #"""
        #!/usr/bin/env python3
        import sys, socket

        args = sys.argv[1:]
        if not args or args[0] != "serve" or "--no-join" not in args:
            sys.stderr.write("stub error: expected serve --no-join\n")
            sys.exit(2)

        try:
            port = int(args[args.index("--port") + 1])
        except (ValueError, IndexError):
            sys.stderr.write("stub error: missing --port\n")
            sys.exit(2)

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print(f"stub ready port={port}", flush=True)

        while True:
            client, _ = server.accept()
            client.recv(2048)
            body = '{"object":"list","data":[{"id":"stub-model","object":"model"}]}'
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
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func failingProviderScript(message: String, rc: Int32) throws -> URL {
        let directory = try temporaryDirectory(name: "prewarm-failing-stub")
        let scriptURL = directory.appendingPathComponent("failing-provider")
        let script = """
        #!/bin/sh
        echo "\(message)" >&2
        exit \(rc)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func hangingProviderScript() throws -> URL {
        let directory = try temporaryDirectory(name: "prewarm-hanging-stub")
        let scriptURL = directory.appendingPathComponent("hanging-provider")
        let script = """
        #!/bin/sh
        sleep 60
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
}
