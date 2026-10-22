import CryptoKit
import Foundation

// Issue #2084 group attestation primitives (SPEC-051-R019), pure and unsigned: the
// running per-link activation digest, the per-member sub-receipt with its canonical
// JSON encoding, and the chain verifier. Signing with member device keys and the
// head's group attestation object come with group registration.
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
