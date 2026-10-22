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
    /// Bound on change-triggered group messages: at most four a second, on top of
    /// the one per coordinator heartbeat tick.
    static let minimumChangeInterval: TimeInterval = 0.25
    /// How often a participant looks for a change to report.
    static let changePollInterval: TimeInterval = 0.1

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

    /// The closed SPEC-051-R019 takeover reason for the stage loss a spare replaced.
    static func takeoverReason(_ cause: Error) -> String {
        switch cause {
        case ShardLinkError.peerClosed: return "peer_closed"
        case ShardLinkError.peerDead: return "peer_dead"
        case ShardLinkError.receiveTimedOut, ShardLinkError.sendTimedOut, is ShardGroupEngineFault: return "deadline_missed"
        case ShardBenchError.peerError: return "peer_error"
        default: return "link_error"
        }
    }

    /// The `group_attestation` member of the end frame carrying `receipt`: bound to
    /// the SHA-256 of the receipt's tuple bytes and to its request id, attempt and
    /// provider id, one segment covering every token step in the request's final
    /// epoch, signed with the head's receipt key. When a spare took over during the
    /// request the segment is the new epoch's from step 0 (the spare recomputed the
    /// whole prefix) and `takeover` names the epoch it replaced and why.
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
        var unsignedObject = unsigned
        if let replay = evidence.attestation.replays.last(where: { $0.groupEpoch == evidence.attestation.groupEpoch }),
           replay.groupEpoch > 1 {
            unsignedObject["takeover"] = .object([
                "from_group_epoch": .int(Int(replay.groupEpoch - 1)), "reason": .string(replay.reason),
            ])
        }
        var signed = unsignedObject
        signed["signature"] = .string(try sign(.object(unsignedObject), domain: attestationDomain, key: key))
        guard let object = jsonObject(.object(signed)) as? [String: Any] else { throw WireError.receiptMalformed }
        return object
    }

    // MARK: Head messages

    /// The SPEC-051-R005 group record of a running chain. `spareMemberID` names the
    /// spare backing stage 1 while it has not taken over.
    static func record(
        config: ShardGroupHeadConfig, chain: [ShardBenchHello], groupEpoch: UInt64, providerID: String, wireModelID: String,
        poolModelID: String, artifactHashAlgorithm: String, artifactHash: String, spareMemberID: String? = nil
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
            "spares": .array(spareMemberID.map { [.object(["member_device_id": .string($0), "stage_index": .int(1)])] } ?? []),
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

    /// One SPEC-051-R029 heartbeat link as the head reports it.
    struct LinkReport: Equatable, Sendable {
        let from: String
        let to: String
        /// Stage index of the link's receiving end (the member it is measured toward).
        let toStage: Int
        let interfaceType: String
        let rttP99Microseconds: Int
        /// False when the member relaying this link's measurement stopped reporting it.
        let fresh: Bool
    }

    /// The required links of a chain: stage i to i+1, then the last stage back to
    /// stage 0. Round trips are the live sliding p99s (SPEC-051-R007): the head's own
    /// for its two links, the relayed member measurements for the others, and the
    /// handshake probe until a link has one. A relayed report older than `staleAfter`
    /// keeps its last value and marks the link not fresh.
    /// The head-to-spare link of a record with a spare, as the standby link measures
    /// it; not fresh while the spare is not reachable.
    static func spareLink(providerID: String, spareMemberID: String, health: ShardGroupSpareHealth?) -> LinkReport {
        LinkReport(
            from: providerID, to: spareMemberID, toStage: -1,
            interfaceType: health?.interfaceType ?? ShardLinkInterface.other,
            rttP99Microseconds: health?.roundTrip?.p99Microseconds ?? 0, fresh: health?.alive ?? false)
    }

    static func linkReports(
        chain: [ShardBenchHello], providerID: String, health: ShardGroupLinkHealth?, now: TimeInterval, staleAfter: TimeInterval
    ) -> [LinkReport] {
        guard chain.count >= 2 else { return [] }
        func member(_ index: Int) -> String { index == 0 ? providerID : chain[index].memberDeviceID ?? "" }
        func microseconds(_ seconds: Double?) -> Int { min(Int(((seconds ?? 0) * 1e6).rounded(.up)), 1 << 53 - 1) }
        func probe(_ latency: ShardBenchLatency?) -> Int { min(Int((latency?.p99Microseconds ?? 0).rounded(.up)), 1 << 53 - 1) }
        func measured(_ roundTrip: ShardLinkRoundTrip?, else fallback: ShardBenchLatency?) -> Int {
            guard let roundTrip, roundTrip.samples > 0 else { return probe(fallback) }
            return microseconds(roundTrip.p99Seconds)
        }
        var reports = (1..<chain.count).map { index -> LinkReport in
            var rtt = probe(chain[index].upstreamProbe)
            var fresh = true
            if index == 1 {
                rtt = measured(health?.downstream, else: chain[index].upstreamProbe)
            } else if let reported = health?.reported(from: index - 1, to: index) {
                rtt = Int(reported.health.rttP99Microseconds)
                fresh = now - reported.at <= staleAfter
            }
            return LinkReport(
                from: member(index - 1), to: member(index), toStage: index,
                interfaceType: chain[index].upstreamInterface ?? ShardLinkInterface.other, rttP99Microseconds: rtt, fresh: fresh)
        }
        let last = chain.count - 1
        // A two-stage chain returns tokens on the same link it sends activations on.
        let collapsed = last == 1 && chain[last].returnProbe == nil
        reports.append(LinkReport(
            from: member(last), to: member(0), toStage: 0,
            interfaceType: (collapsed ? chain[last].upstreamInterface : chain[last].returnInterface) ?? ShardLinkInterface.other,
            rttP99Microseconds: collapsed
                ? measured(health?.downstream, else: chain[last].upstreamProbe)
                : measured(health?.upstream, else: chain[last].returnProbe),
            fresh: true))
        return reports
    }

    /// SPEC-051-R015 member health as the head sees it: every member is healthy while
    /// the chain runs, except the receiving member of a link whose relayed report went stale.
    static func memberHealth(chainCount: Int, running: Bool, links: [LinkReport]) -> [Bool] {
        (0..<chainCount).map { index in
            running && (index == 0 || links.allSatisfy { $0.toStage != index || $0.fresh })
        }
    }

    /// What a heartbeat says, coarsened so that only a health, interface or
    /// round-trip change of about a fifth or more counts as a change.
    struct HealthSignature: Equatable, Sendable {
        let epoch: UInt64
        let members: [Bool]
        let links: [String]

        init(epoch: UInt64, members: [Bool], links: [LinkReport]) {
            self.epoch = epoch
            self.members = members
            self.links = links.map { link in
                // Quarter-octave buckets: 1.19x steps.
                let bucket = Int((log2(Double(max(1, link.rttP99Microseconds))) * 4).rounded(.up))
                return "\(link.from)>\(link.to) \(link.interfaceType) \(bucket) \(link.fresh)"
            }
        }
    }

    /// `members` holds the chain's members in stage order, then the spare when the
    /// record has one (`spareMemberID`); `links` the chain's links, then the spare's.
    static func heartbeat(
        groupEpoch: UInt64, providerID: String, chain: [ShardBenchHello], members: [Bool], links: [LinkReport],
        spareMemberID: String? = nil
    ) throws -> Data {
        let ids = chain.indices.map { $0 == 0 ? providerID : chain[$0].memberDeviceID ?? "" } + (spareMemberID.map { [$0] } ?? [])
        let memberValues = ids.indices.map { index -> RFC8785JCS.Value in
            .object([
                "member_device_id": .string(ids[index]),
                "healthy": .bool(members.indices.contains(index) && members[index]),
            ])
        }
        let linkValues = links.map { link -> RFC8785JCS.Value in
            .object([
                "from_member_device_id": .string(link.from), "to_member_device_id": .string(link.to),
                "interface_type": .string(link.interfaceType), "rtt_p99_us": .int(link.rttP99Microseconds),
            ])
        }
        return try message(.object([
            "type": .string("shard_group_heartbeat"),
            "version": .int(version),
            "group_provider_id": .string(providerID),
            "group_epoch": .int(Int(groupEpoch)),
            "members": .array(memberValues),
            "links": .array(linkValues),
        ]))
    }

    // MARK: Member message

    /// `weightsVerified` and `stageFits` are what the member proved before loading
    /// (`ShardGroupServe.proveStage`); the coordinator accepts only both true.
    ///
    /// A spare's `takeover` hello names the epoch its takeover starts as an ordinary
    /// stage, so the coordinator keeps it and binds the spare's key when the head
    /// registers that epoch.
    static func memberHello(
        config: ShardMemberConfig, status: ShardMemberStatus, memberDeviceID: String,
        artifactHashAlgorithm: String, artifactHash: String, weightsVerified: Bool, stageFits: Bool, takeover: Bool = false
    ) throws -> Data? {
        guard !takeover || config.role == .spare else { return nil }
        // The epoch of the head this member joined (`ShardMemberStatus.groupEpoch`);
        // a spare's standby link runs at its takeover epoch.
        let joined = status.groupEpoch ?? config.linkEpoch
        let epoch = config.role == .spare && !takeover ? joined - 1 : joined
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
            "group_epoch": .int(Int(epoch)),
            "member_device_id": .string(memberDeviceID),
            "role": .string(takeover ? ShardMemberConfig.Role.stage.rawValue : config.role.rawValue),
            "stage_index": .int(config.stageIndex),
            "layer_start": .int(config.layerStart),
            "layer_end": .int(config.layerEnd),
            "transport_version": .int(Int(ShardStageFrameCodec.version)),
            "artifact_hash_algorithm": .string(artifactHashAlgorithm),
            "artifact_hash": .string(artifactHash),
            "weights_verified": .bool(weightsVerified),
            "stage_fits": .bool(stageFits),
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
    /// (`sessionStarted`), on every heartbeat tick, and when the participant's
    /// change handler asks for it.
    func shardCoordinatorMessages(context: ShardCoordinatorContext, sessionStarted: Bool) async -> [Data]
    func handleShardCoordinatorMessage(_ data: Data) async
    /// The participant calls `handler` when what it would report changed (SPEC-051-R029:
    /// the group heartbeat goes out immediately on a member health or link change),
    /// at most once per `ShardGroupWire.minimumChangeInterval`.
    func setShardChangeHandler(_ handler: (@Sendable () async -> Void)?) async
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
        guard let registration, let status = engineStatus, !status.chain.isEmpty else { return [] }
        if let problem = registrationProblem(registration, context: context) {
            warnOnce(problem)
            return []
        }
        do {
            if acceptedEpoch == status.groupEpoch {
                // A chain that went down still reports, with its members unhealthy, so
                // the coordinator stops routing before the next reservation.
                let view = healthView(status, providerID: context.providerID)
                reportedHealth = view.signature
                return [try ShardGroupWire.heartbeat(
                    groupEpoch: status.groupEpoch, providerID: context.providerID, chain: status.chain,
                    members: view.members, links: view.links, spareMemberID: spareMemberID(status))]
            }
            guard status.running else { return [] }
            let now = Date()
            if registerSent?.epoch == status.groupEpoch, let at = registerSent?.at, now.timeIntervalSince(at) < 15 { return [] }
            let record = try ShardGroupWire.record(
                config: registration.config, chain: status.chain, groupEpoch: status.groupEpoch,
                providerID: context.providerID, wireModelID: context.wireModelID,
                poolModelID: registration.config.poolModelID ?? "", artifactHashAlgorithm: identity.modelHashAlgorithm ?? "",
                artifactHash: identity.modelHash ?? "", spareMemberID: spareMemberID(status))
            registerSent = (status.groupEpoch, now)
            shardGroupLog("registering group epoch \(status.groupEpoch)")
            return [try ShardGroupWire.register(record: record, key: registration.signer.key)]
        } catch {
            warnOnce("group message not built: \(error)")
            return []
        }
    }

    func setShardChangeHandler(_ handler: (@Sendable () async -> Void)?) async {
        changeHandler = handler
        startChangeMonitor()
    }

    /// The spare the record of this epoch names: the configured one until it took over.
    func spareMemberID(_ status: ShardGroupEngineStatus) -> String? {
        status.replays == 0 ? registration?.config.spare?.memberDeviceID : nil
    }

    /// The members and links the next heartbeat reports, and their signature. A
    /// spare is healthy while its standby link is up; its health never stops the
    /// group serving (SPEC-051-R015), only a takeover.
    func healthView(_ status: ShardGroupEngineStatus, providerID: String) -> (members: [Bool], links: [ShardGroupWire.LinkReport], signature: ShardGroupWire.HealthSignature) {
        let supervision = registration?.config.supervision ?? .defaults
        // A relayed report crosses one hop per heartbeat interval.
        let staleAfter = max(1, Double(supervision.heartbeatIntervalMilliseconds) / 1000
            * Double(supervision.heartbeatMissLimit + status.chain.count))
        var links = ShardGroupWire.linkReports(
            chain: status.chain, providerID: providerID, health: status.links,
            now: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9, staleAfter: staleAfter)
        var members = ShardGroupWire.memberHealth(chainCount: status.chain.count, running: status.running, links: links)
        if let spare = spareMemberID(status) {
            let link = ShardGroupWire.spareLink(providerID: providerID, spareMemberID: spare, health: status.spare)
            links.append(link)
            members.append(status.running && link.fresh)
        }
        return (members, links, ShardGroupWire.HealthSignature(epoch: status.groupEpoch, members: members, links: links))
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
                noteRegisteredEpoch(result.groupEpoch)
                shardGroupLog("group epoch \(result.groupEpoch) registered")
            } else {
                registerSent = nil
                shardGroupLog("group epoch \(result.groupEpoch) refused: \(result.reason)")
                if gate != .notRequired { setGate(.unavailable("registration refused: \(result.reason)")) }
                if result.reason == "epoch_not_increasing" { rebuildAboveSeenEpoch(result.groupEpoch) }
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

    func setShardChangeHandler(_ handler: (@Sendable () async -> Void)?) async {
        changeHandler = handler
        startChangeMonitor()
    }

    func shardCoordinatorMessages(context: ShardCoordinatorContext, sessionStarted: Bool) async -> [Data] {
        let status = server.status
        if sessionStarted || status.groupEpoch != helloEpoch {
            helloState = .notSent
            takeoverState = .notSent
            helloEpoch = status.groupEpoch
        }
        guard memberDeviceID == context.providerID, let hash = identity.modelHash, let algorithm = identity.modelHashAlgorithm else {
            return []
        }
        func due(_ state: ShardMemberHelloState) -> Bool {
            switch state {
            case .accepted, .awaitingRegistration: return false
            case .sent(let at): return Date().timeIntervalSince(at) >= 30
            case .notSent: return true
            }
        }
        let takeover: Bool
        if due(helloState) {
            takeover = false
        } else if config.role == .spare, helloState == .accepted, due(takeoverState) {
            takeover = true
        } else {
            return []
        }
        guard let hello = try? ShardGroupWire.memberHello(
            config: config, status: status, memberDeviceID: memberDeviceID, artifactHashAlgorithm: algorithm, artifactHash: hash,
            weightsVerified: stageProof.weightsVerified, stageFits: stageProof.fit.fits, takeover: takeover)
        else { return [] }
        if takeover { takeoverState = .sent(Date()) } else { helloState = .sent(Date()) }
        return [hello]
    }

    func handleShardCoordinatorMessage(_ data: Data) async {
        guard let result = ShardGroupWire.decodeResult(data), result.type == "shard_member_hello_result",
              result.groupProviderID == config.groupProviderID
        else {
            shardGroupLog("ignored a malformed or foreign group message")
            return
        }
        guard let joined = helloEpoch else {
            shardGroupLog("ignored a member hello result before this member joined a head")
            return
        }
        let epochs = helloEpochs(joined: joined)
        let takeover = epochs.takeover == result.groupEpoch
        guard takeover || result.groupEpoch == epochs.own else {
            shardGroupLog("ignored a member hello result for epoch \(result.groupEpoch)")
            return
        }
        let next: ShardMemberHelloState
        if result.accepted == true {
            next = .accepted
            shardGroupLog("member hello accepted for epoch \(result.groupEpoch)\(takeover ? " (takeover)" : "")")
        } else if result.reason == "group_not_registered" {
            // The coordinator keeps the hello and answers again at registration.
            next = .awaitingRegistration
        } else {
            next = .sent(Date())
            shardGroupLog("member hello for epoch \(result.groupEpoch) refused: \(result.reason)")
        }
        if takeover { takeoverState = next } else { helloState = next }
    }
}
