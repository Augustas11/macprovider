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
