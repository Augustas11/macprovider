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

    func testNativeMTPRuntimeAdmissionDowngradesAfterTokenizedPromptExceedsRuntimePrefillBound() throws {
        let admission = ModelRuntime.nativeMTPRuntimeAdmission(
            for: try makeRequest(extra: ["max_completion_tokens": 8]),
            draftConfigured: false,
            draftLoaded: false,
            numDraftTokens: nil,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumPromptTokens: 4096, maximumCompletionTokens: 8),
            schedulerSupportsNativeMTP: true
        ).resolvingTokenBounds(
            promptTokenCount: 513,
            maxOutputTokens: 8,
            runtimeMaximumPromptTokens: ModelRuntime.nativeMTPFullPromptPrefillTokenLimit(prefillStepSize: 512)
        )

        XCTAssertEqual(ModelRuntime.nativeMTPFullPromptPrefillTokenLimit(prefillStepSize: 512), 512)
        XCTAssertEqual(admission.selection.path, .ordinary)
        XCTAssertEqual(admission.selection.nativeMTPReason, .capabilityMismatch)
        XCTAssertEqual(admission.effectivePath, .ordinary)
        XCTAssertEqual(admission.initialProposalDepth, 0)
        XCTAssertTrue(admission.allowsConversationCacheLease)
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

    func testNonStreamingEntryPathUsesInjectedNativeMTPAdmissionAndMaxCompletionTokens() async throws {
        let recorder = NativeMTPAdmissionRecorder()
        let runtime = ModelRuntime(
            modelID: "target",
            modelHash: Self.modelHash,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumProposalDepth: 4),
            nativeMTPSchedulerSupported: true,
            testNativeMTPAdmissionObserver: { admission in
                recorder.append(admission)
            },
            warmSwapEnabled: true,
            loader: { _ in throw CancellationError() },
            testCompletion: { _, request in
                XCTAssertEqual(request.maxTokens, 7)
                return Self.completion()
            }
        )

        let (completion, _) = try await runtime.completeWithServedSnapshot(
            try makeRequest(extra: ["max_completion_tokens": 7])
        )

        XCTAssertEqual(completion.finishReason, "stop")
        let admission = try XCTUnwrap(recorder.last())
        XCTAssertEqual(admission.effectivePath, .nativeMTP)
        XCTAssertEqual(admission.initialProposalDepth, 4)
        XCTAssertFalse(admission.allowsConversationCacheLease)
    }

    func testStreamingEntryPathUsesInjectedNativeMTPAdmissionAndMaxCompletionTokens() async throws {
        let recorder = NativeMTPAdmissionRecorder()
        let runtime = ModelRuntime(
            modelID: "target",
            modelHash: Self.modelHash,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumProposalDepth: 3),
            nativeMTPSchedulerSupported: true,
            testNativeMTPAdmissionObserver: { admission in
                recorder.append(admission)
            },
            warmSwapEnabled: true,
            loader: { _ in throw CancellationError() },
            testCompletion: { _, request in
                XCTAssertEqual(request.maxTokens, 5)
                return Self.completion(content: "stream")
            }
        )
        let request = try makeRequest(extra: ["stream": true, "max_completion_tokens": 5])
        let handle = try await runtime.acquireRequestHandle(request)
        defer { Task { await runtime.unregisterInFlight(handle.registrationID) } }

        let completion = try await runtime.stream(request, with: handle, onChunk: { _ in })

        XCTAssertEqual(completion.content, "stream")
        let admission = try XCTUnwrap(recorder.last())
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

    func testRuntimeAdmissionCountsOtherInFlightRowsAgainstSignedBound() async throws {
        let recorder = NativeMTPAdmissionRecorder()
        let runtime = ModelRuntime(
            modelID: "target",
            modelHash: Self.modelHash,
            nativeMTPMode: .auto,
            nativeMTPCapability: admittedCapability(maximumProposalDepth: 2, maximumNativeActiveRows: 1),
            nativeMTPSchedulerSupported: true,
            testNativeMTPAdmissionObserver: { admission in
                recorder.append(admission)
            },
            warmSwapEnabled: true,
            loader: { _ in throw CancellationError() },
            testCompletion: { _, _ in Self.completion() }
        )

        _ = try await runtime.completeWithServedSnapshot(try makeRequest())
        XCTAssertEqual(recorder.last()?.effectivePath, .nativeMTP)

        // A second in-flight row (native or ordinary) fills the bound of one.
        let holder = try await runtime.acquireRequestHandle(try makeRequest())
        _ = try await runtime.completeWithServedSnapshot(try makeRequest())
        let downgraded = try XCTUnwrap(recorder.last())
        XCTAssertEqual(downgraded.effectivePath, .ordinary)
        XCTAssertEqual(downgraded.selection.nativeMTPReason, .capacityAboveNativeBound)
        let gatedStatus = await runtime.currentSnapshot().nativeMTPStatus
        XCTAssertEqual(gatedStatus.lastReason, .capacityAboveNativeBound)
        XCTAssertEqual(gatedStatus.preoutputFallbacks, 0)

        await runtime.unregisterInFlight(holder.registrationID)
        _ = try await runtime.completeWithServedSnapshot(try makeRequest())
        XCTAssertEqual(recorder.last()?.effectivePath, .nativeMTP)
    }

    private func admittedCapability(
        supportsStreaming: Bool = true,
        supportsNonStreaming: Bool = true,
        supportsStopSequences: Bool = false,
        maximumProposalDepth: Int = 2,
        maximumPromptTokens: Int = 32768,
        maximumCompletionTokens: Int = 4096,
        maximumNativeActiveRows: Int = Int.max,
        supportsSampling: Bool = false
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

    private static let modelHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private static func completion(content: String = "ok") -> CompletionResult {
        CompletionResult(
            content: content,
            finishReason: "stop",
            promptTokens: 1,
            completionTokens: 1,
            settlementDisposition: .eligibleOwner
        )
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

private final class NativeMTPAdmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var admissions: [NativeMTPRuntimeAdmission] = []

    func append(_ admission: NativeMTPRuntimeAdmission) {
        lock.lock()
        admissions.append(admission)
        lock.unlock()
    }

    func last() -> NativeMTPRuntimeAdmission? {
        lock.lock()
        defer { lock.unlock() }
        return admissions.last
    }
}
