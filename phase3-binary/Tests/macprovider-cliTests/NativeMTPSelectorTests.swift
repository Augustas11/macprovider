import MacProviderCore
import XCTest
@testable import macprovider_cli

final class NativeMTPSelectorTests: XCTestCase {
    func testDecodePathEnumIsClosedAndDistinctFromClassicSpeculation() {
        XCTAssertEqual(DecodePath.ordinary.rawValue, "ordinary")
        XCTAssertEqual(DecodePath.classicDraftSpec.rawValue, "classic_draft_spec")
        XCTAssertEqual(DecodePath.nativeMTP.rawValue, "native_mtp")
    }

    func testNativeMTPReasonsFitBoundedDiagnosticContract() {
        for reason in NativeMTPSelectorReason.allCases {
            XCTAssertLessThanOrEqual(reason.rawValue.utf8.count, 48, reason.rawValue)
            XCTAssertTrue(reason.rawValue.allSatisfy { scalar in
                scalar.isASCII && (scalar.isLetter || scalar.isNumber || scalar == "_")
            }, reason.rawValue)
        }
    }

    func testDefaultUnavailableCapabilityRoutesOrdinaryWithModeOff() throws {
        let selection = ModelRuntime.decodePath(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPCapability: nil
        )

        XCTAssertEqual(selection.path, .ordinary)
        XCTAssertEqual(selection.nativeMTPReason, .modeOff)
    }

    func testOrdinaryRequestDoesNotOverwriteStartupRevocationUnavailableStatus() async throws {
        let runtime = ModelRuntime(
            modelID: "target",
            maxBatch: 1,
            nativeMTPMode: .auto,
            warmSwapEnabled: false,
            loader: { _ in throw APIError(status: 503, message: "unused", type: "server_error", code: "unused") }
        )
        await runtime.setNativeMTPDisabledStatusReasonForTest(.revocationStateUnavailable)
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: nil,
            schedulerSupportsNativeMTP: false
        )

        await runtime.recordNativeMTPAdmissionStatusForTest(admission)

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.nativeMTPStatus.lastReason, .revocationStateUnavailable)
    }

    func testClassicDraftConfigurationTakesPrecedenceOverNativeMTP() throws {
        let selection = ModelRuntime.decodePath(
            for: try makeRequest(),
            draftConfigured: true,
            draftLoaded: true,
            numDraftTokens: 3,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability()
        )

        XCTAssertEqual(selection.path, .classicDraftSpec)
        XCTAssertEqual(selection.nativeMTPReason, .classicDraftConfigured)
    }

    func testClassicDraftConfiguredButIneligibleRequestRoutesOrdinaryNotNativeMTP() throws {
        let selection = ModelRuntime.decodePath(
            for: try makeRequest(extra: ["temperature": 0.5]),
            draftConfigured: true,
            draftLoaded: true,
            numDraftTokens: 3,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability()
        )

        XCTAssertEqual(selection.path, .ordinary)
        XCTAssertEqual(selection.nativeMTPReason, .classicDraftConfigured)
    }

    func testQualifiedCapabilityCanSelectNativeMTPForGreedyTextOnlyKeylessRequest() throws {
        let selection = ModelRuntime.decodePath(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability()
        )

        XCTAssertEqual(selection.path, .nativeMTP)
        XCTAssertEqual(selection.nativeMTPReason, .eligible)
    }

    func testSupportedSamplingParametersSelectNativeMTP() throws {
        let cases: [(String, [String: Any])] = [
            ("temperature", ["temperature": 0.7]),
            ("top_p", ["top_p": 0.9]),
            ("temperature_and_top_p", ["temperature": 1.3, "top_p": 0.8]),
        ]
        for (name, extra) in cases {
            let sampled = ModelRuntime.decodePath(
                for: try makeRequest(extra: extra),
                draftConfigured: false,
                draftLoaded: false,
                numDraftTokens: nil,
                nativeMTPMode: .auto,
                nativeMTPCapability: admittedCapability(supportsSampling: true)
            )
            XCTAssertEqual(sampled.path, .nativeMTP, name)
            XCTAssertEqual(sampled.nativeMTPReason, .eligible, name)

            // A greedy-only signed tuple keeps sampled requests ordinary.
            let greedyOnly = ModelRuntime.decodePath(
                for: try makeRequest(extra: extra),
                draftConfigured: false,
                draftLoaded: false,
                numDraftTokens: nil,
                nativeMTPMode: .auto,
                nativeMTPCapability: admittedCapability()
            )
            XCTAssertEqual(greedyOnly.path, .ordinary, name)
            XCTAssertEqual(greedyOnly.nativeMTPReason, .sampling, name)
        }

        // Sampling support does not admit logit controls or penalties.
        for (name, extra, reason) in [
            ("top_k", ["temperature": 0.7, "top_k": 10] as [String: Any], NativeMTPSelectorReason.logitControls),
            ("presence", ["temperature": 0.7, "presence_penalty": 0.5], .logitControls),
        ] {
            let selection = ModelRuntime.decodePath(
                for: try makeRequest(extra: extra),
                draftConfigured: false,
                draftLoaded: false,
                numDraftTokens: nil,
                nativeMTPMode: .auto,
                nativeMTPCapability: admittedCapability(supportsSampling: true)
            )
            XCTAssertEqual(selection.path, .ordinary, name)
            XCTAssertEqual(selection.nativeMTPReason, reason, name)
        }
    }

    func testGLMAdmitsUnconstrainedToolsHistoryAndReasoning() throws {
        let tools: [[String: Any]] = [["type": "function", "function": [
            "name": "lookup", "parameters": ["type": "object", "properties": [:]],
        ]]]
        let history: [[String: Any]] = [
            ["role": "user", "content": "Look it up."],
            ["role": "assistant", "content": "", "reasoning_content": "I should use lookup.",
             "tool_calls": [["id": "call_lookup0000000001", "type": "function",
                             "function": ["name": "lookup", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "call_lookup0000000001", "content": "42"],
            ["role": "user", "content": "Explain the result."],
        ]
        for choice in ["auto", "none"] {
            let request = try makeRequest(extra: [
                "tools": tools, "tool_choice": choice, "messages": history,
                "reasoning_effort": "high", "parallel_tool_calls": true,
            ])
            XCTAssertEqual(request.reasoningEffort, "high")
            XCTAssertEqual(request.messages[1].reasoningContent, "I should use lookup.")
            XCTAssertEqual(NativeMTPSelector.reason(
                request: request, mode: .auto,
                nativeCapability: admittedCapability(supportsSampling: true, family: "glm5_next_mtp_v1")
            ), .eligible, choice)
            // A family without this qualification retains the unknown-field gate.
            XCTAssertEqual(NativeMTPSelector.reason(
                request: request, mode: .auto,
                nativeCapability: admittedCapability(family: "qwen3_5_mtp_v1")
            ), .unknownRequestField, choice)
        }
        for parallel in [nil, true] as [Bool?] {
            var extra: [String: Any] = ["tools": tools]
            if let parallel { extra["parallel_tool_calls"] = parallel }
            XCTAssertEqual(NativeMTPSelector.reason(
                request: try makeRequest(extra: extra), mode: .auto,
                nativeCapability: admittedCapability(supportsSampling: true, family: "glm5_next_mtp_v1")
            ), .eligible)
        }
        let serialTool = try makeRequest(extra: ["tools": tools, "parallel_tool_calls": false])
        XCTAssertEqual(NativeMTPSelector.reason(
            request: serialTool, mode: .auto,
            nativeCapability: admittedCapability(supportsSampling: true, family: "glm5_next_mtp_v1")
        ), .tools)
        let toolsOnly = try makeRequest(extra: ["tools": tools])
        XCTAssertEqual(NativeMTPSelector.reason(
            request: toolsOnly, mode: .auto, nativeCapability: admittedCapability()
        ), .tools)
    }

    func testGLMGreedyProfileIdentityRebindKeepsPriorShapeScope() throws {
        let tools: [[String: Any]] = [["type": "function", "function": [
            "name": "lookup", "parameters": ["type": "object"],
        ]]]
        let cases: [([String: Any], NativeMTPSelectorReason)] = [
            (["tools": tools], .tools),
            (["tool_choice": "none"], .tools),
            (["reasoning_effort": "high"], .unknownRequestField),
            (["reasoning_effort": NSNull()], .unknownRequestField),
            (["parallel_tool_calls": true], .unknownRequestField),
            (["parallel_tool_calls": false], .unknownRequestField),
            (["messages": [
                ["role": "assistant", "content": "", "tool_calls": [[
                    "id": "call_lookup0000000001", "type": "function",
                    "function": ["name": "lookup", "arguments": "{}"],
                ]]],
                ["role": "tool", "tool_call_id": "call_lookup0000000001", "content": "42"],
            ]], .tools),
        ]
        for (extra, expected) in cases {
            XCTAssertEqual(NativeMTPSelector.reason(
                request: try makeRequest(extra: extra), mode: .auto,
                nativeCapability: admittedCapability(family: "glm5_next_mtp_v1")
            ), expected, String(describing: extra.keys))
        }
        XCTAssertEqual(NativeMTPSelector.reason(
            request: try makeRequest(), mode: .auto,
            nativeCapability: admittedCapability(family: "glm5_next_mtp_v1")
        ), .eligible, "old greedy plain-text scope remains active")
        XCTAssertEqual(NativeMTPSelector.reason(
            request: try makeRequest(extra: ["reasoning_effort": "high"]), mode: .auto,
            nativeCapability: admittedCapability(supportsSampling: true, family: "glm5_next_mtp_v1")
        ), .eligible, "sampled signed profile authorizes expanded scope even at temperature zero")
    }

    func testGLMStillRejectsStatefulToolGrammarAndUnknownTemplateControls() throws {
        let tools: [[String: Any]] = [["type": "function", "function": [
            "name": "lookup", "parameters": ["type": "object", "properties": [:]],
        ]]]
        let constrainedChoices: [Any] = ["required", ["type": "function", "function": ["name": "lookup"]]]
        for choice in constrainedChoices {
            let request = try makeRequest(extra: ["tools": tools, "tool_choice": choice])
            XCTAssertTrue(GrammarConstraintState.isRequired(request))
            XCTAssertEqual(NativeMTPSelector.reason(
                request: request, mode: .auto,
                nativeCapability: admittedCapability(supportsSampling: true, family: "glm5_next_mtp_v1")
            ), .tools)
        }
        let unknownControls: [[String: Any]] = [
            ["chat_template_kwargs": ["enable_thinking": true]],
            ["thinking_budget": 32],
        ]
        for extra in unknownControls {
            XCTAssertEqual(NativeMTPSelector.reason(
                request: try makeRequest(extra: extra), mode: .auto,
                nativeCapability: admittedCapability(supportsSampling: true, family: "glm5_next_mtp_v1")
            ), .unknownRequestField)
        }
    }

    func testQualifiedCapabilityAdmitsMaxCompletionTokensAlias() throws {
        let request = try makeRequest(extra: ["max_completion_tokens": 64])
        let selection = ModelRuntime.decodePath(
            for: request,
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability()
        )

        XCTAssertTrue(request.topLevelKeys.contains("max_completion_tokens"))
        XCTAssertEqual(request.maxTokens, 64)
        XCTAssertEqual(selection.path, .nativeMTP)
        XCTAssertEqual(selection.nativeMTPReason, .eligible)
    }

    func testNativeMTPRejectsExplicitCompletionLimitAboveSignedProfile() throws {
        let selection = ModelRuntime.decodePath(
            for: try makeRequest(extra: ["max_completion_tokens": 65]),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumCompletionTokens: 64)
        )

        XCTAssertEqual(selection.path, .ordinary)
        XCTAssertEqual(selection.nativeMTPReason, .capabilityMismatch)
    }

    func testNativeMTPRuntimeAdmissionDowngradesAfterTokenizedPromptExceedsSignedProfile() throws {
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(extra: ["max_completion_tokens": 8]),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumPromptTokens: 4, maximumCompletionTokens: 8),
            schedulerSupportsNativeMTP: true
        ).resolvingTokenBounds(promptTokenCount: 5, maxOutputTokens: 8)

        XCTAssertEqual(admission.selection.path, .ordinary)
        XCTAssertEqual(admission.selection.nativeMTPReason, .capabilityMismatch)
        XCTAssertEqual(admission.effectivePath, .ordinary)
        XCTAssertEqual(admission.initialProposalDepth, 0)
        XCTAssertTrue(admission.allowsConversationCacheLease)
    }

    func testTokenBoundDowngradeIsDetectedForRecording() throws {
        let admitted = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(extra: ["max_completion_tokens": 8]),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumPromptTokens: 4096, maximumCompletionTokens: 8),
            schedulerSupportsNativeMTP: true
        )
        let over = admitted.resolvingTokenBounds(promptTokenCount: 4097, maxOutputTokens: 8)
        let within = admitted.resolvingTokenBounds(promptTokenCount: 4096, maxOutputTokens: 8)
        XCTAssertTrue(ModelRuntime.isNativeMTPTokenBoundDowngrade(admitted: admitted, resolved: over))
        XCTAssertEqual(over.selection.nativeMTPReason, .capabilityMismatch)
        XCTAssertFalse(ModelRuntime.isNativeMTPTokenBoundDowngrade(admitted: admitted, resolved: within))
        XCTAssertFalse(ModelRuntime.isNativeMTPTokenBoundDowngrade(admitted: over, resolved: over))
    }

    func testNativeMTPRuntimeAdmissionKeepsMultiChunkPromptsUpToTheSignedBound() throws {
        func admission(promptTokenCount: Int) throws -> NativeMTPRuntimeAdmission {
            ModelRuntime.nativeMTPRuntimeAdmission(
                for: try makeRequest(extra: ["max_completion_tokens": 8]),
                draftConfigured: false,
                draftLoaded: false,
                numDraftTokens: nil,
                nativeMTPMode: .auto,
                nativeMTPCapability: admittedCapability(maximumPromptTokens: 8192, maximumCompletionTokens: 8),
                schedulerSupportsNativeMTP: true
            ).resolvingTokenBounds(promptTokenCount: promptTokenCount, maxOutputTokens: 8)
        }

        // Chunked prefill seeds the drafter chunk by chunk, so the prefill
        // chunk size no longer bounds native prompts; the signed sidecar does.
        for promptTokenCount in [513, 1536, 4096, 8192] {
            let native = try admission(promptTokenCount: promptTokenCount)
            XCTAssertEqual(native.selection.path, .nativeMTP, "\(promptTokenCount)")
            XCTAssertEqual(native.effectivePath, .nativeMTP, "\(promptTokenCount)")
        }
        let oversized = try admission(promptTokenCount: 8193)
        XCTAssertEqual(oversized.selection.path, .ordinary)
        XCTAssertEqual(oversized.selection.nativeMTPReason, .capabilityMismatch)
        XCTAssertEqual(oversized.effectivePath, .ordinary)
        XCTAssertEqual(oversized.initialProposalDepth, 0)
        XCTAssertTrue(oversized.allowsConversationCacheLease)
    }

    func testNativeMTPRuntimeAdmissionDowngradesAfterDefaultCompletionExceedsSignedProfile() throws {
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumPromptTokens: 16, maximumCompletionTokens: 4),
            schedulerSupportsNativeMTP: true
        ).resolvingTokenBounds(promptTokenCount: 3, maxOutputTokens: 5)

        XCTAssertEqual(admission.selection.path, .ordinary)
        XCTAssertEqual(admission.selection.nativeMTPReason, .capabilityMismatch)
        XCTAssertEqual(admission.effectivePath, .ordinary)
        XCTAssertEqual(admission.initialProposalDepth, 0)
        XCTAssertTrue(admission.allowsConversationCacheLease)
    }

    func testAutoWithoutCapabilityFailsClosed() throws {
        let selection = ModelRuntime.decodePath(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: nil
        )

        XCTAssertEqual(selection.path, .ordinary)
        XCTAssertEqual(selection.nativeMTPReason, .capabilityMismatch)
    }

    func testStreamingRequiresAQualifiedStreamingFixture() throws {
        let selection = ModelRuntime.decodePath(
            for: try makeRequest(extra: ["stream": true]),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(supportsStreaming: false)
        )

        XCTAssertEqual(selection.path, .ordinary)
        XCTAssertEqual(selection.nativeMTPReason, .capabilityMismatch)
    }

    func testNativeMTPRejectsRequestFeaturesWithClosedReasons() throws {
        let cases: [(String, ChatCompletionRequest, NativeMTPSelectorReason)] = [
            ("sampling", try makeRequest(extra: ["top_p": 0.9]), .sampling),
            ("structured", try makeRequest(extra: ["response_format": ["type": "json_object"]]), .structuredOutput),
            ("logprobs", try makeRequest(extra: ["logprobs": true]), .logprobs),
            ("logit_bias", try makeRequest(extra: ["logit_bias": ["1": -1]]), .logitControls),
            ("top_k", try makeRequest(extra: ["top_k": 10]), .logitControls),
            ("min_p", try makeRequest(extra: ["min_p": 0.1]), .logitControls),
            ("repetition_penalty", try makeRequest(extra: ["repetition_penalty": 1.1]), .logitControls),
            ("unknown", try makeRequest(extra: ["metadata": ["trace": "local"]]), .unknownRequestField),
            ("stream_options", try makeRequest(extra: ["stream_options": ["include_usage": true, "debug": true]]), .unknownRequestField),
            ("conversation", try makeRequest().withConversationKey("conv:native-mtp"), .conversationKey),
            ("multimodal", try makeMultimodalRequest(), .multimodal),
            ("harmony", try makeRequest(model: "mlx-community/gpt-oss-20b-MXFP4-Q8"), .reasoningOrTemplate),
        ]

        for (name, request, reason) in cases {
            let selection = ModelRuntime.decodePath(
                for: request,
                draftConfigured: false,
                draftLoaded: false,
                numDraftTokens: nil,
                nativeMTPMode: .auto,
                nativeMTPCapability: admittedCapability()
            )
            XCTAssertEqual(selection.path, .ordinary, name)
            XCTAssertEqual(selection.nativeMTPReason, reason, name)
        }
    }

    func testStopSequencesRequireAnExplicitQualifiedFixture() throws {
        let request = try makeRequest(extra: ["stop": ["END"]])

        let unqualified = ModelRuntime.decodePath(
            for: request,
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability()
        )
        XCTAssertEqual(unqualified.path, .ordinary)
        XCTAssertEqual(unqualified.nativeMTPReason, .capabilityMismatch)

        let qualified = ModelRuntime.decodePath(
            for: request,
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(supportsStopSequences: true)
        )
        XCTAssertEqual(qualified.path, .nativeMTP)
        XCTAssertEqual(qualified.nativeMTPReason, .eligible)
    }

    func testNativeMTPRejectsTupleAndRuntimeGatesBeforeRequestEligibility() throws {
        let request = try makeRequest()
        let cases: [(String, NativeMTPCapability, NativeMTPSelectorReason)] = [
            ("upstream", NativeMTPCapability(
                admitted: true,
                revoked: false,
                revocationStateAvailable: true,
                supportsCurrentProcessor: true,
                supportsCurrentStateCache: true,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: false,
                hasQualifiedRowMappedTransactions: false,
                maximumProposalDepth: 2,
                maximumPromptTokens: 32768,
                maximumCompletionTokens: 4096
            ), .capabilityMismatch),
            ("revocation_state", NativeMTPCapability(
                admitted: true,
                revoked: false,
                revocationStateAvailable: false,
                supportsCurrentProcessor: true,
                supportsCurrentStateCache: true,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: false,
                hasQualifiedRowMappedTransactions: true,
                maximumProposalDepth: 2,
                maximumPromptTokens: 32768,
                maximumCompletionTokens: 4096
            ), .revocationStateUnavailable),
            ("revoked", NativeMTPCapability(
                admitted: true,
                revoked: true,
                revocationStateAvailable: true,
                supportsCurrentProcessor: true,
                supportsCurrentStateCache: true,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: false,
                hasQualifiedRowMappedTransactions: true,
                maximumProposalDepth: 2,
                maximumPromptTokens: 32768,
                maximumCompletionTokens: 4096
            ), .tupleRevoked),
            ("not_admitted", NativeMTPCapability(
                admitted: false,
                revoked: false,
                revocationStateAvailable: true,
                supportsCurrentProcessor: true,
                supportsCurrentStateCache: true,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: false,
                hasQualifiedRowMappedTransactions: true,
                maximumProposalDepth: 2,
                maximumPromptTokens: 32768,
                maximumCompletionTokens: 4096
            ), .tupleNotAdmitted),
            ("processor", NativeMTPCapability(
                admitted: true,
                revoked: false,
                revocationStateAvailable: true,
                supportsCurrentProcessor: false,
                supportsCurrentStateCache: true,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: false,
                hasQualifiedRowMappedTransactions: true,
                maximumProposalDepth: 2,
                maximumPromptTokens: 32768,
                maximumCompletionTokens: 4096
            ), .unsupportedProcessor),
            ("cache", NativeMTPCapability(
                admitted: true,
                revoked: false,
                revocationStateAvailable: true,
                supportsCurrentProcessor: true,
                supportsCurrentStateCache: false,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: false,
                hasQualifiedRowMappedTransactions: true,
                maximumProposalDepth: 2,
                maximumPromptTokens: 32768,
                maximumCompletionTokens: 4096
            ), .unsupportedStateCache),
            ("capacity", NativeMTPCapability(
                admitted: true,
                revoked: false,
                revocationStateAvailable: true,
                supportsCurrentProcessor: true,
                supportsCurrentStateCache: true,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: false,
                hasQualifiedRowMappedTransactions: true,
                maximumProposalDepth: 0,
                maximumPromptTokens: 32768,
                maximumCompletionTokens: 4096
            ), .insufficientVerificationCapacity),
        ]

        for (name, capability, reason) in cases {
            let selection = ModelRuntime.decodePath(
                for: request,
                draftConfigured: false,
                draftLoaded: false,
                numDraftTokens: nil,
                nativeMTPMode: .auto,
                nativeMTPCapability: capability
            )
            XCTAssertEqual(selection.path, .ordinary, name)
            XCTAssertEqual(selection.nativeMTPReason, reason, name)
        }
    }

    func testNativeMTPRuntimeAdmissionFailsClosedWithoutSchedulerSupport() throws {
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(),
            schedulerSupportsNativeMTP: false
        )

        XCTAssertEqual(admission.selection.path, .nativeMTP)
        XCTAssertEqual(admission.effectivePath, .ordinary)
        XCTAssertEqual(admission.initialProposalDepth, 0)
        XCTAssertFalse(admission.usesNativeMTP)
        XCTAssertTrue(admission.allowsConversationCacheLease)
    }

    func testNativeMTPRuntimeAdmissionIsCachelessWhenSchedulerSupportsNativeMTP() throws {
        let capability = admittedCapability(maximumProposalDepth: 4)
        let nonStreaming = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: capability,
            schedulerSupportsNativeMTP: true
        )
        let streaming = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(extra: ["stream": true]),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: capability,
            schedulerSupportsNativeMTP: true
        )

        for admission in [nonStreaming, streaming] {
            XCTAssertEqual(admission.selection.path, .nativeMTP)
            XCTAssertEqual(admission.effectivePath, .nativeMTP)
            XCTAssertEqual(admission.initialProposalDepth, 4)
            XCTAssertTrue(admission.usesNativeMTP)
            XCTAssertFalse(admission.allowsConversationCacheLease)
        }
    }

    func testNativeMTPRuntimeAdmissionKeepsIneligibleRequestsOnOrdinaryCachePath() throws {
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest().withConversationKey("conv:ordinary"),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(),
            schedulerSupportsNativeMTP: true
        )

        XCTAssertEqual(admission.selection.path, .ordinary)
        XCTAssertEqual(admission.selection.nativeMTPReason, .conversationKey)
        XCTAssertEqual(admission.effectivePath, .ordinary)
        XCTAssertTrue(admission.allowsConversationCacheLease)
    }

    /// SPEC-048-R009 (G7): a cache-only auto-prefix key stays eligible at
    /// selection and may take a lease; a sticky key still selects ordinary.
    func testCacheOnlyConversationKeyStaysEligibleAndMayLease() throws {
        let cacheOnly = try makeRequest().withConversationKey("conv:auto", cacheOnly: true)
        XCTAssertTrue(cacheOnly.conversationCacheOnly)
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: cacheOnly,
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(),
            schedulerSupportsNativeMTP: true
        )
        XCTAssertEqual(admission.selection.path, .nativeMTP)
        XCTAssertEqual(admission.selection.nativeMTPReason, .eligible)
        XCTAssertTrue(admission.usesNativeMTP)
        XCTAssertFalse(admission.allowsConversationCacheLease)
        XCTAssertTrue(admission.allowsConversationCacheLease(cacheOnlyKey: true))
        XCTAssertFalse(admission.allowsConversationCacheLease(cacheOnlyKey: false))

        let sticky = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest().withConversationKey("conv:sticky", cacheOnly: false),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(),
            schedulerSupportsNativeMTP: true
        )
        XCTAssertEqual(sticky.selection.nativeMTPReason, .conversationKey)
        XCTAssertFalse(sticky.usesNativeMTP)
    }

    /// The cache-only flag never outlives its key and survives every copy.
    func testConversationCacheOnlyFollowsTheKeyThroughRequestCopies() throws {
        let request = try makeRequest()
            .withConversationKey("conv:auto", cacheOnly: true)
            .withRequestID("req-1")
            .withIngestProvenance(.relay)
            .withMaxTokensLimit(4)
        XCTAssertTrue(request.conversationCacheOnly)
        XCTAssertFalse(try makeRequest().withConversationKey(nil, cacheOnly: true).conversationCacheOnly)
        XCTAssertFalse(try makeRequest().withConversationKey("  ", cacheOnly: true).conversationCacheOnly)
        XCTAssertFalse(request.withConversationKey(nil).conversationCacheOnly)
        XCTAssertFalse(request.withConversationKey("conv:auto").conversationCacheOnly)
    }

    /// SPEC-048-R004/R009: a gateway chat request reaches the runtime the way
    /// the relay builds it: auto-prefix key marked cache-only, then the
    /// coordinator's fleet grant for that key. Plain text stays eligible;
    /// tools stay ordinary; a grant for another key carries no marker.
    func testGatewayShapedRequestWithFleetGrantStaysEligible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-gateway-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = FleetConversationCacheAuthority(storageURL: root.appendingPathComponent("floors.json"))
        let key = "conv:" + String(repeating: "ab", count: 32)
        let grant = try authority.authorize(conversationKey: key, generation: 1)
        func relayed(_ extra: [String: Any] = [:], cacheOnly: Bool = true) throws -> ChatCompletionRequest {
            var body: [String: Any] = [
                "messages": [["role": "user", "content": "Write a short paragraph about rivers."]],
                "max_tokens": 256,
                "stream": true,
                "stream_options": ["include_usage": true],
            ]
            for (name, value) in extra { body[name] = value }
            return try makeRequest(extra: body)
                .withConversationKey(key, cacheOnly: cacheOnly)
                .withRequestID("req-gateway-shape")
                .withIngestProvenance(.relay)
                .withFleetCacheGrant(grant)
                .withMaxTokensLimit(4096)
        }
        func admission(_ request: ChatCompletionRequest) -> NativeMTPRuntimeAdmission {
            ModelRuntime.nativeMTPRuntimeAdmission(
                for: request,
                draftConfigured: false,
                draftLoaded: false,
                numDraftTokens: nil,
                nativeMTPMode: .auto,
                nativeMTPCapability: admittedCapability(),
                schedulerSupportsNativeMTP: true
            )
        }

        let plain = try relayed()
        XCTAssertEqual(plain.conversationKey, key)
        XCTAssertTrue(plain.conversationCacheOnly)
        XCTAssertEqual(plain.fleetCacheGrant?.conversationKey, key)
        let native = admission(plain)
        XCTAssertEqual(native.selection.nativeMTPReason, .eligible)
        XCTAssertTrue(native.usesNativeMTP)
        XCTAssertTrue(native.allowsConversationCacheLease(cacheOnlyKey: plain.conversationCacheOnly))
        XCTAssertTrue(native.resolvingConversationCacheLease(
            hasConversationKey: true, leaseAllowed: true, cachedPromptTokens: 0, keyedRowsCommitSerialFormat: true
        ).usesNativeMTP)

        // A cache hit the scheduler cannot resume sends the row to the serial
        // path, which never runs native: it keeps the ordinary lease there.
        XCTAssertTrue(ModelRuntime.serialConversationCacheLeaseAllowed(request: plain, admission: native))
        XCTAssertFalse(ModelRuntime.serialConversationCacheLeaseAllowed(
            request: plain.withIngestProvenance(.privacy), admission: native))

        let tools = admission(try relayed([
            "tools": [["type": "function", "function": ["name": "lookup", "parameters": ["type": "object"]]]],
        ]))
        XCTAssertEqual(tools.selection.nativeMTPReason, .tools)
        XCTAssertFalse(tools.usesNativeMTP)

        let sticky = try relayed(cacheOnly: false)
        XCTAssertFalse(sticky.conversationCacheOnly)
        XCTAssertEqual(admission(sticky).selection.nativeMTPReason, .conversationKey)

        let otherGrant = try authority.authorize(conversationKey: "conv:other", generation: 1)
        let regranted = try makeRequest()
            .withConversationKey(key, cacheOnly: true)
            .withFleetCacheGrant(otherGrant)
        XCTAssertEqual(regranted.conversationKey, "conv:other")
        XCTAssertFalse(regranted.conversationCacheOnly)
        XCTAssertFalse(try makeRequest().withConversationKey(key, cacheOnly: true)
            .withFleetCacheGrant(nil).conversationCacheOnly)
    }

    /// The lease decides a cache-only native row: only a miss on a runtime
    /// that commits keyed rows in serial format stays native.
    func testCacheOnlyNativeAdmissionResolvesOnTheLease() throws {
        let native = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest().withConversationKey("conv:auto", cacheOnly: true),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(),
            schedulerSupportsNativeMTP: true
        )
        func resolve(key: Bool = true, allowed: Bool = true, cached: Int?, serial: Bool = true) -> NativeMTPRuntimeAdmission {
            native.resolvingConversationCacheLease(
                hasConversationKey: key,
                leaseAllowed: allowed,
                cachedPromptTokens: cached,
                keyedRowsCommitSerialFormat: serial
            )
        }
        XCTAssertTrue(resolve(cached: 0).usesNativeMTP)
        XCTAssertTrue(resolve(key: false, cached: nil).usesNativeMTP)
        XCTAssertTrue(resolve(allowed: false, cached: nil).usesNativeMTP)
        // SPEC-048 0.1.56 MTP-9: a snapshot hit that restores the MTP head
        // state stays native; without it, the hit still reselects ordinary.
        XCTAssertTrue(native.resolvingConversationCacheLease(
            hasConversationKey: true, leaseAllowed: true, cachedPromptTokens: 12,
            keyedRowsCommitSerialFormat: true, cachedPrefixRestoresNativeMTPDrafter: true
        ).usesNativeMTP)
        XCTAssertFalse(native.resolvingConversationCacheLease(
            hasConversationKey: true, leaseAllowed: true, cachedPromptTokens: 12,
            keyedRowsCommitSerialFormat: false, cachedPrefixRestoresNativeMTPDrafter: true
        ).usesNativeMTP)
        XCTAssertFalse(native.resolvingConversationCacheLease(
            hasConversationKey: true, leaseAllowed: true, cachedPromptTokens: nil,
            keyedRowsCommitSerialFormat: true, cachedPrefixRestoresNativeMTPDrafter: true
        ).usesNativeMTP)
        for downgraded in [resolve(cached: 12), resolve(cached: nil), resolve(cached: 0, serial: false)] {
            XCTAssertFalse(downgraded.usesNativeMTP)
            XCTAssertEqual(downgraded.selection.path, .ordinary)
            XCTAssertEqual(downgraded.selection.nativeMTPReason, .conversationKey)
            XCTAssertTrue(downgraded.allowsConversationCacheLease)
        }
        let ordinary = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest().withConversationKey("conv:sticky"),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(),
            schedulerSupportsNativeMTP: true
        )
        XCTAssertEqual(
            ordinary.resolvingConversationCacheLease(
                hasConversationKey: true, leaseAllowed: true, cachedPromptTokens: 0, keyedRowsCommitSerialFormat: true
            ).selection,
            ordinary.selection
        )
    }

    func testNonStreamingAdmissionUsesServedNativeCapabilityAndMaxCompletionTokens() throws {
        let request = try makeRequest(extra: ["max_completion_tokens": 7])
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: request,
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumProposalDepth: 4),
            schedulerSupportsNativeMTP: true
        )

        XCTAssertEqual(request.maxTokens, 7)
        XCTAssertEqual(admission.effectivePath, .nativeMTP)
        XCTAssertEqual(admission.initialProposalDepth, 4)
        XCTAssertFalse(admission.allowsConversationCacheLease)
    }

    func testStreamingAdmissionUsesServedNativeCapabilityAndMaxCompletionTokens() throws {
        let request = try makeRequest(extra: ["stream": true, "max_completion_tokens": 5])
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: request,
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumProposalDepth: 3),
            schedulerSupportsNativeMTP: true
        )

        XCTAssertEqual(request.maxTokens, 5)
        XCTAssertEqual(admission.effectivePath, .nativeMTP)
        XCTAssertEqual(admission.initialProposalDepth, 3)
        XCTAssertFalse(admission.allowsConversationCacheLease)
    }

    func testNativeMTPRuntimeAdmissionDowngradesAtSignedActiveRowBound() throws {
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumNativeActiveRows: 2),
            schedulerSupportsNativeMTP: true
        )
        XCTAssertEqual(admission.maximumNativeActiveRows, 2)

        for otherRows in [-1, 0, 1] {
            let kept = admission.resolvingActiveRows(otherActiveRows: otherRows)
            XCTAssertEqual(kept, admission, "other rows \(otherRows)")
        }
        for otherRows in [2, 7] {
            let downgraded = admission.resolvingActiveRows(otherActiveRows: otherRows)
            XCTAssertEqual(downgraded.selection.path, .ordinary)
            XCTAssertEqual(downgraded.selection.nativeMTPReason, .capacityAboveNativeBound)
            XCTAssertEqual(downgraded.effectivePath, .ordinary)
            XCTAssertEqual(downgraded.initialProposalDepth, 0)
            XCTAssertEqual(downgraded.completeWindowBytesByDepth, [])
            XCTAssertNil(downgraded.tupleFence)
            XCTAssertFalse(downgraded.usesNativeMTP)
        }
        XCTAssertEqual(NativeMTPSelectorReason.capacityAboveNativeBound.rawValue, "capacity_above_native_bound")
        XCTAssertEqual(NativeMTPStatusReason.capacityAboveNativeBound.rawValue, "capacity_above_native_bound")
    }

    func testOrdinaryAdmissionIsNotTouchedByActiveRowBound() throws {
        let ordinary = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest().withConversationKey("conv:ordinary"),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumNativeActiveRows: 1),
            schedulerSupportsNativeMTP: true
        )
        XCTAssertEqual(ordinary.resolvingActiveRows(otherActiveRows: 5), ordinary)
        XCTAssertEqual(ordinary.selection.nativeMTPReason, .conversationKey)
    }

    func testAdmissionCountsOtherInFlightRowsAgainstSignedBound() throws {
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumProposalDepth: 2, maximumNativeActiveRows: 1),
            schedulerSupportsNativeMTP: true
        )

        XCTAssertEqual(admission.effectivePath, .nativeMTP)

        let downgraded = admission.resolvingActiveRows(otherActiveRows: 1)
        XCTAssertEqual(downgraded.effectivePath, .ordinary)
        XCTAssertEqual(downgraded.selection.nativeMTPReason, .capacityAboveNativeBound)
    }

    private func admittedCapability(
        supportsStreaming: Bool = true,
        supportsNonStreaming: Bool = true,
        supportsStopSequences: Bool = false,
        maximumProposalDepth: Int = 2,
        maximumPromptTokens: Int = 32768,
        maximumCompletionTokens: Int = 4096,
        maximumNativeActiveRows: Int = Int.max,
        supportsSampling: Bool = false,
        family: String? = nil
    ) -> NativeMTPCapability {
        NativeMTPCapability(
            admitted: true,
            revoked: false,
            revocationStateAvailable: true,
            supportsCurrentProcessor: true,
            supportsCurrentStateCache: true,
            supportsStreaming: supportsStreaming,
            supportsNonStreaming: supportsNonStreaming,
            supportsStopSequences: supportsStopSequences,
            hasQualifiedRowMappedTransactions: true,
            maximumProposalDepth: maximumProposalDepth,
            maximumPromptTokens: maximumPromptTokens,
            maximumCompletionTokens: maximumCompletionTokens,
            family: family,
            maximumNativeActiveRows: maximumNativeActiveRows,
            supportsSampling: supportsSampling
        )
    }

    private func makeRequest(
        model: String = "target",
        extra: [String: Any] = [:]
    ) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hello"]],
            "temperature": 0,
            "top_p": 1.0,
        ]
        for (key, value) in extra {
            body[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ChatCompletionRequest.parse(data: data)
    }

    private func makeMultimodalRequest() throws -> ChatCompletionRequest {
        try makeRequest(extra: [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "hello"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]],
                ],
            ]],
        ])
    }
}
