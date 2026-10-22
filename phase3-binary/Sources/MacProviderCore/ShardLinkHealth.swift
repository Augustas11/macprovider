import Foundation

// Issue #2084 continuous link health (SPEC-051-R007, R014, R015). Every heartbeat
// is a ping the peer's reader thread echoes at once, so each end keeps a sliding
// window of round trips measured while the link carries real traffic. A ping also
// carries the link round trips its sender knows, so measurements made by members
// on links the head does not touch travel down the chain to the head.
//
// Heartbeat payload, little-endian:
//
//   off size field
//     0    1 kind (1 ping, 2 echo)
//     1    8 nonce
//     9    1 link entry count n (0 for an echo, at most `maxEntries`)
//    10 10*n entries: from stage u16, to stage u16, rtt p99 us u32, samples u16

/// One link's measured round trip, as a ping reports it.
public struct ShardLinkHealth: Equatable, Sendable {
    public var fromStage: UInt16
    public var toStage: UInt16
    public var rttP99Microseconds: UInt32
    public var samples: UInt16

    public init(fromStage: UInt16, toStage: UInt16, rttP99Microseconds: UInt32, samples: UInt16) {
        self.fromStage = fromStage
        self.toStage = toStage
        self.rttP99Microseconds = rttP99Microseconds
        self.samples = samples
    }
}

public struct ShardHeartbeatPayload: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case ping = 1
        case echo = 2
    }

    public static let maxEntries = 16
    static let entrySize = 10

    public var kind: Kind
    public var nonce: UInt64
    public var links: [ShardLinkHealth]

    public init(kind: Kind, nonce: UInt64, links: [ShardLinkHealth] = []) {
        self.kind = kind
        self.nonce = nonce
        self.links = links
    }

    public func encode() -> Data {
        var bytes = [UInt8]()
        let entries = kind == .ping ? Array(links.prefix(Self.maxEntries)) : []
        bytes.reserveCapacity(10 + Self.entrySize * entries.count)
        bytes.append(kind.rawValue)
        withUnsafeBytes(of: nonce.littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(UInt8(entries.count))
        for entry in entries {
            withUnsafeBytes(of: entry.fromStage.littleEndian) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: entry.toStage.littleEndian) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: entry.rttP99Microseconds.littleEndian) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: entry.samples.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes)
    }

    /// Strict: an unknown kind, an echo with entries, too many entries or a length
    /// that disagrees with the count is refused.
    public static func decode(_ data: Data) throws -> ShardHeartbeatPayload {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, let kind = Kind(rawValue: bytes[0]) else { throw ShardFrameError.malformedHeartbeat }
        let count = Int(bytes[9])
        guard count <= maxEntries, kind == .ping || count == 0, bytes.count == 10 + entrySize * count else {
            throw ShardFrameError.malformedHeartbeat
        }
        func read<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size { value |= T(bytes[offset + index]) << (8 * index) }
            return value
        }
        let links = (0..<count).map { index -> ShardLinkHealth in
            let base = 10 + entrySize * index
            return ShardLinkHealth(
                fromStage: read(base, UInt16.self), toStage: read(base + 2, UInt16.self),
                rttP99Microseconds: read(base + 4, UInt32.self), samples: read(base + 8, UInt16.self))
        }
        return ShardHeartbeatPayload(kind: kind, nonce: read(1, UInt64.self), links: links)
    }
}

/// Round trips of one link's last `capacity` heartbeat echoes.
public struct ShardRoundTripWindow: Equatable, Sendable {
    public static let defaultCapacity = 256
    public let capacity: Int
    private var samples: [Double] = []
    private var next = 0
    public private(set) var p99Seconds: Double?

    public init(capacity: Int = ShardRoundTripWindow.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { samples.count }

    public mutating func add(_ seconds: Double) {
        if samples.count < capacity {
            samples.append(seconds)
        } else {
            samples[next] = seconds
        }
        next = (next + 1) % capacity
        let sorted = samples.sorted()
        p99Seconds = sorted[max(0, Int((0.99 * Double(sorted.count)).rounded(.up)) - 1)]
    }

    /// The window's p99 and sample count as a ping entry for `from` -> `to`.
    public func health(from: UInt16, to: UInt16) -> ShardLinkHealth? {
        guard let p99Seconds else { return nil }
        return ShardLinkHealth(
            fromStage: from, toStage: to, rttP99Microseconds: UInt32(min(Double(UInt32.max), (p99Seconds * 1e6).rounded(.up))),
            samples: UInt16(min(samples.count, Int(UInt16.max))))
    }
}

/// What a link's owner reads about its health.
public struct ShardLinkRoundTrip: Equatable, Sendable {
    public var samples: Int
    public var p99Seconds: Double?
    /// The link entries the peer's latest ping carried, and when it arrived
    /// (`CLOCK_UPTIME_RAW` seconds); nil before the first ping.
    public var peerLinks: [ShardLinkHealth]
    public var peerLinksAt: TimeInterval?

    public init(samples: Int, p99Seconds: Double?, peerLinks: [ShardLinkHealth], peerLinksAt: TimeInterval?) {
        self.samples = samples
        self.p99Seconds = p99Seconds
        self.peerLinks = peerLinks
        self.peerLinksAt = peerLinksAt
    }

    public var p99Microseconds: Int? { p99Seconds.map { Int(($0 * 1e6).rounded(.up)) } }
}
