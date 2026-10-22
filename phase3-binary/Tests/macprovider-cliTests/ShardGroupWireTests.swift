import CryptoKit
import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084: the provider half of the SPEC-051-R029 group messages and the
/// R019 group attestation, in the shapes the coordinator's `internal/shardgroup`
/// decoders accept.
final class ShardGroupWireTests: XCTestCase {
    private let headKey = Curve25519.Signing.PrivateKey()
    private let tailKey = Curve25519.Signing.PrivateKey()

    private func headConfig(poolModelID: String? = "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b", spare: ShardGroupSpareConfig? = nil) -> ShardGroupHeadConfig {
        ShardGroupHeadConfig(
            groupEpoch: ShardBenchTestRig.epoch, poolModelID: poolModelID, headLayerEnd: 2,
            stages: [ShardGroupStageConfig(memberDeviceID: "mac-b", endpoint: "127.0.0.1:1", layerStart: 2, layerEnd: 4)],
            spare: spare, maxConcurrency: 4)
    }

    /// A head runtime over fake stages whose tail signs as mac-b.
    private func runtime(registration: Bool = true, poolModelID: String? = "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b") async throws -> ShardGroupRuntime {
        let headSigner = ShardMemberSigner(memberDeviceID: "prov-head", key: headKey)
        let tailSigner = ShardMemberSigner(memberDeviceID: "mac-b", key: tailKey)
        let tail = FakeShardStage(layers: 2..<4, totalLayers: 4)
        let head = FakeShardStage(layers: 0..<2, totalLayers: 4)
        let runtime = ShardGroupRuntime(
            identity: ShardGroupRuntime.Identity(
                modelID: "lab/model", modelHash: String(repeating: "c", count: 64),
                modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1, weightsManifestSHA256: nil, catalogModelIDAlias: nil),
            prompting: ShardGroupRuntime.Prompting(
                tokenizer: ShardTestTokenizer(), eosTokenIDs: [], stopFilter: StopTokenFilter(tokens: []),
                templateSupportsThinkingToggle: false, templateSupportsPreserveThinking: false),
            maxContextTokens: 1024, gate: .awaitingCoordinator,
            registration: registration ? ShardGroupRegistration(config: headConfig(poolModelID: poolModelID), signer: headSigner) : nil,
            connect: {
                let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
                var tailOptions = ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1)
                tailOptions.signer = tailSigner
                tailOptions.upstreamInterface = ShardLinkInterface.thunderbolt
                let session = ShardBenchSession(options: tailOptions, stage: tail)
                Thread { _ = try? session.run(links: links[1]) }.start()
                var options = ShardGroupEngineTests.options()
                options.signer = headSigner
                let engine = ShardGroupEngine(stage: head, options: options)
                try engine.start(links: links[0])
                return engine
            })
        try await runtime.start()
        return runtime
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The JCS value of a JSONSerialization object (integers, strings, bools, nesting).
    private func jcs(_ value: Any) -> RFC8785JCS.Value {
        switch value {
        case let object as [String: Any]: return .object(object.mapValues { jcs($0) })
        case let array as [Any]: return .array(array.map { jcs($0) })
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return .bool(number.boolValue)
        case let number as NSNumber: return .int(number.intValue)
        case let string as String: return .string(string)
        default: return .null
        }
    }

    private func verify(_ object: [String: Any], signatureKey: String, domain: String, key: Curve25519.Signing.PublicKey) throws -> Bool {
        var unsigned = object
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(unsigned.removeValue(forKey: signatureKey) as? String)))
        let canonical = try RFC8785JCS.canonicalStringRawStrings(jcs(unsigned))
        return key.isValidSignature(signature, for: Data((domain + canonical).utf8))
    }

    private func receiptEnvelope(requestID: String, providerID: String, attemptN: Int = 2) throws -> (String, Data) {
        let tuple = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID, "attempt_n": attemptN, "provider_id": providerID, "receipt_version": "4",
        ], options: [.sortedKeys])
        return (tuple.base64EncodedString() + "." + Data(repeating: 7, count: 64).base64EncodedString(), tuple)
    }

    private func completion(_ runtime: ShardGroupRuntime, requestID: String = "req_9") async throws -> CompletionResult {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "lab/model", "max_tokens": 4, "temperature": 0, "messages": [["role": "user", "content": "attest"]],
        ])).withRequestID(requestID)
        return try await runtime.complete(request, shouldCancel: { false })
    }

    // MARK: Attestation

    func testGroupAttestationBindsTheReceiptAndCarriesSignedSubReceipts() async throws {
        let runtime = try await runtime()
        let result = try await completion(runtime)
        let evidence = try XCTUnwrap(result.shardGroupEvidence)
        let (receipt, tuple) = try receiptEnvelope(requestID: "req_9", providerID: "prov-head")
        let attestation = try ShardGroupWire.attestation(receipt: receipt, evidence: evidence, key: headKey)

        XCTAssertEqual(Set(attestation.keys), ["schema", "group_provider_id", "request_id", "attempt_n", "receipt_tuple_sha256", "segments", "signature"])
        XCTAssertEqual(attestation["schema"] as? String, "macprovider.shard-group-attestation.v1")
        XCTAssertEqual(attestation["group_provider_id"] as? String, "prov-head")
        XCTAssertEqual(attestation["request_id"] as? String, "req_9")
        XCTAssertEqual(attestation["attempt_n"] as? Int, 2)
        XCTAssertEqual(attestation["receipt_tuple_sha256"] as? String, SHA256.hash(data: tuple).map { String(format: "%02x", $0) }.joined())
        XCTAssertTrue(try verify(attestation, signatureKey: "signature", domain: "macprovider.shard-group-attestation.v1\n", key: headKey.publicKey))

        let segments = try XCTUnwrap(attestation["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0]["group_epoch"] as? Int, Int(ShardBenchTestRig.epoch))
        XCTAssertEqual(segments[0]["step_start"] as? Int, 0)
        XCTAssertEqual(segments[0]["step_end"] as? Int, 4)
        let subReceipts = try XCTUnwrap(segments[0]["sub_receipts"] as? [[String: Any]])
        let decoded = try subReceipts.map { try JSONDecoder().decode(ShardSignedSubReceipt.self, from: JSONSerialization.data(withJSONObject: $0)) }
        XCTAssertEqual(decoded.map(\.receipt.memberDeviceID), ["prov-head", "mac-b"])
        XCTAssertEqual(decoded.map(\.publicKey), [headKey, tailKey].map { $0.publicKey.rawRepresentation.base64EncodedString() })
        XCTAssertTrue(decoded.allSatisfy(\.signatureIsValid))
        XCTAssertEqual(ShardGroupAttestationVerifier.verify(signed: decoded), .ok)
        XCTAssertEqual(Set(try XCTUnwrap(subReceipts[0]["sub_receipt"] as? [String: Any]).keys), [
            "member_device_id", "group_epoch", "stage_index", "layer_start", "layer_end", "request_id",
            "prompt_tokens", "decode_steps", "in_digest", "out_digest",
        ])
        await runtime.stop()
    }

    func testAttestationRefusesAReceiptForAnotherProviderOrRequest() async throws {
        let runtime = try await runtime()
        let result = try await completion(runtime)
        let evidence = try XCTUnwrap(result.shardGroupEvidence)
        XCTAssertThrowsError(try ShardGroupWire.attestation(
            receipt: try receiptEnvelope(requestID: "req_9", providerID: "someone-else").0, evidence: evidence, key: headKey))
        XCTAssertThrowsError(try ShardGroupWire.attestation(
            receipt: try receiptEnvelope(requestID: "req_other", providerID: "prov-head").0, evidence: evidence, key: headKey))
        XCTAssertThrowsError(try ShardGroupWire.attestation(
            receipt: try receiptEnvelope(requestID: "req_9", providerID: "prov-head").0, evidence: evidence,
            key: Curve25519.Signing.PrivateKey()), "stage 0 must be signed with the receipt key")
        XCTAssertThrowsError(try ShardGroupWire.attestation(receipt: "not-a-receipt", evidence: evidence, key: headKey))
        await runtime.stop()
    }

    // MARK: Head registration and heartbeat

    func testHeadRegistersThenHeartbeatsAndFollowsTheCoordinatorStatus() async throws {
        let runtime = try await runtime()
        let context = ShardCoordinatorContext(providerID: "prov-head", wireModelID: "wire/model")

        let first = await runtime.shardCoordinatorMessages(context: context, sessionStarted: true)
        XCTAssertEqual(first.count, 1)
        let register = try object(first[0])
        XCTAssertEqual(Set(register.keys), ["type", "version", "record", "record_signature"])
        XCTAssertEqual(register["type"] as? String, "shard_group_register")
        let record = try XCTUnwrap(register["record"] as? [String: Any])
        XCTAssertEqual(Set(record.keys), [
            "schema", "group_provider_id", "group_epoch", "parallelism_mode", "interconnect_class", "frame_protection",
            "transport_version", "model", "num_layers", "max_concurrency", "stages", "spares", "supervision",
        ])
        XCTAssertEqual(record["group_provider_id"] as? String, "prov-head")
        XCTAssertEqual(record["model"] as? [String: String], [
            "model_id": "wire/model", "pool_model_id": "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b",
            "artifact_hash_algorithm": ModelArtifactIdentity.snapshotManifestV1, "artifact_hash": String(repeating: "c", count: 64),
        ])
        let stages = try XCTUnwrap(record["stages"] as? [[String: Any]])
        XCTAssertEqual(stages.map { $0["member_device_id"] as? String }, ["prov-head", "mac-b"])
        XCTAssertEqual(stages.map { $0["layer_end"] as? Int }, [2, 4])
        let recordSignature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(register["record_signature"] as? String)))
        XCTAssertTrue(headKey.publicKey.isValidSignature(
            recordSignature, for: Data(("macprovider.shard-group-record.v1\n" + (try RFC8785JCS.canonicalStringRawStrings(jcs(record)))).utf8)))

        // No duplicate registration while the result is pending.
        let pending = await runtime.shardCoordinatorMessages(context: context, sessionStarted: false)
        XCTAssertTrue(pending.isEmpty)

        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_register_result", "version": 1, "group_provider_id": "prov-head",
            "group_epoch": Int(ShardBenchTestRig.epoch), "accepted": true, "reason": "",
        ]))
        let beats = await runtime.shardCoordinatorMessages(context: context, sessionStarted: false)
        let heartbeat = try object(try XCTUnwrap(beats.first))
        XCTAssertEqual(heartbeat["type"] as? String, "shard_group_heartbeat")
        let members = try XCTUnwrap(heartbeat["members"] as? [[String: Any]])
        XCTAssertEqual(members.map { $0["member_device_id"] as? String }, ["prov-head", "mac-b"])
        XCTAssertEqual(members.map { $0["healthy"] as? Bool }, [true, true])
        let links = try XCTUnwrap(heartbeat["links"] as? [[String: Any]])
        XCTAssertEqual(links.map { [$0["from_member_device_id"] as? String, $0["to_member_device_id"] as? String] },
                       [["prov-head", "mac-b"], ["mac-b", "prov-head"]])
        XCTAssertEqual(links.map { $0["interface_type"] as? String }, [ShardLinkInterface.thunderbolt, ShardLinkInterface.thunderbolt])
        XCTAssertTrue(links.allSatisfy { ($0["rtt_p99_us"] as? Int ?? -1) > 0 })

        let request = try ChatCompletionRequest.parse(data: Data(#"{"model":"lab/model","messages":[{"role":"user","content":"x"}]}"#.utf8))
        do {
            _ = try await runtime.acquireRequestHandle(request)
            XCTFail("no network buyer before available")
        } catch {}
        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_status", "version": 1, "group_provider_id": "prov-head",
            "group_epoch": Int(ShardBenchTestRig.epoch), "available": true, "reason": "",
        ]))
        _ = try await runtime.acquireRequestHandle(request)
        let gateAfter = await runtime.gate
        XCTAssertEqual(gateAfter, .available)

        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_status", "version": 1, "group_provider_id": "prov-head",
            "group_epoch": Int(ShardBenchTestRig.epoch), "available": false, "reason": "member_unhealthy",
        ]))
        let gateDown = await runtime.gate
        XCTAssertEqual(gateDown, .unavailable("member_unhealthy"))

        // A new session starts over: register again, network buyers wait.
        let again = await runtime.shardCoordinatorMessages(context: context, sessionStarted: true)
        XCTAssertEqual(try object(try XCTUnwrap(again.first))["type"] as? String, "shard_group_register")
        let gateReset = await runtime.gate
        XCTAssertEqual(gateReset, .awaitingCoordinator)
        await runtime.stop()
    }

    func testHeadDoesNotRegisterWithoutAPoolModelOrUnderAnotherIdentity() async throws {
        let noPool = try await runtime(poolModelID: nil)
        let none = await noPool.shardCoordinatorMessages(context: ShardCoordinatorContext(providerID: "prov-head", wireModelID: "m"), sessionStarted: true)
        XCTAssertTrue(none.isEmpty)
        await noPool.stop()
        let runtime = try await runtime()
        let foreign = await runtime.shardCoordinatorMessages(context: ShardCoordinatorContext(providerID: "prov-other", wireModelID: "m"), sessionStarted: true)
        XCTAssertTrue(foreign.isEmpty)
        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_status", "version": 1, "group_provider_id": "prov-other", "group_epoch": 1, "available": true, "reason": "",
        ]))
        let gate = await runtime.gate
        XCTAssertEqual(gate, .awaitingCoordinator, "a status for another group is ignored")
        await runtime.stop()
    }

    func testRegistrationRefusalHoldsTheGroup() async throws {
        let runtime = try await runtime()
        _ = await runtime.shardCoordinatorMessages(context: ShardCoordinatorContext(providerID: "prov-head", wireModelID: "m"), sessionStarted: true)
        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_register_result", "version": 1, "group_provider_id": "prov-head",
            "group_epoch": Int(ShardBenchTestRig.epoch), "accepted": false, "reason": "owner_mismatch",
        ]))
        let gate = await runtime.gate
        XCTAssertEqual(gate, .unavailable("registration refused: owner_mismatch"))
        await runtime.stop()
    }

    // MARK: Member hello

    func testMemberHelloNamesItsStageArtifactAndOneLinkPerPeer() throws {
        let config = ShardMemberConfig(
            groupProviderID: "prov-head", groupEpoch: 5, stageIndex: 1, layerStart: 14, layerEnd: 28, listen: "0.0.0.0:7101")
        let joined = ShardMemberStatus(
            listening: true, chain: [], stageIndex: 1, upstreamPeer: "prov-head", downstreamPeer: "prov-head",
            upstreamInterface: "thunderbolt", downstreamInterface: "thunderbolt", sessionsServed: 0, lastError: nil)
        let hello = try object(try XCTUnwrap(try ShardGroupWire.memberHello(
            config: config, status: joined, memberDeviceID: "mac-b", artifactHashAlgorithm: "macprovider.snapshot-manifest.v1",
            artifactHash: String(repeating: "d", count: 64))))
        XCTAssertEqual(Set(hello.keys), [
            "type", "version", "group_provider_id", "group_epoch", "member_device_id", "role", "stage_index", "layer_start",
            "layer_end", "transport_version", "artifact_hash_algorithm", "artifact_hash", "weights_verified", "stage_fits", "links",
        ])
        XCTAssertEqual(hello["type"] as? String, "shard_member_hello")
        XCTAssertEqual(hello["role"] as? String, "stage")
        XCTAssertEqual(hello["group_epoch"] as? Int, 5)
        XCTAssertEqual(hello["links"] as? [[String: String]], [["peer_member_device_id": "prov-head", "interface_type": "thunderbolt"]],
                       "a two-stage tail reaches the head over one link")

        var middle = joined
        middle.downstreamPeer = "mac-c"
        let threeStage = try object(try XCTUnwrap(try ShardGroupWire.memberHello(
            config: config, status: middle, memberDeviceID: "mac-b", artifactHashAlgorithm: "a", artifactHash: "b")))
        XCTAssertEqual((threeStage["links"] as? [[String: String]])?.map { $0["peer_member_device_id"] }, ["prov-head", "mac-c"])

        var idle = joined
        idle.upstreamPeer = nil
        XCTAssertNil(try ShardGroupWire.memberHello(config: config, status: idle, memberDeviceID: "mac-b", artifactHashAlgorithm: "a", artifactHash: "b"),
                     "no hello before the member has joined a chain")
    }

    // MARK: Relay terminal status

    func testChainFailureEndFrameIsRetryableOnlyBeforeTheFirstChunk() {
        let early = ShardGroupRuntime.buyerError(ShardGroupEngineError.failedBeforeFirstToken(cause: "peer closed"))
        let late = ShardGroupRuntime.buyerError(ShardGroupEngineError.streamTerminated(delivered: 3, cause: "peer closed"))
        let before = InferenceRelay.errorEndFrame(requestID: "r", error: early as! APIError, chunksSent: 0)
        XCTAssertEqual(before["status"] as? String, "error_shard_group_failed")
        XCTAssertEqual(before["retryable"] as? Bool, true)
        XCTAssertEqual(before["chunks_sent"] as? Int, 0)
        XCTAssertNil(before["receipt"])
        let after = InferenceRelay.errorEndFrame(requestID: "r", error: late as! APIError, chunksSent: 3)
        XCTAssertEqual(after["status"] as? String, "error_shard_group_failed")
        XCTAssertEqual(after["retryable"] as? Bool, false)
        let other = InferenceRelay.errorEndFrame(requestID: "r", error: ShardMemberRuntime.notRoutable, chunksSent: 0)
        XCTAssertEqual(other["status"] as? String, "error_internal", "a member's refusal is an ordinary provider error")
    }
}
