import Foundation

/// The one per-request clock (SPEC-015 §3, SPEC-001 usage timing). Every
/// serving path marks the same instants on a monotonic `ContinuousClock`, and
/// the receipt `ttft_ms` and the usage timing fields are derived from it.
///
/// Marks are idempotent: the first mark of an instant wins. A mark already
/// taken returns after one unlocked flag read, so a decode loop that marks
/// on every token takes the lock only for the first one.
final class RequestTimeline: @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    /// The timeline of the request the current task serves. The transport
    /// binds it at provider admission; a runtime entry that finds none (a
    /// bench or a direct runtime call) starts its own.
    @TaskLocal static var current: RequestTimeline?

    enum Mark: UInt8, CaseIterable {
        /// Left the queue: prefill or cache restore begins.
        case started
        /// First sampled token of any channel.
        case firstToken
        /// First reasoning delta emitted to the buyer.
        case firstReasoning
        /// First content or tool-call delta emitted to the buyer, after
        /// output filtering.
        case firstAnswer
        /// Last token sampled.
        case ended
        /// The buyer's cancel reached the provider.
        case cancelReceived
    }

    /// What the receipt is signed for (SPEC-015 §3 `ttft_ms`).
    enum ReceiptOutcome: Sendable {
        case streamed
        case nonStreamed
        case nullUsageError
        case buyerCancel
    }

    struct Snapshot: Sendable, Equatable {
        let admitted: Instant
        let started: Instant?
        let firstToken: Instant?
        let firstReasoning: Instant?
        let firstAnswer: Instant?
        let ended: Instant?
        let cancelReceived: Instant?
        /// A CB waiter that attached to a row already in flight: its first
        /// token is a replayed delivery, and it ran no prefill of its own.
        let replayed: Bool

        var firstVisible: Instant? {
            switch (firstReasoning, firstAnswer) {
            case let (reasoning?, answer?): return min(reasoning, answer)
            case let (reasoning?, nil): return reasoning
            case let (nil, answer?): return answer
            case (nil, nil): return nil
            }
        }

        var queueMs: Int64? { RequestTimeline.milliseconds(from: admitted, to: started) }
        var prefillWallMs: Int64? {
            replayed ? nil : RequestTimeline.milliseconds(from: started, to: firstToken)
        }
        var firstTokenMs: Int64? { RequestTimeline.milliseconds(from: admitted, to: firstToken) }
        var firstAnswerMs: Int64? { RequestTimeline.milliseconds(from: admitted, to: firstAnswer) }
        var decodeMs: Int64? { RequestTimeline.milliseconds(from: firstToken, to: ended) }
    }

    let admitted: Instant
    private let lock = NSLock()
    private var instants = [Instant?](repeating: nil, count: Mark.allCases.count)
    /// One bit per `Mark`; written under `lock`, read without it first. A
    /// bit only ever goes 0 -> 1, so a stale 0 just falls through to the
    /// locked, idempotent path.
    private var markedBits: UInt8 = 0
    private var replayed = false

    init(admitted: Instant = .now) {
        self.admitted = admitted
    }

    /// Admission recorded as a wall-clock `Date` (provider admission returns
    /// one), carried onto the monotonic clock.
    convenience init(admittedAt date: Date, now: Date = Date(), clockNow: Instant = .now) {
        self.init(admitted: clockNow - .seconds(max(0, now.timeIntervalSince(date))))
    }

    func mark(_ mark: Mark, at instant: Instant? = nil) {
        let bit = UInt8(1) << mark.rawValue
        if markedBits & bit != 0 { return }
        let now = instant ?? .now
        lock.lock()
        defer { lock.unlock() }
        if markedBits & bit != 0 { return }
        instants[Int(mark.rawValue)] = now
        markedBits |= bit
    }

    func isMarked(_ mark: Mark) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return markedBits & (UInt8(1) << mark.rawValue) != 0
    }

    func markStarted(at instant: Instant? = nil) {
        mark(.started, at: instant)
    }

    /// The first sampled token. A path that never observed the queue exit
    /// (a duplicate waiter, a test runtime) starts at the same instant, so
    /// `started <= firstToken` always holds.
    func markFirstToken(at instant: Instant? = nil) {
        if markedBits & (UInt8(1) << Mark.firstToken.rawValue) != 0 { return }
        let now = instant ?? .now
        mark(.started, at: now)
        mark(.firstToken, at: now)
    }

    func markEnded(at instant: Instant? = nil) {
        mark(.ended, at: instant)
    }

    func markCancelReceived(at instant: Instant? = nil) {
        mark(.cancelReceived, at: instant)
    }

    /// A CB duplicate waiter attached to a row already producing output.
    func markReplayAttach() {
        lock.lock()
        replayed = true
        lock.unlock()
    }

    /// Records a chunk the buyer is sent. Progress carries no bytes.
    func noteEmitted(_ chunk: StreamChunk) {
        switch chunk {
        case .reasoning(let text):
            if !text.isEmpty { mark(.firstReasoning) }
        case .content(let text):
            if !text.isEmpty { mark(.firstAnswer) }
        case .toolCallDelta:
            mark(.firstAnswer)
        case .progress:
            break
        }
    }

    /// A non-streaming response reaches the buyer whole, at once.
    func noteResponseComplete(_ completion: CompletionResult) {
        let now = Instant.now
        if completion.reasoningContent?.isEmpty == false {
            mark(.firstReasoning, at: now)
        }
        if !completion.content.isEmpty || completion.toolCalls?.isEmpty == false {
            mark(.firstAnswer, at: now)
        }
    }

    /// Wraps a buyer chunk sink so each emitted chunk is recorded.
    func noting(_ onChunk: @escaping @Sendable (StreamChunk) -> Void) -> @Sendable (StreamChunk) -> Void {
        { chunk in
            self.noteEmitted(chunk)
            onChunk(chunk)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            admitted: admitted,
            started: instants[Int(Mark.started.rawValue)],
            firstToken: instants[Int(Mark.firstToken.rawValue)],
            firstReasoning: instants[Int(Mark.firstReasoning.rawValue)],
            firstAnswer: instants[Int(Mark.firstAnswer.rawValue)],
            ended: instants[Int(Mark.ended.rawValue)],
            cancelReceived: instants[Int(Mark.cancelReceived.rawValue)],
            replayed: replayed
        )
    }

    /// Milliseconds from the first sampled token to `end`; nil before it.
    func millisecondsSinceFirstToken(until end: Instant) -> Int64? {
        Self.milliseconds(from: snapshot().firstToken, to: end)
    }

    /// The receipt `ttft_ms` (SPEC-015 §3), measured from request accepted:
    /// - streamed: to the first buyer-visible output byte, or the whole
    ///   request when nothing visible was emitted;
    /// - non-streamed: full generation latency, to the response complete now;
    /// - null-usage error: to the error emitted now;
    /// - buyer cancel: to the first buyer-visible byte when output was
    ///   delivered, otherwise to the cancel received.
    /// Never negative and never missing.
    func receiptTTFTMilliseconds(_ outcome: ReceiptOutcome, now: Instant = .now) -> Int64 {
        let timeline = snapshot()
        let end: Instant
        switch outcome {
        case .streamed:
            end = timeline.firstVisible ?? now
        case .nonStreamed, .nullUsageError:
            end = now
        case .buyerCancel:
            end = timeline.firstVisible ?? timeline.cancelReceived ?? now
        }
        return Self.milliseconds(from: admitted, to: end) ?? 0
    }

    static func milliseconds(from start: Instant?, to end: Instant?) -> Int64? {
        guard let start, let end else { return nil }
        let components = (end - start).components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return max(0, milliseconds)
    }
}
