import Foundation
import MacProviderCore

// Issue #2084 owner-local shard group configuration (SPEC-051 §4). The head reads a
// `macprovider.shard-group-config.v1` file (`serve --shard-group`), each member a
// `macprovider.shard-member-config.v1` file (`serve --shard-member`). Unknown keys,
// missing keys and values outside the SPEC-051 bounds fail the load.

enum ShardGroupConfigError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let detail): return "invalid shard group configuration: \(detail)"
        }
    }
}

private struct ShardConfigKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

private func refuseUnknownKeys(_ decoder: Decoder, known: [String], in object: String) throws {
    let keys = try decoder.container(keyedBy: ShardConfigKey.self).allKeys.map(\.stringValue)
    let unknown = keys.filter { !known.contains($0) }.sorted()
    guard unknown.isEmpty else { throw ShardGroupConfigError.invalid("\(object) has unknown keys \(unknown)") }
}

/// The SPEC-051 §4 group supervision values, carried in the group record.
struct ShardSupervisionConfig: Codable, Equatable, Sendable {
    var heartbeatIntervalMilliseconds: Int
    var heartbeatMissLimit: Int
    var decodeHopDeadlineMilliseconds: Int
    var prefillChunkDeadlineMilliseconds: Int
    var replayDeadlineMilliseconds: Int

    static let defaults = ShardSupervisionConfig(
        heartbeatIntervalMilliseconds: 100, heartbeatMissLimit: 3, decodeHopDeadlineMilliseconds: 500,
        prefillChunkDeadlineMilliseconds: 3000, replayDeadlineMilliseconds: 10000)

    init(
        heartbeatIntervalMilliseconds: Int, heartbeatMissLimit: Int, decodeHopDeadlineMilliseconds: Int,
        prefillChunkDeadlineMilliseconds: Int, replayDeadlineMilliseconds: Int
    ) {
        self.heartbeatIntervalMilliseconds = heartbeatIntervalMilliseconds
        self.heartbeatMissLimit = heartbeatMissLimit
        self.decodeHopDeadlineMilliseconds = decodeHopDeadlineMilliseconds
        self.prefillChunkDeadlineMilliseconds = prefillChunkDeadlineMilliseconds
        self.replayDeadlineMilliseconds = replayDeadlineMilliseconds
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case heartbeatIntervalMilliseconds = "heartbeat_interval_ms"
        case heartbeatMissLimit = "heartbeat_miss_limit"
        case decodeHopDeadlineMilliseconds = "decode_hop_deadline_ms"
        case prefillChunkDeadlineMilliseconds = "prefill_chunk_deadline_ms"
        case replayDeadlineMilliseconds = "replay_deadline_ms"
    }

    init(from decoder: Decoder) throws {
        try refuseUnknownKeys(decoder, known: CodingKeys.allCases.map(\.stringValue), in: "supervision")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        heartbeatIntervalMilliseconds = try container.decode(Int.self, forKey: .heartbeatIntervalMilliseconds)
        heartbeatMissLimit = try container.decode(Int.self, forKey: .heartbeatMissLimit)
        decodeHopDeadlineMilliseconds = try container.decode(Int.self, forKey: .decodeHopDeadlineMilliseconds)
        prefillChunkDeadlineMilliseconds = try container.decode(Int.self, forKey: .prefillChunkDeadlineMilliseconds)
        replayDeadlineMilliseconds = try container.decode(Int.self, forKey: .replayDeadlineMilliseconds)
    }

    func validate() throws {
        for (name, value, range) in [
            ("heartbeat_interval_ms", heartbeatIntervalMilliseconds, 20...1000),
            ("heartbeat_miss_limit", heartbeatMissLimit, 2...10),
            ("decode_hop_deadline_ms", decodeHopDeadlineMilliseconds, 50...2000),
            ("prefill_chunk_deadline_ms", prefillChunkDeadlineMilliseconds, 500...4000),
            ("replay_deadline_ms", replayDeadlineMilliseconds, 1000...30000),
        ] where !range.contains(value) {
            throw ShardGroupConfigError.invalid("supervision.\(name) \(value) is outside \(range.lowerBound)..\(range.upperBound)")
        }
    }

    /// Link supervision for a given epoch. Peer-dead detection arms after the hello.
    /// `adoptsHigherEpoch` (members): `epoch` is the lowest the link accepts.
    func link(epoch: UInt64, frameProtection: ShardLinkFrameProtection = .crc32c, adoptsHigherEpoch: Bool = false) -> ShardLinkConfiguration {
        ShardLinkConfiguration(
            groupEpoch: epoch, heartbeatInterval: Double(heartbeatIntervalMilliseconds) / 1000,
            missedHeartbeatLimit: heartbeatMissLimit, armLivenessOnOpen: false, frameProtection: frameProtection,
            adoptsHigherEpoch: adoptsHigherEpoch)
    }
}

/// SPEC-051-R005 closed enums; this build serves the values it implements.
enum ShardInterconnectClass: String, Codable, Sendable {
    case thunderboltIP = "thunderbolt-ip"
    case ethernet
    case rdmaTB5 = "rdma-tb5"

    /// The SPEC-051-R029 `interface_type` a link of this class must report.
    var requiredInterfaceType: String { self == .ethernet ? "ethernet" : "thunderbolt" }

    /// SPEC-051 §4 `required_frame_protection` defaults: a point-to-point
    /// Thunderbolt cable needs CRC32C, a switched Ethernet segment HMAC-SHA256.
    var minimumFrameProtection: ShardFrameProtection { self == .ethernet ? .hmacSHA256 : .crc32c }
}

enum ShardFrameProtection: String, Codable, Sendable {
    case crc32c
    case hmacSHA256 = "hmac-sha256"
    case aeadChaCha20Poly1305 = "aead-chacha20poly1305"

    /// The link mode serving this value; configuration validation refuses AEAD,
    /// which this build does not implement, before any link opens.
    var linkProtection: ShardLinkFrameProtection { self == .crc32c ? .crc32c : .hmacSHA256 }

    var rank: Int {
        switch self {
        case .crc32c: return 0
        case .hmacSHA256: return 1
        case .aeadChaCha20Poly1305: return 2
        }
    }
}

private func validateMemberID(_ value: String, field: String) throws {
    guard (1...64).contains(value.utf8.count),
          value.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2E || $0 == 0x2D })
    else {
        throw ShardGroupConfigError.invalid("\(field) '\(value)' must match ^[a-zA-Z0-9_.-]{1,64}$")
    }
}

private func validateTransport(_ interconnect: ShardInterconnectClass, _ protection: ShardFrameProtection) throws {
    guard interconnect != .rdmaTB5 else { throw ShardGroupConfigError.invalid("interconnect_class rdma-tb5 is reserved") }
    guard protection != .aeadChaCha20Poly1305 else {
        throw ShardGroupConfigError.invalid("frame_protection aead-chacha20poly1305 is not implemented by this build; use hmac-sha256")
    }
    // SPEC-051-R011: the coordinator refuses a record below its class minimum.
    guard protection.rank >= interconnect.minimumFrameProtection.rank else {
        throw ShardGroupConfigError.invalid("frame_protection \(protection.rawValue) is below the \(interconnect.minimumFrameProtection.rawValue) minimum of \(interconnect.rawValue)")
    }
}

/// SPEC-051-R008: this Mac holds only its stage's files of the snapshot whose
/// manifest is at `snapshotManifestPath` (the bytes the signed artifact hash covers).
struct ShardStageScope: Equatable, Sendable {
    let snapshotManifestPath: String
    let layers: Range<Int>
}

private func validateManifestPath(_ path: String?) throws {
    guard let path else { return }
    guard !path.isEmpty, ((path as NSString).expandingTildeInPath as NSString).isAbsolutePath else {
        throw ShardGroupConfigError.invalid("snapshot_manifest must be an absolute path")
    }
}

/// One downstream stage the head dials, in order.
struct ShardGroupStageConfig: Codable, Equatable, Sendable {
    var memberDeviceID: String
    var endpoint: String
    var layerStart: Int
    var layerEnd: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case memberDeviceID = "member_device_id"
        case endpoint
        case layerStart = "layer_start"
        case layerEnd = "layer_end"
    }

    init(memberDeviceID: String, endpoint: String, layerStart: Int, layerEnd: Int) {
        self.memberDeviceID = memberDeviceID
        self.endpoint = endpoint
        self.layerStart = layerStart
        self.layerEnd = layerEnd
    }

    init(from decoder: Decoder) throws {
        try refuseUnknownKeys(decoder, known: CodingKeys.allCases.map(\.stringValue), in: "stages[]")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberDeviceID = try container.decode(String.self, forKey: .memberDeviceID)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        layerStart = try container.decode(Int.self, forKey: .layerStart)
        layerEnd = try container.decode(Int.self, forKey: .layerEnd)
    }
}

struct ShardGroupSpareConfig: Codable, Equatable, Sendable {
    var memberDeviceID: String
    var endpoint: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case memberDeviceID = "member_device_id"
        case endpoint
    }

    init(memberDeviceID: String, endpoint: String) {
        self.memberDeviceID = memberDeviceID
        self.endpoint = endpoint
    }

    init(from decoder: Decoder) throws {
        try refuseUnknownKeys(decoder, known: CodingKeys.allCases.map(\.stringValue), in: "spare")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberDeviceID = try container.decode(String.self, forKey: .memberDeviceID)
        endpoint = try container.decode(String.self, forKey: .endpoint)
    }
}

/// The head's group: stage 0 is this Mac (layers `0..<head_layer_end`), the
/// downstream stages are dialed in order. With more than two stages the last stage
/// dials back to `return_listen`.
struct ShardGroupHeadConfig: Codable, Equatable, Sendable {
    static let schemaID = "macprovider.shard-group-config.v1"

    var schema: String
    var groupEpoch: UInt64
    var interconnectClass: ShardInterconnectClass
    var frameProtection: ShardFrameProtection
    /// SPEC-042-R015 pool model the group serves; named in the group record.
    var poolModelID: String?
    var headLayerEnd: Int
    var returnListen: String?
    var stages: [ShardGroupStageConfig]
    var spare: ShardGroupSpareConfig?
    var maxConcurrency: Int
    var prefillChunkTokens: Int?
    var supervision: ShardSupervisionConfig
    /// Set when this Mac holds only stage 0's files (SPEC-051-R008).
    var snapshotManifest: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case groupEpoch = "group_epoch"
        case interconnectClass = "interconnect_class"
        case frameProtection = "frame_protection"
        case poolModelID = "pool_model_id"
        case headLayerEnd = "head_layer_end"
        case returnListen = "return_listen"
        case stages
        case spare
        case maxConcurrency = "max_concurrency"
        case prefillChunkTokens = "prefill_chunk_tokens"
        case supervision
        case snapshotManifest = "snapshot_manifest"
    }

    init(
        groupEpoch: UInt64, interconnectClass: ShardInterconnectClass = .thunderboltIP,
        frameProtection: ShardFrameProtection = .crc32c, poolModelID: String? = nil, headLayerEnd: Int,
        returnListen: String? = nil, stages: [ShardGroupStageConfig], spare: ShardGroupSpareConfig? = nil,
        maxConcurrency: Int, prefillChunkTokens: Int? = nil, supervision: ShardSupervisionConfig = .defaults,
        snapshotManifest: String? = nil
    ) {
        self.schema = Self.schemaID
        self.groupEpoch = groupEpoch
        self.interconnectClass = interconnectClass
        self.frameProtection = frameProtection
        self.poolModelID = poolModelID
        self.headLayerEnd = headLayerEnd
        self.returnListen = returnListen
        self.stages = stages
        self.spare = spare
        self.maxConcurrency = maxConcurrency
        self.prefillChunkTokens = prefillChunkTokens
        self.supervision = supervision
        self.snapshotManifest = snapshotManifest
    }

    init(from decoder: Decoder) throws {
        try refuseUnknownKeys(decoder, known: CodingKeys.allCases.map(\.stringValue), in: "shard group config")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        groupEpoch = try container.decode(UInt64.self, forKey: .groupEpoch)
        interconnectClass = try container.decode(ShardInterconnectClass.self, forKey: .interconnectClass)
        frameProtection = try container.decode(ShardFrameProtection.self, forKey: .frameProtection)
        poolModelID = try container.decodeIfPresent(String.self, forKey: .poolModelID)
        headLayerEnd = try container.decode(Int.self, forKey: .headLayerEnd)
        returnListen = try container.decodeIfPresent(String.self, forKey: .returnListen)
        stages = try container.decode([ShardGroupStageConfig].self, forKey: .stages)
        spare = try container.decodeIfPresent(ShardGroupSpareConfig.self, forKey: .spare)
        maxConcurrency = try container.decode(Int.self, forKey: .maxConcurrency)
        prefillChunkTokens = try container.decodeIfPresent(Int.self, forKey: .prefillChunkTokens)
        supervision = try container.decode(ShardSupervisionConfig.self, forKey: .supervision)
        snapshotManifest = try container.decodeIfPresent(String.self, forKey: .snapshotManifest)
    }

    static func load(path: String) throws -> ShardGroupHeadConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let config: ShardGroupHeadConfig
        do {
            config = try JSONDecoder().decode(ShardGroupHeadConfig.self, from: data)
        } catch let error as ShardGroupConfigError {
            throw error
        } catch {
            throw ShardGroupConfigError.invalid("\(path): \(error)")
        }
        try config.validate()
        return config
    }

    func validate() throws {
        guard schema == Self.schemaID else { throw ShardGroupConfigError.invalid("schema must be \(Self.schemaID)") }
        guard (1...(UInt64(1) << 53 - 1)).contains(groupEpoch) else {
            throw ShardGroupConfigError.invalid("group_epoch must be within 1..2^53-1")
        }
        try validateTransport(interconnectClass, frameProtection)
        try supervision.validate()
        guard !stages.isEmpty, stages.count + 1 + (spare == nil ? 0 : 1) <= 8 else {
            throw ShardGroupConfigError.invalid("a group has 2..8 members including spares, got \(stages.count + 1) stages")
        }
        guard headLayerEnd > 0 else { throw ShardGroupConfigError.invalid("head_layer_end must be > 0") }
        var expectedStart = headLayerEnd
        var ids = Set<String>()
        for (index, stage) in stages.enumerated() {
            try validateMemberID(stage.memberDeviceID, field: "stages[\(index)].member_device_id")
            guard ids.insert(stage.memberDeviceID).inserted else {
                throw ShardGroupConfigError.invalid("member \(stage.memberDeviceID) appears twice")
            }
            guard stage.layerStart == expectedStart, stage.layerEnd > stage.layerStart else {
                throw ShardGroupConfigError.invalid("stages[\(index)] layers \(stage.layerStart):\(stage.layerEnd) must start at \(expectedStart) and be non-empty")
            }
            _ = try ShardBenchEndpoint.parse(stage.endpoint)
            expectedStart = stage.layerEnd
        }
        if stages.count > 1 {
            guard let returnListen else { throw ShardGroupConfigError.invalid("return_listen is required with more than two stages") }
            _ = try ShardBenchEndpoint.parse(returnListen)
        }
        if let spare {
            guard stages.count == 1 else { throw ShardGroupConfigError.invalid("a spare replaces the downstream stage of a two-stage group only") }
            try validateMemberID(spare.memberDeviceID, field: "spare.member_device_id")
            guard !ids.contains(spare.memberDeviceID) else { throw ShardGroupConfigError.invalid("the spare is also an active member") }
            _ = try ShardBenchEndpoint.parse(spare.endpoint)
        }
        guard (1...256).contains(maxConcurrency) else { throw ShardGroupConfigError.invalid("max_concurrency must be within 1..256") }
        if let prefillChunkTokens, prefillChunkTokens <= 0 {
            throw ShardGroupConfigError.invalid("prefill_chunk_tokens must be > 0")
        }
        if let poolModelID, poolModelID.range(of: BYOMAdmissionStatusWire.poolModelIDPattern, options: .regularExpression) == nil {
            throw ShardGroupConfigError.invalid("pool_model_id '\(poolModelID)' is not a SPEC-042-R015 pool model id (pool/<pool id>/<slug>)")
        }
        try validateManifestPath(snapshotManifest)
    }

    var stageScope: ShardStageScope? {
        snapshotManifest.map { ShardStageScope(snapshotManifestPath: ($0 as NSString).expandingTildeInPath, layers: 0..<headLayerEnd) }
    }

    var numLayers: Int { stages.last?.layerEnd ?? headLayerEnd }

    var expectedMembers: [ShardGroupExpectedMember] {
        stages.map { ShardGroupExpectedMember(memberDeviceID: $0.memberDeviceID, layers: $0.layerStart..<$0.layerEnd) }
    }

    var spareMember: ShardGroupExpectedMember? {
        guard let spare, let last = stages.last else { return nil }
        return ShardGroupExpectedMember(memberDeviceID: spare.memberDeviceID, layers: last.layerStart..<last.layerEnd)
    }
}

/// One member's stage: it listens for its upstream neighbour and, unless it is the
/// tail of a two-stage group, dials `connect` (the next stage, or the head's
/// return listener for the tail of a longer chain).
struct ShardMemberConfig: Codable, Equatable, Sendable {
    static let schemaID = "macprovider.shard-member-config.v1"

    enum Role: String, Codable, Sendable {
        case stage
        case spare
    }

    var schema: String
    var groupProviderID: String
    /// The epoch of the group record that names this member. A spare runs its
    /// links at the next epoch, the one the head starts when it replaces a stage.
    var groupEpoch: UInt64
    var role: Role
    var stageIndex: Int
    var layerStart: Int
    var layerEnd: Int
    var listen: String
    var connect: String?
    var interconnectClass: ShardInterconnectClass
    /// Must equal the group record's (SPEC-051-R011); defaults to the class minimum.
    var frameProtection: ShardFrameProtection
    var maxSequences: Int
    var supervision: ShardSupervisionConfig
    /// Set when this Mac holds only its stage's files (SPEC-051-R008).
    var snapshotManifest: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case groupProviderID = "group_provider_id"
        case groupEpoch = "group_epoch"
        case role
        case stageIndex = "stage_index"
        case layerStart = "layer_start"
        case layerEnd = "layer_end"
        case listen
        case connect
        case interconnectClass = "interconnect_class"
        case frameProtection = "frame_protection"
        case maxSequences = "max_sequences"
        case supervision
        case snapshotManifest = "snapshot_manifest"
    }

    init(
        groupProviderID: String, groupEpoch: UInt64, role: Role = .stage, stageIndex: Int, layerStart: Int, layerEnd: Int,
        listen: String, connect: String? = nil, interconnectClass: ShardInterconnectClass = .thunderboltIP,
        frameProtection: ShardFrameProtection? = nil, maxSequences: Int = 16, supervision: ShardSupervisionConfig = .defaults,
        snapshotManifest: String? = nil
    ) {
        self.schema = Self.schemaID
        self.groupProviderID = groupProviderID
        self.groupEpoch = groupEpoch
        self.role = role
        self.stageIndex = stageIndex
        self.layerStart = layerStart
        self.layerEnd = layerEnd
        self.listen = listen
        self.connect = connect
        self.interconnectClass = interconnectClass
        self.frameProtection = frameProtection ?? interconnectClass.minimumFrameProtection
        self.maxSequences = maxSequences
        self.supervision = supervision
        self.snapshotManifest = snapshotManifest
    }

    init(from decoder: Decoder) throws {
        try refuseUnknownKeys(decoder, known: CodingKeys.allCases.map(\.stringValue), in: "shard member config")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        groupProviderID = try container.decode(String.self, forKey: .groupProviderID)
        groupEpoch = try container.decode(UInt64.self, forKey: .groupEpoch)
        role = try container.decode(Role.self, forKey: .role)
        stageIndex = try container.decode(Int.self, forKey: .stageIndex)
        layerStart = try container.decode(Int.self, forKey: .layerStart)
        layerEnd = try container.decode(Int.self, forKey: .layerEnd)
        listen = try container.decode(String.self, forKey: .listen)
        connect = try container.decodeIfPresent(String.self, forKey: .connect)
        interconnectClass = try container.decode(ShardInterconnectClass.self, forKey: .interconnectClass)
        frameProtection = try container.decodeIfPresent(ShardFrameProtection.self, forKey: .frameProtection)
            ?? interconnectClass.minimumFrameProtection
        maxSequences = try container.decode(Int.self, forKey: .maxSequences)
        supervision = try container.decode(ShardSupervisionConfig.self, forKey: .supervision)
        snapshotManifest = try container.decodeIfPresent(String.self, forKey: .snapshotManifest)
    }

    static func load(path: String) throws -> ShardMemberConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let config: ShardMemberConfig
        do {
            config = try JSONDecoder().decode(ShardMemberConfig.self, from: data)
        } catch let error as ShardGroupConfigError {
            throw error
        } catch {
            throw ShardGroupConfigError.invalid("\(path): \(error)")
        }
        try config.validate()
        return config
    }

    func validate() throws {
        guard schema == Self.schemaID else { throw ShardGroupConfigError.invalid("schema must be \(Self.schemaID)") }
        try validateMemberID(groupProviderID, field: "group_provider_id")
        guard (1...(UInt64(1) << 53 - 2)).contains(groupEpoch) else {
            throw ShardGroupConfigError.invalid("group_epoch must be within 1..2^53-2")
        }
        try validateTransport(interconnectClass, frameProtection)
        try supervision.validate()
        guard stageIndex >= 1, layerStart > 0, layerEnd > layerStart else {
            throw ShardGroupConfigError.invalid("a member holds stage >= 1 with non-empty layers after layer 0")
        }
        _ = try ShardBenchEndpoint.parse(listen)
        if let connect { _ = try ShardBenchEndpoint.parse(connect) }
        guard (1...256).contains(maxSequences) else { throw ShardGroupConfigError.invalid("max_sequences must be within 1..256") }
        try validateManifestPath(snapshotManifest)
    }

    var stageScope: ShardStageScope? {
        snapshotManifest.map { ShardStageScope(snapshotManifestPath: ($0 as NSString).expandingTildeInPath, layers: layerStart..<layerEnd) }
    }

    /// The lowest epoch this member's links accept: a member follows the head to
    /// any later epoch (a rebuild or a takeover) and refuses an earlier one.
    var linkEpoch: UInt64 { role == .spare ? groupEpoch + 1 : groupEpoch }
}
