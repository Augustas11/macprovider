import ArgumentParser
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class EndToEndAcceptanceTests: XCTestCase {
    func testAC_N_0_L1ByteIdenticalDefault_WireSurface() async throws {
        let recorder = CoordinatorFrameRecorder()
        let client = try await makeClient(modelID: "model-a", enableWarmSwap: false, recorder: recorder)

        let authJSON = jsonString(await client.authInitialMessage(attempt: Tier2AuthAttempt()))
        let helloJSON = jsonString(await client.helloMessage())
        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        let heartbeatJSON = jsonString(heartbeat)

        XCTAssertTrue(authJSON.contains("\"supported_models\":[\"model-a\"]"), authJSON)
        XCTAssertFalse(authJSON.contains("\"publishes_supported_models\""), authJSON)
        XCTAssertFalse(helloJSON.contains("\"loading\""), helloJSON)
        XCTAssertFalse(heartbeatJSON.contains("\"model_hash\""), heartbeatJSON)
        XCTAssertFalse(heartbeatJSON.contains("\"loading\""), heartbeatJSON)
    }

    func testAC_N_1_SPEC010_OptIn_ExplicitCatalog() async throws {
        let client = try await makeClient(
            modelID: "A",
            supportedModels: ["A", "B", "C"],
            publishesSupportedModels: true
        )

        let authJSON = jsonString(await client.authInitialMessage(attempt: Tier2AuthAttempt()))

        XCTAssertTrue(authJSON.contains("\"model_id\":\"A\""), authJSON)
        XCTAssertTrue(authJSON.contains("\"supported_models\":[\"A\",\"B\",\"C\"]"), authJSON)
        XCTAssertTrue(authJSON.contains("\"publishes_supported_models\":true"), authJSON)
    }

    func testAC_N_2_SPEC010_PreFlight_ExitCode2() async throws {
        let socketPath = try makeSocketPath()
        let statePath = try makeStatePath()
        let command = try ModelsSwitchCommand.parse([
            "C",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", statePath.path,
        ])

        let capture = await captureOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        XCTAssertTrue(capture.stderr.contains("switch target C not in --supported-models"), capture.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath.path))
    }

    func testAC_N_3_SPEC011_OptInGate_DisabledMode() async throws {
        var disabledConfig = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        disabledConfig.enableWarmSwap = false
        let socketPath = try makeSocketPath()

        let list = try ModelsListCommand.parse([
            "--ctl-socket-path", socketPath.path,
            "--model", "old-model",
        ])
        let listCapture = await captureOutput {
            try await list.run()
        }
        let switchCommand = try ModelsSwitchCommand.parse([
            "new-model",
            "--supported-models", "old-model,new-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", try makeStatePath().path,
        ])
        let switchCapture = await captureOutput {
            try await switchCommand.run()
        }

        XCTAssertFalse(disabledConfig.enableWarmSwap)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
        XCTAssertNil(listCapture.error)
        XCTAssertTrue(listCapture.stdout.contains("serve not running; warm-swap disabled"), listCapture.stdout)
        XCTAssertEqual(switchCapture.error as? ExitCode, ExitCode(4))
        XCTAssertTrue(switchCapture.stderr.contains("is not running on this host"), switchCapture.stderr)
    }

    func testAC_N_4_SPEC011_OptInGate_EnabledMode_FilePermissions() async throws {
        let socketPath = try makeSocketPath()
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "old-model"))

        try await server.start()

        XCTAssertEqual(octalMode(socketPath.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(octalMode(socketPath), 0o600)
        await server.stop()
    }

    func testAC_N_5_MacOSNativePath() throws {
        let ctlPath = ControlSocketPaths.resolve(ctlSocketPath: nil)
        let statePath = ControlSocketPaths.defaultSwitchStatePath(nil)
        let source = try String(contentsOfFile: "Sources/macprovider-cli/ControlSocket.swift", encoding: .utf8)

        XCTAssertTrue(ctlPath.path.hasPrefix(FileManager.default.temporaryDirectory.path), ctlPath.path)
        XCTAssertTrue(ctlPath.path.contains("macprovider-cli/ctl.sock"), ctlPath.path)
        XCTAssertTrue(statePath.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path), statePath.path)
        XCTAssertTrue(statePath.path.contains("Library/Application Support/macprovider-cli/last-switch.ts"), statePath.path)
        XCTAssertFalse(source.contains("XDG_RUNTIME_DIR"))
    }

    func testAC_N_6_AtomicSwap_InFlightVsNewRequest() async throws {
        let probe = InFlightProbe()
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            loader: { target in
                try await Task.sleep(nanoseconds: 50_000_000)
                return (target, "new-hash")
            },
            completion: { snapshot, _ in
                await probe.markStarted(modelID: snapshot.modelID)
                while await !probe.canFinish {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        let socketPath = try makeSocketPath()
        let statePath = try makeStatePath()
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()

        let inFlight = Task {
            try await runtime.complete(try makeRequest(model: "old-model"))
        }
        try await waitUntil {
            await probe.startedModelID != nil
        }

        let command = try ModelsSwitchCommand.parse([
            "new-model",
            "--supported-models", "old-model,new-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", statePath.path,
        ])
        let capture = await captureOutput {
            try await command.run()
        }
        await probe.allowFinish()
        let oldCompletion = try await inFlight.value
        let newCompletion = try await runtime.complete(try makeRequest(model: "new-model"))
        await server.stop()

        XCTAssertNil(capture.error)
        XCTAssertEqual(oldCompletion.content, "old-model")
        XCTAssertEqual(newCompletion.content, "new-model")
    }

    func testAC_N_7_NoStarveHeartbeat() async throws {
        let gate = SwapLoaderGate()
        let oldHash = String(repeating: "1", count: 64)
        let runtime = makeRuntime(modelID: "model-a", modelHash: oldHash) { target in
            try await gate.waitForRelease()
            return (target, String(repeating: "2", count: 64))
        }
        let recorder = CoordinatorFrameRecorder()
        let client = try await makeClient(modelID: "model-a", enableWarmSwap: true, modelRuntime: runtime, recorder: recorder)

        let swapTask = try await runtime.beginSwap(targetModelID: "model-b")
        try await waitUntil {
            await runtime.currentSnapshot().state == .loading
        }
        try await client.sendHeartbeatForTest()
        await gate.release()
        try await swapTask.value

        let frames = await recorder.frames
        XCTAssertTrue(frames.contains { $0["type"] as? String == "heartbeat" && $0["loading"] as? Bool == true })
    }

    func testAC_N_8_HeartbeatHashFormat() async throws {
        let hash = String(repeating: "a", count: 64)
        let recorder = CoordinatorFrameRecorder()
        let client = try await makeClient(modelID: "model-a", modelHash: hash, enableWarmSwap: true, recorder: recorder)

        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        let modelHash = try XCTUnwrap(heartbeat["model_hash"] as? String)

        XCTAssertEqual(modelHash.count, 64)
        XCTAssertNotNil(modelHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression))
        XCTAssertFalse(modelHash.contains("sha256:"))
    }

    func testAC_N_9_FourMatrixCells_AuthInitial() async throws {
        let cells: [(supported: [String]?, publishes: Bool, warm: Bool, expectedCatalog: [String], expectedPublish: Bool, expectedWarmFields: Bool)] = [
            (nil, false, false, ["model-a"], false, false),
            (["model-a", "model-b"], true, false, ["model-a", "model-b"], true, false),
            (nil, false, true, ["model-a"], false, true),
            (["model-a", "model-b"], true, true, ["model-a", "model-b"], true, true),
        ]

        for cell in cells {
            let recorder = CoordinatorFrameRecorder()
            let client = try await makeClient(
                modelID: "model-a",
                modelHash: String(repeating: "b", count: 64),
                supportedModels: cell.supported,
                publishesSupportedModels: cell.publishes,
                enableWarmSwap: cell.warm,
                recorder: recorder
            )
            let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
            try await client.sendHeartbeatForTest()
            let frames = await recorder.frames
            let heartbeat = try XCTUnwrap(frames.first)

            XCTAssertEqual(auth["supported_models"] as? [String], cell.expectedCatalog)
            XCTAssertEqual(auth["publishes_supported_models"] as? Bool, cell.expectedPublish ? true : nil)
            XCTAssertEqual(heartbeat["loading"] != nil, cell.expectedWarmFields)
            XCTAssertEqual(heartbeat["model_hash"] != nil, cell.expectedWarmFields)
        }
    }

    func testAC_N_10_V2HandshakeFieldsMatchSPEC010_3_1_A() async throws {
        let client = try await makeClient(
            modelID: "X",
            supportedModels: ["X", "Y"],
            publishesSupportedModels: true
        )

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        let expectedKeys: Set<String> = [
            "type",
            "version",
            "stage",
            "provider_id",
            "hostname",
            "model_id",
            "model_params_b",
            "ram_gb",
            "max_context_tokens",
            "max_concurrency",
            "throughput_tps_estimate",
            "binary_version",
            "provider_ecdh_public_key",
            "tier2_capabilities",
            "supported_models",
            "publishes_supported_models",
        ]

        for key in expectedKeys {
            XCTAssertNotNil(auth[key], "missing \(key)")
        }
    }

    func testAC_N_11_LegacyHelloByteIdenticalToV124() async throws {
        let client = try await makeClient(modelID: "A", modelHash: String(repeating: "c", count: 64), enableWarmSwap: false)

        let hello = await client.helloMessage()
        let allowedKeys: Set<String> = [
            "type",
            "version",
            "tier",
            "provider_id",
            "hostname",
            "model_id",
            "model_params_b",
            "ram_gb",
            "max_context_tokens",
            "max_concurrency",
            "throughput_tps_estimate",
            "binary_version",
            "attestation",
            "endpoint_url",
            "model_hash",
        ]

        XCTAssertEqual(Set(hello.keys), Set(hello.keys).intersection(allowedKeys))
        XCTAssertNil(hello["supported_models"])
        XCTAssertNil(hello["publishes_supported_models"])
        XCTAssertNil(hello["loading"])
    }

    func testCooldownSoftGuardWritesStateExits6AndForceBypasses() async throws {
        let socketPath = try makeSocketPath()
        let statePath = try makeStatePath()
        let runtime = makeRuntime(modelID: "old-model") { target in
            (target, "hash-\(target)")
        }
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: runtime)
        try await server.start()

        let first = try ModelsSwitchCommand.parse([
            "new-model",
            "--supported-models", "old-model,new-model,other-model",
            "--model", "old-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", statePath.path,
        ])
        let firstCapture = await captureOutput {
            try await first.run()
        }
        let second = try ModelsSwitchCommand.parse([
            "other-model",
            "--supported-models", "old-model,new-model,other-model",
            "--model", "new-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", statePath.path,
        ])
        let secondCapture = await captureOutput {
            try await second.run()
        }
        let forced = try ModelsSwitchCommand.parse([
            "other-model",
            "--force",
            "--supported-models", "old-model,new-model,other-model",
            "--model", "new-model",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", statePath.path,
        ])
        let forcedCapture = await captureOutput {
            try await forced.run()
        }
        await server.stop()

        XCTAssertNil(firstCapture.error)
        XCTAssertNotNil(SwitchStateStore(path: statePath).readLastSwitchMs())
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath.path + ".tmp"))
        XCTAssertEqual(secondCapture.error as? ExitCode, ExitCode(6))
        XCTAssertTrue(secondCapture.stderr.contains("swap on cooldown for"), secondCapture.stderr)
        XCTAssertTrue(secondCapture.stderr.contains("Re-issue with --force to bypass"), secondCapture.stderr)
        XCTAssertNil(forcedCapture.error)
    }

    func testForceDoesNotBypassExitCodes2_3_4_5() async throws {
        let preflight = try ModelsSwitchCommand.parse([
            "C",
            "--force",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", try makeSocketPath().path,
            "--switch-state-path", try makeStatePath().path,
        ])
        let preflightCapture = await captureOutput {
            try await preflight.run()
        }

        let absent = try ModelsSwitchCommand.parse([
            "B",
            "--force",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", try makeSocketPath().path,
            "--switch-state-path", try makeStatePath().path,
        ])
        let absentCapture = await captureOutput {
            try await absent.run()
        }

        let concurrentSocket = try makeSocketPath()
        let concurrentServer = ControlSocketServer(socketPath: concurrentSocket, modelRuntime: makeRuntime(modelID: "A") { target in
            try await Task.sleep(nanoseconds: 300_000_000)
            return (target, "hash")
        })
        try await concurrentServer.start()
        let first = try await ControlSocketClient.connect(socketPath: concurrentSocket)
        try await first.send(.statusRequest)
        _ = try await first.receive(timeout: 1)
        try await first.send(.switchRequest(targetModelID: "B", requestedAtMs: nowMs()))
        _ = try await first.receive(timeout: 1)
        _ = try await first.receive(timeout: 1)
        let concurrent = try ModelsSwitchCommand.parse([
            "C",
            "--force",
            "--supported-models", "A,B,C",
            "--model", "A",
            "--ctl-socket-path", concurrentSocket.path,
            "--switch-state-path", try makeStatePath().path,
        ])
        let concurrentCapture = await captureOutput {
            try await concurrent.run()
        }
        _ = try? await first.receive(timeout: 1)
        _ = try? await first.receive(timeout: 1)
        await first.close()
        await concurrentServer.stop()

        let failedSocket = try makeSocketPath()
        let failedServer = ControlSocketServer(socketPath: failedSocket, modelRuntime: makeRuntime(modelID: "A") { _ in
            throw EndToEndTestError.loadFailed
        })
        try await failedServer.start()
        let failed = try ModelsSwitchCommand.parse([
            "B",
            "--force",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", failedSocket.path,
            "--switch-state-path", try makeStatePath().path,
        ])
        let failedCapture = await captureOutput {
            try await failed.run()
        }
        await failedServer.stop()

        XCTAssertEqual(preflightCapture.error as? ExitCode, ExitCode(2))
        XCTAssertEqual(absentCapture.error as? ExitCode, ExitCode(4))
        XCTAssertEqual(concurrentCapture.error as? ExitCode, ExitCode(3))
        XCTAssertEqual(failedCapture.error as? ExitCode, ExitCode(5))
    }

    func testCorruptCooldownStateDoesNotExit() async throws {
        let socketPath = try makeSocketPath()
        let statePath = try makeStatePath()
        try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a number".write(to: statePath, atomically: false, encoding: .utf8)
        let server = ControlSocketServer(socketPath: socketPath, modelRuntime: makeRuntime(modelID: "A") { target in
            (target, "hash")
        })
        try await server.start()

        let command = try ModelsSwitchCommand.parse([
            "B",
            "--supported-models", "A,B",
            "--model", "A",
            "--ctl-socket-path", socketPath.path,
            "--switch-state-path", statePath.path,
        ])
        let capture = await captureOutput {
            try await command.run()
        }
        await server.stop()

        XCTAssertNil(capture.error)
    }

    private func makeClient(
        modelID: String?,
        modelHash: String? = nil,
        supportedModels: [String]? = nil,
        publishesSupportedModels: Bool = false,
        enableWarmSwap: Bool = false,
        modelRuntime: ModelRuntime? = nil,
        recorder: CoordinatorFrameRecorder = CoordinatorFrameRecorder()
    ) async throws -> CoordinatorClient {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = modelID
        config.supportedModels = supportedModels
        config.publishesSupportedModels = publishesSupportedModels
        config.enableWarmSwap = enableWarmSwap
        let status = ProviderStatus(
            modelID: modelID,
            modelLoaded: modelID != nil,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: modelHash
        )
        let runtime = modelRuntime ?? makeRuntime(modelID: modelID, modelHash: modelHash, warmSwapEnabled: enableWarmSwap)
        return try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sendOverride: { frame in
                await recorder.append(frame)
            },
            sleepAssertionFactory: { nil }
        ))
    }

    private func makeRuntime(
        modelID: String?,
        modelHash: String? = nil,
        warmSwapEnabled: Bool = true,
        loader: @escaping @Sendable (String) async throws -> (String, String?) = { target in (target, nil) },
        completion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            modelHash: modelHash,
            warmSwapEnabled: warmSwapEnabled,
            loader: { _ in throw EndToEndTestError.unexpectedContainerLoader },
            testLoader: loader,
            testCompletion: completion
        )
    }

    private func makeSocketPath() throws -> URL {
        try makeTempDirectory().appendingPathComponent("ctl.sock")
    }

    private func makeStatePath() throws -> URL {
        try makeTempDirectory().appendingPathComponent("last-switch.ts")
    }

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpm-e2e-\(getpid())-\(Int.random(in: 0 ... 999_999))")
        try? FileManager.default.removeItem(at: dir)
        return dir
    }

    private func makeRequest(model: String) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    private func octalMode(_ url: URL) -> Int {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            return -1
        }
        return Int(statBuffer.st_mode & S_IRWXU)
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
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

private actor CoordinatorFrameRecorder {
    private(set) var frames: [[String: Any]] = []

    func append(_ frame: [String: Any]) {
        frames.append(frame)
    }
}

private actor InFlightProbe {
    private var _startedModelID: String?
    private var _canFinish = false

    var startedModelID: String? { _startedModelID }
    var canFinish: Bool { _canFinish }

    func markStarted(modelID: String?) {
        _startedModelID = modelID
    }

    func allowFinish() {
        _canFinish = true
    }
}

private actor SwapLoaderGate {
    private var released = false

    func waitForRelease() async throws {
        while !released {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func release() {
        released = true
    }
}

private enum EndToEndTestError: Error {
    case unexpectedContainerLoader
    case loadFailed
    case noHeartbeatCapture
}
