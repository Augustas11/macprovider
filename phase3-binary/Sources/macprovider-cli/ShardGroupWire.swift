import CryptoKit
import Foundation
import MacProviderCore

// Issue #2084 provider half of the SPEC-051-R029 group wire messages and the
// SPEC-051-R019 group attestation, matching the coordinator's
// `internal/shardgroup` decoders: the head registers each epoch's group record
// signed with its receipt key and heartbeats member health and links; a member
// sends its hello on its own (never routable) session; the coordinator answers
// with register, status and hello results. Strings and integers are built so the
// JCS bytes the coordinator re-canonicalizes are exactly the signed ones.

enum ShardGroupWire {
    static let headCapability = "shard_group_head_v1"
    static let memberCapability = "shard_member_v1"
    static let version = 1
    static let recordSchema = "macprovider.shard-group-record.v1"
    static let attestationSchema = "macprovider.shard-group-attestation.v1"
    static let recordDomain = "macprovider.shard-group-record.v1\n"
    static let attestationDomain = "macprovider.shard-group-attestation.v1\n"
    /// Coordinator to provider message types this layer handles.
    static let inboundTypes: Set<String> = ["shard_group_register_result", "shard_group_status", "shard_member_hello_result"]
    /// SPEC-051-R021, R022: the end-frame status of a group failure.
    static let failureStatus = "error_shard_group_failed"

    enum WireError: Error, Equatable, CustomStringConvertible {
        case receiptMalformed
        case receiptMismatch(String)

        var description: String {
            switch self {
            case .receiptMalformed: return "the receipt envelope is not base64(tuple).base64(signature)"
            case .receiptMismatch(let detail): return "the receipt does not match the group evidence: \(detail)"
            }
        }
    }

    // MARK: Encoding helpers

    /// JSON object (JSONSerialization form) of a JCS value.
    static func jsonObject(_ value: RFC8785JCS.Value) -> Any {
        switch value {
        case .object(let object): return object.mapValues { jsonObject($0) }
        case .array(let array): return array.map { jsonObject($0) }
        case .string(let string), .rawString(let string): return string
        case .int(let int): return int
        case .double(let double): return double
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }

    static func message(_ value: RFC8785JCS.Value) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(value), options: [.sortedKeys])
    }

    /// Ed25519 signature (base64) over `domain || JCS(value)`, strings kept as sent
    /// (the coordinator canonicalizes with raw strings too).
    static func sign(_ value: RFC8785JCS.Value, domain: String, key: Curve25519.Signing.PrivateKey) throws -> String {
        let canonical = try RFC8785JCS.canonicalStringRawStrings(value)
        return try key.signature(for: Data((domain + canonical).utf8)).base64EncodedString()
    }

    static func subReceiptValue(_ signed: ShardSignedSubReceipt) -> RFC8785JCS.Value {
        let receipt = signed.receipt
        return .object([
            "sub_receipt": .object([
                "member_device_id": .string(receipt.memberDeviceID),
                "group_epoch": .int(Int(receipt.groupEpoch)),
                "stage_index": .int(receipt.stageIndex),
                "layer_start": .int(receipt.layerStart),
                "layer_end": .int(receipt.layerEnd),
                "request_id": .string(receipt.requestID),
                "prompt_tokens": .int(receipt.promptTokens),
                "decode_steps": .int(receipt.decodeSteps),
                "in_digest": .string(receipt.inDigest),
                "out_digest": .string(receipt.outDigest),
            ]),
            "public_key": .string(signed.publicKey),
            "signature": .string(signed.signature),
        ])
    }

    // MARK: Group attestation (SPEC-051-R019)

    /// The `group_attestation` member of the end frame carrying `receipt`: bound to
    /// the SHA-256 of the receipt's tuple bytes and to its request id, attempt and
    /// provider id, one segment covering every token step in the request's final
    /// epoch, signed with the head's receipt key.
    static func attestation(
        receipt: String, evidence: ShardGroupCompletionEvidence, key: Curve25519.Signing.PrivateKey
    ) throws -> [String: Any] {
        let parts = receipt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let tuple = Data(base64Encoded: String(parts[0])),
              let facts = try? JSONSerialization.jsonObject(with: tuple) as? [String: Any],
              let requestID = facts["request_id"] as? String, let providerID = facts["provider_id"] as? String
        else {
            throw WireError.receiptMalformed
        }
        let attemptN = (facts["attempt_n"] as? NSNumber)?.intValue ?? 0
        let receipts = evidence.attestation.receipts
        guard let head = receipts.first, head.receipt.memberDeviceID == providerID else {
            throw WireError.receiptMismatch("stage 0 is \(receipts.first?.receipt.memberDeviceID ?? "missing"), the receipt names \(providerID)")
        }
        guard receipts.allSatisfy({ $0.receipt.requestID == requestID }) else {
            throw WireError.receiptMismatch("sub-receipts name another request than \(requestID)")
        }
        guard head.publicKey == key.publicKey.rawRepresentation.base64EncodedString() else {
            throw WireError.receiptMismatch("stage 0 was signed with another key than the receipt key")
        }
        let digest = SHA256.hash(data: tuple).map { String(format: "%02x", $0) }.joined()
        let unsigned: [String: RFC8785JCS.Value] = [
            "schema": .string(attestationSchema),
            "group_provider_id": .string(providerID),
            "request_id": .string(requestID),
            "attempt_n": .int(attemptN),
            "receipt_tuple_sha256": .string(digest),
            "segments": .array([.object([
                "group_epoch": .int(Int(evidence.attestation.groupEpoch)),
                "step_start": .int(0),
                "step_end": .int(evidence.tokenSteps),
                "sub_receipts": .array(receipts.map(subReceiptValue)),
            ])]),
        ]
        var signed = unsigned
        signed["signature"] = .string(try sign(.object(unsigned), domain: attestationDomain, key: key))
        guard let object = jsonObject(.object(signed)) as? [String: Any] else { throw WireError.receiptMalformed }
        return object
    }

    // MARK: Head messages

    /// The SPEC-051-R005 group record of a running chain.
    static func record(
        config: ShardGroupHeadConfig, chain: [ShardBenchHello], groupEpoch: UInt64, providerID: String, wireModelID: String,
        poolModelID: String, artifactHashAlgorithm: String, artifactHash: String
    ) throws -> RFC8785JCS.Value {
        let stages = try chain.enumerated().map { index, hello -> RFC8785JCS.Value in
            guard let member = hello.memberDeviceID else {
                throw ShardGroupConfigError.invalid("stage \(index) has no member device id")
            }
            return .object([
                "stage_index": .int(index), "member_device_id": .string(index == 0 ? providerID : member),
                "layer_start": .int(hello.layerStart), "layer_end": .int(hello.layerEnd),
            ])
        }
        let supervision = config.supervision
        return .object([
            "schema": .string(recordSchema),
            "group_provider_id": .string(providerID),
            "group_epoch": .int(Int(groupEpoch)),
            "parallelism_mode": .string("pipeline"),
            "interconnect_class": .string(config.interconnectClass.rawValue),
            "frame_protection": .string(config.frameProtection.rawValue),
            "transport_version": .int(Int(ShardStageFrameCodec.version)),
            "model": .object([
                "model_id": .string(wireModelID), "pool_model_id": .string(poolModelID),
                "artifact_hash_algorithm": .string(artifactHashAlgorithm), "artifact_hash": .string(artifactHash),
            ]),
            "num_layers": .int(config.numLayers),
            "max_concurrency": .int(config.maxConcurrency),
            "stages": .array(stages),
            "spares": .array([]),
            "supervision": .object([
                "heartbeat_interval_ms": .int(supervision.heartbeatIntervalMilliseconds),
                "heartbeat_miss_limit": .int(supervision.heartbeatMissLimit),
                "decode_hop_deadline_ms": .int(supervision.decodeHopDeadlineMilliseconds),
                "prefill_chunk_deadline_ms": .int(supervision.prefillChunkDeadlineMilliseconds),
                "replay_deadline_ms": .int(supervision.replayDeadlineMilliseconds),
            ]),
        ])
    }

    static func register(record: RFC8785JCS.Value, key: Curve25519.Signing.PrivateKey) throws -> Data {
        try message(.object([
            "type": .string("shard_group_register"),
            "version": .int(version),
            "record": record,
            "record_signature": .string(try sign(record, domain: recordDomain, key: key)),
        ]))
    }

    /// Links of a chain as the receiving end measured them in the handshake: stage i
    /// to i+1, then the last stage back to stage 0.
    static func links(chain: [ShardBenchHello], providerID: String) -> [RFC8785JCS.Value] {
        guard chain.count >= 2 else { return [] }
        func member(_ index: Int) -> String { index == 0 ? providerID : chain[index].memberDeviceID ?? "" }
        func microseconds(_ latency: ShardBenchLatency?) -> Int {
            min(Int((latency?.p99Microseconds ?? 0).rounded(.up)), 1 << 53 - 1)
        }
        var links = (1..<chain.count).map { index -> RFC8785JCS.Value in
            .object([
                "from_member_device_id": .string(member(index - 1)), "to_member_device_id": .string(member(index)),
                "interface_type": .string(chain[index].upstreamInterface ?? ShardLinkInterface.other),
                "rtt_p99_us": .int(microseconds(chain[index].upstreamProbe)),
            ])
        }
        let last = chain.count - 1
        // A two-stage chain returns tokens on the same link it sends activations on.
        let collapsed = last == 1 && chain[last].returnProbe == nil
        links.append(.object([
            "from_member_device_id": .string(member(last)), "to_member_device_id": .string(member(0)),
            "interface_type": .string((collapsed ? chain[last].upstreamInterface : chain[last].returnInterface) ?? ShardLinkInterface.other),
            "rtt_p99_us": .int(microseconds(collapsed ? chain[last].upstreamProbe : chain[last].returnProbe)),
        ]))
        return links
    }

    static func heartbeat(chain: [ShardBenchHello], groupEpoch: UInt64, providerID: String, healthy: Bool) throws -> Data {
        let members = chain.indices.map { index -> RFC8785JCS.Value in
            .object([
                "member_device_id": .string(index == 0 ? providerID : chain[index].memberDeviceID ?? ""),
                "healthy": .bool(healthy),
            ])
        }
        return try message(.object([
            "type": .string("shard_group_heartbeat"),
            "version": .int(version),
            "group_provider_id": .string(providerID),
            "group_epoch": .int(Int(groupEpoch)),
            "members": .array(members),
            "links": .array(links(chain: chain, providerID: providerID)),
        ]))
    }

    // MARK: Member message

    static func memberHello(
        config: ShardMemberConfig, status: ShardMemberStatus, memberDeviceID: String,
        artifactHashAlgorithm: String, artifactHash: String
    ) throws -> Data? {
        guard let upstream = status.upstreamPeer, let downstream = status.downstreamPeer,
              let upstreamInterface = status.upstreamInterface, let downstreamInterface = status.downstreamInterface
        else { return nil }
        var links: [RFC8785JCS.Value] = [.object([
            "peer_member_device_id": .string(upstream), "interface_type": .string(upstreamInterface),
        ])]
        if downstream != upstream {
            links.append(.object([
                "peer_member_device_id": .string(downstream), "interface_type": .string(downstreamInterface),
            ]))
        }
        return try message(.object([
            "type": .string("shard_member_hello"),
            "version": .int(version),
            "group_provider_id": .string(config.groupProviderID),
            "group_epoch": .int(Int(config.groupEpoch)),
            "member_device_id": .string(memberDeviceID),
            "role": .string(config.role.rawValue),
            "stage_index": .int(config.stageIndex),
            "layer_start": .int(config.layerStart),
            "layer_end": .int(config.layerEnd),
            "transport_version": .int(Int(ShardStageFrameCodec.version)),
            "artifact_hash_algorithm": .string(artifactHashAlgorithm),
            "artifact_hash": .string(artifactHash),
            "weights_verified": .bool(true),
            "stage_fits": .bool(true),
            "links": .array(links),
        ]))
    }

    // MARK: Coordinator answers

    struct Result: Decodable, Equatable {
        let type: String
        let version: Int
        let groupProviderID: String
        let groupEpoch: UInt64
        let accepted: Bool?
        let available: Bool?
        let reason: String

        enum CodingKeys: String, CodingKey {
            case type, version, accepted, available, reason
            case groupProviderID = "group_provider_id"
            case groupEpoch = "group_epoch"
        }
    }

    static func decodeResult(_ data: Data) -> Result? {
        guard let result = try? JSONDecoder().decode(Result.self, from: data), result.version == version else { return nil }
        switch result.type {
        case "shard_group_register_result", "shard_member_hello_result":
            return result.accepted == nil ? nil : result
        case "shard_group_status":
            return result.available == nil ? nil : result
        default:
            return nil
        }
    }
}

/// What the coordinator client tells a shard participant about its session.
struct ShardCoordinatorContext: Sendable {
    let providerID: String
    /// The model id the session's hello names.
    let wireModelID: String
}

/// A runtime that speaks the SPEC-051-R029 group messages on its coordinator session.
protocol ShardGroupCoordinatorParticipant: Actor {
    nonisolated var shardCapability: String { get }
    /// Messages to send now, JSON encoded: called when a session is accepted
    /// (`sessionStarted`) and on every heartbeat tick.
    func shardCoordinatorMessages(context: ShardCoordinatorContext, sessionStarted: Bool) async -> [Data]
    func handleShardCoordinatorMessage(_ data: Data) async
}

/// The head's registration inputs: its group config and the receipt key it signs with.
struct ShardGroupRegistration: Sendable {
    let config: ShardGroupHeadConfig
    let signer: ShardMemberSigner
}

extension ShardGroupRuntime: ShardGroupCoordinatorParticipant {
    nonisolated var shardCapability: String { ShardGroupWire.headCapability }

    func shardCoordinatorMessages(context: ShardCoordinatorContext, sessionStarted: Bool) async -> [Data] {
        if sessionStarted { resetCoordinatorSession() }
        guard let registration, let status = engineStatus, status.running, !status.chain.isEmpty else { return [] }
        if let problem = registrationProblem(registration, context: context) {
            warnOnce(problem)
            return []
        }
        do {
            if acceptedEpoch == status.groupEpoch {
                return [try ShardGroupWire.heartbeat(
                    chain: status.chain, groupEpoch: status.groupEpoch, providerID: context.providerID, healthy: true)]
            }
            let now = Date()
            if registerSent?.epoch == status.groupEpoch, let at = registerSent?.at, now.timeIntervalSince(at) < 15 { return [] }
            let record = try ShardGroupWire.record(
                config: registration.config, chain: status.chain, groupEpoch: status.groupEpoch,
                providerID: context.providerID, wireModelID: context.wireModelID,
                poolModelID: registration.config.poolModelID ?? "", artifactHashAlgorithm: identity.modelHashAlgorithm ?? "",
                artifactHash: identity.modelHash ?? "")
            registerSent = (status.groupEpoch, now)
            shardGroupLog("registering group epoch \(status.groupEpoch)")
            return [try ShardGroupWire.register(record: record, key: registration.signer.key)]
        } catch {
            warnOnce("group message not built: \(error)")
            return []
        }
    }

    func handleShardCoordinatorMessage(_ data: Data) async {
        guard let result = ShardGroupWire.decodeResult(data), result.groupProviderID == registration?.signer.memberDeviceID else {
            shardGroupLog("ignored a malformed or foreign group message")
            return
        }
        switch result.type {
        case "shard_group_register_result":
            if result.accepted == true {
                acceptedEpoch = result.groupEpoch
                shardGroupLog("group epoch \(result.groupEpoch) registered")
            } else {
                registerSent = nil
                shardGroupLog("group epoch \(result.groupEpoch) refused: \(result.reason)")
                if gate != .notRequired { setGate(.unavailable("registration refused: \(result.reason)")) }
            }
        case "shard_group_status":
            guard gate != .notRequired, result.groupEpoch == acceptedEpoch else { return }
            setGate(result.available == true ? .available : .unavailable(result.reason))
        default:
            return
        }
    }

    private func registrationProblem(_ registration: ShardGroupRegistration, context: ShardCoordinatorContext) -> String? {
        if registration.signer.memberDeviceID != context.providerID {
            return "the head signs as \(registration.signer.memberDeviceID) but its session is \(context.providerID); not registering"
        }
        if registration.config.spare != nil {
            return "a group with a spare cannot register with a coordinator yet (its spare link is not measured); not registering"
        }
        if registration.config.poolModelID == nil {
            return "the group config names no pool_model_id; not registering"
        }
        if identity.modelHash == nil || identity.modelHashAlgorithm == nil {
            return "the model has no verified catalog artifact; not registering"
        }
        return nil
    }
}

extension ShardMemberRuntime: ShardGroupCoordinatorParticipant {
    nonisolated var shardCapability: String { ShardGroupWire.memberCapability }

    func shardCoordinatorMessages(context: ShardCoordinatorContext, sessionStarted: Bool) async -> [Data] {
        if sessionStarted { helloState = .notSent }
        guard memberDeviceID == context.providerID, let hash = identity.modelHash, let algorithm = identity.modelHashAlgorithm else {
            return []
        }
        switch helloState {
        case .accepted, .awaitingRegistration:
            return []
        case .sent(let at) where Date().timeIntervalSince(at) < 30:
            return []
        case .notSent, .sent:
            break
        }
        let status = server.status
        guard let hello = try? ShardGroupWire.memberHello(
            config: config, status: status, memberDeviceID: memberDeviceID, artifactHashAlgorithm: algorithm, artifactHash: hash)
        else { return [] }
        helloState = .sent(Date())
        return [hello]
    }

    func handleShardCoordinatorMessage(_ data: Data) async {
        guard let result = ShardGroupWire.decodeResult(data), result.type == "shard_member_hello_result",
              result.groupProviderID == config.groupProviderID
        else {
            shardGroupLog("ignored a malformed or foreign group message")
            return
        }
        if result.accepted == true {
            helloState = .accepted
            shardGroupLog("member hello accepted for epoch \(result.groupEpoch)")
        } else if result.reason == "group_not_registered" {
            // The coordinator keeps the hello and answers again at registration.
            helloState = .awaitingRegistration
        } else {
            helloState = .sent(Date())
            shardGroupLog("member hello refused: \(result.reason)")
        }
    }
}
