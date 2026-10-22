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
    private let spareKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

    private func headConfig(poolModelID: String? = "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b", spare: ShardGroupSpareConfig? = nil) -> ShardGroupHeadConfig {
        ShardGroupHeadConfig(
            groupEpoch: ShardBenchTestRig.epoch, poolModelID: poolModelID, headLayerEnd: 2,
            stages: [ShardGroupStageConfig(
                memberDeviceID: "mac-b", endpoint: "127.0.0.1:1", layerStart: 2, layerEnd: 4,
                memberPublicKey: tailKey.publicKey.rawRepresentation.base64EncodedString())],
            spare: spare, maxConcurrency: 4)
    }

    /// A head runtime over fake stages whose tail signs as mac-b.
    private func runtime(
        registration: Bool = true, poolModelID: String? = "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b", tailLinks: ShardTestLinksBox? = nil,
        spare: ShardGroupSpareConfig? = nil, epochStore: ShardGroupEpochStore? = nil, builtEpochs: ShardTestEpochLog? = nil
    ) async throws -> ShardGroupRuntime {
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
            registration: registration ? ShardGroupRegistration(config: headConfig(poolModelID: poolModelID, spare: spare), signer: headSigner) : nil,
            epochStore: epochStore,
            connect: { epoch in
                builtEpochs?.append(epoch)
                // The tail, like a member, accepts the head's epoch when it is not
                // below its own configured one.
                let (member, headLink) = try ShardBenchTestRig.adoptingPair(headEpoch: epoch, memberMinimum: ShardBenchTestRig.epoch)
                let links = [ShardBenchLinks(upstream: headLink, downstream: headLink), ShardBenchLinks(upstream: member, downstream: member)]
                tailLinks?.links = links[1]
                var tailOptions = ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1)
                tailOptions.signer = tailSigner
                tailOptions.upstreamInterface = ShardLinkInterface.thunderbolt
                let session = ShardBenchSession(options: tailOptions, stage: tail)
                Thread { _ = try? session.run(links: links[1]) }.start()
                var options = ShardGroupEngineTests.options(epoch: epoch)
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

    // MARK: Continuous link health

    private func hello(_ role: ShardBenchRole, _ layers: Range<Int>, member: String, probeMicroseconds: Double) -> ShardBenchHello {
        ShardBenchHello(
            role: role, modelType: "fake", totalLayers: 6, hiddenSize: 4, layerStart: layers.lowerBound, layerEnd: layers.upperBound,
            upstreamProbe: role == .head ? nil : ShardBenchLatency(seconds: [probeMicroseconds / 1e6]), memberDeviceID: member,
            upstreamInterface: role == .head ? nil : ShardLinkInterface.ethernet,
            returnInterface: role == .tail ? ShardLinkInterface.ethernet : nil)
    }

    func testHeartbeatLinksUseLiveRoundTripsAndRelayedMemberReports() {
        var chain = [
            hello(.head, 0..<2, member: "prov-head", probeMicroseconds: 0),
            hello(.middle, 2..<4, member: "mac-b", probeMicroseconds: 900),
            hello(.tail, 4..<6, member: "mac-c", probeMicroseconds: 800),
        ]
        chain[2].returnProbe = ShardBenchLatency(seconds: [700e-6])
        // Before any echo: the handshake probes.
        let probes = ShardGroupWire.linkReports(chain: chain, providerID: "prov-head", health: nil, now: 0, staleAfter: 1)
        XCTAssertEqual(probes.map(\.rttP99Microseconds), [900, 800, 700])
        XCTAssertEqual(probes.map { "\($0.from)>\($0.to)" }, ["prov-head>mac-b", "mac-b>mac-c", "mac-c>prov-head"])

        var downstream = ShardRoundTripWindow()
        downstream.add(310e-6)
        var back = ShardRoundTripWindow()
        back.add(420e-6)
        let relayed = [ShardLinkHealth(fromStage: 0, toStage: 1, rttP99Microseconds: 333, samples: 10),
                       ShardLinkHealth(fromStage: 1, toStage: 2, rttP99Microseconds: 1500, samples: 10)]
        let health = ShardGroupLinkHealth(
            downstream: ShardLinkRoundTrip(samples: 1, p99Seconds: downstream.p99Seconds, peerLinks: [], peerLinksAt: nil),
            upstream: ShardLinkRoundTrip(samples: 1, p99Seconds: back.p99Seconds, peerLinks: relayed, peerLinksAt: 100))
        let live = ShardGroupWire.linkReports(chain: chain, providerID: "prov-head", health: health, now: 100.5, staleAfter: 1)
        XCTAssertEqual(live.map(\.rttP99Microseconds), [310, 1500, 420], "the head's own links, the member's relayed one")
        XCTAssertTrue(live.allSatisfy(\.fresh))
        XCTAssertEqual(ShardGroupWire.memberHealth(chainCount: 3, running: true, links: live), [true, true, true])

        // The middle stopped relaying: its downstream member goes unhealthy, and that is a change.
        let stale = ShardGroupWire.linkReports(chain: chain, providerID: "prov-head", health: health, now: 105, staleAfter: 1)
        XCTAssertEqual(stale.map(\.fresh), [true, false, true])
        XCTAssertEqual(ShardGroupWire.memberHealth(chainCount: 3, running: true, links: stale), [true, true, false])
        XCTAssertEqual(ShardGroupWire.memberHealth(chainCount: 3, running: false, links: live), [false, false, false])
        let freshSignature = ShardGroupWire.HealthSignature(
            epoch: 3, members: ShardGroupWire.memberHealth(chainCount: 3, running: true, links: live), links: live)
        XCTAssertNotEqual(freshSignature, ShardGroupWire.HealthSignature(
            epoch: 3, members: ShardGroupWire.memberHealth(chainCount: 3, running: true, links: stale), links: stale))
        // Jitter inside one quarter octave is not a change; a 1.5x jump is.
        var jitter = health
        jitter.downstream.p99Seconds = 320e-6
        var jump = health
        jump.downstream.p99Seconds = 470e-6
        func signature(_ h: ShardGroupLinkHealth) -> ShardGroupWire.HealthSignature {
            let links = ShardGroupWire.linkReports(chain: chain, providerID: "prov-head", health: h, now: 100.5, staleAfter: 1)
            return ShardGroupWire.HealthSignature(epoch: 3, members: [true, true, true], links: links)
        }
        XCTAssertEqual(signature(jitter), signature(health))
        XCTAssertNotEqual(signature(jump), signature(health))
    }

    func testAChainFailureIsReportedAtOnceWithinTheRateBound() async throws {
        let tailLinks = ShardTestLinksBox()
        let runtime = try await runtime(tailLinks: tailLinks)
        let context = ShardCoordinatorContext(providerID: "prov-head", wireModelID: "wire/model")
        _ = await runtime.shardCoordinatorMessages(context: context, sessionStarted: true)
        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_register_result", "version": 1, "group_provider_id": "prov-head",
            "group_epoch": Int(ShardBenchTestRig.epoch), "accepted": true, "reason": "",
        ]))
        let sent = ShardTestMessageLog()
        await runtime.setShardChangeHandler {
            sent.append(await runtime.shardCoordinatorMessages(context: context, sessionStarted: false))
        }
        // The first heartbeat reports the healthy chain; until something changes the
        // monitor sends nothing more.
        _ = await runtime.shardCoordinatorMessages(context: context, sessionStarted: false)
        let quietStart = sent.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThanOrEqual(sent.count - quietStart, 1, "at most a round-trip bucket change while idle")

        // The tail goes away: the head reports both members unhealthy without waiting for a tick.
        let failedAt = Date()
        tailLinks.links?.close()
        var unhealthy: [String: Any]?
        while unhealthy == nil, Date().timeIntervalSince(failedAt) < 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
            unhealthy = try sent.all.reversed().compactMap { try object($0) }.first {
                ($0["members"] as? [[String: Any]])?.contains { $0["healthy"] as? Bool == false } == true
            }
        }
        let report = try XCTUnwrap(unhealthy, "no change-triggered heartbeat after the chain failed")
        XCTAssertLessThan(Date().timeIntervalSince(failedAt), 2)
        XCTAssertEqual((report["members"] as? [[String: Any]])?.map { $0["healthy"] as? Bool }, [false, false])
        XCTAssertEqual(report["type"] as? String, "shard_group_heartbeat")

        // Rate bound: two checks within the minimum interval send at most once.
        let before = sent.count
        await runtime.reportChangeIfDue()
        await runtime.reportChangeIfDue()
        XCTAssertLessThanOrEqual(sent.count - before, 1)
        XCTAssertGreaterThanOrEqual(ShardGroupWire.minimumChangeInterval, 0.25)
        await runtime.setShardChangeHandler(nil)
        await runtime.stop()
    }

    // MARK: Spares

    func testRecordAndHeartbeatCarryTheSpareUntilItTakesOver() async throws {
        let runtime = try await runtime(spare: ShardGroupSpareConfig(memberDeviceID: "mac-s", endpoint: "127.0.0.1:9", memberPublicKey: spareKey))
        let context = ShardCoordinatorContext(providerID: "prov-head", wireModelID: "wire/model")
        let first = await runtime.shardCoordinatorMessages(context: context, sessionStarted: true)
        let record = try XCTUnwrap(try object(try XCTUnwrap(first.first))["record"] as? [String: Any])
        XCTAssertEqual(record["spares"] as? [[String: AnyHashable]], [["member_device_id": "mac-s", "stage_index": 1]],
                       "a group with a spare registers with it")
        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_register_result", "version": 1, "group_provider_id": "prov-head",
            "group_epoch": Int(ShardBenchTestRig.epoch), "accepted": true, "reason": "",
        ]))
        let beats = await runtime.shardCoordinatorMessages(context: context, sessionStarted: false)
        let heartbeat = try object(try XCTUnwrap(beats.first))
        let members = try XCTUnwrap(heartbeat["members"] as? [[String: Any]])
        XCTAssertEqual(members.map { $0["member_device_id"] as? String }, ["prov-head", "mac-b", "mac-s"])
        XCTAssertEqual(members.map { $0["healthy"] as? Bool }, [true, true, false], "no spare listens on port 9")
        let links = try XCTUnwrap(heartbeat["links"] as? [[String: Any]])
        XCTAssertEqual(links.map { [$0["from_member_device_id"] as? String, $0["to_member_device_id"] as? String] },
                       [["prov-head", "mac-b"], ["mac-b", "prov-head"], ["prov-head", "mac-s"]])
        XCTAssertEqual(links.last?["interface_type"] as? String, ShardLinkInterface.other)
        await runtime.stop()

        // After a takeover the new epoch's record names the spare as stage 1 and no spare.
        var chain = [
            ShardBenchHello(role: .head, modelType: "fake", totalLayers: 4, hiddenSize: 4, layerStart: 0, layerEnd: 2, memberDeviceID: "prov-head"),
            ShardBenchHello(role: .tail, modelType: "fake", totalLayers: 4, hiddenSize: 4, layerStart: 2, layerEnd: 4, memberDeviceID: "mac-s"),
        ]
        chain[1].upstreamInterface = ShardLinkInterface.thunderbolt
        let takeover = try ShardGroupWire.record(
            config: headConfig(spare: ShardGroupSpareConfig(memberDeviceID: "mac-s", endpoint: "127.0.0.1:9", memberPublicKey: spareKey)), chain: chain,
            groupEpoch: ShardBenchTestRig.epoch + 1, providerID: "prov-head", wireModelID: "wire/model",
            poolModelID: "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b", artifactHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            artifactHash: String(repeating: "c", count: 64))
        let takeoverRecord = try XCTUnwrap(ShardGroupWire.jsonObject(takeover) as? [String: Any])
        XCTAssertEqual((takeoverRecord["stages"] as? [[String: Any]])?.map { $0["member_device_id"] as? String }, ["prov-head", "mac-s"])
        XCTAssertEqual((takeoverRecord["spares"] as? [Any])?.count, 0)
    }

    func testASpareSendsItsHelloThenItsTakeoverHello() async throws {
        let config = ShardMemberConfig(
            groupProviderID: "prov-head", groupEpoch: 5, role: .spare, stageIndex: 1, layerStart: 14, layerEnd: 28, listen: "0.0.0.0:7101")
        let standby = ShardMemberStatus(
            listening: true, chain: [], stageIndex: 1, upstreamPeer: "prov-head", downstreamPeer: "prov-head",
            upstreamInterface: "thunderbolt", downstreamInterface: "thunderbolt", sessionsServed: 0, lastError: nil)
        let own = try object(try XCTUnwrap(try ShardGroupWire.memberHello(
            config: config, status: standby, memberDeviceID: "mac-s", artifactHashAlgorithm: "a", artifactHash: "b",
            weightsVerified: true, stageFits: true)))
        XCTAssertEqual(own["role"] as? String, "spare")
        XCTAssertEqual(own["group_epoch"] as? Int, 5)
        let takeover = try object(try XCTUnwrap(try ShardGroupWire.memberHello(
            config: config, status: standby, memberDeviceID: "mac-s", artifactHashAlgorithm: "a", artifactHash: "b",
            weightsVerified: true, stageFits: true, takeover: true)))
        XCTAssertEqual(takeover["role"] as? String, "stage", "in the takeover epoch the spare is stage 1")
        XCTAssertEqual(takeover["group_epoch"] as? Int, 6)
        XCTAssertEqual(takeover["stage_index"] as? Int, 1)
        XCTAssertEqual(takeover["links"] as? [[String: String]], [["peer_member_device_id": "prov-head", "interface_type": "thunderbolt"]])
        var stage = config
        stage.role = .stage
        XCTAssertNil(try ShardGroupWire.memberHello(
            config: stage, status: standby, memberDeviceID: "mac-s", artifactHashAlgorithm: "a", artifactHash: "b",
            weightsVerified: true, stageFits: true, takeover: true), "only a spare has a takeover hello")
    }

    func testASpareMemberJoinsOnTheStandbyLinkAndSendsBothHellos() async throws {
        let spareKey = Curve25519.Signing.PrivateKey()
        let headSigner = ShardMemberSigner(memberDeviceID: "head-device", key: Curve25519.Signing.PrivateKey())
        let spareConfig = ShardMemberConfig(
            groupProviderID: "head-device", groupEpoch: ShardBenchTestRig.epoch, role: .spare, stageIndex: 1, layerStart: 2, layerEnd: 4,
            listen: "127.0.0.1:0", maxSequences: 8,
            supervision: ShardSupervisionConfig(
                heartbeatIntervalMilliseconds: 50, heartbeatMissLimit: 4, decodeHopDeadlineMilliseconds: 2000,
                prefillChunkDeadlineMilliseconds: 3000, replayDeadlineMilliseconds: 5000),
            upstreamPublicKey: headSigner.publicKeyBase64)
        let server = ShardMemberStageServer(
            stage: FakeShardStage(layers: 2..<4, totalLayers: 4), config: spareConfig,
            signer: ShardMemberSigner(memberDeviceID: "mac-s", key: spareKey), modelDigest: nil, modelLabel: "fake")
        try server.start()
        defer { server.stop() }
        let member = ShardMemberRuntime(
            config: spareConfig,
            identity: ShardGroupRuntime.Identity(
                modelID: "m", modelHash: String(repeating: "c", count: 64), modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
                weightsManifestSHA256: nil, catalogModelIDAlias: nil),
            memberDeviceID: "mac-s", server: server,
            stageProof: ShardGroupServe.StageProof(
                digest: "d", weightsVerified: true, fit: ShardStageArtifact.Fit(stageWeightBytes: 1, kvBudgetBytes: 2, kvDemandBytes: 1)))
        // A head with this spare: its standby link joins the spare before any takeover.
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        Thread {
            _ = try? ShardBenchSession(options: ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1), stage: FakeShardStage(layers: 2..<4, totalLayers: 4))
                .run(links: links[1])
        }.start()
        var options = ShardGroupEngineTests.options(spare: ShardBenchEndpoint(host: "127.0.0.1", port: try XCTUnwrap(server.port)))
        options.spareMember = ShardGroupExpectedMember(
            memberDeviceID: "mac-s", layers: 2..<4, publicKey: spareKey.publicKey.rawRepresentation.base64EncodedString())
        options.signer = headSigner
        let engine = ShardGroupEngine(stage: FakeShardStage(layers: 0..<2, totalLayers: 4), options: options)
        try engine.start(links: links[0])
        defer { _ = try? engine.shutdown() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, engine.status.spare?.alive != true || server.status.upstreamPeer == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(engine.status.spare?.memberDeviceID, "mac-s")
        XCTAssertEqual(engine.status.spare?.interfaceType, ShardLinkInterface.other, "loopback")
        XCTAssertEqual(server.status.upstreamPeer, "head-device")
        XCTAssertEqual(server.status.stageIndex, 1)

        let context = ShardCoordinatorContext(providerID: "mac-s", wireModelID: "m")
        let firstBatch = await member.shardCoordinatorMessages(context: context, sessionStarted: true)
        let first = try object(try XCTUnwrap(firstBatch.first))
        XCTAssertEqual(first["role"] as? String, "spare")
        XCTAssertEqual(first["group_epoch"] as? Int, Int(ShardBenchTestRig.epoch))
        let pending = await member.shardCoordinatorMessages(context: context, sessionStarted: false)
        XCTAssertTrue(pending.isEmpty, "no takeover hello before the spare's own hello is accepted")
        await member.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_member_hello_result", "version": 1, "group_provider_id": "head-device",
            "group_epoch": Int(ShardBenchTestRig.epoch), "accepted": true, "reason": "",
        ]))
        let secondBatch = await member.shardCoordinatorMessages(context: context, sessionStarted: false)
        let second = try object(try XCTUnwrap(secondBatch.first))
        XCTAssertEqual(second["role"] as? String, "stage")
        XCTAssertEqual(second["group_epoch"] as? Int, Int(ShardBenchTestRig.epoch) + 1)
        await member.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_member_hello_result", "version": 1, "group_provider_id": "head-device",
            "group_epoch": Int(ShardBenchTestRig.epoch) + 1, "accepted": false, "reason": "group_not_registered",
        ]))
        let held = await member.takeoverState
        XCTAssertEqual(held, .awaitingRegistration)
        // No hello is due any more; the member's own health goes out on every tick.
        let quiet = await member.shardCoordinatorMessages(context: context, sessionStarted: false)
        XCTAssertEqual(try quiet.map { try object($0)["type"] as? String }, ["shard_member_health"])
        let health = try object(try XCTUnwrap(quiet.first))
        XCTAssertEqual(health["group_epoch"] as? Int, Int(ShardBenchTestRig.epoch), "a spare reports under its own hello's epoch")
        XCTAssertEqual(health["healthy"] as? Bool, true)
        XCTAssertEqual((health["links"] as? [[String: Any]])?.map { $0["peer_member_device_id"] as? String }, ["head-device"])
    }

    func testACompletionWaitsForItsTakeoverEpochToBeAccepted() async throws {
        let runtime = try await runtime()
        let context = ShardCoordinatorContext(providerID: "prov-head", wireModelID: "wire/model")
        _ = await runtime.shardCoordinatorMessages(context: context, sessionStarted: true)
        func accept(_ epoch: UInt64) async throws {
            await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
                "type": "shard_group_register_result", "version": 1, "group_provider_id": "prov-head",
                "group_epoch": Int(epoch), "accepted": true, "reason": "",
            ]))
        }
        try await accept(ShardBenchTestRig.epoch)
        let started = Date()
        await runtime.awaitEpochAccepted(ShardBenchTestRig.epoch)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "an accepted epoch does not wait")
        let waiter = Task { await runtime.awaitEpochAccepted(ShardBenchTestRig.epoch + 1) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try await accept(ShardBenchTestRig.epoch + 1)
        await waiter.value
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 2, "the completion goes as soon as the takeover epoch is accepted")
        await runtime.stop()
    }

    // MARK: Epochs after a takeover (SPEC-051-R023)

    private func registerResult(_ runtime: ShardGroupRuntime, epoch: UInt64, accepted: Bool, reason: String = "") async throws {
        await runtime.handleShardCoordinatorMessage(try JSONSerialization.data(withJSONObject: [
            "type": "shard_group_register_result", "version": 1, "group_provider_id": "prov-head",
            "group_epoch": Int(epoch), "accepted": accepted, "reason": reason,
        ]))
    }

    private func waitForEngineEpoch(_ runtime: ShardGroupRuntime, _ epoch: UInt64) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let status = await runtime.engineStatus, status.running, status.groupEpoch == epoch { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let status = await runtime.engineStatus
        XCTFail("engine at \(String(describing: status?.groupEpoch)) running=\(String(describing: status?.running)), expected \(epoch)")
    }

    func testARebuildAfterATakeoverRegistersAboveTheTakeoverEpoch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("shard-rebuild-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ShardGroupEpochStore.defaultStore(groupProviderID: "prov-head", home: home)
        let tailLinks = ShardTestLinksBox()
        let built = ShardTestEpochLog()
        let runtime = try await runtime(tailLinks: tailLinks, epochStore: store, builtEpochs: built)
        let context = ShardCoordinatorContext(providerID: "prov-head", wireModelID: "wire/model")
        XCTAssertEqual(built.all, [ShardBenchTestRig.epoch])
        _ = await runtime.shardCoordinatorMessages(context: context, sessionStarted: true)
        try await registerResult(runtime, epoch: ShardBenchTestRig.epoch, accepted: true)
        // The takeover epoch was registered too.
        let takeover = ShardBenchTestRig.epoch + 1
        try await registerResult(runtime, epoch: takeover, accepted: true)
        XCTAssertEqual(try store.lastRegisteredEpoch(), takeover)

        // The chain fails; the rebuild runs above every accepted epoch and registers it.
        tailLinks.links?.close()
        try await waitForEngineEpoch(runtime, takeover + 1)
        XCTAssertEqual(built.all.last, takeover + 1)
        let messages = await runtime.shardCoordinatorMessages(context: context, sessionStarted: false)
        let register = try object(try XCTUnwrap(messages.first))
        XCTAssertEqual(register["type"] as? String, "shard_group_register")
        XCTAssertEqual((register["record"] as? [String: Any])?["group_epoch"] as? Int, Int(takeover + 1))
        await runtime.stop()

        // A restarted head reads the state file and starts above it.
        let restartedBuilt = ShardTestEpochLog()
        let restarted = try await self.runtime(epochStore: store, builtEpochs: restartedBuilt)
        XCTAssertEqual(restartedBuilt.all, [takeover + 1])
        await restarted.stop()
    }

    func testAnEpochTheCoordinatorAlreadySawRebuildsTheChainAboveIt() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("shard-seen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ShardGroupEpochStore.defaultStore(groupProviderID: "prov-head", home: home)
        let built = ShardTestEpochLog()
        let runtime = try await runtime(epochStore: store, builtEpochs: built)
        let context = ShardCoordinatorContext(providerID: "prov-head", wireModelID: "wire/model")
        _ = await runtime.shardCoordinatorMessages(context: context, sessionStarted: true)
        try await registerResult(runtime, epoch: ShardBenchTestRig.epoch, accepted: false, reason: "epoch_not_increasing")
        XCTAssertEqual(try store.lastRegisteredEpoch(), ShardBenchTestRig.epoch)
        try await waitForEngineEpoch(runtime, ShardBenchTestRig.epoch + 1)
        XCTAssertEqual(built.all, [ShardBenchTestRig.epoch, ShardBenchTestRig.epoch + 1])
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
            artifactHash: String(repeating: "d", count: 64), weightsVerified: true, stageFits: true)))
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
            config: config, status: middle, memberDeviceID: "mac-b", artifactHashAlgorithm: "a", artifactHash: "b",
            weightsVerified: true, stageFits: true)))
        XCTAssertEqual((threeStage["links"] as? [[String: String]])?.map { $0["peer_member_device_id"] }, ["prov-head", "mac-c"])

        var idle = joined
        idle.upstreamPeer = nil
        XCTAssertNil(try ShardGroupWire.memberHello(
            config: config, status: idle, memberDeviceID: "mac-b", artifactHashAlgorithm: "a", artifactHash: "b",
            weightsVerified: true, stageFits: true),
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

final class ShardTestLinksBox: @unchecked Sendable {
    var links: ShardBenchLinks?
}

final class ShardTestMessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages = [Data]()

    func append(_ batch: [Data]) {
        lock.lock()
        messages.append(contentsOf: batch)
        lock.unlock()
    }

    var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    var count: Int { all.count }
}

final class ShardTestEpochLog: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs = [UInt64]()

    func append(_ epoch: UInt64) {
        lock.lock()
        epochs.append(epoch)
        lock.unlock()
    }

    var all: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return epochs
    }
}
