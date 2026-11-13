import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// #2319: the heartbeat decode rate and native-MTP acceptance are aggregated
/// from each request's timeline and counters once, at request completion.
final class HeartbeatDecodeWindowTests: XCTestCase {
    private typealias Instant = RequestTimeline.Instant

    private func timeline(
        origin: Instant,
        firstTokenAtMs: Int?,
        endedAtMs: Int?,
        replayed: Bool = false
    ) -> RequestTimeline {
        let timeline = RequestTimeline(admitted: origin)
        if replayed { timeline.markReplayAttach() }
        if let firstTokenAtMs { timeline.markFirstToken(at: origin + .milliseconds(firstTokenAtMs)) }
        if let endedAtMs { timeline.markEnded(at: origin + .milliseconds(endedAtMs)) }
        return timeline
    }

    private func completion(
        visibleTokens: Int,
        generatedTokens: Int,
        timeline: RequestTimeline?,
        mtpProposed: Int = 0,
        mtpAccepted: Int = 0
    ) -> CompletionResult {
        CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 5,
            completionTokens: visibleTokens,
            generatedCompletionTokens: generatedTokens,
            settlementDisposition: .eligibleOwner,
            nativeMTPProposedTokens: mtpProposed,
            nativeMTPAcceptedTokens: mtpAccepted,
            timeline: timeline
        )
    }

    private func makeStatus() -> ProviderStatus {
        ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: 4)
        )
    }

    // MARK: - per-request sample

    func testSampleCountsGeneratedTokensNotTheVisibleFinalChannel() throws {
        // gpt-oss: 3 final-channel tokens reach the buyer, 101 were decoded.
        let origin = Instant.now
        let sample = try XCTUnwrap(ProviderStatus.decodeSample(completion(
            visibleTokens: 3,
            generatedTokens: 101,
            timeline: timeline(origin: origin, firstTokenAtMs: 400, endedAtMs: 1_400)
        )))
        XCTAssertEqual(sample.tokens, 100, "tokens after the first, from generatedCompletionTokens")
        XCTAssertEqual(sample.milliseconds, 1_000, "first token to last, queue and prefill excluded")
    }

    func testSampleSkipsRequestsWithoutADecodeInterval() {
        let origin = Instant.now
        XCTAssertNil(ProviderStatus.decodeSample(completion(
            visibleTokens: 1, generatedTokens: 1,
            timeline: timeline(origin: origin, firstTokenAtMs: 100, endedAtMs: 200)
        )), "one token has no decode interval")
        XCTAssertNil(ProviderStatus.decodeSample(completion(
            visibleTokens: 4, generatedTokens: 4,
            timeline: timeline(origin: origin, firstTokenAtMs: 100, endedAtMs: 100)
        )), "zero decode time")
        XCTAssertNil(ProviderStatus.decodeSample(completion(
            visibleTokens: 4, generatedTokens: 4,
            timeline: timeline(origin: origin, firstTokenAtMs: 100, endedAtMs: nil)
        )), "last token never marked")
        XCTAssertNil(ProviderStatus.decodeSample(completion(
            visibleTokens: 4, generatedTokens: 4, timeline: nil
        )), "no timeline")
        XCTAssertNil(ProviderStatus.decodeSample(completion(
            visibleTokens: 4, generatedTokens: 4,
            timeline: timeline(origin: origin, firstTokenAtMs: 100, endedAtMs: 900, replayed: true)
        )), "a replay waiter's tokens belong to the original row")
    }

    // MARK: - heartbeat window

    func testEmptyWindowReportsNoDecodeRateAndZeroAcceptance() async {
        let status = makeStatus()
        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertNil(snapshot.decodeTPSSinceLast)
        XCTAssertEqual(snapshot.nativeMTPProposedTokensSinceLast, 0)
        XCTAssertEqual(snapshot.nativeMTPAcceptedTokensSinceLast, 0)
    }

    func testWindowWithOnlySingleTokenRequestsReportsNoDecodeRate() async {
        let status = makeStatus()
        let origin = Instant.now
        await status.finishRequest(
            startedAt: Date(),
            completion: completion(
                visibleTokens: 1, generatedTokens: 1,
                timeline: timeline(origin: origin, firstTokenAtMs: 50, endedAtMs: 60)
            ),
            failed: false
        )
        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snapshot.requestsServedSinceLast, 1)
        XCTAssertNil(snapshot.decodeTPSSinceLast)
    }

    func testConcurrentRowsReportThePerRowRateWithoutDoubleCountingWallTime() async throws {
        let status = makeStatus()
        let origin = Instant.now
        // Two overlapping rows, each decoding 50 tokens after its first in
        // 2 s: 25 tok/s per row. The rows' shared wall time is 2.5 s and
        // their summed admission-to-finish time is larger still; neither
        // enters the rate.
        let rowA = completion(
            visibleTokens: 51, generatedTokens: 51,
            timeline: timeline(origin: origin, firstTokenAtMs: 300, endedAtMs: 2_300)
        )
        let rowB = completion(
            visibleTokens: 51, generatedTokens: 51,
            timeline: timeline(origin: origin, firstTokenAtMs: 800, endedAtMs: 2_800)
        )
        await status.finishRequest(startedAt: Date(), completion: rowA, failed: false)
        await status.finishRequest(startedAt: Date(), completion: rowB, failed: false)

        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(try XCTUnwrap(snapshot.decodeTPSSinceLast), 25, accuracy: 1e-9)
        let next = await status.snapshot(resetWindow: true)
        XCTAssertNil(next.decodeTPSSinceLast, "the window resets with the heartbeat")
    }

    func testWindowDecodeRateIsTokenWeightedAcrossRequests() async throws {
        let status = makeStatus()
        let origin = Instant.now
        // 10 tokens in 1 s and 90 tokens in 1 s: 100 tokens over 2 s.
        await status.finishRequest(startedAt: Date(), completion: completion(
            visibleTokens: 11, generatedTokens: 11,
            timeline: timeline(origin: origin, firstTokenAtMs: 0, endedAtMs: 1_000)
        ), failed: false)
        // gpt-oss: only 2 visible tokens, 91 generated.
        await status.finishRequest(startedAt: Date(), completion: completion(
            visibleTokens: 2, generatedTokens: 91,
            timeline: timeline(origin: origin, firstTokenAtMs: 0, endedAtMs: 1_000)
        ), failed: false)
        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(try XCTUnwrap(snapshot.decodeTPSSinceLast), 50, accuracy: 1e-9)
    }

    func testNativeMTPCountsSumOverTheWindowAndReset() async {
        let status = makeStatus()
        let origin = Instant.now
        await status.finishRequest(startedAt: Date(), completion: completion(
            visibleTokens: 9, generatedTokens: 9,
            timeline: timeline(origin: origin, firstTokenAtMs: 0, endedAtMs: 100),
            mtpProposed: 12, mtpAccepted: 7
        ), failed: false)
        await status.finishRequest(startedAt: Date(), completion: completion(
            visibleTokens: 4, generatedTokens: 4,
            timeline: timeline(origin: origin, firstTokenAtMs: 0, endedAtMs: 100),
            mtpProposed: 3, mtpAccepted: 3
        ), failed: false)
        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snapshot.nativeMTPProposedTokensSinceLast, 15)
        XCTAssertEqual(snapshot.nativeMTPAcceptedTokensSinceLast, 10)
        let next = await status.snapshot(resetWindow: true)
        XCTAssertEqual(next.nativeMTPProposedTokensSinceLast, 0)
        XCTAssertEqual(next.nativeMTPAcceptedTokensSinceLast, 0)
    }

    func testThroughputSinceLastKeepsItsMeaning() async throws {
        // The drift check's field stays visible tokens over admission-to-
        // finish wall time; the new decode rate does not replace it.
        let status = makeStatus()
        let origin = Instant.now
        await status.finishRequest(
            startedAt: Date().addingTimeInterval(-2),
            completion: completion(
                visibleTokens: 2, generatedTokens: 91,
                timeline: timeline(origin: origin, firstTokenAtMs: 0, endedAtMs: 1_000)
            ),
            failed: false
        )
        let snapshot = await status.snapshot(resetWindow: true)
        let throughput = try XCTUnwrap(snapshot.throughputTPSSinceLast)
        XCTAssertLessThan(throughput, 1.01, "visible tokens over ~2 s of wall time")
        XCTAssertEqual(try XCTUnwrap(snapshot.decodeTPSSinceLast), 90, accuracy: 1e-9)
    }

    // MARK: - continuous-batching finalize

    private func schedulerResult(
        disposition: ContinuousBatchSettlementDisposition,
        counters: NativeMTPSelfTestCounters?
    ) -> ContinuousBatchSchedulerResult {
        var result = ContinuousBatchSchedulerResult(
            requestID: "r",
            conversationKey: "",
            generatedTokens: [0, 1, 2],
            outputTokens: [0, 1, 2],
            promptTokens: 3,
            completionTokens: 3,
            emittedTokens: 3,
            cachedPromptTokens: 0,
            terminalStatus: .stop,
            errorCode: nil,
            snapshot: nil,
            settlementDisposition: disposition,
            retainedCache: nil
        )
        result.nativeMTPCounters = counters
        return result
    }

    private func finalize(_ result: ContinuousBatchSchedulerResult) throws -> CompletionResult {
        let request = try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: [
            "model": "mlx-community/Qwen3-8B-4bit",
            "messages": [["role": "user", "content": "hi"]],
        ]))
        let pieces = ["a", "b", "c"]
        return try ModelRuntime.finalizeContinuousBatchRow(
            request: request,
            result: result,
            modelStopTokenIDs: [],
            promptTokenIDs: [1, 2, 3],
            decode: { $0.map { pieces[$0] }.joined() },
            stopTokenFilter: StopTokenFilter(tokens: ["<|im_end|>"]),
            generationMilliseconds: 0,
            modelHash: nil,
            toolCallPrefill: nil
        ).completion
    }

    func testFinalizeCarriesTheRowsNativeMTPCounters() throws {
        let counters = NativeMTPSelfTestCounters(acceptedTokens: 5, rejectedTokens: 3, bonusTokens: 2, committedTokens: 7)
        let completion = try finalize(schedulerResult(disposition: .eligibleOwner, counters: counters))
        XCTAssertEqual(completion.nativeMTPProposedTokens, 8)
        XCTAssertEqual(completion.nativeMTPAcceptedTokens, 5)
        // Copies made after finalize keep them.
        XCTAssertEqual(completion.withContent("other").nativeMTPProposedTokens, 8)
        XCTAssertEqual(completion.withContent("other").nativeMTPAcceptedTokens, 5)
    }

    func testFinalizeReportsNoCountersForAReplayOrAnOrdinaryRow() throws {
        let counters = NativeMTPSelfTestCounters(acceptedTokens: 5, rejectedTokens: 3, bonusTokens: 2, committedTokens: 7)
        let replay = try finalize(schedulerResult(disposition: .nonSettlingReplay, counters: counters))
        XCTAssertEqual(replay.nativeMTPProposedTokens, 0)
        XCTAssertEqual(replay.nativeMTPAcceptedTokens, 0)
        let ordinary = try finalize(schedulerResult(disposition: .eligibleOwner, counters: nil))
        XCTAssertEqual(ordinary.nativeMTPProposedTokens, 0)
        XCTAssertEqual(ordinary.nativeMTPAcceptedTokens, 0)
    }

    // MARK: - relay usage

    func testRelayUsageCarriesTheTimelineTimingFields() {
        let origin = Instant.now
        let timeline = RequestTimeline(admitted: origin)
        timeline.markStarted(at: origin + .milliseconds(20))
        timeline.markFirstToken(at: origin + .milliseconds(120))
        timeline.mark(.firstAnswer, at: origin + .milliseconds(150))
        timeline.markEnded(at: origin + .milliseconds(1_120))
        for disposition in [ContinuousBatchSettlementDisposition.eligibleOwner, .usageUnattested] {
            let usage = InferenceRelay.usage(CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 5,
                completionTokens: 4,
                settlementDisposition: disposition,
                timeline: timeline
            ))
            XCTAssertEqual(usage["macprovider_queue_ms"] as? Int64, 20)
            XCTAssertEqual(usage["macprovider_first_token_ms"] as? Int64, 120)
            XCTAssertEqual(usage["macprovider_first_answer_ms"] as? Int64, 150)
            XCTAssertEqual(usage["macprovider_decode_ms"] as? Int64, 1_000)
            XCTAssertTrue(usage.keys.contains("macprovider_model_hash_observed"))
            XCTAssertNil(usage["macprovider_generation_ms"], "the relay never carried it")
            if disposition == .usageUnattested {
                for key in ["prompt_tokens", "cached_prompt_tokens", "completion_tokens", "total_tokens"] {
                    XCTAssertNil(usage[key], "\(key) sent for unattested usage")
                }
            } else {
                XCTAssertEqual(usage["completion_tokens"] as? Int, 4)
                XCTAssertEqual(usage["total_tokens"] as? Int, 9)
            }
        }
    }

    func testRelayUsageTimingIsNullWithoutATimeline() {
        let usage = InferenceRelay.usage(CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 5,
            completionTokens: 4,
            settlementDisposition: .eligibleOwner
        ))
        for key in ["macprovider_queue_ms", "macprovider_first_token_ms", "macprovider_first_answer_ms", "macprovider_decode_ms"] {
            XCTAssertTrue(usage[key] is NSNull, key)
        }
    }
}
