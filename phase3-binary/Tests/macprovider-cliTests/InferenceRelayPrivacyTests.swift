import CryptoKit
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class InferenceRelayPrivacyTests: XCTestCase {
    private let model = "mlx-community/relay-blind-test"
    private let session = "assigned-test-session"
    private let promptCanary = "PRIVACY-CANARY-7f3a"
    private let completionCanary = "PRIVACY-COMPLETION-9b2c"

    override func setUp() {
        super.setUp()
        PrivacyRuntimeHardening.resetDecryptRecheckForTest()
    }

    override func tearDown() {
        PrivacyRuntimeHardening.resetDecryptRecheckForTest()
        super.tearDown()
    }

    func testPrivacyStreamFramesDecryptWithGoldenBuyerKeyAndEndWithFinalThenClearUsage() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let message = try harness.message(
            requestID: "privacy-stream",
            stream: true,
            privacy: true,
            prompt: promptCanary,
            buyerPrivateKey: try goldenBuyerPrivateKey()
        )
        let relay = harness.relay(privacyMode: true, probe: ScriptedDecryptProbe(traced: false))
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.first?["type"] as? String, "inference_response_validation")
        XCTAssertEqual(frames.last?["status"] as? String, "complete")
        let sawTrace = await harness.runtime.sawPerfTrace()
        XCTAssertFalse(sawTrace)

        let opened = try openPrivacyStream(frames)
        XCTAssertGreaterThanOrEqual(opened.privacy.count, 2)
        for (index, frame) in opened.privacy.enumerated() {
            XCTAssertEqual(jsonInt(frame["seq"]), index)
            XCTAssertEqual(jsonBool(frame["final"]), index == opened.privacy.count - 1)
            XCTAssertEqual(frame["object"] as? String, PrivacyClassConstants.frameObject)
            XCTAssertEqual(frame["version"] as? String, PrivacyClassConstants.responseVersion)
        }
        let material = try responseMaterial(message: message, buyerPrivateKey: try goldenBuyerPrivateKey(), providerPublic: harness.providerPublic)
        var sawCompletion = false
        for (index, frame) in opened.privacy.dropLast().enumerated() {
            let plain = try decryptFrame(frame, material: material, message: message, stream: true, seq: UInt64(index), final: false)
            let text = String(decoding: plain, as: UTF8.self)
            if text.contains(completionCanary) { sawCompletion = true }
            XCTAssertFalse(text.contains(promptCanary))
        }
        XCTAssertTrue(sawCompletion)
        let finalPlain = try decryptFrame(
            opened.privacy[opened.privacy.count - 1],
            material: material,
            message: message,
            stream: true,
            seq: UInt64(opened.privacy.count - 1),
            final: true
        )
        let final = try jsonObject(finalPlain)
        XCTAssertEqual(final["version"] as? String, PrivacyClassConstants.finalVersion)
        XCTAssertEqual(final["status"] as? String, PrivacyClassConstants.finalStatusComplete)
        XCTAssertEqual(jsonInt(final["prompt_tokens"]), 4)
        XCTAssertEqual(jsonInt(final["completion_tokens"]), 2)

        XCTAssertEqual(opened.tail.count, 2)
        let usage = try sseObject(opened.tail[0])
        XCTAssertEqual(usage["object"] as? String, "chat.completion.chunk")
        XCTAssertEqual(usage["model"] as? String, model)
        XCTAssertEqual((usage["choices"] as? [Any])?.isEmpty, true)
        let usageObject = try XCTUnwrap(usage["usage"] as? [String: Any])
        XCTAssertEqual(jsonInt(usageObject["prompt_tokens"]), 4)
        XCTAssertEqual(jsonInt(usageObject["completion_tokens"]), 2)
        XCTAssertEqual(jsonInt(usageObject["total_tokens"]), 6)
        XCTAssertEqual(Set(usageObject.keys), ["prompt_tokens", "completion_tokens", "total_tokens"])
        XCTAssertEqual(opened.tail[1], "data: [DONE]\n\n")
        let chunks = frames.filter { $0["type"] as? String == "inference_response_chunk" }
        XCTAssertEqual(jsonInt(frames.last?["chunks_sent"]), chunks.count)
        try assertNoCanary(frames)
    }

    func testPrivacyNonStreamResponseShape() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let message = try harness.message(
            requestID: "privacy-json",
            stream: false,
            privacy: true,
            prompt: promptCanary,
            buyerPrivateKey: try goldenBuyerPrivateKey()
        )
        let relay = harness.relay(privacyMode: true, probe: ScriptedDecryptProbe(traced: false))
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        let frames = await harness.frames.values
        let chunks = frames.filter { $0["type"] as? String == "inference_response_chunk" }
        XCTAssertEqual(chunks.count, 1)
        let data = try XCTUnwrap(chunks[0]["data"] as? String)
        XCTAssertFalse(data.hasPrefix("data:"))
        let response = try jsonObject(Data(data.utf8))
        XCTAssertEqual(response["object"] as? String, PrivacyClassConstants.responseObject)
        XCTAssertEqual(response["version"] as? String, PrivacyClassConstants.responseVersion)
        let privacyFrames = try XCTUnwrap(response["frames"] as? [[String: Any]])
        XCTAssertEqual(privacyFrames.count, 2)
        XCTAssertEqual(jsonInt(privacyFrames[0]["seq"]), 0)
        XCTAssertEqual(jsonBool(privacyFrames[0]["final"]), false)
        XCTAssertEqual(jsonInt(privacyFrames[1]["seq"]), 1)
        XCTAssertEqual(jsonBool(privacyFrames[1]["final"]), true)
        let usage = try XCTUnwrap(response["usage"] as? [String: Any])
        XCTAssertEqual(jsonInt(usage["prompt_tokens"]), 4)
        XCTAssertEqual(jsonInt(usage["completion_tokens"]), 2)
        XCTAssertEqual(jsonInt(usage["total_tokens"]), 6)
        let material = try responseMaterial(message: message, buyerPrivateKey: try goldenBuyerPrivateKey(), providerPublic: harness.providerPublic)
        let body = try decryptFrame(privacyFrames[0], material: material, message: message, stream: false, seq: 0, final: false)
        let completion = try jsonObject(body)
        let choice = try XCTUnwrap((completion["choices"] as? [[String: Any]])?.first)
        let reply = try XCTUnwrap((choice["message"] as? [String: Any])?["content"] as? String)
        XCTAssertEqual(reply, completionCanary)
        let final = try jsonObject(try decryptFrame(privacyFrames[1], material: material, message: message, stream: false, seq: 1, final: true))
        XCTAssertEqual(final["status"] as? String, PrivacyClassConstants.finalStatusComplete)
        XCTAssertEqual(frames.last?["status"] as? String, "complete")
        try assertNoCanary(frames)
    }

    func testMarkerMissingInPrivacyModeRejected() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let relay = harness.relay(privacyMode: true, probe: ScriptedDecryptProbe(traced: false))
        let missing = try harness.message(requestID: "privacy-missing", stream: false, privacy: false, prompt: promptCanary)
        try await relay.handleInferenceRequest(missing)
        await assertIdle(relay)
        let rejected = await harness.frames.values
        try assertBoundRejection(rejected, code: PrivacyClassConstants.downgradeRejected)
        await assertCompletionCount(harness.runtime, 0)
        try assertNoJournalClaims(harness.journalDirectory)

        await harness.frames.removeAll()
        let wrong = try harness.message(
            requestID: "privacy-wrong", stream: false, privacy: true, prompt: promptCanary, marker: "not-the-class"
        )
        try await relay.handleInferenceRequest(wrong)
        await assertIdle(relay)
        try assertBoundRejection(await harness.frames.values, code: PrivacyClassConstants.downgradeRejected)
        await assertCompletionCount(harness.runtime, 0)
        try assertNoJournalClaims(harness.journalDirectory)
    }

    func testMarkerPresentOutsidePrivacyModeRejected() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let relay = harness.relay(privacyMode: false, probe: nil)
        let message = try harness.message(requestID: "privacy-off", stream: false, privacy: true, prompt: promptCanary)
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        try assertBoundRejection(await harness.frames.values, code: PrivacyClassConstants.downgradeRejected)
        await assertCompletionCount(harness.runtime, 0)
        try assertNoJournalClaims(harness.journalDirectory)
    }

    func testTracedRecheckRejectsBeforeDecrypt() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let probe = ScriptedDecryptProbe(traced: true)
        let relay = harness.relay(privacyMode: true, probe: probe)
        let first = try harness.message(requestID: "privacy-traced", stream: false, privacy: true, prompt: promptCanary)
        try await relay.handleInferenceRequest(first)
        await assertIdle(relay)
        try assertBoundRejection(await harness.frames.values, code: PrivacyClassConstants.postureStale)
        XCTAssertTrue(PrivacyRuntimeHardening.decryptRecheckFailed)
        await assertCompletionCount(harness.runtime, 0)
        try assertNoJournalClaims(harness.journalDirectory)

        probe.traced = false
        await harness.frames.removeAll()
        let second = try harness.message(requestID: "privacy-latched", stream: false, privacy: true, prompt: promptCanary)
        try await relay.handleInferenceRequest(second)
        await assertIdle(relay)
        try assertBoundRejection(await harness.frames.values, code: PrivacyClassConstants.postureStale)
        await assertCompletionCount(harness.runtime, 0)
        try assertNoJournalClaims(harness.journalDirectory)
    }

    func testCancelEmitsAuthenticatedCancelledFinal() async throws {
        let harness = try await Harness(
            model: model, session: session, content: completionCanary, inputTokens: 4, cancelAfterChunk: true
        )
        let message = try harness.message(
            requestID: "privacy-cancel",
            stream: true,
            privacy: true,
            prompt: promptCanary,
            buyerPrivateKey: try goldenBuyerPrivateKey()
        )
        let relay = harness.relay(privacyMode: true, probe: ScriptedDecryptProbe(traced: false))
        try await relay.handleInferenceRequest(message)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await relay.handleCancelRequest(["type": "cancel_request", "request_id": "privacy-cancel"])
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.last?["status"] as? String, "cancelled")
        let opened = try openPrivacyStream(frames)
        let final = opened.privacy.last
        XCTAssertEqual(jsonBool(final?["final"]), true)
        let material = try responseMaterial(message: message, buyerPrivateKey: try goldenBuyerPrivateKey(), providerPublic: harness.providerPublic)
        let plain = try decryptFrame(
            try XCTUnwrap(final),
            material: material,
            message: message,
            stream: true,
            seq: UInt64(try XCTUnwrap(jsonInt(final?["seq"]))),
            final: true
        )
        let object = try jsonObject(plain)
        XCTAssertEqual(object["status"] as? String, PrivacyClassConstants.finalStatusCancelled)
        XCTAssertEqual(opened.tail.last, "data: [DONE]\n\n")
        try assertNoCanary(frames)
    }

    func testNoReceiptNoTelemetryNoConversationCache() async throws {
        let store = CountingReceiptKeyStore()
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        var message = try harness.message(requestID: "privacy-sinks", stream: false, privacy: true, prompt: promptCanary)
        message["conversation_key"] = "conv:kvs-synth:privacy-must-not-lease"
        let relay = harness.relay(
            privacyMode: true,
            probe: ScriptedDecryptProbe(traced: false),
            receiptBuilder: ReceiptBuilder(keyStore: store)
        )
        let telemetry = KVCacheTelemetryBox()
        try await KVCacheTelemetry.withSink({ telemetry.append($0) }) {
            try await relay.handleInferenceRequest(message)
            await assertIdle(relay)
        }
        let prepared = await harness.runtime.lastPrepared()
        XCTAssertEqual(prepared?.conversationKey, nil)
        XCTAssertEqual(prepared?.ingestProvenance, .privacy)
        XCTAssertEqual(store.loads, 0)
        let frames = await harness.frames.values
        XCTAssertFalse(frames.contains { $0["receipt"] != nil })
        XCTAssertTrue(telemetry.values.isEmpty)
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: "conv:kvs-synth:privacy", provenance: .privacy))
        XCTAssertTrue(KVDiskCacheGate.persists(conversationKey: "conv:kvs-synth:direct", provenance: .directHTTP))
        XCTAssertFalse(ModelRuntime.allowsConversationCacheLease(provenance: .privacy, nativeAllows: true))
        XCTAssertTrue(ModelRuntime.allowsConversationCacheLease(provenance: .relay, nativeAllows: true))
        XCTAssertFalse(ModelRuntime.allowsConversationCacheLease(provenance: .privacy, nativeAllows: false))
        try assertNoCanary(frames)
    }

    func testCapturedFramesContainNoCanary() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let message = try harness.message(
            requestID: "privacy-canary", stream: true, privacy: true, prompt: promptCanary
        )
        let relay = harness.relay(privacyMode: true, probe: ScriptedDecryptProbe(traced: false))
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertFalse(frames.isEmpty)
        try assertNoCanary(frames)
        let opened = try openPrivacyStream(frames)
        let joined = opened.privacy.compactMap { $0["ciphertext"] as? String }.joined()
        XCTAssertFalse(joined.contains(promptCanary))
        XCTAssertFalse(joined.contains(completionCanary))
    }

    func testPrivacyModeStillServesCleartextWithoutMarker() async throws {
        let harness = try await Harness(model: model, session: session, content: "ordinary answer", inputTokens: 4)
        let relay = harness.relay(privacyMode: true, probe: ScriptedDecryptProbe(traced: false))
        let body = """
        {"model":"\(model)","messages":[{"role":"user","content":"hello"}],"max_tokens":4}
        """
        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "clear-ok",
            "stream": false,
            "body": body,
        ])
        await assertIdle(relay)
        let frames = await harness.frames.values
        let data = try XCTUnwrap(frames.first { $0["type"] as? String == "inference_response_chunk" }?["data"] as? String)
        XCTAssertTrue(data.contains("ordinary answer"))
        XCTAssertFalse(data.contains(PrivacyClassConstants.frameObject))
        XCTAssertEqual(frames.last?["status"] as? String, "complete")
        await assertCompletionCount(harness.runtime, 1)

        await harness.frames.removeAll()
        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "clear-marked",
            "stream": false,
            "body": body,
            "privacy_class": PrivacyClassConstants.v1,
        ])
        await assertIdle(relay)
        let rejected = await harness.frames.values
        XCTAssertEqual(rejected.last?["status"] as? String, PrivacyClassConstants.downgradeRejected)
        XCTAssertEqual(rejected.last?["error"] as? String, PrivacyClassConstants.downgradeRejected)
        XCTAssertFalse(rejected.contains { $0["type"] as? String == "inference_response_chunk" })
        await assertCompletionCount(harness.runtime, 1)
    }

    func testTier2InnerPrivacyMarkerSealsResponse() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let tier2 = try Tier2ProviderSession(
            providerID: "provider-1",
            assignedID: session,
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "tier2-key",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([1, 2, 3, 4]),
            p2cNonceBase: Data([5, 6, 7, 8])
        )
        tier2.enableResponseChunkPlaintextEnvelope()
        let clear = try harness.message(
            requestID: "tier2-privacy",
            stream: false,
            privacy: true,
            prompt: promptCanary,
            buyerPrivateKey: try goldenBuyerPrivateKey()
        )
        let wrapped = try Tier2ProviderSession.sealRequestForTest(
            session: tier2,
            requestID: "tier2-privacy",
            stream: false,
            plaintext: try XCTUnwrap(clear["body"] as? String),
            bodyEncoding: RelayBlindEnvelope.version,
            relayBlindContext: try XCTUnwrap(clear["relay_blind_context"] as? [String: Any]),
            privacyClass: PrivacyClassConstants.v1
        )
        XCTAssertNil(wrapped["privacy_class"])
        let relay = harness.relay(privacyMode: true, probe: ScriptedDecryptProbe(traced: false), tier2: tier2)
        try await relay.handleInferenceRequest(wrapped)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.map { $0["type"] as? String }, [
            "inference_response_validation", "inference_response_chunk", "inference_response_end",
        ])
        let validation = try Tier2ProviderSession.openResponseValidationForTest(
            session: tier2, frame: frames[0], requestID: "tier2-privacy", stream: false, seq: 0
        )
        XCTAssertEqual((validation["relay_blind_validation"] as? [String: Any])?["state"] as? String, "validated")
        let chunk = try Tier2ProviderSession.openResponseChunkForTest(
            session: tier2, frame: frames[1], requestID: "tier2-privacy", stream: false, seq: 1
        )
        XCTAssertFalse(chunk.contains(completionCanary))
        XCTAssertTrue(chunk.contains(PrivacyClassConstants.responseObject))
        let end = try Tier2ProviderSession.openResponseEndForTest(
            session: tier2, frame: frames[2], requestID: "tier2-privacy", stream: false, seq: 2
        )
        XCTAssertEqual(end["status"] as? String, "complete")
        try assertNoCanary(frames)

        await harness.frames.removeAll()
        let disagreeClear = try harness.message(
            requestID: "tier2-disagree", stream: false, privacy: true, prompt: promptCanary
        )
        var disagree = try Tier2ProviderSession.sealRequestForTest(
            session: tier2,
            requestID: "tier2-disagree",
            stream: false,
            plaintext: try XCTUnwrap(disagreeClear["body"] as? String),
            bodyEncoding: RelayBlindEnvelope.version,
            relayBlindContext: try XCTUnwrap(disagreeClear["relay_blind_context"] as? [String: Any]),
            privacyClass: PrivacyClassConstants.v1,
            seq: 1
        )
        disagree["privacy_class"] = "other"
        try await relay.handleInferenceRequest(disagree)
        await assertIdle(relay)
        let rejectedFrames = await harness.frames.values
        let rejectedFrame = try XCTUnwrap(rejectedFrames.first)
        let rejected = try Tier2ProviderSession.openResponseValidationForTest(
            session: tier2, frame: rejectedFrame,
            requestID: "tier2-disagree", stream: false, seq: 3
        )
        XCTAssertEqual(
            (rejected["relay_blind_validation"] as? [String: Any])?["error_code"] as? String,
            PrivacyClassConstants.downgradeRejected
        )
        await assertCompletionCount(harness.runtime, 1)
    }

    // MARK: - SPEC-001-R005 / SPEC-015 §N.13 relay-blind settlement receipt

    private let receiptProvider = "provider-1"
    private let pinnedModelHash = String(repeating: "5e", count: 32)

    func testRelayBlindSettlementReceiptSignsCiphertextOnPrivacyStream() async throws {
        let harness = try await Harness(
            model: model, session: session, content: completionCanary, inputTokens: 4, modelHash: pinnedModelHash
        )
        let (builder, key) = try receiptBuilder()
        var message = try harness.message(
            requestID: "privacy-settle-stream", stream: true, privacy: true, prompt: promptCanary,
            buyerPrivateKey: try goldenBuyerPrivateKey()
        )
        message[RelayBlindSettlementMetadata.wireKey] = try settlementWire(for: message, key: key)
        let relay = harness.relay(
            privacyMode: true, probe: ScriptedDecryptProbe(traced: false),
            receiptBuilder: builder, receiptProviderID: receiptProvider
        )
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        let frames = await harness.frames.values
        let end = try XCTUnwrap(frames.last)
        XCTAssertEqual(end["status"] as? String, "complete")
        let tuple = try assertSettlementReceipt(frames, key: key, privacyClass: PrivacyClassConstants.v1, terminalState: "normal_done")
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual(jsonInt(usage["input_tokens"]), 4)
        XCTAssertEqual(jsonInt(usage["output_tokens"]), 2)
        XCTAssertEqual(jsonInt(tuple["input_token_upper_bound"]), 8)
        XCTAssertEqual(jsonInt(tuple["max_output_tokens"]), 4)
        // The digest covers the ciphertext frames exactly as emitted.
        let opened = try openPrivacyStream(frames)
        XCTAssertGreaterThanOrEqual(opened.privacy.count, 2)
        try assertNoCanary(frames)
    }

    func testRelayBlindSettlementReceiptCoversClearBytesOnPlainNonStream() async throws {
        let harness = try await Harness(
            model: model, session: session, content: "plain relay-blind answer", inputTokens: 4, modelHash: pinnedModelHash
        )
        let (builder, key) = try receiptBuilder()
        var message = try harness.message(requestID: "plain-settle", stream: false, privacy: false, prompt: promptCanary)
        // The settlement request id is the ledger id, not the envelope request id.
        message[RelayBlindSettlementMetadata.wireKey] = try settlementWire(
            for: message, key: key, overrides: ["request_id": "ledger-row-77"]
        )
        let relay = harness.relay(privacyMode: false, probe: nil, receiptBuilder: builder, receiptProviderID: receiptProvider)
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.last?["status"] as? String, "complete")
        let tuple = try assertSettlementReceipt(frames, key: key, privacyClass: "none", terminalState: "normal_done")
        XCTAssertEqual(tuple["request_id"] as? String, "ledger-row-77")
        let chunks = frames.compactMap { $0["data"] as? String }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("plain relay-blind answer"))
    }

    func testRelayBlindSettlementReceiptOnCancelledPrivacyStream() async throws {
        let harness = try await Harness(
            model: model, session: session, content: completionCanary, inputTokens: 4,
            cancelAfterChunk: true, modelHash: pinnedModelHash
        )
        let (builder, key) = try receiptBuilder()
        var message = try harness.message(
            requestID: "privacy-settle-cancel", stream: true, privacy: true, prompt: promptCanary,
            buyerPrivateKey: try goldenBuyerPrivateKey()
        )
        message[RelayBlindSettlementMetadata.wireKey] = try settlementWire(for: message, key: key)
        let relay = harness.relay(
            privacyMode: true, probe: ScriptedDecryptProbe(traced: false),
            receiptBuilder: builder, receiptProviderID: receiptProvider
        )
        try await relay.handleInferenceRequest(message)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await relay.handleCancelRequest(["type": "cancel_request", "request_id": "privacy-settle-cancel"])
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.last?["status"] as? String, "cancelled")
        try assertSettlementReceipt(frames, key: key, privacyClass: PrivacyClassConstants.v1, terminalState: "buyer_cancel")
        try assertNoCanary(frames)
    }

    func testRelayBlindSettlementMetadataRejectedBeforeDecryptAndClaim() async throws {
        let harness = try await Harness(
            model: model, session: session, content: completionCanary, inputTokens: 4, modelHash: pinnedModelHash
        )
        let (builder, key) = try receiptBuilder()
        let relay = harness.relay(
            privacyMode: true, probe: ScriptedDecryptProbe(traced: false),
            receiptBuilder: builder, receiptProviderID: receiptProvider
        )
        let otherKey = Curve25519.Signing.PrivateKey()
        let cases: [(String, ([String: Any]) throws -> Any)] = [
            ("unknown member", { try self.settlementWire(for: $0, key: key, overrides: ["prompt_hash": self.pinnedModelHash]) }),
            ("missing member", { try self.settlementWire(for: $0, key: key, removing: "catalog_id") }),
            ("null member", { try self.settlementWire(for: $0, key: key, overrides: ["model_id": NSNull()]) }),
            ("wrong entrypoint", { try self.settlementWire(for: $0, key: key, overrides: ["paid_entrypoint": "coordinator_buyer_v1_chat_completions"]) }),
            ("wrong envelope digest", { try self.settlementWire(for: $0, key: key, overrides: ["relay_blind_envelope_digest": RelayBlindBase64URL.encode(Data(repeating: 7, count: 32))]) }),
            ("other provider", { try self.settlementWire(for: $0, key: key, overrides: ["provider_id": "provider-2"]) }),
            ("other receipt key", { try self.settlementWire(for: $0, key: otherKey) }),
            ("not an object", { _ in "relay_blind_settlement" }),
            ("null object", { _ in NSNull() }),
        ]
        for (index, entry) in cases.enumerated() {
            await harness.frames.removeAll()
            var message = try harness.message(
                requestID: "privacy-settle-bad-\(index)", stream: false, privacy: true, prompt: promptCanary
            )
            message[RelayBlindSettlementMetadata.wireKey] = try entry.1(message)
            try await relay.handleInferenceRequest(message)
            await assertIdle(relay)
            let frames = await harness.frames.values
            XCTAssertEqual(frames.count, 1, entry.0)
            XCTAssertEqual(frames.last?["status"] as? String, RelayBlindProviderError.invalidEnvelope.code, entry.0)
            XCTAssertNil(frames.last?["relay_blind_settlement_receipt"], entry.0)
            try assertNoJournalClaims(harness.journalDirectory)
        }
        // The v0.4 `settlement` member stays forbidden on relay-blind dispatch.
        await harness.frames.removeAll()
        var withSettlement = try harness.message(requestID: "privacy-settle-v04", stream: false, privacy: true, prompt: promptCanary)
        withSettlement[RelayBlindSettlementMetadata.wireKey] = try settlementWire(for: withSettlement, key: key)
        withSettlement["settlement"] = ["request_id": "privacy-settle-v04"]
        try await relay.handleInferenceRequest(withSettlement)
        await assertIdle(relay)
        let v04Frames = await harness.frames.values
        XCTAssertEqual(v04Frames.last?["status"] as? String, RelayBlindProviderError.invalidEnvelope.code)
        try assertNoJournalClaims(harness.journalDirectory)
        await assertCompletionCount(harness.runtime, 0)
    }

    func testRelayBlindSettlementForbiddenOnPlaintextDispatch() async throws {
        let harness = try await Harness(model: model, session: session, content: "plain", inputTokens: 4, modelHash: pinnedModelHash)
        let (builder, key) = try receiptBuilder()
        let relay = harness.relay(privacyMode: false, probe: nil, receiptBuilder: builder, receiptProviderID: receiptProvider)
        let relayBlind = try harness.message(requestID: "plain-carrier", stream: false, privacy: false, prompt: "hello")
        let plaintext: [String: Any] = [
            "type": "inference_request",
            "request_id": "plaintext-with-relay-blind-settlement",
            "stream": false,
            "body": #"{"model":"\#(model)","messages":[{"role":"user","content":"hello"}]}"#,
            RelayBlindSettlementMetadata.wireKey: try settlementWire(for: relayBlind, key: key),
        ]
        try await relay.handleInferenceRequest(plaintext)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.last?["status"] as? String, RelayBlindProviderError.invalidEnvelope.code)
        await assertCompletionCount(harness.runtime, 0)
    }

    func testRelayBlindWithoutSettlementMetadataEmitsNoReceipt() async throws {
        let store = CountingReceiptKeyStore()
        let harness = try await Harness(
            model: model, session: session, content: completionCanary, inputTokens: 4, modelHash: pinnedModelHash
        )
        let message = try harness.message(requestID: "privacy-observe", stream: true, privacy: true, prompt: promptCanary)
        let relay = harness.relay(
            privacyMode: true, probe: ScriptedDecryptProbe(traced: false),
            receiptBuilder: ReceiptBuilder(keyStore: store), receiptProviderID: receiptProvider
        )
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.last?["status"] as? String, "complete")
        XCTAssertFalse(frames.contains { $0["relay_blind_settlement_receipt"] != nil || $0["receipt"] != nil })
        XCTAssertEqual(store.loads, 0)
    }

    func testRelayBlindSettlementReceiptWithheldWithoutPinnedModelHash() async throws {
        let harness = try await Harness(model: model, session: session, content: completionCanary, inputTokens: 4)
        let (builder, key) = try receiptBuilder()
        var message = try harness.message(requestID: "privacy-no-hash", stream: false, privacy: true, prompt: promptCanary)
        message[RelayBlindSettlementMetadata.wireKey] = try settlementWire(for: message, key: key)
        let relay = harness.relay(
            privacyMode: true, probe: ScriptedDecryptProbe(traced: false),
            receiptBuilder: builder, receiptProviderID: receiptProvider
        )
        try await relay.handleInferenceRequest(message)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.last?["status"] as? String, "complete")
        XCTAssertFalse(frames.contains { $0["relay_blind_settlement_receipt"] != nil || $0["receipt"] != nil })
    }

    func testTier2RelayBlindSettlementTravelsInsideProtectedPayload() async throws {
        let harness = try await Harness(
            model: model, session: session, content: completionCanary, inputTokens: 4, modelHash: pinnedModelHash
        )
        let (builder, key) = try receiptBuilder()
        let tier2 = try Tier2ProviderSession(
            providerID: receiptProvider,
            assignedID: session,
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "tier2-key",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([1, 2, 3, 4]),
            p2cNonceBase: Data([5, 6, 7, 8])
        )
        tier2.enableResponseChunkPlaintextEnvelope()
        let clear = try harness.message(requestID: "tier2-settle", stream: false, privacy: true, prompt: promptCanary)
        let metadata = try settlementWire(for: clear, key: key)
        let wrapped = try Tier2ProviderSession.sealRequestForTest(
            session: tier2,
            requestID: "tier2-settle",
            stream: false,
            plaintext: try XCTUnwrap(clear["body"] as? String),
            bodyEncoding: RelayBlindEnvelope.version,
            relayBlindContext: try XCTUnwrap(clear["relay_blind_context"] as? [String: Any]),
            privacyClass: PrivacyClassConstants.v1,
            relayBlindSettlement: metadata
        )
        XCTAssertNil(wrapped[RelayBlindSettlementMetadata.wireKey])
        let relay = harness.relay(
            privacyMode: true, probe: ScriptedDecryptProbe(traced: false),
            receiptBuilder: builder, receiptProviderID: receiptProvider, tier2: tier2
        )
        try await relay.handleInferenceRequest(wrapped)
        await assertIdle(relay)
        let frames = await harness.frames.values
        XCTAssertEqual(frames.count, 3)
        XCTAssertFalse(frames.contains { $0["relay_blind_settlement_receipt"] != nil })
        let chunk = try Tier2ProviderSession.openResponseChunkForTest(
            session: tier2, frame: frames[1], requestID: "tier2-settle", stream: false, seq: 1
        )
        let end = try Tier2ProviderSession.openResponseEndForTest(
            session: tier2, frame: frames[2], requestID: "tier2-settle", stream: false, seq: 2
        )
        XCTAssertEqual(end["status"] as? String, "complete")
        XCTAssertNil(end["receipt"])
        let envelope = try XCTUnwrap(end["relay_blind_settlement_receipt"] as? String)
        let tuple = try RelayBlindSettlementReceiptTests.verify(envelope, publicKey: key.publicKey)
        XCTAssertEqual(tuple["response_body_sha256"] as? String, hex(SHA256.hash(data: Data(chunk.utf8))))
        XCTAssertEqual(jsonInt(tuple["response_body_bytes"]), chunk.utf8.count)

        // An unauthenticated outer copy is misplaced and rejected.
        await harness.frames.removeAll()
        let outerClear = try harness.message(requestID: "tier2-settle-outer", stream: false, privacy: true, prompt: promptCanary)
        var outer = try Tier2ProviderSession.sealRequestForTest(
            session: tier2,
            requestID: "tier2-settle-outer",
            stream: false,
            plaintext: try XCTUnwrap(outerClear["body"] as? String),
            bodyEncoding: RelayBlindEnvelope.version,
            relayBlindContext: try XCTUnwrap(outerClear["relay_blind_context"] as? [String: Any]),
            privacyClass: PrivacyClassConstants.v1,
            seq: 1
        )
        outer[RelayBlindSettlementMetadata.wireKey] = try settlementWire(for: outerClear, key: key)
        try await relay.handleInferenceRequest(outer)
        await assertIdle(relay)
        let outerFrames = await harness.frames.values
        let rejected = try XCTUnwrap(outerFrames.last)
        let rejectedEnd = try Tier2ProviderSession.openResponseEndForTest(
            session: tier2, frame: rejected, requestID: "tier2-settle-outer", stream: false, seq: 3
        )
        XCTAssertEqual(rejectedEnd["status"] as? String, RelayBlindProviderError.invalidEnvelope.code)
        await assertCompletionCount(harness.runtime, 1)
    }

    private func receiptBuilder() throws -> (ReceiptBuilder, Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        let store = InMemoryReceiptKeyStore()
        try store.storeNew(providerId: receiptProvider, privateKey: key)
        return (ReceiptBuilder(keyStore: store), key)
    }

    private func settlementWire(
        for message: [String: Any],
        key: Curve25519.Signing.PrivateKey,
        overrides: [String: Any] = [:],
        removing: String? = nil
    ) throws -> [String: Any] {
        let context = try XCTUnwrap(message["relay_blind_context"] as? [String: Any])
        var wire: [String: Any] = [
            "account_scope": "acct-scope-test",
            "request_id": "ledger-row-1",
            "attempt_n": 0,
            "provider_id": receiptProvider,
            "provider_receipt_key_id": "ed25519-sha256:" + hex(SHA256.hash(data: key.publicKey.rawRepresentation)),
            "model_id": model,
            "expected_catalog_model_hash": pinnedModelHash,
            "catalog_id": "catalog-test",
            "catalog_body_digest": String(repeating: "c", count: 64),
            "route_snapshot_digest": String(repeating: "d", count: 64),
            "route_snapshot_policy_version": "spec022-policy-test",
            "route_snapshot_mode": "enforce",
            "pending_deadline_seconds": 300,
            "paid_entrypoint": RelayBlindSettlementMetadata.paidEntrypoint,
            "prompt_hash_basis": RelayBlindSettlementMetadata.promptHashBasis,
            "relay_blind_envelope_digest": try XCTUnwrap(context["envelope_digest"] as? String),
        ]
        for (field, value) in overrides { wire[field] = value }
        if let removing { wire.removeValue(forKey: removing) }
        return wire
    }

    /// Exactly one receipt, on the terminal frame only, with no v0.4 `receipt`;
    /// its digest is the SHA-256 of the emitted chunk `data` bytes; it holds no
    /// canary and no SHA-256 of plaintext.
    @discardableResult
    private func assertSettlementReceipt(
        _ frames: [[String: Any]],
        key: Curve25519.Signing.PrivateKey,
        privacyClass: String,
        terminalState: String
    ) throws -> [String: Any] {
        let end = try XCTUnwrap(frames.last)
        XCTAssertEqual(end["type"] as? String, "inference_response_end")
        XCTAssertNil(end["receipt"])
        XCTAssertEqual(frames.filter { $0["relay_blind_settlement_receipt"] != nil }.count, 1)
        XCTAssertFalse(frames.contains { $0["receipt"] != nil })
        let envelope = try XCTUnwrap(end["relay_blind_settlement_receipt"] as? String)
        let tuple = try RelayBlindSettlementReceiptTests.verify(envelope, publicKey: key.publicKey)
        let emitted = Data(frames.compactMap { frame -> String? in
            frame["type"] as? String == "inference_response_chunk" ? frame["data"] as? String : nil
        }.joined().utf8)
        XCTAssertEqual(tuple["response_body_sha256"] as? String, hex(SHA256.hash(data: emitted)))
        XCTAssertEqual(jsonInt(tuple["response_body_bytes"]), emitted.count)
        XCTAssertEqual(tuple["privacy_class"] as? String, privacyClass)
        XCTAssertEqual(tuple["terminal_state"] as? String, terminalState)
        XCTAssertEqual(tuple["model_hash"] as? String, pinnedModelHash)
        XCTAssertEqual(jsonInt(tuple["terminal_state_ts_unix_ms"]), jsonInt(end["terminal_state_ts_unix_ms"]))
        let context = (frames.first?["relay_blind_validation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(tuple["relay_blind_envelope_digest"] as? String, context["envelope_digest"] as? String)
        XCTAssertEqual(tuple["relay_blind_execution_auth_digest"] as? String, context["execution_auth_digest"] as? String)
        XCTAssertEqual(tuple["relay_blind_provider_binding_digest"] as? String, context["provider_binding_digest"] as? String)
        XCTAssertEqual(tuple["relay_blind_kid"] as? String, context["kid"] as? String)
        let tupleText = String(decoding: try XCTUnwrap(Data(base64Encoded: String(envelope.split(separator: ".")[0]))), as: UTF8.self)
        XCTAssertFalse(containsCanary(tupleText))
        for canary in [promptCanary, completionCanary] {
            let digest = SHA256.hash(data: Data(canary.utf8))
            XCTAssertFalse(tupleText.contains(hex(digest)))
            XCTAssertFalse(tupleText.contains(RelayBlindBase64URL.encode(Data(digest))))
        }
        return tuple
    }

    private func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func assertIdle(_ relay: InferenceRelay) async {
        let idle = await relay.waitUntilIdle(timeoutSeconds: 5)
        XCTAssertTrue(idle)
    }

    private func assertCompletionCount(_ runtime: PrivacyTestRuntime, _ expected: Int) async {
        let count = await runtime.completionCount()
        XCTAssertEqual(count, expected)
    }

    private func assertBoundRejection(_ frames: [[String: Any]], code: String) throws {
        XCTAssertEqual(frames.first?["type"] as? String, "inference_response_validation")
        let evidence = try XCTUnwrap(frames.first?["relay_blind_validation"] as? [String: Any])
        XCTAssertEqual(evidence["state"] as? String, "rejected")
        XCTAssertEqual(jsonInt(evidence["input_tokens"]), 0)
        XCTAssertEqual(evidence["error_code"] as? String, code)
        XCTAssertFalse(frames.contains { $0["type"] as? String == "inference_response_chunk" })
        XCTAssertEqual(frames.last?["status"] as? String, code)
        XCTAssertEqual(frames.last?["error"] as? String, code)
        XCTAssertEqual((frames.last?["relay_blind_validation"] as? [String: Any])?["error_code"] as? String, code)
    }

    private func assertNoJournalClaims(_ directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".json") })
    }

    private func assertNoCanary(_ frames: [[String: Any]]) throws {
        for frame in frames {
            XCTAssertFalse(containsCanary(frame))
        }
    }

    private func containsCanary(_ value: Any) -> Bool {
        if let text = value as? String {
            return text.contains(promptCanary) || text.contains(completionCanary)
        }
        if let object = value as? [String: Any] {
            return object.values.contains { containsCanary($0) }
        }
        if let list = value as? [Any] {
            return list.contains { containsCanary($0) }
        }
        return false
    }

    private func openPrivacyStream(_ frames: [[String: Any]]) throws -> (privacy: [[String: Any]], tail: [String]) {
        let chunks = frames.compactMap { frame -> String? in
            guard frame["type"] as? String == "inference_response_chunk" else { return nil }
            return frame["data"] as? String
        }
        var privacy: [[String: Any]] = []
        var tail: [String] = []
        var sawTail = false
        for chunk in chunks {
            if !sawTail, chunk.hasPrefix("data: {"),
               let object = try? sseObject(chunk),
               object["object"] as? String == PrivacyClassConstants.frameObject {
                privacy.append(object)
            } else {
                sawTail = true
                tail.append(chunk)
            }
        }
        return (privacy, tail)
    }

    private func responseMaterial(message: [String: Any], buyerPrivateKey: String, providerPublic: Data) throws -> (SymmetricKey, Data) {
        let body = try XCTUnwrap(message["body"] as? String)
        let envelope = try RelayBlindEnvelope.parse(body, nowUnix: Int64(Date().timeIntervalSince1970))
        let buyer = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try RelayBlindBase64URL.decode(buyerPrivateKey, exactCount: 32)
        )
        let provider = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: providerPublic)
        let shared = try buyer.sharedSecretFromKeyAgreement(with: provider)
        let derived = try PrivacyResponseSealer.derive(sharedSecret: shared, aad: envelope.aad)
        return (derived.key, derived.noncePrefix)
    }

    private func decryptFrame(
        _ frame: [String: Any],
        material: (SymmetricKey, Data),
        message: [String: Any],
        stream: Bool,
        seq: UInt64,
        final: Bool
    ) throws -> Data {
        let context = try XCTUnwrap(message["relay_blind_context"] as? [String: Any])
        let ciphertext = try RelayBlindBase64URL.decode(try XCTUnwrap(frame["ciphertext"] as? String))
        XCTAssertGreaterThanOrEqual(ciphertext.count, 16)
        var nonce = Data(material.1)
        nonce.appendUnsigned64(seq)
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.prefix(ciphertext.count - 16),
            tag: ciphertext.suffix(16)
        )
        let aad = PrivacyResponseSealer.frameAAD(
            envelopeDigest: try XCTUnwrap(context["envelope_digest"] as? String),
            kid: try XCTUnwrap(context["kid"] as? String),
            requestID: try XCTUnwrap(message["request_id"] as? String),
            stream: stream,
            seq: seq,
            final: final
        )
        return try AES.GCM.open(box, using: material.0, authenticating: aad)
    }

    private func goldenBuyerPrivateKey() throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = tests.appendingPathComponent("../../../test/fixtures/relay-blind/golden-v1.json").standardizedFileURL
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(golden["buyer_x25519_private_key"] as? String)
    }

    private func sseObject(_ data: String) throws -> [String: Any] {
        XCTAssertTrue(data.hasPrefix("data: "))
        XCTAssertTrue(data.hasSuffix("\n\n"))
        let json = data.dropFirst("data: ".count).dropLast(2)
        return try jsonObject(Data(json.utf8))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.intValue }
        return nil
    }

    private func jsonBool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
        return nil
    }
}

private final class ScriptedDecryptProbe: PrivacyPostureProbe, @unchecked Sendable {
    var traced: Bool
    init(traced: Bool) { self.traced = traced }
    func observe() -> PrivacyPostureObservation {
        PrivacyPostureObservation(
            hardenedRuntime: true,
            libraryValidation: true,
            getTaskAllow: false,
            csDebugged: traced,
            pTraced: traced,
            ptDenyAttachApplied: true,
            coreDumpsDisabled: true,
            sipEnabled: true,
            diagnosticEnvClear: true,
            kvDiskTierDisabled: true,
            runtimeSource: PrivacyClassConstants.runtimeSource,
            codeCDHash: String(repeating: "ab", count: 20),
            teamID: "ABCDE12345",
            signingIdentifier: "live.malibu.provider.cli",
            binaryVersion: CoordinatorClient.binaryVersion,
            failureReasons: []
        )
    }
    func isTracedOrDebugged() -> Bool { traced }
}

private final class CountingReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var loadCount = 0
    var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        noteLoad()
        return Curve25519.Signing.PrivateKey()
    }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        noteLoad()
        return nil
    }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws { noteLoad() }
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws { noteLoad() }
    private func noteLoad() {
        lock.lock()
        loadCount += 1
        lock.unlock()
    }
}

private final class KVCacheTelemetryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append(_ data: Data) {
        lock.lock()
        stored.append(data)
        lock.unlock()
    }
}

private actor PrivacyFrameRecorder {
    private(set) var values: [[String: Any]] = []
    func append(_ frame: [String: Any]) { values.append(frame) }
    func removeAll() { values.removeAll() }
}

private actor PrivacyTestRuntime: ModelRuntimeServing {
    private let inputTokens: Int
    private let model: String
    private let content: String
    private let cancelAfterChunk: Bool
    private let modelHash: String?
    private var completions = 0
    private var prepared: ChatCompletionRequest?
    private var perfTraceInstalled = false

    init(inputTokens: Int, model: String, content: String, cancelAfterChunk: Bool, modelHash: String? = nil) {
        self.inputTokens = inputTokens
        self.model = model
        self.content = content
        self.cancelAfterChunk = cancelAfterChunk
        self.modelHash = modelHash
    }

    func completionCount() -> Int { completions }
    func lastPrepared() -> ChatCompletionRequest? { prepared }
    func sawPerfTrace() -> Bool { perfTraceInstalled }
    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}
    func currentSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: nil)
    }
    func relayBlindPrepare(_ request: ChatCompletionRequest) throws -> RelayBlindPreparedRequest {
        prepared = request
        return RelayBlindPreparedRequest(handle: try acquireRequestHandle(request), inputTokens: inputTokens)
    }
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        completions += 1
        return result()
    }
    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        (try await complete(request, shouldCancel: shouldCancel), handle.snapshot)
    }
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        try ModelRuntime.validateNativeSamplingPenalties(request)
        return RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: modelHash),
            registrationID: 1,
            drainCancelled: DrainCancelToken()
        )
    }
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {}
    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        completions += 1
        perfTraceInstalled = EgressPerfTraceKey.current != nil
        onChunk(.content(content))
        if cancelAfterChunk {
            while !shouldCancel() {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return result()
    }
    func unregisterInFlight(_ id: Int) {}

    private func result() -> CompletionResult {
        CompletionResult(
            content: content,
            finishReason: "stop",
            promptTokens: inputTokens,
            completionTokens: 2,
            settlementDisposition: .eligibleOwner
        )
    }
}

private struct Harness {
    let root: URL
    let journalDirectory: URL
    let runtime: PrivacyTestRuntime
    let frames: PrivacyFrameRecorder
    let providerPublic: Data
    let keys: RelayBlindKeyManager
    let providerRuntime: RelayBlindProviderRuntime
    let model: String
    let session: String

    init(
        model: String,
        session: String,
        content: String,
        inputTokens: Int,
        cancelAfterChunk: Bool = false,
        modelHash: String? = nil
    ) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macprovider-privacy-relay-\(UUID().uuidString)", isDirectory: true)
        let journalDirectory = root.appendingPathComponent("journal", isDirectory: true)
        let keys = try RelayBlindKeyManager(directory: root, models: [model])
        let providerRuntime = RelayBlindProviderRuntime(
            keyManager: keys,
            journal: try RelayBlindExecutionJournal(directory: journalDirectory),
            assignedSession: session
        )
        self.root = root
        self.journalDirectory = journalDirectory
        self.runtime = PrivacyTestRuntime(
            inputTokens: inputTokens, model: model, content: content, cancelAfterChunk: cancelAfterChunk,
            modelHash: modelHash
        )
        self.frames = PrivacyFrameRecorder()
        self.providerPublic = try keys.currentRecord().publicKey
        self.keys = keys
        self.providerRuntime = providerRuntime
        self.model = model
        self.session = session
    }

    func relay(
        privacyMode: Bool,
        probe: (any PrivacyPostureProbe)?,
        receiptBuilder: ReceiptBuilder? = nil,
        receiptProviderID: String? = nil,
        tier2: Tier2ProviderSession? = nil
    ) -> InferenceRelay {
        InferenceRelay(
            modelRuntime: runtime,
            providerStatus: ProviderStatus(
                modelID: model,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
            ),
            loadedModelID: model,
            maxActiveRequests: 1,
            maxBodyBytes: 1_200_000,
            tier2Session: tier2,
            receiptBuilder: receiptBuilder,
            receiptProviderID: receiptProviderID,
            relayBlindRuntime: providerRuntime,
            privacyClassBeta: privacyMode,
            postureProbe: probe,
            sendFrame: { frame in await frames.append(frame) }
        )
    }

    func message(
        requestID: String,
        stream: Bool,
        privacy: Bool,
        prompt: String,
        buyerPrivateKey: String? = nil,
        marker: String? = nil
    ) throws -> [String: Any] {
        let record = try keys.currentRecord()
        let buyer: Curve25519.KeyAgreement.PrivateKey
        if let buyerPrivateKey {
            buyer = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: try RelayBlindBase64URL.decode(buyerPrivateKey, exactCount: 32)
            )
        } else {
            buyer = Curve25519.KeyAgreement.PrivateKey()
        }
        let inputCap: UInt64 = 8
        let outputCap: UInt64 = 4
        let providerBinding = RelayBlindBase64URL.encode(Data(repeating: 0x41, count: 32))
        let buyerBinding = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(requestID.utf8))))
        let replay = Data(SHA256.hash(data: Data("replay-\(requestID)".utf8)))
        let now = Int64(Date().timeIntervalSince1970)
        let empty = RelayBlindEnvelope(
            model: model,
            providerModel: model,
            stream: stream,
            requestID: requestID,
            maxOutputTokens: outputCap,
            inputTokenUpperBound: inputCap,
            reservationTokenCap: inputCap + outputCap,
            providerBinding: providerBinding,
            buyerBinding: buyerBinding,
            keyRecordDigest: record.keyRecordDigest,
            kid: record.kid,
            buyerEphemeralPublicKey: buyer.publicKey.rawRepresentation,
            requestReplayNonce: replay,
            issuedAtUnix: now,
            ciphertext: Data([0]),
            tag: Data(repeating: 0, count: 16)
        )
        let shared = try buyer.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: record.publicKey)
        )
        let transcript = Data(SHA256.hash(data: Data("macprovider/spec041/relay-blind/transcript/v1".utf8) + empty.aad))
        let requestKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead/v1".utf8),
            outputByteCount: 32
        )
        let nonceKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead-nonce/v1".utf8),
            outputByteCount: 12
        )
        let inner: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": outputCap,
            "stream": stream,
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys])
        let sealed = try AES.GCM.seal(
            plaintext,
            using: requestKey,
            nonce: try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) }),
            authenticating: empty.aad
        )
        let envelopeObject: [String: Any] = [
            "version": RelayBlindEnvelope.version,
            "mode": RelayBlindEnvelope.mode,
            "endpoint_family": RelayBlindEnvelope.endpointFamily,
            "model": model,
            "provider_model": model,
            "stream": stream,
            "request_id": requestID,
            "max_output_tokens": outputCap,
            "input_token_upper_bound": inputCap,
            "reservation_token_cap": inputCap + outputCap,
            "provider_binding": providerBinding,
            "buyer_binding": buyerBinding,
            "key_record_digest": record.keyRecordDigest,
            "kid": record.kid,
            "buyer_ephemeral_public_key": RelayBlindBase64URL.encode(buyer.publicKey.rawRepresentation),
            "request_replay_nonce": RelayBlindBase64URL.encode(replay),
            "issued_at_unix": now,
            "algorithm": RelayBlindKeyRecord.algorithm,
            "ciphertext": RelayBlindBase64URL.encode(sealed.ciphertext),
            "tag": RelayBlindBase64URL.encode(sealed.tag),
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelopeObject, options: [.sortedKeys])
        let body = try XCTUnwrap(String(data: envelopeData, encoding: .utf8))
        let digest: (String) -> String = { value in
            RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(value.utf8))))
        }
        var context: [String: Any] = [
            "execution_auth_digest": digest("execution-auth-\(requestID)"),
            "envelope_digest": digest(body),
            "provider_binding_digest": digest(providerBinding),
            "buyer_binding_digest": digest(buyerBinding),
            "kid": record.kid,
            "assigned_session": session,
            "request_id": requestID,
            "input_token_upper_bound": inputCap,
            "max_output_tokens": outputCap,
        ]
        var message: [String: Any] = [
            "type": "inference_request",
            "request_id": requestID,
            "stream": stream,
            "body": body,
            "body_encoding": RelayBlindEnvelope.version,
        ]
        if privacy {
            let value = marker ?? PrivacyClassConstants.v1
            context["privacy_class"] = value
            message["privacy_class"] = value
        }
        message["relay_blind_context"] = context
        return message
    }
}
