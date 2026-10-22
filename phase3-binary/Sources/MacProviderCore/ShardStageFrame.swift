import Foundation

// Issue #2084 stage transport: the binary frame two pipeline stages exchange over a
// LAN link. Pure Swift (no MLX) so the codec and its strict decoder are unit-tested
// without model weights.
//
// Wire layout, little-endian, fixed 60-byte header:
//
//   off size field
//     0    4 magic "MPSF" (0x4D 0x50 0x53 0x46)
//     4    2 version (1)
//     6    1 kind
//     7    1 dtype
//     8    8 group epoch
//    16    8 request id
//    24    4 micro-batch id
//    28    4 token step
//    32    2 source stage
//    34    2 destination stage
//    36    4 layer range start
//    40    4 layer range end (exclusive)
//    44    8 per-link sequence number
//    52    4 payload length
//    56    1 shape rank
//    57    1 flags (ShardFrameFlags; activation frames only)
//    58    2 reserved (must be zero)
//    60  4*r shape dims (UInt32 each)
//     .    n payload
//     .    4 CRC32C over every preceding byte of the frame
//
// The header carries the payload length and rank, so a frame is self-delimiting:
// a reader takes the fixed header, validates it, then reads exactly the rest.

public enum ShardFrameKind: UInt8, Sendable, CaseIterable {
    case hello = 1
    case activation = 2
    case token = 3
    case heartbeat = 4
    case abort = 5
    case error = 6
    /// A token plus the last stage's logit summary (`ShardLogitSummaryCodec`), for
    /// teacher-forced parity.
    case tokenLogits = 7
    /// Per-request control message, JSON payload (`ShardRequestControl`): the head
    /// opens each request with its sampling parameters before its first activation.
    case control = 8
}

/// Per-frame flags. Unknown bits are refused, so a peer that does not know a flag
/// fails closed instead of misreading the frame.
public struct ShardFrameFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The receiver only extends its KV with this activation: every stage forwards
    /// it, and the last stage samples no token for it. Used for all but the last
    /// chunk of a chunked prefill and for replaying a delivered prefix into a spare.
    public static let fillOnly = ShardFrameFlags(rawValue: 1 << 0)

    public static let known: ShardFrameFlags = [.fillOnly]
}

public enum ShardTensorDType: UInt8, Sendable, CaseIterable {
    /// No tensor: the payload is opaque bytes (hello JSON, error text) and rank is 0.
    case none = 0
    case bfloat16 = 1
    case float16 = 2
    case float32 = 3
    case int32 = 4

    public var byteWidth: Int {
        switch self {
        case .none: return 1
        case .bfloat16, .float16: return 2
        case .float32, .int32: return 4
        }
    }

    var isFloatingPoint: Bool {
        switch self {
        case .bfloat16, .float16, .float32: return true
        case .none, .int32: return false
        }
    }
}

public enum ShardFrameError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case badMagic
    case unsupportedVersion(UInt16)
    case unknownKind(UInt8)
    case unknownDType(UInt8)
    case nonzeroReserved
    case unknownFlags(UInt8)
    case flagsOnNonActivation(kind: ShardFrameKind)
    case rankTooLarge(Int)
    case payloadTooLarge(length: Int, cap: Int)
    case shapePayloadMismatch(expectedBytes: Int, payloadBytes: Int)
    case kindDTypeMismatch(kind: ShardFrameKind, dtype: ShardTensorDType)
    case invalidLayerRange(start: UInt32, end: UInt32)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    case trailingBytes(Int)
    case epochMismatch(expected: UInt64, actual: UInt64)
    case sequenceGap(expected: UInt64, actual: UInt64)
    case sequenceReplay(expected: UInt64, actual: UInt64)
}

public struct ShardStageFrameHeader: Equatable, Sendable {
    public var kind: ShardFrameKind
    public var dtype: ShardTensorDType
    public var groupEpoch: UInt64
    public var requestID: UInt64
    public var microBatchID: UInt32
    public var tokenStep: UInt32
    public var sourceStage: UInt16
    public var destinationStage: UInt16
    public var layerStart: UInt32
    public var layerEnd: UInt32
    /// Assigned by the sending link; a caller-built header's value is overwritten on send.
    public var sequence: UInt64
    public var shape: [UInt32]
    public var flags: ShardFrameFlags

    public init(
        kind: ShardFrameKind,
        dtype: ShardTensorDType = .none,
        groupEpoch: UInt64,
        requestID: UInt64 = 0,
        microBatchID: UInt32 = 0,
        tokenStep: UInt32 = 0,
        sourceStage: UInt16 = 0,
        destinationStage: UInt16 = 0,
        layerStart: UInt32 = 0,
        layerEnd: UInt32 = 0,
        sequence: UInt64 = 0,
        shape: [UInt32] = [],
        flags: ShardFrameFlags = []
    ) {
        self.kind = kind
        self.dtype = dtype
        self.groupEpoch = groupEpoch
        self.requestID = requestID
        self.microBatchID = microBatchID
        self.tokenStep = tokenStep
        self.sourceStage = sourceStage
        self.destinationStage = destinationStage
        self.layerStart = layerStart
        self.layerEnd = layerEnd
        self.sequence = sequence
        self.shape = shape
        self.flags = flags
    }
}

public struct ShardStageFrame: Equatable, Sendable {
    public var header: ShardStageFrameHeader
    public var payload: Data

    public init(header: ShardStageFrameHeader, payload: Data = Data()) {
        self.header = header
        self.payload = payload
    }
}

public struct ShardFrameLimits: Equatable, Sendable {
    public static let maxRank = 8
    /// 64 MiB covers a multi-thousand-token bf16 prefill chunk of a 7168-wide model.
    public static let defaultPayloadCap = 64 * 1024 * 1024

    public var payloadCap: Int

    public init(payloadCap: Int = ShardFrameLimits.defaultPayloadCap) {
        self.payloadCap = payloadCap
    }
}

public enum ShardStageFrameCodec {
    public static let magic: [UInt8] = [0x4D, 0x50, 0x53, 0x46]
    public static let version: UInt16 = 1
    public static let fixedHeaderSize = 60
    public static let checksumSize = 4

    /// Encoded size of a frame with this rank and payload length.
    public static func frameSize(rank: Int, payloadLength: Int) -> Int {
        fixedHeaderSize + 4 * rank + payloadLength + checksumSize
    }

    public static func encode(_ frame: ShardStageFrame, limits: ShardFrameLimits = ShardFrameLimits()) throws -> Data {
        let header = frame.header
        try validate(header: header, payloadLength: frame.payload.count, limits: limits)
        var bytes = [UInt8]()
        bytes.reserveCapacity(frameSize(rank: header.shape.count, payloadLength: frame.payload.count))
        bytes.append(contentsOf: magic)
        appendLE(&bytes, version)
        bytes.append(header.kind.rawValue)
        bytes.append(header.dtype.rawValue)
        appendLE(&bytes, header.groupEpoch)
        appendLE(&bytes, header.requestID)
        appendLE(&bytes, header.microBatchID)
        appendLE(&bytes, header.tokenStep)
        appendLE(&bytes, header.sourceStage)
        appendLE(&bytes, header.destinationStage)
        appendLE(&bytes, header.layerStart)
        appendLE(&bytes, header.layerEnd)
        appendLE(&bytes, header.sequence)
        appendLE(&bytes, UInt32(frame.payload.count))
        bytes.append(UInt8(header.shape.count))
        bytes.append(header.flags.rawValue)
        bytes.append(contentsOf: [0, 0])
        for dim in header.shape { appendLE(&bytes, dim) }
        bytes.append(contentsOf: frame.payload)
        appendLE(&bytes, CRC32C.checksum(bytes))
        return Data(bytes)
    }

    /// Validate the fixed header prefix and return the full encoded frame length.
    ///
    /// A stream reader calls this on the first `fixedHeaderSize` bytes so it never
    /// allocates for a frame whose header already fails (bad magic, oversize payload).
    public static func frameLength(fixedHeader bytes: Data, limits: ShardFrameLimits = ShardFrameLimits()) throws -> Int {
        guard bytes.count >= fixedHeaderSize else {
            throw ShardFrameError.truncated(needed: fixedHeaderSize, available: bytes.count)
        }
        let fixed = try parseFixed(Array(bytes.prefix(fixedHeaderSize)), limits: limits)
        return frameSize(rank: fixed.rank, payloadLength: fixed.payloadLength)
    }

    /// Strictly decode exactly one frame occupying all of `data`.
    public static func decode(_ data: Data, limits: ShardFrameLimits = ShardFrameLimits()) throws -> ShardStageFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= fixedHeaderSize else {
            throw ShardFrameError.truncated(needed: fixedHeaderSize, available: bytes.count)
        }
        let fixed = try parseFixed(bytes, limits: limits)
        let total = frameSize(rank: fixed.rank, payloadLength: fixed.payloadLength)
        guard bytes.count >= total else {
            throw ShardFrameError.truncated(needed: total, available: bytes.count)
        }
        guard bytes.count == total else {
            throw ShardFrameError.trailingBytes(bytes.count - total)
        }
        let crcOffset = total - checksumSize
        let expected = readLE(bytes, crcOffset, as: UInt32.self)
        let actual = CRC32C.checksum(bytes[0..<crcOffset])
        guard expected == actual else {
            throw ShardFrameError.checksumMismatch(expected: expected, actual: actual)
        }
        var shape = [UInt32]()
        shape.reserveCapacity(fixed.rank)
        for index in 0..<fixed.rank {
            shape.append(readLE(bytes, fixedHeaderSize + 4 * index, as: UInt32.self))
        }
        var header = fixed.header
        header.shape = shape
        try validate(header: header, payloadLength: fixed.payloadLength, limits: limits)
        let payloadStart = fixedHeaderSize + 4 * fixed.rank
        return ShardStageFrame(header: header, payload: Data(bytes[payloadStart..<crcOffset]))
    }

    // MARK: - Internals

    private struct FixedHeader {
        var header: ShardStageFrameHeader
        var rank: Int
        var payloadLength: Int
    }

    private static func parseFixed(_ bytes: [UInt8], limits: ShardFrameLimits) throws -> FixedHeader {
        guard Array(bytes[0..<4]) == magic else { throw ShardFrameError.badMagic }
        let version = readLE(bytes, 4, as: UInt16.self)
        guard version == Self.version else { throw ShardFrameError.unsupportedVersion(version) }
        guard let kind = ShardFrameKind(rawValue: bytes[6]) else { throw ShardFrameError.unknownKind(bytes[6]) }
        guard let dtype = ShardTensorDType(rawValue: bytes[7]) else { throw ShardFrameError.unknownDType(bytes[7]) }
        guard bytes[58] == 0, bytes[59] == 0 else { throw ShardFrameError.nonzeroReserved }
        let flags = ShardFrameFlags(rawValue: bytes[57])
        guard ShardFrameFlags.known.isSuperset(of: flags) else { throw ShardFrameError.unknownFlags(bytes[57]) }
        let rank = Int(bytes[56])
        guard rank <= ShardFrameLimits.maxRank else { throw ShardFrameError.rankTooLarge(rank) }
        let payloadLength = Int(readLE(bytes, 52, as: UInt32.self))
        guard payloadLength <= limits.payloadCap else {
            throw ShardFrameError.payloadTooLarge(length: payloadLength, cap: limits.payloadCap)
        }
        let header = ShardStageFrameHeader(
            kind: kind,
            dtype: dtype,
            groupEpoch: readLE(bytes, 8, as: UInt64.self),
            requestID: readLE(bytes, 16, as: UInt64.self),
            microBatchID: readLE(bytes, 24, as: UInt32.self),
            tokenStep: readLE(bytes, 28, as: UInt32.self),
            sourceStage: readLE(bytes, 32, as: UInt16.self),
            destinationStage: readLE(bytes, 34, as: UInt16.self),
            layerStart: readLE(bytes, 36, as: UInt32.self),
            layerEnd: readLE(bytes, 40, as: UInt32.self),
            sequence: readLE(bytes, 44, as: UInt64.self),
            flags: flags
        )
        return FixedHeader(header: header, rank: rank, payloadLength: payloadLength)
    }

    /// Kind/dtype/shape/payload consistency shared by encode and decode, so a sender
    /// cannot emit a frame its peer would reject.
    private static func validate(header: ShardStageFrameHeader, payloadLength: Int, limits: ShardFrameLimits) throws {
        guard header.shape.count <= ShardFrameLimits.maxRank else {
            throw ShardFrameError.rankTooLarge(header.shape.count)
        }
        guard payloadLength <= limits.payloadCap else {
            throw ShardFrameError.payloadTooLarge(length: payloadLength, cap: limits.payloadCap)
        }
        guard ShardFrameFlags.known.isSuperset(of: header.flags) else {
            throw ShardFrameError.unknownFlags(header.flags.rawValue)
        }
        guard header.flags.isEmpty || header.kind == .activation else {
            throw ShardFrameError.flagsOnNonActivation(kind: header.kind)
        }
        guard header.layerStart <= header.layerEnd else {
            throw ShardFrameError.invalidLayerRange(start: header.layerStart, end: header.layerEnd)
        }
        switch header.kind {
        case .activation:
            guard header.dtype.isFloatingPoint else {
                throw ShardFrameError.kindDTypeMismatch(kind: header.kind, dtype: header.dtype)
            }
        case .token:
            guard header.dtype == .int32 else {
                throw ShardFrameError.kindDTypeMismatch(kind: header.kind, dtype: header.dtype)
            }
        case .tokenLogits:
            guard header.dtype == .int32 else {
                throw ShardFrameError.kindDTypeMismatch(kind: header.kind, dtype: header.dtype)
            }
            // Token, k ids, k logprobs, log-sum-exp: rank 1, an even count of at least 4.
            guard header.shape.count == 1, header.shape[0] >= 4, header.shape[0] % 2 == 0 else {
                throw ShardFrameError.shapePayloadMismatch(expectedBytes: 0, payloadBytes: payloadLength)
            }
        case .hello, .heartbeat, .abort, .error, .control:
            guard header.dtype == .none else {
                throw ShardFrameError.kindDTypeMismatch(kind: header.kind, dtype: header.dtype)
            }
        }
        if header.dtype == .none {
            guard header.shape.isEmpty else {
                throw ShardFrameError.shapePayloadMismatch(expectedBytes: 0, payloadBytes: payloadLength)
            }
            return
        }
        // Overflow-checked element count: a hostile shape must not wrap to a small
        // product that happens to match the payload.
        var expected = header.dtype.byteWidth
        for dim in header.shape {
            let (product, overflow) = expected.multipliedReportingOverflow(by: Int(dim))
            guard !overflow, product <= limits.payloadCap else {
                throw ShardFrameError.shapePayloadMismatch(expectedBytes: Int.max, payloadBytes: payloadLength)
            }
            expected = product
        }
        guard !header.shape.isEmpty, expected == payloadLength else {
            throw ShardFrameError.shapePayloadMismatch(
                expectedBytes: header.shape.isEmpty ? 0 : expected, payloadBytes: payloadLength)
        }
    }

    private static func appendLE<T: FixedWidthInteger>(_ bytes: inout [UInt8], _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func readLE<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int, as: T.Type) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        return value
    }
}

/// Receiver-side link state: every frame on a link must carry the group epoch the
/// link was opened for and the next consecutive sequence number. A gap means a lost
/// frame and a lower number means a replay; both end the link.
public struct ShardLinkReceiveState: Equatable, Sendable {
    public let groupEpoch: UInt64
    public private(set) var expectedSequence: UInt64

    public init(groupEpoch: UInt64, firstSequence: UInt64 = 0) {
        self.groupEpoch = groupEpoch
        self.expectedSequence = firstSequence
    }

    public mutating func accept(_ header: ShardStageFrameHeader) throws {
        guard header.groupEpoch == groupEpoch else {
            throw ShardFrameError.epochMismatch(expected: groupEpoch, actual: header.groupEpoch)
        }
        if header.sequence < expectedSequence {
            throw ShardFrameError.sequenceReplay(expected: expectedSequence, actual: header.sequence)
        }
        if header.sequence > expectedSequence {
            throw ShardFrameError.sequenceGap(expected: expectedSequence, actual: header.sequence)
        }
        expectedSequence &+= 1
    }
}

/// CRC-32C (Castagnoli, reflected polynomial 0x82F63B78), table driven.
public enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
        }
        return crc
    }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        update(0, bytes)
    }

    /// Continue a running checksum; `update(update(0, a), b) == checksum(a + b)`.
    public static func update<C: Collection>(_ crc: UInt32, _ bytes: C) -> UInt32 where C.Element == UInt8 {
        let table = Self.table
        var value = ~crc
        let fast: Void? = bytes.withContiguousStorageIfAvailable { buffer in
            for byte in buffer {
                value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
            }
        }
        if fast == nil {
            for byte in bytes {
                value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
            }
        }
        return ~value
    }
}

/// Payload of a `control` frame. The head sends `open` for each request before its
/// first activation; middles forward it and the last stage samples that request
/// with these parameters. Unknown fields are refused so a peer never silently drops
/// a sampling setting it does not understand.
public struct ShardRequestControl: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case open
    }

    public var operation: Operation
    /// 0 is greedy.
    public var temperature: Float
    /// Nucleus mass in (0, 1]; 1 disables it.
    public var topP: Float
    /// Seeds this request's sampler; nil draws from entropy.
    public var seed: UInt64?
    /// The id members put in their sub-receipts for this request (the coordinator
    /// request id); nil uses the decimal transport request id.
    public var requestID: String?

    public init(operation: Operation = .open, temperature: Float, topP: Float = 1, seed: UInt64? = nil, requestID: String? = nil) {
        self.operation = operation
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case operation = "op"
        case temperature
        case topP = "top_p"
        case seed
        case requestID = "request_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let extra = try decoder.container(keyedBy: ShardAnyCodingKey.self).allKeys.map(\.stringValue).filter { !known.contains($0) }
        guard extra.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown control fields \(extra.sorted())"))
        }
        operation = try container.decode(Operation.self, forKey: .operation)
        temperature = try container.decode(Float.self, forKey: .temperature)
        topP = try container.decode(Float.self, forKey: .topP)
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        guard temperature.isFinite, temperature >= 0, topP.isFinite, topP > 0, topP <= 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "temperature must be >= 0 and top_p within (0, 1]"))
        }
    }
}

struct ShardAnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
