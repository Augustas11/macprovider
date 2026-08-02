import ArgumentParser
import Foundation
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class Spec028PlumbingTests: XCTestCase {
    private enum TestError: Error {
        case unexpectedContainerLoader
    }

    private func makeChatRequest(
        model: String = "target",
        temperature: Double = 0.0,
        topP: Double = 1.0,
        extra: [String: Any] = [:]
    ) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hello"]],
            "temperature": temperature,
            "top_p": topP,
        ]
        for (key, value) in extra {
            body[key] = value
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

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

    func testTelemetryPublishFlagPassesPreflightAfterHeartbeatPR() throws {
        var config = AppConfig.defaults()
        config.publishesSpecDecodeTelemetry = true

        XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config))
        XCTAssertNoThrow(try ServeCommand.runSpecDecodeHeartbeatCompatibilityPreflight(
            config,
            coordinatorAcceptsSpecDecodeTelemetry: ServeCommand.bundledCoordinatorAcceptsSpecDecodeTelemetry
        ))
    }

    func testTelemetryPublishFlagFailsClosedWhenCoordinatorCompatibilityMissing() throws {
        var config = AppConfig.defaults()
        config.publishesSpecDecodeTelemetry = true

        XCTAssertThrowsError(try ServeCommand.runSpecDecodeHeartbeatCompatibilityPreflight(
            config,
            coordinatorAcceptsSpecDecodeTelemetry: false
        ))
    }

    func testRuntimeSpeculativeRouteUsesGreedyGateAndDraftAvailability() throws {
        let greedy = try makeChatRequest()
        let stochastic = try makeChatRequest(temperature: 0.2)
        let toolChoice = try makeChatRequest(extra: ["tool_choice": "none"])
        let stop = try makeChatRequest(extra: ["stop": ["END"]])
        let harmony = try makeChatRequest(model: "mlx-community/gpt-oss-20b-MXFP4-Q8")

        XCTAssertEqual(
            ModelRuntime.speculativeRoute(for: greedy, draftLoaded: true, numDraftTokens: 3),
            .speculative
        )
        XCTAssertEqual(
            ModelRuntime.speculativeRoute(for: greedy, draftLoaded: false, numDraftTokens: 3),
            .tokenIterator
        )
        XCTAssertEqual(
            ModelRuntime.speculativeRoute(for: greedy, draftLoaded: true, numDraftTokens: nil),
            .tokenIterator
        )
        XCTAssertEqual(
            ModelRuntime.speculativeRoute(for: stochastic, draftLoaded: true, numDraftTokens: 3),
            .tokenIterator
        )
        XCTAssertEqual(
            ModelRuntime.speculativeRoute(for: toolChoice, draftLoaded: true, numDraftTokens: 3),
            .tokenIterator
        )
        XCTAssertEqual(
            ModelRuntime.speculativeRoute(for: stop, draftLoaded: true, numDraftTokens: 3),
            .tokenIterator
        )
        XCTAssertEqual(
            ModelRuntime.speculativeRoute(for: harmony, draftLoaded: true, numDraftTokens: 3),
            .tokenIterator,
            "Harmony responses require token IDs for channel parsing"
        )
    }

    func testSpeculativeNonStreamingFailureFallsBackBeforeOutput() async throws {
        let speculativeCalls = LockedCounter()
        let fallbackCalls = LockedCounter()
        let runtime = ModelRuntime(
            modelID: "target",
            draftModelID: "draft",
            warmSwapEnabled: false,
            loader: { _ in throw TestError.unexpectedContainerLoader },
            testCompletion: { _, _ in
                fallbackCalls.increment()
                return CompletionResult(
                    content: "fallback",
                    finishReason: "stop",
                    promptTokens: 1,
                    completionTokens: 1
                )
            },
            testSpeculativeCompletion: { _, _ in
                speculativeCalls.increment()
                throw ModelRuntime.SpeculativeGenerationFailure(reason: "injected_pre_output")
            }
        )

        let completion = try await runtime.complete(try makeChatRequest())

        XCTAssertEqual(completion.content, "fallback")
        XCTAssertEqual(completion.specDecodeDraftedTokens, 0)
        XCTAssertEqual(completion.specDecodeAcceptedTokens, 0)
        XCTAssertEqual(speculativeCalls.value, 1)
        XCTAssertEqual(fallbackCalls.value, 1)
    }

    func testSpeculativeStreamingFailureDoesNotRetryOrEmitMixedOutput() async throws {
        let speculativeCalls = LockedCounter()
        let fallbackCalls = LockedCounter()
        let chunkCalls = LockedCounter()
        let runtime = ModelRuntime(
            modelID: "target",
            draftModelID: "draft",
            warmSwapEnabled: false,
            loader: { _ in throw TestError.unexpectedContainerLoader },
            testCompletion: { _, _ in
                fallbackCalls.increment()
                return CompletionResult(
                    content: "fallback",
                    finishReason: "stop",
                    promptTokens: 1,
                    completionTokens: 1
                )
            },
            testSpeculativeStream: { _, _ in
                speculativeCalls.increment()
                throw ModelRuntime.SpeculativeGenerationFailure(reason: "injected_after_internal_chunk")
            }
        )
        let request = try makeChatRequest(extra: ["stream": true])
        let handle = try await runtime.acquireRequestHandle(request)
        defer {
            Task { await runtime.unregisterInFlight(handle.registrationID) }
        }

        do {
            _ = try await runtime.stream(request, with: handle) { _ in
                chunkCalls.increment()
            }
            XCTFail("expected injected speculative streaming failure")
        } catch let error as ModelRuntime.SpeculativeGenerationFailure {
            XCTAssertEqual(error.reason, "injected_after_internal_chunk")
        }

        XCTAssertEqual(speculativeCalls.value, 1)
        XCTAssertEqual(fallbackCalls.value, 0)
        XCTAssertEqual(chunkCalls.value, 0)
    }

    func testRuntimeSnapshotRequiresTargetCompatibleDraft() {
        let matching = RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "target-a",
            modelHash: nil,
            draftModelID: "draft",
            draftTargetModelID: "target-a",
            numDraftTokens: 3
        )
        let mismatched = RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "target-b",
            modelHash: nil,
            draftModelID: "draft",
            draftTargetModelID: "target-a",
            numDraftTokens: 3
        )

        XCTAssertTrue(matching.hasTargetCompatibleDraft)
        XCTAssertFalse(mismatched.hasTargetCompatibleDraft)
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

    /// Round-2 code MEDIUM-3 (Fix E): an autotune candidate with a draft model
    /// configured (via flag/env/config, all collapsing into the resolved
    /// AppConfig) must resolve to NO draft model, so the speculative route —
    /// whose decode loop never fires the outer decode timer — is never taken
    /// and the probe always exercises the main, timed decode path.
    func testAutotuneCandidateSuppressesResolvedDraftModel() {
        var config = AppConfig.defaults()
        config.draftModel = "/models/draft"
        config.draftModelArtifactSHA256 = String(repeating: "a", count: 64)

        ServeCommand.applyAutotuneCandidateDraftSuppression(&config, autotuneCandidate: true)

        XCTAssertNil(config.draftModel,
            "autotune candidate must resolve to no draft model (speculative decode disabled)")
        XCTAssertNil(config.draftModelArtifactSHA256,
            "the draft artifact hash must be cleared alongside the draft model")

        // Downstream capacity preflight must now be a no-op (no draft model).
        var followOn = config
        XCTAssertNoThrow(try ServeCommand.runSpecDecodeCapacityPreflight(&followOn))
    }

    /// Non-candidate serve must keep its configured draft model untouched.
    func testNonAutotuneCandidateKeepsResolvedDraftModel() {
        var config = AppConfig.defaults()
        config.draftModel = "/models/draft"
        let hash = String(repeating: "b", count: 64)
        config.draftModelArtifactSHA256 = hash

        ServeCommand.applyAutotuneCandidateDraftSuppression(&config, autotuneCandidate: false)

        XCTAssertEqual(config.draftModel, "/models/draft",
            "a normal serve must retain its draft model")
        XCTAssertEqual(config.draftModelArtifactSHA256, hash)
    }

    func testTokenizerArtifactFingerprintBindsTokenizerFiles() throws {
        let first = try makeTokenizerSnapshot(tokenizerJSON: #"{"model":"same"}"#, configJSON: #"{"eos_token":"</s>"}"#)
        let matching = try makeTokenizerSnapshot(tokenizerJSON: #"{"model":"same"}"#, configJSON: #"{"eos_token":"</s>"}"#)
        let matchingExceptChatTemplate = try makeTokenizerSnapshot(
            tokenizerJSON: #"{"model":"same"}"#,
            configJSON: #"{"eos_token":"</s>","chat_template":"different default assistant prompt"}"#
        )
        let matchingFastTokenizerWithRedundantMerges = try makeTokenizerSnapshot(
            tokenizerJSON: #"{"model":"same"}"#,
            configJSON: #"{"eos_token":"</s>"}"#,
            mergesTXT: "redundant BPE sidecar ignored when tokenizer.json is present"
        )
        let divergentConfig = try makeTokenizerSnapshot(tokenizerJSON: #"{"model":"same"}"#, configJSON: #"{"eos_token":"<eos>"}"#)
        let divergent = try makeTokenizerSnapshot(tokenizerJSON: #"{"model":"different"}"#, configJSON: #"{"eos_token":"</s>"}"#)
        let slowTokenizer = try makeTokenizerSnapshot(
            tokenizerJSON: nil,
            configJSON: #"{"eos_token":"</s>"}"#,
            vocabJSON: #"{"hello":0}"#,
            mergesTXT: "h e"
        )
        let divergentSlowTokenizer = try makeTokenizerSnapshot(
            tokenizerJSON: nil,
            configJSON: #"{"eos_token":"</s>"}"#,
            vocabJSON: #"{"hello":0}"#,
            mergesTXT: "x y"
        )
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec028-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        XCTAssertEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: first),
            try ModelRuntime.tokenizerArtifactFingerprint(in: matching)
        )
        XCTAssertEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: first),
            try ModelRuntime.tokenizerArtifactFingerprint(in: matchingExceptChatTemplate)
        )
        XCTAssertEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: first),
            try ModelRuntime.tokenizerArtifactFingerprint(in: matchingFastTokenizerWithRedundantMerges)
        )
        XCTAssertNotEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: first),
            try ModelRuntime.tokenizerArtifactFingerprint(in: divergentConfig)
        )
        XCTAssertNotEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: first),
            try ModelRuntime.tokenizerArtifactFingerprint(in: divergent)
        )
        XCTAssertNotEqual(
            try ModelRuntime.tokenizerArtifactFingerprint(in: slowTokenizer),
            try ModelRuntime.tokenizerArtifactFingerprint(in: divergentSlowTokenizer)
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

        let code = try jsonObject(root.appendingPathComponent("spec028-code-iso8601-v1.json"))
        XCTAssertEqual(code["fixture_id"] as? String, "spec028-code-iso8601-v1")
        XCTAssertEqual(code["target_model"] as? String, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertEqual(code["draft_model"] as? String, "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        let codeRequest = try XCTUnwrap(code["request"] as? [String: Any])
        let codeMessages = try XCTUnwrap(codeRequest["messages"] as? [[String: Any]])
        XCTAssertEqual(codeMessages.count, 2)
        XCTAssertEqual(codeMessages[0]["role"] as? String, "system")
        XCTAssertEqual(codeMessages[0]["content"] as? String, "You write production Python. No prose, just code blocks.")
        XCTAssertEqual(codeMessages[1]["role"] as? String, "user")
        XCTAssertTrue((codeMessages[1]["content"] as? String)?.contains("def parse_iso8601(s: str) -> datetime:") == true)
        XCTAssertEqual(codeRequest["temperature"] as? Int, 0)
        XCTAssertEqual(codeRequest["top_p"] as? Double, 1.0)
        XCTAssertEqual(codeRequest["max_tokens"] as? Int, 240)
        XCTAssertEqual(codeRequest["stream"] as? Bool, false)
        XCTAssertEqual((codeRequest["response_format"] as? [String: Any])?["type"] as? String, "text")
    }

    func testAC10CanaryFixtureLoadsAndBaselineForcesTokenIterator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spec028/spec028-code-iso8601-v1.json")
        let fixture = try Spec028CanaryFixture.load(path: root.path)

        let spec = try fixture.request(forceTokenIterator: false)
        let baseline = try fixture.request(forceTokenIterator: true)

        XCTAssertEqual(fixture.fixtureID, "spec028-code-iso8601-v1")
        XCTAssertEqual(fixture.targetModel, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertEqual(fixture.draftModel, "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertTrue(spec.allowsSpeculativeDecoding)
        XCTAssertFalse(baseline.allowsSpeculativeDecoding)
        XCTAssertEqual(spec.temperature, baseline.temperature)
        XCTAssertEqual(spec.topP, baseline.topP)
        XCTAssertEqual(spec.maxTokens, baseline.maxTokens)
        XCTAssertEqual(spec.messages.map(\.content), baseline.messages.map(\.content))
    }

    func testSpec028BenchmarkEvaluationGatesTTFTRegression() throws {
        let now = Date()
        let evaluation = try Spec028BenchmarkEvaluation.evaluate(
            baselineSamples: [
                benchmarkSample(
                    phase: "baseline",
                    tokensPerSecond: 20,
                    ttftMilliseconds: 100,
                    endedAtUnixSeconds: now.timeIntervalSince1970 - 10
                ),
            ],
            specSamples: [
                benchmarkSample(
                    phase: "spec",
                    tokensPerSecond: 28,
                    ttftMilliseconds: 130,
                    draftedTokens: 100,
                    acceptedTokens: 95,
                    endedAtUnixSeconds: now.timeIntervalSince1970 - 5
                ),
            ],
            sustainedSamples: [
                benchmarkSample(
                    phase: "sustained",
                    tokensPerSecond: 27,
                    ttftMilliseconds: 120,
                    draftedTokens: 100,
                    acceptedTokens: 95,
                    endedAtUnixSeconds: now.timeIntervalSince1970
                ),
            ],
            sustainedEndedAt: now,
            lastWindowSeconds: 30,
            recommendRatioFloor: 1.15,
            maxP95LatencyRatio: 2.0,
            maxP95TTFTRatio: 1.0,
            recommendAcceptanceFloor: 0.30
        )

        XCTAssertEqual(evaluation.tpsRatio, 1.4, accuracy: 0.001)
        XCTAssertEqual(evaluation.ttftP95Ratio ?? 0, 1.3, accuracy: 0.001)
        XCTAssertFalse(evaluation.recommendEnable)
        XCTAssertTrue(evaluation.recommendationReasons.contains("p95 TTFT ratio 1.300 > 1.000"))
    }

    func testAC10CanaryEvaluationRequiresRatioAcceptanceAndSustainedWindow() throws {
        let now = Date()
        let baseline = (0..<5).map { index in
            Spec028CanarySample(
                phase: "baseline",
                generatedTokens: 100,
                elapsedSeconds: 10,
                tokensPerSecond: 10 + Double(index % 2),
                draftedTokens: 0,
                acceptedTokens: 0,
                endedAtUnixSeconds: now.timeIntervalSince1970 - 120 + Double(index),
                thermalState: "nominal"
            )
        }
        let spec = (0..<5).map { index in
            Spec028CanarySample(
                phase: "spec",
                generatedTokens: 160,
                elapsedSeconds: 10,
                tokensPerSecond: 15 + Double(index % 2),
                draftedTokens: 100,
                acceptedTokens: 45,
                endedAtUnixSeconds: now.timeIntervalSince1970 - 60 + Double(index),
                thermalState: "nominal"
            )
        }
        let sustained = (0..<3).map { index in
            Spec028CanarySample(
                phase: "sustained",
                generatedTokens: 130,
                elapsedSeconds: 10,
                tokensPerSecond: 13 + Double(index),
                draftedTokens: 100,
                acceptedTokens: 45,
                endedAtUnixSeconds: now.timeIntervalSince1970 - Double(index * 10),
                thermalState: "nominal"
            )
        }

        let passing = try Spec028CanaryEvaluation.evaluate(
            baselineSamples: baseline,
            specSamples: spec,
            sustainedSamples: sustained,
            sustainedEndedAt: now,
            lastWindowSeconds: 60,
            ratioFloor: 1.4,
            sustainedRatioFloor: 1.2,
            acceptanceFloor: 0.30
        )
        XCTAssertTrue(passing.passed)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(passing.acceptanceRate), 0.30)
        XCTAssertGreaterThanOrEqual(passing.ratio, 1.4)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(passing.sustainedLastWindowRatio), 1.2)

        let failing = try Spec028CanaryEvaluation.evaluate(
            baselineSamples: baseline,
            specSamples: spec.map {
                Spec028CanarySample(
                    phase: $0.phase,
                    generatedTokens: $0.generatedTokens,
                    elapsedSeconds: $0.elapsedSeconds,
                    tokensPerSecond: 11,
                    draftedTokens: 100,
                    acceptedTokens: 20,
                    endedAtUnixSeconds: $0.endedAtUnixSeconds,
                    thermalState: $0.thermalState
                )
            },
            sustainedSamples: sustained,
            sustainedEndedAt: now,
            lastWindowSeconds: 60,
            ratioFloor: 1.4,
            sustainedRatioFloor: 1.2,
            acceptanceFloor: 0.30
        )
        XCTAssertFalse(failing.passed)
        XCTAssertTrue(failing.failureReasons.contains { $0.contains("spec ratio") })
        XCTAssertTrue(failing.failureReasons.contains { $0.contains("acceptance") })
    }

    func testAC11CanaryEvaluationRequiresSpecDecodeAndStreamingEvidence() {
        let shortChat = ac11FixtureResult(
            mode: "short_chat",
            streamed: false,
            draftedTokens: 12,
            acceptedTokens: 6,
            chunks: 0
        )
        let streaming = ac11FixtureResult(
            mode: "streaming_check",
            streamed: true,
            draftedTokens: 10,
            acceptedTokens: 4,
            chunks: 3
        )

        XCTAssertTrue(Spec028AC11Evaluation.evaluate(fixtures: [shortChat, streaming]).passed)

        let zeroDraft = Spec028AC11Evaluation.evaluate(fixtures: [
            ac11FixtureResult(mode: "short_chat", streamed: false, draftedTokens: 0, acceptedTokens: 0, chunks: 0),
            streaming
        ])
        XCTAssertFalse(zeroDraft.passed)
        XCTAssertTrue(zeroDraft.failureReasons.contains { $0.contains("produced no drafted tokens") })
        XCTAssertTrue(zeroDraft.failureReasons.contains { $0.contains("accepted no drafted tokens") })

        let zeroChunks = Spec028AC11Evaluation.evaluate(fixtures: [
            shortChat,
            ac11FixtureResult(mode: "streaming_check", streamed: true, draftedTokens: 10, acceptedTokens: 4, chunks: 0)
        ])
        XCTAssertFalse(zeroChunks.passed)
        XCTAssertTrue(zeroChunks.failureReasons.contains { $0.contains("streamed no chunks") })
    }

    func testSpec028CanaryFixtureInvalidShapeDoesNotExposeAbsolutePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec028-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("bad.json")
        try Data(#"{"fixture_id":"bad"}"#.utf8).write(to: fixtureURL)

        XCTAssertThrowsError(try Spec028CanaryFixture.load(
            path: fixtureURL.path,
            defaultResourceName: "bad",
            defaultFixturePath: "unused.json",
            label: "AC-11 bad_fixture"
        )) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("invalid AC-11 bad_fixture fixture bad.json"))
            XCTAssertFalse(message.contains(directory.path))
        }
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

    private func makeTokenizerSnapshot(
        tokenizerJSON: String?,
        configJSON: String,
        vocabJSON: String? = nil,
        mergesTXT: String? = nil
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec028-tokenizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let tokenizerJSON {
            try Data(tokenizerJSON.utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        }
        try Data(configJSON.utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))
        if let vocabJSON {
            try Data(vocabJSON.utf8).write(to: root.appendingPathComponent("vocab.json"))
        }
        if let mergesTXT {
            try Data(mergesTXT.utf8).write(to: root.appendingPathComponent("merges.txt"))
        }
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

    private func ac11FixtureResult(
        mode: String,
        streamed: Bool,
        draftedTokens: Int,
        acceptedTokens: Int,
        chunks: Int,
        temperature: Double = 0,
        completionTokens: Int = 8
    ) -> Spec028AC11FixtureResult {
        Spec028AC11FixtureResult(
            fixtureID: "fixture-\(mode)",
            mode: mode,
            temperature: temperature,
            streamed: streamed,
            promptTokens: 12,
            completionTokens: completionTokens,
            elapsedSeconds: 0.5,
            draftedTokens: draftedTokens,
            acceptedTokens: acceptedTokens,
            acceptanceRate: draftedTokens > 0 ? Double(acceptedTokens) / Double(draftedTokens) : nil,
            chunks: chunks,
            thermalState: "nominal"
        )
    }

    private func benchmarkSample(
        phase: String,
        tokensPerSecond: Double,
        ttftMilliseconds: Int64,
        draftedTokens: Int = 0,
        acceptedTokens: Int = 0,
        endedAtUnixSeconds: Double
    ) -> Spec028BenchmarkSample {
        Spec028BenchmarkSample(
            phase: phase,
            promptTokens: 10,
            completionTokens: 20,
            elapsedSeconds: 20 / tokensPerSecond,
            tokensPerSecond: tokensPerSecond,
            ttftMilliseconds: ttftMilliseconds,
            draftedTokens: draftedTokens,
            acceptedTokens: acceptedTokens,
            streamedChunks: 20,
            endedAtUnixSeconds: endedAtUnixSeconds,
            thermalState: "nominal"
        )
    }
}
