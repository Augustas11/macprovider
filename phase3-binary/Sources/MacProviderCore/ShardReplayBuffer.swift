import Foundation

// Issue #2084 replay (SPEC-051-R022, Petals-style): the head keeps the activation
// frames it sent to its downstream stage for every in-flight request, so a spare
// holding the same layers can be brought up to the delivered prefix after that stage
// is lost, without recomputing anything upstream and without re-emitting a token.
//
// Bounded by bytes: a request whose frames would push the buffer past its capacity
// stops being buffered and is marked not replayable, so the head can say so
// explicitly when it loses the stage instead of replaying a partial prefix.

public enum ShardReplayError: Error, Equatable, Sendable {
    case notReplayable(requestID: UInt64)
    /// A buffered frame asks for a token past the next undelivered one: the buffer and
    /// the delivered count disagree, so replay would re-emit or skip a token.
    case frameAhead(requestID: UInt64, tokenStep: UInt32, delivered: Int)
}

public struct ShardReplayBuffer: Sendable {
    public let capacityBytes: Int
    public private(set) var usedBytes = 0
    private var frames: [UInt64: [ShardStageFrame]] = [:]
    private var overflowed: Set<UInt64> = []

    public init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
    }

    /// Requests with buffered frames or marked not replayable, in id order.
    public var requestIDs: [UInt64] {
        Set(frames.keys).union(overflowed).sorted()
    }

    public func isReplayable(_ requestID: UInt64) -> Bool {
        !overflowed.contains(requestID)
    }

    /// Keep a frame the head is about to send downstream.
    public mutating func append(_ frame: ShardStageFrame) {
        let requestID = frame.header.requestID
        guard !overflowed.contains(requestID) else { return }
        guard usedBytes + frame.payload.count <= capacityBytes else {
            usedBytes -= bytes(of: requestID)
            frames[requestID] = nil
            overflowed.insert(requestID)
            return
        }
        frames[requestID, default: []].append(frame)
        usedBytes += frame.payload.count
    }

    /// Forget a finished request.
    public mutating func remove(requestID: UInt64) {
        usedBytes -= bytes(of: requestID)
        frames[requestID] = nil
        overflowed.remove(requestID)
    }

    /// The frames that bring a fresh stage up to `deliveredTokens` tokens of this
    /// request, in the order first sent. Every frame whose token was already delivered
    /// becomes fill-only, so the replacement fills its KV without sampling; the frame
    /// for the next undelivered token (if already sent) keeps asking for it.
    public func replayPlan(requestID: UInt64, deliveredTokens: Int) throws -> [ShardStageFrame] {
        guard isReplayable(requestID) else { throw ShardReplayError.notReplayable(requestID: requestID) }
        return try (frames[requestID] ?? []).map { frame in
            var replayed = frame
            guard !frame.header.flags.contains(.fillOnly) else { return replayed }
            let step = Int(frame.header.tokenStep)
            if step < deliveredTokens {
                replayed.header.flags.insert(.fillOnly)
            } else if step > deliveredTokens {
                throw ShardReplayError.frameAhead(requestID: requestID, tokenStep: frame.header.tokenStep, delivered: deliveredTokens)
            }
            return replayed
        }
    }

    private func bytes(of requestID: UInt64) -> Int {
        (frames[requestID] ?? []).reduce(0) { $0 + $1.payload.count }
    }
}
