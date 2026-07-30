import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelsSubcommandTests: XCTestCase {
    func testModelsStatusReturnsStatusResponse() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "old-model"))
        try await server.start()

        let command = try ModelsStatusCommand.parse(["--ctl-socket-path", socketPath.path])
        let capture = await captureOutput {
            try await command.run()
        }
        await server.stop()

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stdout.contains("old-model"))
        XCTAssertTrue(capture.stdout.contains("status_response"))
    }

    func testModelsStatusCase1ENOENT() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsStatusCommand.parse(["--ctl-socket-path", socketPath.path])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(4))
        XCTAssertTrue(capture.stderr.contains("is not running on this host"))
        XCTAssertTrue(capture.stderr.contains(socketPath.path))
    }

    func testModelsStatusCase2ECONNREFUSED() async throws {
        let socketPath = try makeSocketPath()
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socketPath.path, contents: Data())
        let command = try ModelsStatusCommand.parse(["--ctl-socket-path", socketPath.path])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(4))
        XCTAssertTrue(capture.stderr.contains("stale control socket"))
    }

    func testModelsListDisabledModePrintsIdleTableAndExitsZero() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsListCommand.parse([
            "--ctl-socket-path", socketPath.path,
            "--model", "old-model",
            "--supported-models", "old-model",
        ])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stdout.contains("serve not running; warm-swap disabled"))
        XCTAssertTrue(capture.stdout.contains("old-model\tidle"))
        XCTAssertTrue(capture.stderr.contains("macprovider-cli serve is not running on this host"))
    }

    func testModelsSwitchSuccess() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "old-model") { target in
            try await Task.sleep(nanoseconds: 50_000_000)
            return (target, "hash")
        }
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()

        let command = try ModelsSwitchCommand.parse([
            "new-model",
            "--supported-models", "old-model,new-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", makeStatePath().path,
        ])
        let capture = await captureOutput {
            try await command.run()
        }
        await server.stop()

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stderr.contains("state=loading"))
        XCTAssertTrue(capture.stderr.contains("state=draining"))
        XCTAssertTrue(capture.stderr.contains("state=loaded"))
    }

    func testModelsSwitchReportsDrainingWhileInFlightRequestFinishes() async throws {
        let socketPath = try makeSocketPath()
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let requestStartedAt = await providerStatus.beginRequest()
        let runtime = makeRuntime(modelID: "old-model") { target in
            (target, "hash")
        }
        await runtime.setProviderStatus(providerStatus)
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: runtime,
            supportedModels: ["old-model", "new-model"]
        )
        try await server.start()

        let command = try ModelsSwitchCommand.parse([
            "new-model",
            "--supported-models", "old-model,new-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", makeStatePath().path,
        ])
        let release = Task {
            try await Task.sleep(nanoseconds: 250_000_000)
            await providerStatus.finishRequest(startedAt: requestStartedAt, completion: nil, failed: false)
        }
        let capture = await captureOutput {
            try await command.run()
        }
        try await release.value
        await server.stop()

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stderr.contains("switch_progress state=loading"))
        XCTAssertTrue(capture.stderr.contains("switch_progress state=draining"))
        XCTAssertTrue(capture.stderr.contains("switch_progress state=loaded"))
    }

    func testModelsSwitchPreFlightRejection() async throws {
        let socketPath = try makeSocketPath()
        let command = try ModelsSwitchCommand.parse([
            "C",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", socketPath.path,
        ])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        XCTAssertTrue(capture.stderr.contains("switch target C not in --supported-models"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
    }

    func testServerSideRejectsSwitchWhenNotInSupportedModels() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(
            socketPath: socketPath,
            modelRuntime: makeRuntime(modelID: "A"),
            supportedModels: ["A", "B"]
        )
        try await server.start()

        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        try await connection.send(.switchRequest(targetModelID: "C", requestedAtMs: nowMs()))
        let response = try await connection.receive(timeout: 1)
        await connection.close()
        await server.stop()

        XCTAssertEqual(
            response,
            .switchAck(accepted: false, reason: .notInSupportedModels, currentTarget: nil, secondsRemaining: nil)
        )
    }

    func testModelsSwitchConcurrentRejection() async throws {
        let socketPath = try makeSocketPath()
        let runtime = makeRuntime(modelID: "old-model") { target in
            try await Task.sleep(nanoseconds: 300_000_000)
            return (target, "hash")
        }
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()

        let first = try await ControlSocketClient.connect(socketPath: socketPath)
        try await first.send(.statusRequest)
        _ = try await first.receive(timeout: 1)
        try await first.send(.switchRequest(targetModelID: "slow-model", requestedAtMs: nowMs()))
        _ = try await first.receive(timeout: 1)
        _ = try await first.receive(timeout: 1)

        let command = try ModelsSwitchCommand.parse([
            "other-model",
            "--supported-models", "old-model,slow-model,other-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
        ])
        let capture = await captureOutput {
            try await command.run()
        }

        await first.close()
        await server.stop()

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(3))
        XCTAssertTrue(capture.stderr.contains("provider is already loading slow-model"))
    }

    private func makeSocketPath() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpm-\(getpid())-\(Int.random(in: 0 ... 999_999))")
        return dir.appendingPathComponent("ctl.sock")
    }

    private func makeStatePath() -> URL {
        URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpm-state-\(getpid())-\(Int.random(in: 0 ... 999_999))")
            .appendingPathComponent("last-switch.ts")
    }

    private func makeRuntime(
        modelID: String?,
        loader: @escaping @Sendable (String) async throws -> (String, String?) = { target in (target, "hash") }
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            warmSwapEnabled: true,
            loader: { _ in throw ModelsSubcommandTestError.unexpectedContainerLoader },
            testLoader: loader
        )
    }

    private func makeProviderStatus(modelID: String?, modelHash: String?) -> ProviderStatus {
        ProviderStatus(
            modelID: modelID,
            modelLoaded: modelID != nil,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1),
            modelHash: modelHash
        )
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private enum ModelsSubcommandTestError: Error {
    case unexpectedContainerLoader
}

private struct CapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureOutput(_ body: () async throws -> Void) async -> CapturedOutput {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let savedStdout = dup(STDOUT_FILENO)
    let savedStderr = dup(STDERR_FILENO)
    dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    let error: Error?
    do {
        try await body()
        error = nil
    } catch let caught {
        error = caught
    }

    fflush(stdout)
    fflush(stderr)
    dup2(savedStdout, STDOUT_FILENO)
    dup2(savedStderr, STDERR_FILENO)
    close(savedStdout)
    close(savedStderr)
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return CapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
