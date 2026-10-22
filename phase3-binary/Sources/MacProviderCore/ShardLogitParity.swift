import Foundation

// Issue #2084 teacher-forced tolerance parity. Exact greedy-token parity against a
// single-machine reference fails on any mixed-chip group: the full model alone on
// an M3 and on an M5 already diverge at the same step, from floating-point drift
// at a near tie. So qualification feeds the reference tokens through the sharded
// chain and compares, step by step, a compact summary of the last stage's logits
// with the reference's for the same prefix.

/// Top-k token ids with their log-probabilities, plus the full-vocab log-sum-exp of
/// the raw logits. Ids are in descending logprob order.
public struct ShardLogitSummary: Codable, Equatable, Sendable {
    public var topTokens: [Int32]
    public var topLogprobs: [Float]
    public var logSumExp: Float

    public init(topTokens: [Int32], topLogprobs: [Float], logSumExp: Float) {
        self.topTokens = topTokens
        self.topLogprobs = topLogprobs
        self.logSumExp = logSumExp
    }

    public var top1: Int32 { topTokens[0] }

    /// Reference top-1 minus top-2 logprob (infinite with k = 1).
    public var margin: Float { topLogprobs.count > 1 ? topLogprobs[0] - topLogprobs[1] : .infinity }
}

public enum ShardLogitSummaryError: Error, Equatable, Sendable {
    case badShape([UInt32])
    case lengthMismatch(expected: Int, actual: Int)
    case badTopK(Int)
    case nonFinite
    case notDescending
}

/// Payload of a `tokenLogits` frame: int32 elements, shape `[2 + 2k]`:
/// sampled token, k token ids, k logprobs (float32 bit patterns), log-sum-exp
/// (float32 bit pattern). Little-endian like the rest of the frame.
public enum ShardLogitSummaryCodec {
    public static let maxTopK = 64

    public static func encode(token: Int32, summary: ShardLogitSummary) throws -> (shape: [UInt32], payload: Data) {
        try validate(summary)
        var words = [UInt32]()
        words.reserveCapacity(2 + 2 * summary.topTokens.count)
        words.append(UInt32(bitPattern: token))
        words += summary.topTokens.map { UInt32(bitPattern: $0) }
        words += summary.topLogprobs.map(\.bitPattern)
        words.append(summary.logSumExp.bitPattern)
        var payload = Data(capacity: words.count * 4)
        for word in words { withUnsafeBytes(of: word.littleEndian) { payload.append(contentsOf: $0) } }
        return ([UInt32(words.count)], payload)
    }

    public static func decode(shape: [UInt32], payload: Data) throws -> (token: Int32, summary: ShardLogitSummary) {
        guard shape.count == 1, shape[0] >= 4, shape[0] % 2 == 0 else { throw ShardLogitSummaryError.badShape(shape) }
        let count = Int(shape[0])
        guard payload.count == count * 4 else {
            throw ShardLogitSummaryError.lengthMismatch(expected: count * 4, actual: payload.count)
        }
        let words: [UInt32] = payload.withUnsafeBytes { buffer in
            (0..<count).map { UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        let k = (count - 2) / 2
        let summary = ShardLogitSummary(
            topTokens: words[1...k].map { Int32(bitPattern: $0) },
            topLogprobs: words[(k + 1)...(2 * k)].map { Float(bitPattern: $0) },
            logSumExp: Float(bitPattern: words[count - 1]))
        try validate(summary)
        return (Int32(bitPattern: words[0]), summary)
    }

    static func validate(_ summary: ShardLogitSummary) throws {
        let k = summary.topTokens.count
        guard (1...maxTopK).contains(k), summary.topLogprobs.count == k else { throw ShardLogitSummaryError.badTopK(k) }
        guard summary.logSumExp.isFinite, summary.topLogprobs.allSatisfy(\.isFinite) else {
            throw ShardLogitSummaryError.nonFinite
        }
        guard zip(summary.topLogprobs, summary.topLogprobs.dropFirst()).allSatisfy({ $0 >= $1 }) else {
            throw ShardLogitSummaryError.notDescending
        }
    }
}

public struct ShardParityHardFailure: Codable, Equatable, Sendable {
    public var sequence: Int
    public var step: Int
    public var referenceToken: Int32
    public var shardedToken: Int32
    public var referenceMargin: Float
}

public struct ShardTeacherForcedParity: Codable, Equatable, Sendable {
    public var verdict: String
    public var steps: Int
    /// Steps whose sharded top-1 equals the reference top-1, over all steps.
    public var top1AgreementRate: Double
    public var nearTieFlips: Int
    public var hardFailures: [ShardParityHardFailure]
    /// |reference logprob - sharded logprob| of the reference token. When that token
    /// fell outside the sharded top-k, its sharded logprob is at most the k-th one,
    /// so the k-th one gives a lower bound on the difference.
    public var maxAbsDeltaLogprob: Double
    public var p99AbsDeltaLogprob: Double
    /// Mean |sharded top-k ∩ reference top-k| / k.
    public var meanTopKOverlap: Double
    /// Smallest reference top-1/top-2 margin seen (-1 when k = 1 gives no margin).
    public var minReferenceMargin: Double
    public var tieMargin: Double
    public var logprobTolerance: Double
}

public enum ShardLogitParityError: Error, Equatable, Sendable {
    case sequenceCount(reference: Int, sharded: Int)
    case stepCount(sequence: Int, reference: Int, sharded: Int)
}

public enum ShardLogitParity {
    /// Compare per-step summaries, `[sequence][step]`, from the same prefixes. A step
    /// passes when the top-1 tokens agree, or when they differ at a near tie: the
    /// reference margin is below `tieMargin` and the sharded top-1 is the reference
    /// top-2. The run fails on any hard failure or a p99 |Δ logprob| above
    /// `logprobTolerance`.
    public static func compare(
        reference: [[ShardLogitSummary]],
        sharded: [[ShardLogitSummary]],
        tieMargin: Double = 0.05,
        logprobTolerance: Double = 0.1
    ) throws -> ShardTeacherForcedParity {
        guard reference.count == sharded.count else {
            throw ShardLogitParityError.sequenceCount(reference: reference.count, sharded: sharded.count)
        }
        var steps = 0
        var agreed = 0
        var nearTies = 0
        var failures = [ShardParityHardFailure]()
        var deltas = [Double]()
        var overlap = 0.0
        var minMargin = Double.infinity
        for (sequence, (expected, actual)) in zip(reference, sharded).enumerated() {
            guard expected.count == actual.count else {
                throw ShardLogitParityError.stepCount(sequence: sequence, reference: expected.count, sharded: actual.count)
            }
            for (step, (ref, got)) in zip(expected, actual).enumerated() {
                steps += 1
                minMargin = min(minMargin, Double(ref.margin))
                if got.top1 == ref.top1 {
                    agreed += 1
                } else if Double(ref.margin) < tieMargin, ref.topTokens.count > 1, got.top1 == ref.topTokens[1] {
                    nearTies += 1
                } else {
                    failures.append(ShardParityHardFailure(
                        sequence: sequence, step: step, referenceToken: ref.top1, shardedToken: got.top1,
                        referenceMargin: ref.margin))
                }
                let shardedLogprob = got.topTokens.firstIndex(of: ref.top1).map { got.topLogprobs[$0] }
                    ?? got.topLogprobs[got.topLogprobs.count - 1]
                deltas.append(abs(Double(ref.topLogprobs[0]) - Double(shardedLogprob)))
                let shared = Set(ref.topTokens).intersection(got.topTokens).count
                overlap += Double(shared) / Double(max(ref.topTokens.count, got.topTokens.count))
            }
        }
        let sorted = deltas.sorted()
        let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((0.99 * Double(sorted.count - 1)).rounded(.up)))]
        let maxDelta = sorted.last ?? 0
        return ShardTeacherForcedParity(
            verdict: failures.isEmpty && p99 <= logprobTolerance && steps > 0 ? "pass" : "fail",
            steps: steps,
            top1AgreementRate: steps == 0 ? 0 : Double(agreed) / Double(steps),
            nearTieFlips: nearTies,
            hardFailures: failures,
            maxAbsDeltaLogprob: maxDelta,
            p99AbsDeltaLogprob: p99,
            meanTopKOverlap: steps == 0 ? 0 : overlap / Double(steps),
            minReferenceMargin: minMargin.isFinite ? minMargin : -1,
            tieMargin: tieMargin,
            logprobTolerance: logprobTolerance)
    }
}
