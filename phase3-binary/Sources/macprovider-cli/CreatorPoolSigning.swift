import CryptoKit
import Foundation

// SPEC-042-R001/R012 and SPEC-043-R002 canonical encodings for a self-serve
// pool creator (SPEC-043 0.3.0, #1880). This is a byte-for-byte port of the
// coordinator's phase4-coordinator/internal/poolmanifest encoders and the
// trustpool root-registration / manifest-acceptance signing messages, so a
// creator signs on its own Mac and no private key ever leaves it. The golden
// vectors in CreatorPoolSigningTests freeze parity with the Go encoders.

enum CreatorPoolSigningError: Error, Equatable, CustomStringConvertible {
    case fieldTooLong
    case invalidPrevHash
    case duplicateEntry(String)
    case invalidEncoding
    case invalidExtensionOrder
    case invalidKey(String)
    case invalidInput(String)

    var description: String {
        switch self {
        case .fieldTooLong: return "a field exceeds 2^32-1 bytes"
        case .invalidPrevHash: return "prev_manifest_core_hash must be 32 bytes"
        case let .duplicateEntry(what): return "duplicate \(what)"
        case .invalidEncoding: return "policy core encoding must be 1 or 2"
        case .invalidExtensionOrder: return "extensions must be strictly ascending by id"
        case let .invalidKey(what): return "invalid key: \(what)"
        case let .invalidInput(what): return what
        }
    }
}

/// The SPEC-042-R001 length-prefixed grammar: big-endian u32 lengths and
/// counts, big-endian u64 integers, one byte booleans.
struct PoolCanonicalEncoder {
    private(set) var bytes = Data()

    mutating func tag(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }

    mutating func u64(_ n: UInt64) {
        var be = n.bigEndian
        withUnsafeBytes(of: &be) { bytes.append(contentsOf: $0) }
    }

    mutating func u32(_ n: Int) throws {
        guard n >= 0, UInt64(n) <= UInt64(UInt32.max) else { throw CreatorPoolSigningError.fieldTooLong }
        var be = UInt32(n).bigEndian
        withUnsafeBytes(of: &be) { bytes.append(contentsOf: $0) }
    }

    mutating func boolean(_ b: Bool) { bytes.append(b ? 0x01 : 0x00) }

    mutating func lenPrefixed(_ data: Data) throws {
        try u32(data.count)
        bytes.append(data)
    }

    mutating func str(_ s: String) throws { try lenPrefixed(Data(s.utf8)) }

    mutating func byte(_ b: UInt8) { bytes.append(b) }
}

enum PoolTags {
    static let identityCore = "macprovider/spec042/identity-core/v1"
    static let policyCoreV1 = "macprovider/spec042/policy-core/v1"
    static let policyCoreV2 = "macprovider/spec042/policy-core/v2"
    static let policyCoreSigV1 = "macprovider/spec042/policy-core-sig/v1"
    static let policyCoreSigV2 = "macprovider/spec042/policy-core-sig/v2"
    static let authorityLogEntry = "macprovider/spec042/authority-log-entry/v1"
    static let authorityLogEntrySig = "macprovider/spec042/authority-log-entry-sig/v1"
    static let manifestSnapshotV1 = "macprovider/spec042/manifest-snapshot/v1"
    static let manifestSnapshotV2 = "macprovider/spec042/manifest-snapshot/v2"
    static let rootIssuerFingerprint = "macprovider/spec043/root-issuer-key/v1"
    static let rootRegistrationSig = "macprovider/spec043/root-key-registration-sig/v1"
    static let manifestAcceptedSig = "macprovider/spec043/manifest-accepted-sig/v1"
}

enum PoolBytes {
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func fromHex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index ..< next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Byte-lexicographic order, matching Go's sort.Strings on UTF-8.
    static func byteLess(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }
}

struct PoolIdentityCore: Equatable {
    var rootIssuerKeyID: String
    var genesisNonce: Data

    func canonicalBytes() throws -> Data {
        var e = PoolCanonicalEncoder()
        e.tag(PoolTags.identityCore)
        try e.str(rootIssuerKeyID)
        try e.lenPrefixed(genesisNonce)
        return e.bytes
    }

    /// base64url(SHA256(identity core)[0:16]), unpadded.
    func poolID() throws -> String {
        PoolBytes.base64URLNoPad(PoolBytes.sha256(try canonicalBytes()).prefix(16))
    }
}

struct PoolSignerKey: Codable, Equatable {
    var keyID: String
    var publicKey: Data

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case publicKey = "public_key"
    }
}

struct PoolSignature: Codable, Equatable {
    var keyID: String
    var sig: Data

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case sig
    }
}

struct PoolAuthorityLogEntry: Codable, Equatable {
    var poolID: String
    var signerSetVersion: UInt64
    var prevAuthorityLogEntryHash: Data
    var keys: [PoolSignerKey]
    var threshold: UInt32
    var notBeforeUnix: UInt64
    var expiresAtUnix: UInt64
    var revokesVersions: [UInt64]
    var authorizingSignerSetVersion: UInt64
    var signatures: [PoolSignature]

    enum CodingKeys: String, CodingKey {
        case poolID = "pool_id"
        case signerSetVersion = "signer_set_version"
        case prevAuthorityLogEntryHash = "prev_authority_log_entry_hash"
        case keys, threshold
        case notBeforeUnix = "not_before_unix"
        case expiresAtUnix = "expires_at_unix"
        case revokesVersions = "revokes_versions"
        case authorizingSignerSetVersion = "authorizing_signer_set_version"
        case signatures
    }

    /// SPEC-042-R012 entry content: keys ordered by key id, revokes ascending.
    func canonicalContentBytes() throws -> Data {
        guard prevAuthorityLogEntryHash.count == 32 else { throw CreatorPoolSigningError.invalidPrevHash }
        let ordered = keys.sorted { PoolBytes.byteLess($0.keyID, $1.keyID) }
        for i in ordered.indices.dropFirst() where ordered[i].keyID == ordered[i - 1].keyID {
            throw CreatorPoolSigningError.duplicateEntry("signer key id")
        }
        for i in revokesVersions.indices.dropFirst() where revokesVersions[i] <= revokesVersions[i - 1] {
            throw CreatorPoolSigningError.invalidInput("revokes_versions must be strictly ascending")
        }
        var e = PoolCanonicalEncoder()
        e.tag(PoolTags.authorityLogEntry)
        try e.str(poolID)
        e.u64(signerSetVersion)
        try e.lenPrefixed(prevAuthorityLogEntryHash)
        try e.u32(ordered.count)
        for key in ordered {
            try e.str(key.keyID)
            try e.lenPrefixed(key.publicKey)
        }
        e.u64(UInt64(threshold))
        e.u64(notBeforeUnix)
        e.u64(expiresAtUnix)
        try e.u32(revokesVersions.count)
        for v in revokesVersions { e.u64(v) }
        e.u64(authorizingSignerSetVersion)
        return e.bytes
    }

    func entryHash() throws -> Data { PoolBytes.sha256(try canonicalContentBytes()) }

    func signingMessage() throws -> Data {
        var msg = Data(PoolTags.authorityLogEntrySig.utf8)
        msg.append(try entryHash())
        return msg
    }
}

struct PoolModelPricing: Codable, Equatable {
    var promptRatePerMtok: UInt64
    var promptCacheHitRatePerMtok: UInt64
    var completionRatePerMtok: UInt64

    enum CodingKeys: String, CodingKey {
        case promptRatePerMtok = "prompt_rate_per_mtok"
        case promptCacheHitRatePerMtok = "prompt_cache_hit_rate_per_mtok"
        case completionRatePerMtok = "completion_rate_per_mtok"
    }
}

/// One SPEC-042-R015 pool model entry, encoded in this field order.
struct PoolModelEntry: Codable, Equatable {
    var poolModelID: String
    var artifactHashAlgorithm: String
    var artifactHash: String
    var allowedRuntimeSources: [String]
    var license: String
    var paidServingAttested: Bool
    var pricing: PoolModelPricing
    var disclosureClass: String
    var maxContextTokens: UInt64

    enum CodingKeys: String, CodingKey {
        case poolModelID = "pool_model_id"
        case artifactHashAlgorithm = "artifact_hash_algorithm"
        case artifactHash = "artifact_hash"
        case allowedRuntimeSources = "allowed_runtime_sources"
        case license
        case paidServingAttested = "paid_serving_attested"
        case pricing
        case disclosureClass = "disclosure_class"
        case maxContextTokens = "max_context_tokens"
    }
}

/// One SPEC-042-R016 member-account attestation.
struct PoolAttestedMember: Codable, Equatable {
    var providerAccountID: String
    var runtimeClasses: [String]

    enum CodingKeys: String, CodingKey {
        case providerAccountID = "provider_account_id"
        case runtimeClasses = "runtime_classes"
    }
}

enum PoolExtensions {
    static let modelEntriesV1 = "pool_model_entries/v1"
    static let attestedMembersV1 = "pool_attested_members/v1"

    static func encodeModelEntries(_ entries: [PoolModelEntry]) throws -> Data {
        guard !entries.isEmpty else { throw CreatorPoolSigningError.invalidInput("an empty model entry list must be omitted") }
        var e = PoolCanonicalEncoder()
        try e.u32(entries.count)
        for m in entries {
            try e.str(m.poolModelID)
            try e.str(m.artifactHashAlgorithm)
            try e.str(m.artifactHash)
            try e.u32(m.allowedRuntimeSources.count)
            for source in m.allowedRuntimeSources { try e.str(source) }
            try e.str(m.license)
            e.boolean(m.paidServingAttested)
            e.u64(m.pricing.promptRatePerMtok)
            e.u64(m.pricing.promptCacheHitRatePerMtok)
            e.u64(m.pricing.completionRatePerMtok)
            try e.str(m.disclosureClass)
            e.u64(m.maxContextTokens)
        }
        return e.bytes
    }

    static func encodeAttestedMembers(_ members: [PoolAttestedMember]) throws -> Data {
        guard !members.isEmpty else { throw CreatorPoolSigningError.invalidInput("an empty attested member list must be omitted") }
        var e = PoolCanonicalEncoder()
        try e.u32(members.count)
        for member in members {
            try e.str(member.providerAccountID)
            try e.u32(member.runtimeClasses.count)
            for source in member.runtimeClasses { try e.str(source) }
        }
        return e.bytes
    }
}

/// Reads back the SPEC-042-R015/R016 extension bodies `PoolExtensions`
/// encodes, so a later manifest version can carry or drop prior entries.
struct PoolCanonicalDecoder {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var atEnd: Bool { offset == bytes.count }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, bytes.count - offset >= n else { throw CreatorPoolSigningError.invalidInput("truncated pool extension body") }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func u32() throws -> Int { Int(try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) }

    mutating func boolean() throws -> Bool {
        switch try take(1).first {
        case 0x00: return false
        case 0x01: return true
        default: throw CreatorPoolSigningError.invalidInput("invalid boolean in pool extension body")
        }
    }

    mutating func str() throws -> String {
        guard let s = String(bytes: try take(try u32()), encoding: .utf8) else {
            throw CreatorPoolSigningError.invalidInput("invalid UTF-8 in pool extension body")
        }
        return s
    }
}

extension PoolExtensions {
    static func decodeModelEntries(_ body: Data) throws -> [PoolModelEntry] {
        var d = PoolCanonicalDecoder(body)
        var entries: [PoolModelEntry] = []
        for _ in 0..<(try d.u32()) {
            let id = try d.str(), algorithm = try d.str(), hash = try d.str()
            var sources: [String] = []
            for _ in 0..<(try d.u32()) { sources.append(try d.str()) }
            let license = try d.str()
            let attested = try d.boolean()
            let pricing = PoolModelPricing(promptRatePerMtok: try d.u64(), promptCacheHitRatePerMtok: try d.u64(), completionRatePerMtok: try d.u64())
            entries.append(PoolModelEntry(
                poolModelID: id, artifactHashAlgorithm: algorithm, artifactHash: hash, allowedRuntimeSources: sources,
                license: license, paidServingAttested: attested, pricing: pricing, disclosureClass: try d.str(), maxContextTokens: try d.u64()
            ))
        }
        guard d.atEnd else { throw CreatorPoolSigningError.invalidInput("trailing bytes in pool model entries") }
        return entries
    }

    static func decodeAttestedMembers(_ body: Data) throws -> [PoolAttestedMember] {
        var d = PoolCanonicalDecoder(body)
        var members: [PoolAttestedMember] = []
        for _ in 0..<(try d.u32()) {
            let account = try d.str()
            var classes: [String] = []
            for _ in 0..<(try d.u32()) { classes.append(try d.str()) }
            members.append(PoolAttestedMember(providerAccountID: account, runtimeClasses: classes))
        }
        guard d.atEnd else { throw CreatorPoolSigningError.invalidInput("trailing bytes in pool attested members") }
        return members
    }
}

struct PoolPolicyExtension: Codable, Equatable {
    var id: String
    var body: Data
}

/// SPEC-042-R001 policy core. encoding 1 is the frozen v1 grammar; encoding 2
/// appends runtime_allowlist and extensions.
struct PoolPolicyCore: Codable, Equatable {
    var poolID: String
    var manifestVersion: UInt64
    var prevManifestCoreHash: Data
    var signerSetVersion: UInt64
    var modelAllowlist: [String]
    var minBinaryVersion: String
    var minAttestationTier: String
    var requireEncryptedLeg: Bool
    var settlementMode: String
    var revenueSplitBps: UInt64
    var splitExecutionStatus: String
    var retentionPolicyID: String
    var minEligibleMembers: UInt64
    var privacyMode: String
    var relayBlindCapable: Bool
    var receiptContract: String
    var metadataVisible: String
    var downgradePolicy: String
    var stickyRoutingAllowed: Bool
    var notBeforeUnix: UInt64
    var expiresAtUnix: UInt64
    var encoding: UInt8
    var runtimeAllowlist: [String]
    var extensions: [PoolPolicyExtension]

    enum CodingKeys: String, CodingKey {
        case poolID = "pool_id"
        case manifestVersion = "manifest_version"
        case prevManifestCoreHash = "prev_manifest_core_hash"
        case signerSetVersion = "signer_set_version"
        case modelAllowlist = "model_allowlist"
        case minBinaryVersion = "min_binary_version"
        case minAttestationTier = "min_attestation_tier"
        case requireEncryptedLeg = "require_encrypted_leg"
        case settlementMode = "settlement_mode"
        case revenueSplitBps = "revenue_split_bps"
        case splitExecutionStatus = "split_execution_status"
        case retentionPolicyID = "retention_policy_id"
        case minEligibleMembers = "min_eligible_members"
        case privacyMode = "privacy_mode"
        case relayBlindCapable = "relay_blind_capable"
        case receiptContract = "receipt_contract"
        case metadataVisible = "metadata_visible"
        case downgradePolicy = "downgrade_policy"
        case stickyRoutingAllowed = "sticky_routing_allowed"
        case notBeforeUnix = "not_before_unix"
        case expiresAtUnix = "expires_at_unix"
        case encoding
        case runtimeAllowlist = "runtime_allowlist"
        case extensions
    }

    var isV2: Bool { encoding == 2 }

    func canonicalBytes() throws -> Data {
        guard prevManifestCoreHash.count == 32 else { throw CreatorPoolSigningError.invalidPrevHash }
        let allow = modelAllowlist.sorted(by: PoolBytes.byteLess)
        for i in allow.indices.dropFirst() where allow[i] == allow[i - 1] {
            throw CreatorPoolSigningError.duplicateEntry("model allowlist entry")
        }
        let tag: String
        switch encoding {
        case 0, 1:
            guard runtimeAllowlist.isEmpty, extensions.isEmpty else {
                throw CreatorPoolSigningError.invalidInput("a v1 policy core cannot carry runtime_allowlist or extensions")
            }
            tag = PoolTags.policyCoreV1
        case 2:
            for i in runtimeAllowlist.indices.dropFirst() where !PoolBytes.byteLess(runtimeAllowlist[i - 1], runtimeAllowlist[i]) {
                throw CreatorPoolSigningError.invalidInput("runtime_allowlist must be strictly ascending")
            }
            for i in extensions.indices.dropFirst() where !PoolBytes.byteLess(extensions[i - 1].id, extensions[i].id) {
                throw CreatorPoolSigningError.invalidExtensionOrder
            }
            tag = PoolTags.policyCoreV2
        default:
            throw CreatorPoolSigningError.invalidEncoding
        }
        var e = PoolCanonicalEncoder()
        e.tag(tag)
        try e.str(poolID)
        e.u64(manifestVersion)
        try e.lenPrefixed(prevManifestCoreHash)
        e.u64(signerSetVersion)
        try e.u32(allow.count)
        for m in allow { try e.str(m) }
        try encodeFieldsAfterAllowlist(&e)
        e.u64(notBeforeUnix)
        e.u64(expiresAtUnix)
        if isV2 { try encodeV2Fields(&e) }
        return e.bytes
    }

    func manifestCoreDigest() throws -> Data { PoolBytes.sha256(try canonicalBytes()) }

    func signingMessage() throws -> Data {
        var msg = Data((isV2 ? PoolTags.policyCoreSigV2 : PoolTags.policyCoreSigV1).utf8)
        msg.append(try manifestCoreDigest())
        return msg
    }

    fileprivate func encodeFieldsAfterAllowlist(_ e: inout PoolCanonicalEncoder) throws {
        try e.str(minBinaryVersion)
        try e.str(minAttestationTier)
        e.boolean(requireEncryptedLeg)
        try e.str(settlementMode)
        e.u64(revenueSplitBps)
        try e.str(splitExecutionStatus)
        try e.str(retentionPolicyID)
        e.u64(minEligibleMembers)
        try e.str(privacyMode)
        e.boolean(relayBlindCapable)
        try e.str(receiptContract)
        try e.str(metadataVisible)
        try e.str(downgradePolicy)
        e.boolean(stickyRoutingAllowed)
    }

    fileprivate func encodeV2Fields(_ e: inout PoolCanonicalEncoder) throws {
        try e.u32(runtimeAllowlist.count)
        for source in runtimeAllowlist { try e.str(source) }
        try e.u32(extensions.count)
        for ext in extensions {
            try e.str(ext.id)
            try e.lenPrefixed(ext.body)
        }
    }

    /// Snapshot form: the stored field order, unsorted, with no tag.
    fileprivate func encodeForSnapshot(_ e: inout PoolCanonicalEncoder) throws {
        try e.str(poolID)
        e.u64(manifestVersion)
        try e.lenPrefixed(prevManifestCoreHash)
        e.u64(signerSetVersion)
        try e.u32(modelAllowlist.count)
        for m in modelAllowlist { try e.str(m) }
        try encodeFieldsAfterAllowlist(&e)
        e.u64(notBeforeUnix)
        e.u64(expiresAtUnix)
    }
}

struct PoolAcceptedPolicy: Codable, Equatable {
    var core: PoolPolicyCore
    var signatures: [PoolSignature]
    var acceptedAtUnix: UInt64

    enum CodingKeys: String, CodingKey {
        case core, signatures
        case acceptedAtUnix = "accepted_at_unix"
    }
}

/// The durable manifest snapshot the coordinator stores and re-verifies.
struct PoolManifestSnapshot: Codable, Equatable {
    var rootIssuerKeyID: String
    var genesisNonce: Data
    var rootIssuerKey: PoolSignerKey
    var authorityLog: [PoolAuthorityLogEntry]
    var policies: [PoolAcceptedPolicy]

    enum CodingKeys: String, CodingKey {
        case rootIssuerKeyID = "root_issuer_key_id"
        case genesisNonce = "genesis_nonce"
        case rootIssuerKey = "root_issuer_key"
        case authorityLog = "authority_log"
        case policies
    }

    func canonicalBytes() throws -> Data {
        let tagged = policies.contains { $0.core.encoding != 0 }
        var e = PoolCanonicalEncoder()
        e.tag(tagged ? PoolTags.manifestSnapshotV2 : PoolTags.manifestSnapshotV1)
        try e.str(rootIssuerKeyID)
        try e.lenPrefixed(genesisNonce)
        try encodeSigner(&e, rootIssuerKey)
        try e.u32(authorityLog.count)
        for entry in authorityLog {
            try e.str(entry.poolID)
            e.u64(entry.signerSetVersion)
            try e.lenPrefixed(entry.prevAuthorityLogEntryHash)
            try e.u32(entry.keys.count)
            for key in entry.keys { try encodeSigner(&e, key) }
            e.u64(UInt64(entry.threshold))
            e.u64(entry.notBeforeUnix)
            e.u64(entry.expiresAtUnix)
            try e.u32(entry.revokesVersions.count)
            for v in entry.revokesVersions { e.u64(v) }
            e.u64(entry.authorizingSignerSetVersion)
            try encodeSignatures(&e, entry.signatures)
        }
        try e.u32(policies.count)
        for policy in policies {
            if tagged { e.byte(policy.core.encoding) }
            try policy.core.encodeForSnapshot(&e)
            if tagged && policy.core.isV2 { try policy.core.encodeV2Fields(&e) }
            try encodeSignatures(&e, policy.signatures)
            e.u64(policy.acceptedAtUnix)
        }
        return e.bytes
    }

    private func encodeSigner(_ e: inout PoolCanonicalEncoder, _ key: PoolSignerKey) throws {
        try e.str(key.keyID)
        try e.lenPrefixed(key.publicKey)
    }

    private func encodeSignatures(_ e: inout PoolCanonicalEncoder, _ sigs: [PoolSignature]) throws {
        try e.u32(sigs.count)
        for sig in sigs {
            try e.str(sig.keyID)
            try e.lenPrefixed(sig.sig)
        }
    }
}

enum CreatorRootSigning {
    static let algorithm = "ecdsa-p256-sha256"
    static let purpose = "root_issuer_registration"

    /// SPEC-043-R002 root_issuer_public_key_fingerprint over the SPKI DER.
    static func fingerprint(spkiDER: Data) -> String {
        var enc = Data(PoolTags.rootIssuerFingerprint.utf8)
        var algLen = UInt16(algorithm.utf8.count).bigEndian
        withUnsafeBytes(of: &algLen) { enc.append(contentsOf: $0) }
        enc.append(contentsOf: Array(algorithm.utf8))
        var keyLen = UInt32(spkiDER.count).bigEndian
        withUnsafeBytes(of: &keyLen) { enc.append(contentsOf: $0) }
        enc.append(spkiDER)
        return PoolBytes.hex(PoolBytes.sha256(enc))
    }

    /// The tagged RFC 8785 message a root registration proof signs.
    static func rootRegistrationMessage(_ fields: [String: String]) throws -> Data {
        try taggedCanonicalJSON(PoolTags.rootRegistrationSig, fields)
    }

    /// The tagged RFC 8785 message a manifest_accepted root signature signs.
    static func manifestAcceptanceMessage(
        poolID: String,
        manifestVersion: UInt64,
        manifestCoreDigestHex: String,
        manifestSnapshot: Data,
        rootIssuerKeyID: String,
        rootFingerprint: String
    ) throws -> Data {
        try taggedCanonicalJSON(PoolTags.manifestAcceptedSig, [
            "manifest_core_digest": manifestCoreDigestHex,
            "manifest_snapshot_sha256": PoolBytes.hex(PoolBytes.sha256(manifestSnapshot)),
            "manifest_version_dec": String(manifestVersion),
            "pool_id": poolID,
            "root_issuer_key_id": rootIssuerKeyID,
            "root_issuer_public_key_fingerprint": rootFingerprint,
        ])
    }

    static func taggedCanonicalJSON(_ tag: String, _ fields: [String: String]) throws -> Data {
        var msg = Data(tag.utf8)
        msg.append(try CanonicalJSON.encode(.object(fields.mapValues { .string($0) })))
        return msg
    }

    /// ECDSA P-256 over SHA-256(msg), DER, standard base64: the coordinator's
    /// ecdsa.VerifyASN1 input.
    static func signP256(_ key: P256.Signing.PrivateKey, _ msg: Data) throws -> String {
        try key.signature(for: msg).derRepresentation.base64EncodedString()
    }
}
