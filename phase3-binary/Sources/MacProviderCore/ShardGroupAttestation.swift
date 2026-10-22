import CryptoKit
import Foundation

// Issue #2084 group attestation primitives (SPEC-051-R019): the running per-link
// activation digest, the per-member sub-receipt with its canonical JSON encoding,
// its Ed25519 signature by the member's device identity key, and the chain
// verifier. The head's group attestation object, bound to the SPEC-015 receipt, is
// built by the provider CLI from these.
//
// Both ends of a link fold the exact payload bytes they sent or received, so for an
// honest chain the upstream member's `out_digest` equals the downstream member's
// `in_digest` on every link, and the last stage's token `out_digest` equals the
// head's token `in_digest`.

/// Running SHA-256 chain over one request's frames on one link, in sequence order:
/// `d0 = 32 zero bytes`, `d' = SHA-256(d || requestID u64 LE || tokenStep u32 LE ||
/// SHA-256(payload))`.
public struct ShardActivationDigestChain: Equatable, Sendable {
    public private(set) var value: [UInt8] = Array(repeating: 0, count: 32)
    public private(set) var frames: Int = 0

    public init() {}

    public mutating func fold(requestID: UInt64, tokenStep: UInt32, payload: Data) {
        var hasher = SHA256()
        hasher.update(data: value)
        withUnsafeBytes(of: requestID.littleEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: tokenStep.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Array(SHA256.hash(data: payload)))
        value = Array(hasher.finalize())
        frames += 1
    }

    public var hex: String { value.map { String(format: "%02x", $0) }.joined() }
}

/// One member's account of one request (SPEC-051-R019 fields, unsigned).
public struct ShardMemberSubReceipt: Codable, Equatable, Sendable {
    public var memberDeviceID: String
    public var groupEpoch: UInt64
    public var stageIndex: Int
    public var layerStart: Int
    public var layerEnd: Int
    public var requestID: UInt64
    /// Prompt tokens this member ran through its layers.
    public var promptTokens: Int
    /// Decode steps this member ran through its layers.
    public var decodeSteps: Int
    /// Chain over frames received upstream (the head: tokens on the return link).
    public var inDigest: String
    /// Chain over frames sent downstream (the tail: tokens on the return link).
    public var outDigest: String

    public init(
        memberDeviceID: String,
        groupEpoch: UInt64,
        stageIndex: Int,
        layerStart: Int,
        layerEnd: Int,
        requestID: UInt64,
        promptTokens: Int,
        decodeSteps: Int,
        inDigest: String,
        outDigest: String
    ) {
        self.memberDeviceID = memberDeviceID
        self.groupEpoch = groupEpoch
        self.stageIndex = stageIndex
        self.layerStart = layerStart
        self.layerEnd = layerEnd
        self.requestID = requestID
        self.promptTokens = promptTokens
        self.decodeSteps = decodeSteps
        self.inDigest = inDigest
        self.outDigest = outDigest
    }

    enum CodingKeys: String, CodingKey {
        case memberDeviceID = "member_device_id"
        case groupEpoch = "group_epoch"
        case stageIndex = "stage_index"
        case layerStart = "layer_start"
        case layerEnd = "layer_end"
        case requestID = "request_id"
        case promptTokens = "prompt_tokens"
        case decodeSteps = "decode_steps"
        case inDigest = "in_digest"
        case outDigest = "out_digest"
    }

    /// The bytes a member signs: snake_case keys sorted, no whitespace, integers in
    /// decimal, digests as lowercase hex.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct ShardAttestationFault: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tooFewMembers = "too_few_members"
        case stageOrder = "stage_order"
        case requestMismatch = "request_mismatch"
        case epochMismatch = "epoch_mismatch"
        case layerGap = "layer_gap"
        case digestMismatch = "digest_mismatch"
        /// A sub-receipt whose signature does not verify under its public key.
        case signatureInvalid = "signature_invalid"
        /// A sub-receipt signed by a key other than the one its member announced.
        case keyMismatch = "key_mismatch"
    }

    public var kind: Kind
    /// The first broken link, upstream end -> downstream end (positions in the chain;
    /// the token return link is last -> 0).
    public var fromStage: Int
    public var toStage: Int
    public var fromMember: String?
    public var toMember: String?
    public var detail: String
}

public enum ShardAttestationVerdict: Equatable, Sendable {
    case ok
    case broken(ShardAttestationFault)
}

public enum ShardGroupAttestationVerifier {
    /// Check one request's sub-receipts, given in chain order (head first): stage
    /// indices 0..S-1, one request and epoch, contiguous layers from 0, then
    /// `out_i == in_{i+1}` on every link and the last stage's `out` equal to the
    /// head's `in`. Reports the first broken link.
    public static func verify(_ receipts: [ShardMemberSubReceipt]) -> ShardAttestationVerdict {
        guard receipts.count >= 2 else {
            return .broken(ShardAttestationFault(
                kind: .tooFewMembers, fromStage: 0, toStage: 0, fromMember: receipts.first?.memberDeviceID, toMember: nil,
                detail: "a chain needs at least two sub-receipts, got \(receipts.count)"))
        }
        let head = receipts[0]
        for (position, receipt) in receipts.enumerated() {
            let previous = position > 0 ? receipts[position - 1] : nil
            func fault(_ kind: ShardAttestationFault.Kind, _ detail: String) -> ShardAttestationVerdict {
                .broken(ShardAttestationFault(
                    kind: kind, fromStage: max(0, position - 1), toStage: position,
                    fromMember: previous?.memberDeviceID, toMember: receipt.memberDeviceID, detail: detail))
            }
            guard receipt.stageIndex == position else {
                return fault(.stageOrder, "position \(position) holds stage \(receipt.stageIndex)")
            }
            guard receipt.requestID == head.requestID else {
                return fault(.requestMismatch, "request \(receipt.requestID), head has \(head.requestID)")
            }
            guard receipt.groupEpoch == head.groupEpoch else {
                return fault(.epochMismatch, "epoch \(receipt.groupEpoch), head has \(head.groupEpoch)")
            }
            let expectedStart = previous?.layerEnd ?? 0
            guard receipt.layerStart == expectedStart, receipt.layerEnd > receipt.layerStart else {
                return fault(.layerGap, "layers \(receipt.layerStart):\(receipt.layerEnd), expected to start at \(expectedStart)")
            }
            if let previous, previous.outDigest != receipt.inDigest {
                return fault(.digestMismatch, "out_digest \(previous.outDigest) != in_digest \(receipt.inDigest)")
            }
        }
        let last = receipts[receipts.count - 1]
        guard last.outDigest == head.inDigest else {
            return .broken(ShardAttestationFault(
                kind: .digestMismatch, fromStage: receipts.count - 1, toStage: 0,
                fromMember: last.memberDeviceID, toMember: head.memberDeviceID,
                detail: "token out_digest \(last.outDigest) != head in_digest \(head.inDigest)"))
        }
        return .ok
    }
}

/// A member device identity and its Ed25519 signing key (the provider admission
/// identity key in production, an ephemeral key in the lab harness).
public struct ShardMemberSigner: @unchecked Sendable {
    public let memberDeviceID: String
    public let key: Curve25519.Signing.PrivateKey

    public init(memberDeviceID: String, key: Curve25519.Signing.PrivateKey) {
        self.memberDeviceID = memberDeviceID
        self.key = key
    }

    /// Raw 32-byte public key, base64.
    public var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }

    public func sign(_ receipt: ShardMemberSubReceipt) throws -> ShardSignedSubReceipt {
        let signature = try key.signature(for: ShardSignedSubReceipt.signedBytes(receipt))
        return ShardSignedSubReceipt(receipt: receipt, publicKey: publicKeyBase64, signature: signature.base64EncodedString())
    }
}

/// A sub-receipt with its member's signature over
/// `"macprovider.shard-sub-receipt.v1\n" || canonicalJSON(sub_receipt)`.
public struct ShardSignedSubReceipt: Codable, Equatable, Sendable {
    public static let domain = "macprovider.shard-sub-receipt.v1\n"

    public var receipt: ShardMemberSubReceipt
    /// Raw 32-byte Ed25519 public key, base64.
    public var publicKey: String
    /// 64-byte Ed25519 signature, base64.
    public var signature: String

    public init(receipt: ShardMemberSubReceipt, publicKey: String, signature: String) {
        self.receipt = receipt
        self.publicKey = publicKey
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case receipt = "sub_receipt"
        case publicKey = "public_key"
        case signature
    }

    public static func signedBytes(_ receipt: ShardMemberSubReceipt) throws -> Data {
        Data(domain.utf8) + (try receipt.canonicalJSON())
    }

    public var signatureIsValid: Bool {
        guard let keyBytes = Data(base64Encoded: publicKey), let signatureBytes = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let message = try? Self.signedBytes(receipt)
        else { return false }
        return key.isValidSignature(signatureBytes, for: message)
    }
}

extension ShardGroupAttestationVerifier {
    /// Signed form: every signature must verify and, where the head knows the key a
    /// stage announced in its hello (`expectedKeys[stage]`), be made with that key;
    /// then the chain checks of `verify(_:)`.
    public static func verify(signed receipts: [ShardSignedSubReceipt], expectedKeys: [Int: String] = [:]) -> ShardAttestationVerdict {
        for (position, signed) in receipts.enumerated() {
            func fault(_ kind: ShardAttestationFault.Kind, _ detail: String) -> ShardAttestationVerdict {
                .broken(ShardAttestationFault(
                    kind: kind, fromStage: position, toStage: position, fromMember: signed.receipt.memberDeviceID,
                    toMember: signed.receipt.memberDeviceID, detail: detail))
            }
            if let expected = expectedKeys[signed.receipt.stageIndex], expected != signed.publicKey {
                return fault(.keyMismatch, "stage \(signed.receipt.stageIndex) signed with \(signed.publicKey), announced \(expected)")
            }
            guard signed.signatureIsValid else {
                return fault(.signatureInvalid, "stage \(signed.receipt.stageIndex) sub-receipt signature does not verify")
            }
        }
        return verify(receipts.map(\.receipt))
    }
}
