import Foundation
@testable import macprovider_cli
import XCTest

final class RequestTimelineTests: XCTestCase {
    private struct PathCase {
        let name: String
        let replay: Bool
        /// Milliseconds after admission; nil leaves the instant unreached.
        let started: Int?
        let firstToken: Int?
        let firstReasoning: Int?
        let firstAnswer: Int?
        let ended: Int?
        let cancelReceived: Int?
        let outcome: RequestTimeline.ReceiptOutcome
        /// When the receipt is built, after admission.
        let receiptAt: Int
        let expectedTTFT: Int64
        let expectedPrefill: Int64?
    }

    private static let cases: [PathCase] = [
        // Non-streaming: ttft is the full generation latency, not the first token.
        PathCase(name: "serial non-stream", replay: false, started: 5, firstToken: 105, firstReasoning: nil,
                 firstAnswer: 410, ended: 405, cancelReceived: nil, outcome: .nonStreamed,
                 receiptAt: 420, expectedTTFT: 420, expectedPrefill: 100),
        PathCase(name: "serial stream", replay: false, started: 5, firstToken: 105, firstReasoning: nil,
                 firstAnswer: 120, ended: 405, cancelReceived: nil, outcome: .streamed,
                 receiptAt: 420, expectedTTFT: 120, expectedPrefill: 100),
        // Reasoning reaches the buyer first: it is the first visible byte.
        PathCase(name: "CB 1 row", replay: false, started: 30, firstToken: 230, firstReasoning: 240,
                 firstAnswer: 600, ended: 900, cancelReceived: nil, outcome: .streamed,
                 receiptAt: 910, expectedTTFT: 240, expectedPrefill: 200),
        // A waiter on a row already in flight: its first replayed delivery,
        // and no prefill of its own.
        PathCase(name: "CB replay waiter", replay: true, started: 2, firstToken: 50, firstReasoning: nil,
                 firstAnswer: 50, ended: 70, cancelReceived: nil, outcome: .streamed,
                 receiptAt: 80, expectedTTFT: 50, expectedPrefill: nil),
        PathCase(name: "native MTP", replay: false, started: 10, firstToken: 300, firstReasoning: nil,
                 firstAnswer: 505, ended: 500, cancelReceived: nil, outcome: .nonStreamed,
                 receiptAt: 510, expectedTTFT: 510, expectedPrefill: 290),
        PathCase(name: "shard group", replay: false, started: 1, firstToken: 80, firstReasoning: nil,
                 firstAnswer: 90, ended: 200, cancelReceived: nil, outcome: .streamed,
                 receiptAt: 210, expectedTTFT: 90, expectedPrefill: 79),
        // A null-usage error: accepted to the error emitted.
        PathCase(name: "error", replay: false, started: nil, firstToken: nil, firstReasoning: nil,
                 firstAnswer: nil, ended: nil, cancelReceived: nil, outcome: .nullUsageError,
                 receiptAt: 15, expectedTTFT: 15, expectedPrefill: nil),
        PathCase(name: "cancel with delivered output", replay: false, started: 5, firstToken: 50, firstReasoning: nil,
                 firstAnswer: 60, ended: nil, cancelReceived: 100, outcome: .buyerCancel,
                 receiptAt: 120, expectedTTFT: 60, expectedPrefill: 45),
        PathCase(name: "cancel without delivered output", replay: false, started: 5, firstToken: nil, firstReasoning: nil,
                 firstAnswer: nil, ended: nil, cancelReceived: 40, outcome: .buyerCancel,
                 receiptAt: 60, expectedTTFT: 40, expectedPrefill: nil),
        // A conversation-cache hit: the first token follows the restore at once.
        PathCase(name: "cache hit", replay: false, started: 10, firstToken: 10, firstReasoning: nil,
                 firstAnswer: 12, ended: 50, cancelReceived: nil, outcome: .streamed,
                 receiptAt: 60, expectedTTFT: 12, expectedPrefill: 0),
    ]

    func testEveryServingPathDerivesTheSameFieldsAndReceiptTTFT() throws {
        let base = ContinuousClock.now
        func at(_ ms: Int?) -> ContinuousClock.Instant? { ms.map { base + .milliseconds($0) } }

        for path in Self.cases {
            let timeline = RequestTimeline(admitted: base)
            if path.replay { timeline.markReplayAttach() }
            if let started = at(path.started) { timeline.markStarted(at: started) }
            if let firstToken = at(path.firstToken) { timeline.markFirstToken(at: firstToken) }
            if let reasoning = at(path.firstReasoning) { timeline.mark(.firstReasoning, at: reasoning) }
            if let answer = at(path.firstAnswer) { timeline.mark(.firstAnswer, at: answer) }
            if let ended = at(path.ended) { timeline.markEnded(at: ended) }
            if let cancel = at(path.cancelReceived) { timeline.markCancelReceived(at: cancel) }
            let marks = timeline.snapshot()

            // Same fields on every path; nil only where the instant was not reached.
            XCTAssertEqual(marks.queueMs, path.started.map(Int64.init), path.name)
            XCTAssertEqual(marks.firstTokenMs, path.firstToken.map(Int64.init), path.name)
            XCTAssertEqual(marks.firstAnswerMs, path.firstAnswer.map(Int64.init), path.name)
            XCTAssertEqual(marks.prefillWallMs, path.expectedPrefill, path.name)
            if let firstToken = path.firstToken, let ended = path.ended {
                XCTAssertEqual(marks.decodeMs, Int64(ended - firstToken), path.name)
            } else {
                XCTAssertNil(marks.decodeMs, path.name)
            }

            // admitted <= started <= firstToken <= ended.
            let ordered = [marks.started, marks.firstToken, marks.ended].compactMap { $0 }
            XCTAssertEqual(ordered, ordered.sorted(), path.name)
            XCTAssertTrue(ordered.allSatisfy { marks.admitted <= $0 }, path.name)

            let ttft = timeline.receiptTTFTMilliseconds(path.outcome, now: base + .milliseconds(path.receiptAt))
            XCTAssertEqual(ttft, path.expectedTTFT, path.name)
            if case .buyerCancel = path.outcome {
                XCTAssertGreaterThan(ttft, 0, path.name)
            }
        }
    }

    func testFirstMarkWins() {
        let base = ContinuousClock.now
        let timeline = RequestTimeline(admitted: base)
        timeline.markFirstToken(at: base + .milliseconds(20))
        timeline.markFirstToken(at: base + .milliseconds(90))
        timeline.markStarted(at: base + .milliseconds(5))
        let marks = timeline.snapshot()
        XCTAssertEqual(marks.firstTokenMs, 20)
        // The first token marked the queue exit too, at the same instant.
        XCTAssertEqual(marks.queueMs, 20)
        XCTAssertEqual(marks.prefillWallMs, 0)
    }

    func testEmittedChunksMarkOnlyBuyerVisibleBytes() {
        let timeline = RequestTimeline()
        timeline.noteEmitted(.progress)
        timeline.noteEmitted(.content(""))
        timeline.noteEmitted(.reasoning(""))
        XCTAssertNil(timeline.snapshot().firstVisible)

        timeline.noteEmitted(.reasoning("thinking"))
        XCTAssertNotNil(timeline.snapshot().firstReasoning)
        XCTAssertNil(timeline.snapshot().firstAnswer)

        timeline.noteEmitted(.toolCallDelta(StreamToolCallDelta(index: 0, id: "call", type: "function", functionName: "f", arguments: "")))
        XCTAssertNotNil(timeline.snapshot().firstAnswer)
    }

    func testNoChunkEmittedMarksNothingAndTheWrappedSinkPassesChunksThrough() {
        let timeline = RequestTimeline()
        let delivered = LockedChunks()
        // A sink built for a token the stream filter holds back emits nothing.
        _ = timeline.noting { delivered.append($0) }
        XCTAssertNil(timeline.snapshot().firstVisible)

        let sink = timeline.noting { delivered.append($0) }
        sink(.progress)
        XCTAssertNil(timeline.snapshot().firstVisible)
        sink(.content("hello"))
        XCTAssertEqual(delivered.count, 2)
        XCTAssertNotNil(timeline.snapshot().firstAnswer)
    }

    func testReplayWaiterCountsItsFirstReplayedDelivery() {
        // Rule change from the removed ContinuousBatchFirstTokenClock: a waiter
        // that attaches to a row in flight now counts its first replayed
        // delivery as its first token, with no prefill of its own.
        let timeline = RequestTimeline()
        let snapshot = ContinuousBatchSchedulerSnapshot(modelID: "m", modelSHA256: "h", weightsGeneration: 0)
        ModelRuntime.noteContinuousBatchTokenEvent(
            ContinuousBatchSchedulerTokenEvent(requestID: "r", tokenIndex: 2, token: 9, replayTokens: [7, 8, 9], snapshot: snapshot),
            on: timeline
        )
        timeline.noteEmitted(.content("caught-up"))
        let marks = timeline.snapshot()
        XCTAssertTrue(marks.replayed)
        XCTAssertNotNil(marks.firstToken)
        XCTAssertNil(marks.prefillWallMs)
        XCTAssertNotNil(marks.firstAnswer)
        XCTAssertEqual(timeline.receiptTTFTMilliseconds(.streamed, now: .now + .seconds(60)), marks.firstAnswerMs)
    }

    func testNonStreamingReceiptIsFullLatencyWhileFirstTokenStaysEarlier() {
        // Bench tools read `firstTokenMs`; receipts read the full latency.
        let base = ContinuousClock.now
        let timeline = RequestTimeline(admitted: base)
        timeline.markStarted(at: base + .milliseconds(4))
        timeline.markFirstToken(at: base + .milliseconds(30))
        timeline.markEnded(at: base + .milliseconds(250))
        let full = timeline.receiptTTFTMilliseconds(.nonStreamed, now: base + .milliseconds(260))
        let firstToken = try? XCTUnwrap(timeline.snapshot().firstTokenMs)
        XCTAssertEqual(full, 260)
        XCTAssertEqual(firstToken, 30)
        XCTAssertLessThan(firstToken ?? .max, full)
    }

    func testNonStreamingResponseMarksAnswerAndReasoningTogether() {
        let timeline = RequestTimeline()
        timeline.noteResponseComplete(CompletionResult(
            content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 1,
            settlementDisposition: .eligibleOwner, reasoningContent: "why"
        ))
        let marks = timeline.snapshot()
        XCTAssertNotNil(marks.firstAnswer)
        XCTAssertEqual(marks.firstAnswer, marks.firstReasoning)
    }

    func testStreamWithNothingVisibleReportsTheWholeRequest() {
        let base = ContinuousClock.now
        let timeline = RequestTimeline(admitted: base)
        timeline.markFirstToken(at: base + .milliseconds(10))
        XCTAssertEqual(timeline.receiptTTFTMilliseconds(.streamed, now: base + .milliseconds(75)), 75)
    }

    func testReceiptTTFTIsNeverNegative() {
        // An admission stamped in the future (clock skew) is clamped to now.
        let timeline = RequestTimeline(admittedAt: Date().addingTimeInterval(60))
        XCTAssertGreaterThanOrEqual(timeline.receiptTTFTMilliseconds(.nonStreamed), 0)
        XCTAssertGreaterThanOrEqual(timeline.receiptTTFTMilliseconds(.nullUsageError), 0)
        XCTAssertGreaterThanOrEqual(timeline.receiptTTFTMilliseconds(.buyerCancel), 0)
    }

    func testWallClockAdmissionCarriesOntoTheMonotonicClock() {
        let now = Date()
        let clockNow = ContinuousClock.now
        let timeline = RequestTimeline(admittedAt: now.addingTimeInterval(-0.25), now: now, clockNow: clockNow)
        XCTAssertEqual(RequestTimeline.milliseconds(from: timeline.admitted, to: clockNow), 250)
    }

    func testUsageCarriesTimelineFieldsAndNullsUnreachedInstants() throws {
        let base = ContinuousClock.now
        let timeline = RequestTimeline(admitted: base)
        timeline.markStarted(at: base + .milliseconds(3))
        timeline.markFirstToken(at: base + .milliseconds(40))
        timeline.markEnded(at: base + .milliseconds(140))
        let completion = CompletionResult(
            content: "", finishReason: "stop", promptTokens: 1, completionTokens: 1,
            generationMilliseconds: 99, settlementDisposition: .eligibleOwner, timeline: timeline
        )
        let usage = RouterHandler.usage(completion)
        XCTAssertEqual(usage["macprovider_queue_ms"] as? Int64, 3)
        XCTAssertEqual(usage["macprovider_first_token_ms"] as? Int64, 40)
        XCTAssertTrue(usage["macprovider_first_answer_ms"] is NSNull)
        XCTAssertEqual(usage["macprovider_decode_ms"] as? Int64, 100)
        // `macprovider_generation_ms` is the runtime's own value, unchanged.
        XCTAssertEqual(usage["macprovider_generation_ms"] as? Int64, 99)

        let untimed = RouterHandler.usage(CompletionResult(
            content: "", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner
        ))
        for key in ["macprovider_queue_ms", "macprovider_first_token_ms", "macprovider_first_answer_ms", "macprovider_decode_ms"] {
            XCTAssertTrue(untimed[key] is NSNull, key)
        }
    }
}

private final class LockedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [StreamChunk] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }

    func append(_ chunk: StreamChunk) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }
}
