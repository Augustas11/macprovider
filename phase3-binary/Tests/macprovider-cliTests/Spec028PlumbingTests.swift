import ArgumentParser
import Foundation
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class Spec028PlumbingTests: XCTestCase {
    func testDraftConfigDefaultsAreDisabledAndInert() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" }
        )

        XCTAssertNil(config.draftModel)
        XCTAssertNil(config.draftModelArtifactSHA256)
        XCTAssertEqual(config.numDraftTokens, 3)
        XCTAssertFalse(config.publishesSpecDecodeTelemetry)
    }

    func testDraftConfigCLIOverridesEnvironmentOverridesYAML() throws {
        let cliHash = String(repeating: "a", count: 64)
        let envHash = String(repeating: "b", count: 64)
        let yamlHash = String(repeating: "c", count: 64)

        let config = try ConfigLoader.load(
            cli: CLIOverrides(
                draftModel: "/models/cli-draft",
                draftModelArtifactSHA256: cliHash,
                numDraftTokens: 7,
                publishesSpecDecodeTelemetry: false
            ),
            environment: [
                "MACPROVIDER_DRAFT_MODEL": "/models/env-draft",
                "MACPROVIDER_DRAFT_MODEL_ARTIFACT_SHA256": envHash,
                "MACPROVIDER_NUM_DRAFT_TOKENS": "5",
                "MACPROVIDER_PUBLISHES_SPEC_DECODE_TELEMETRY": "true",
            ],
            fileExists: { _ in true },
            readFile: { _ in
                """
                draft_model: /models/yaml-draft
                draft_model_artifact_sha256: \(yamlHash)
                num_draft_tokens: 3
                publishes_spec_decode_telemetry: true
                """
            }
        )

        XCTAssertEqual(config.draftModel, "/models/cli-draft")
        XCTAssertEqual(config.draftModelArtifactSHA256, cliHash)
        XCTAssertEqual(config.numDraftTokens, 7)
        XCTAssertFalse(config.publishesSpecDecodeTelemetry)
    }

    func testDraftConfigEnvironmentOverridesYAML() throws {
        let envHash = String(repeating: "d", count: 64)
        let yamlHash = String(repeating: "e", count: 64)

        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [
                "MACPROVIDER_DRAFT_MODEL": "/models/env-draft",
                "MACPROVIDER_DRAFT_MODEL_ARTIFACT_SHA256": envHash,
                "MACPROVIDER_NUM_DRAFT_TOKENS": "4",
                "MACPROVIDER_PUBLISHES_SPEC_DECODE_TELEMETRY": "true",
            ],
            fileExists: { _ in true },
            readFile: { _ in
                """
                draft_model: /models/yaml-draft
                draft_model_artifact_sha256: \(yamlHash)
                num_draft_tokens: 2
                publishes_spec_decode_telemetry: false
                """
            }
        )

        XCTAssertEqual(config.draftModel, "/models/env-draft")
        XCTAssertEqual(config.draftModelArtifactSHA256, envHash)
        XCTAssertEqual(config.numDraftTokens, 4)
        XCTAssertTrue(config.publishesSpecDecodeTelemetry)
    }

    func testServeDraftFlagsParse() throws {
        let hash = String(repeating: "f", count: 64)
        let command = try ServeCommand.parse([
            "--draft-model", "/models/draft",
            "--draft-model-artifact-sha256", hash,
            "--num-draft-tokens", "6",
            "--publish-spec-decode-telemetry",
            "--model", "target",
        ])

        XCTAssertEqual(command.draftModel, "/models/draft")
        XCTAssertEqual(command.draftModelArtifactSha256, hash)
        XCTAssertEqual(command.numDraftTokens, 6)
        XCTAssertEqual(command.publishSpecDecodeTelemetry, true)
    }

    func testNumDraftTokensPreflightRejectsOutOfRangeValues() throws {
        for value in [0, -1, 17] {
            var config = AppConfig.defaults()
            config.numDraftTokens = value
            XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config), "value=\(value)")
        }
    }

    func testTelemetryPublishFlagFailsLoudUntilHeartbeatPR() throws {
        var config = AppConfig.defaults()
        config.publishesSpecDecodeTelemetry = true

        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testDraftCapacityHelpersMatchSpec028Tiers() {
        XCTAssertEqual(ProviderCapacity.defaultContextTokens(forPhysicalMemoryGB: 8), 20_000)
        XCTAssertEqual(ProviderCapacity.defaultContextTokens(forPhysicalMemoryGB: 16), 50_000)
        XCTAssertEqual(ProviderCapacity.defaultContextTokens(forPhysicalMemoryGB: 32), 120_000)
        XCTAssertEqual(ProviderCapacity.defaultContextTokens(forPhysicalMemoryGB: 64), 200_000)

        XCTAssertEqual(ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 8), 8_192)
        XCTAssertEqual(ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 16), 20_000)
        XCTAssertEqual(ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 32), 50_000)
        XCTAssertEqual(ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 64), 120_000)
    }

    func testDraftCapacityPreflightRejectsExplicitConcurrentBatchAboveOne() throws {
        var config = AppConfig.defaults()
        config.draftModel = "/models/draft"
        config.maxConcurrencyOverride = 2

        XCTAssertThrowsError(try ServeCommand.runSpecDecodeCapacityPreflight(&config))
    }

    func testDraftCapacityPreflightDownshiftsImplicitContextAndBatch() throws {
        var config = AppConfig.defaults()
        config.draftModel = "/models/draft"

        XCTAssertNoThrow(try ServeCommand.runSpecDecodeCapacityPreflight(&config))
        XCTAssertEqual(config.maxContextOverride, ProviderCapacity.draftContextCapForCurrentHost())
        XCTAssertEqual(config.maxConcurrencyOverride, 1)
    }

    func testDraftCapacityPreflightLeavesDisabledConfigUnchanged() throws {
        var config = AppConfig.defaults()
        config.maxContextOverride = nil
        config.maxConcurrencyOverride = nil

        XCTAssertNoThrow(try ServeCommand.runSpecDecodeCapacityPreflight(&config))
        XCTAssertNil(config.maxContextOverride)
        XCTAssertNil(config.maxConcurrencyOverride)
    }

    func testDraftArtifactPreflightRequiresHashForCoordinatorJoin() throws {
        var config = AppConfig.defaults()
        config.draftModel = "/models/draft"

        XCTAssertThrowsError(try ServeCommand.runDraftModelArtifactPreflight(config, joiningCoordinator: true))
    }

    func testDraftArtifactPreflightAcceptsVerifiedLocalSnapshotForNoJoinSmoke() throws {
        let snapshot = try makeSnapshot()
        var config = AppConfig.defaults()
        config.draftModel = snapshot.path
        config.draftModelArtifactSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)

        let verifiedPath = try ServeCommand.runDraftModelArtifactPreflight(config, joiningCoordinator: false)
        XCTAssertEqual(verifiedPath, snapshot.standardizedFileURL.path)
    }

    func testDraftArtifactPreflightReturnsUnverifiedPathOnlyForLocalSmoke() throws {
        var config = AppConfig.defaults()
        config.draftModel = "/models/local-smoke"

        let loadPath = try ServeCommand.runDraftModelArtifactPreflight(config, joiningCoordinator: false)
        XCTAssertEqual(loadPath, "/models/local-smoke")
    }

    func testTokenizerArtifactFingerprintBindsTokenizerFiles() throws {
        let first = try makeTokenizerSnapshot(tokenizerJSON: #"{"model":"same"}"#, configJSON: #"{"eos_token":"</s>"}"#)
        let matching = try makeTokenizerSnapshot(tokenizerJSON: #"{"model":"same"}"#, configJSON: #"{"eos_token":"</s>"}"#)
        let divergent = try makeTokenizerSnapshot(tokenizerJSON: #"{"model":"different"}"#, configJSON: #"{"eos_token":"</s>"}"#)
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec028-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        XCTAssertEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: first),
            try ModelRuntime.tokenizerArtifactFingerprint(in: matching)
        )
        XCTAssertNotEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: first),
            try ModelRuntime.tokenizerArtifactFingerprint(in: divergent)
        )
        XCTAssertNil(try ModelRuntime.tokenizerArtifactFingerprint(in: empty))
    }

    func testTokenizerCompatibilityDetectsMismatchedDraftTokenizer() {
        let target = FixedTokenizer(eosToken: "<eos>", unknownToken: "<unk>")
        let matching = FixedTokenizer(eosToken: "<eos>", unknownToken: "<unk>")
        let mismatchedSpecial = FixedTokenizer(eosToken: "</s>", unknownToken: "<unk>")
        let mismatchedEncoding = FixedTokenizer(
            eosToken: "<eos>",
            unknownToken: "<unk>",
            overrides: ["hello|true": [42]]
        )

        XCTAssertTrue(ModelRuntime.tokenizersAreCompatible(targetTokenizer: target, draftTokenizer: matching))
        XCTAssertFalse(ModelRuntime.tokenizersAreCompatible(targetTokenizer: target, draftTokenizer: mismatchedSpecial))
        XCTAssertFalse(ModelRuntime.tokenizersAreCompatible(targetTokenizer: target, draftTokenizer: mismatchedEncoding))
    }

    func testSpeculativeEquivalenceRequiresExactTokenIDs() throws {
        XCTAssertNoThrow(try ModelRuntime.validateSpeculativeEquivalence(plain: [1, 2, 3], speculative: [1, 2, 3]))
        XCTAssertThrowsError(try ModelRuntime.validateSpeculativeEquivalence(plain: [1, 2, 3], speculative: [1, 9, 3])) { error in
            XCTAssertEqual(String(describing: error), "draft_model_equivalence_failed")
        }
    }

    func testDraftRuntimeTestInitializerStoresOnlyConfiguredDraftModel() async {
        let disabled = ModelRuntime(
            modelID: "target",
            warmSwapEnabled: false,
            loader: { _ in throw ModelRuntimeLoadError(target: "unused") }
        )
        let disabledDraftModelID = await disabled.draftModelIDForTest()
        let disabledNumDraftTokens = await disabled.numDraftTokensForTest()
        XCTAssertNil(disabledDraftModelID)
        XCTAssertEqual(disabledNumDraftTokens, 3)

        let enabled = ModelRuntime(
            modelID: "target",
            draftModelID: "draft",
            numDraftTokens: 5,
            warmSwapEnabled: false,
            loader: { _ in throw ModelRuntimeLoadError(target: "unused") }
        )
        let enabledDraftModelID = await enabled.draftModelIDForTest()
        let enabledNumDraftTokens = await enabled.numDraftTokensForTest()
        let enabledSnapshot = await enabled.currentSnapshot()
        XCTAssertEqual(enabledDraftModelID, "draft")
        XCTAssertEqual(enabledNumDraftTokens, 5)
        XCTAssertEqual(enabledSnapshot.draftModelID, "draft")
        XCTAssertNil(enabledSnapshot.draftContainer)
        XCTAssertEqual(enabledSnapshot.numDraftTokens, 5)
    }

    func testSupportedModelsDoesNotIncludeDraftModel() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "target-model"
        config.draftModel = "draft-model"
        config.supportedModels = nil
        config.publishesSupportedModels = false
        let status = ProviderStatus(
            modelID: "target-model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sleepAssertionFactory: { nil }
        ))

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        let supported = try XCTUnwrap(auth["supported_models"] as? [String])
        XCTAssertEqual(supported, ["target-model"])
        XCTAssertFalse(supported.contains("draft-model"))
    }

    func testSpec028FixturesArePinnedAndParse() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spec028")

        let equivalence = try jsonObject(root.appendingPathComponent("equivalence-smoke-v1.json"))
        XCTAssertEqual(equivalence["fixture_id"] as? String, "spec028-equivalence-smoke-v1")
        XCTAssertNotNil(equivalence["messages"] as? [[String: Any]])
        XCTAssertEqual(equivalence["temperature"] as? Int, 0)
        XCTAssertEqual(equivalence["stream"] as? Bool, false)

        let shortChat = try jsonObject(root.appendingPathComponent("small-air-short-chat.json"))
        XCTAssertEqual(shortChat["target_model"] as? String, "mlx-community/Llama-3.2-3B-Instruct-4bit")
        XCTAssertEqual(shortChat["draft_model"] as? String, "mlx-community/Llama-3.2-1B-Instruct-4bit")

        let streaming = try jsonObject(root.appendingPathComponent("small-air-streaming-check.json"))
        let request = try XCTUnwrap(streaming["request"] as? [String: Any])
        XCTAssertEqual(request["stream"] as? Bool, true)
    }

    func testSmallAirLlama32CanaryWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SPEC028_RUN_SMALL_AIR_CANARY"] == "1" else {
            throw XCTSkip("Set SPEC028_RUN_SMALL_AIR_CANARY=1 on an M1 8 GB host with local Llama 3.2 3B/1B snapshots to run AC-11.")
        }
        let memoryGB = Int((ProcessInfo.processInfo.physicalMemory + 1_073_741_823) / 1_073_741_824)
        guard memoryGB <= 12 else {
            throw XCTSkip("AC-11 is scoped to M1 8 GB; host reports \(memoryGB) GB.")
        }

        let target = ProcessInfo.processInfo.environment["SPEC028_SMALL_AIR_TARGET_PATH"] ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"
        let draft = ProcessInfo.processInfo.environment["SPEC028_SMALL_AIR_DRAFT_PATH"] ?? "mlx-community/Llama-3.2-1B-Instruct-4bit"
        let runtime = try await ModelRuntime(
            modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelLoadPath: target,
            draftModelID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            draftModelLoadPath: draft,
            numDraftTokens: 3,
            maxContextTokensOverride: 8_192,
            maxBatch: 1,
            warmSwapEnabled: false
        )

        let shortChat = try requestFixture("small-air-short-chat.json", model: "mlx-community/Llama-3.2-3B-Instruct-4bit")
        let completion = try await runtime.complete(shortChat)
        XCTAssertGreaterThan(completion.completionTokens, 0)

        let streaming = try requestFixture("small-air-streaming-check.json", model: "mlx-community/Llama-3.2-3B-Instruct-4bit")
        let handle = try await runtime.acquireRequestHandle(streaming)
        let chunkCounter = LockedCounter()
        do {
            let streamCompletion = try await runtime.stream(streaming, with: handle, onChunk: { _ in
                chunkCounter.increment()
            })
            await runtime.unregisterInFlight(handle.registrationID)
            XCTAssertGreaterThan(streamCompletion.completionTokens, 0)
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        XCTAssertGreaterThan(chunkCounter.value, 0)
    }

    private struct FixedTokenizer: MLXLMCommon.Tokenizer {
        let bosToken: String? = "<bos>"
        let eosToken: String?
        let unknownToken: String?
        let overrides: [String: [Int]]

        init(eosToken: String?, unknownToken: String?, overrides: [String: [Int]] = [:]) {
            self.eosToken = eosToken
            self.unknownToken = unknownToken
            self.overrides = overrides
        }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            if let override = overrides["\(text)|\(addSpecialTokens)"] {
                return override
            }
            let base = text.utf8.map(Int.init)
            return addSpecialTokens ? [1] + base + [2] : base
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            tokenIds.map(String.init).joined(separator: ",")
        }

        func convertTokenToId(_ token: String) -> Int? {
            if token == bosToken { return 1 }
            if token == eosToken { return 2 }
            if token == unknownToken { return 0 }
            return nil
        }

        func convertIdToToken(_ id: Int) -> String? {
            switch id {
            case 1: bosToken
            case 2: eosToken
            case 0: unknownToken
            default: String(id)
            }
        }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            encode(text: "\(messages)", addSpecialTokens: true)
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private func makeSnapshot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec028-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        return root
    }

    private func makeTokenizerSnapshot(tokenizerJSON: String, configJSON: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec028-tokenizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(tokenizerJSON.utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try Data(configJSON.utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))
        return root
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func requestFixture(_ name: String, model: String) throws -> ChatCompletionRequest {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spec028")
        let wrapper = try jsonObject(root.appendingPathComponent(name))
        var request = try XCTUnwrap(wrapper["request"] as? [String: Any])
        request["model"] = model
        let data = try JSONSerialization.data(withJSONObject: request)
        return try ChatCompletionRequest.parse(data: data)
    }
}
