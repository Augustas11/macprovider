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
            ("unsupported_max_completion_tokens", try makeRequest(extra: ["max_completion_tokens": 64]), .unknownRequestField),
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
                maximumProposalDepth: 2
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
                maximumProposalDepth: 2
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
                maximumProposalDepth: 2
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
                maximumProposalDepth: 2
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
                maximumProposalDepth: 2
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
                maximumProposalDepth: 2
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
                maximumProposalDepth: 0
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

    private func admittedCapability(
        supportsStreaming: Bool = true,
        supportsNonStreaming: Bool = true,
        supportsStopSequences: Bool = false
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
            maximumProposalDepth: 2
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
