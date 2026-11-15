import XCTest
@testable import macprovider_cli

#if DEBUG || MACPROVIDER_LAB_HARNESS

/// Pure parts of `multi-model-bench --check` (#2338): gate floors, deadline
/// counting, prefill credit and work_share, the per-model watchdog, TTFT
/// summaries and the build SHA lookup. No model is loaded.
final class MultiModelBenchCheckTests: XCTestCase {
    private let window: [(Double, Double)] = [(10, 60)]

    private func record(
        model: String = "a",
        start: Double,
        end: Double,
        chunks: [Double],
        prompt: Int = 100,
        cached: Int = 0
    ) -> MultiModelCheckRequestRecord {
        MultiModelCheckRequestRecord(
            model: model, lane: 0, promptIndex: 0, requestID: nil,
            startSeconds: start, endSeconds: end, chunkOffsetsSeconds: chunks,
            promptTokens: prompt, cachedPromptTokens: cached, completionTokens: chunks.count,
            finishReason: "length", ttftMilliseconds: chunks.first.map { ($0 - start) * 1000 },
            outputKind: "token_ids", outputSha256: "", outputTokenIDs: nil, outputText: ""
        )
    }

    private func stats(_ records: [MultiModelCheckRequestRecord], rows: Int = 1) -> MultiModelCheckModelPhaseStats {
        MultiModelCheckModelPhaseStats(rows: rows, records: records, segments: window, intervalSeconds: 50, deadlineSeconds: 60)
    }

    /// Solo shape used by several tests: 47 decode tokens and 1000 prefilled
    /// prompt tokens over 4 s inside [10, 60].
    private func soloStats(model: String = "a") -> MultiModelCheckModelPhaseStats {
        stats([
            record(model: model, start: 0, end: 30, chunks: (2...30).map(Double.init)),
            record(model: model, start: 30, end: 59.5, chunks: (34...59).map(Double.init), prompt: 1000),
        ])
    }

    // MARK: Deadline counting

    func testCompletedCountsOnlyRequestsFinishedBeforeDeadline() {
        let s = stats([
            record(start: 0, end: 50, chunks: [1, 20, 50]),
            record(start: 50, end: 65, chunks: [52, 58, 64]),
        ])
        XCTAssertEqual(s.requestsCompleted, 1)
        XCTAssertEqual(s.requestsLate, 1)
        // Tokens after the deadline never enter the interval.
        XCTAssertEqual(s.tokensInInterval, 4)
    }

    func testRequestFinishingExactlyAtDeadlineIsCompleted() {
        let s = stats([record(start: 0, end: 60, chunks: [1, 30, 60])])
        XCTAssertEqual(s.requestsCompleted, 1)
        XCTAssertEqual(s.requestsLate, 0)
    }

    // MARK: Gate floors

    private func floorReasons(
        measured: [MultiModelCheckFloors.Measured],
        alwaysProceeds: Bool = true,
        waits: [MultiModelCheckFloors.Waits] = [],
        comparisons: [MultiModelCheckOutputComparison] = [
            MultiModelCheckOutputComparison(model: "a", kind: "token_ids"),
            MultiModelCheckOutputComparison(model: "b", kind: "token_ids"),
        ]
    ) -> [String] {
        MultiModelCheckFloors.reasons(
            measured: measured, policy: alwaysProceeds ? "passthrough" : "fairshare",
            policyAlwaysProceeds: alwaysProceeds, waits: waits, comparisons: comparisons)
    }

    func testHealthyRunHasNoFloorReasons() {
        let reasons = floorReasons(
            measured: [.init(phase: "solo-a", model: "a", stats: soloStats()), .init(phase: "contended", model: "b", stats: soloStats(model: "b"))],
            alwaysProceeds: false,
            waits: [.init(phase: "contended", totalWaitSeconds: 3.2)])
        XCTAssertEqual(reasons, [])
    }

    func testZeroTokensInIntervalFailsTheGate() {
        // Every chunk lands before the ramp ends: GOAL would read share=0.
        let empty = stats([record(start: 0, end: 5, chunks: [1, 2, 3])])
        XCTAssertEqual(empty.tokensInInterval, 0)
        let reasons = floorReasons(measured: [.init(phase: "contended", model: "b", stats: empty)])
        XCTAssertEqual(reasons, ["zero_tokens_in_interval phase=contended model=b"])
    }

    func testNoRequestsAndMissingStatsFailTheGate() {
        let none = stats([])
        let reasons = floorReasons(measured: [
            .init(phase: "solo-a", model: "a", stats: none),
            .init(phase: "soak", model: "b", stats: nil),
        ])
        XCTAssertEqual(reasons, [
            "zero_tokens_in_interval phase=solo-a model=a",
            "no_completed_requests phase=solo-a model=a late=0",
            "no_stats phase=soak model=b",
        ])
    }

    func testOnlyLateRequestsFailTheGate() {
        let late = stats([record(start: 0, end: 70, chunks: [20, 40, 70])])
        let reasons = floorReasons(measured: [.init(phase: "contended", model: "a", stats: late)])
        XCTAssertEqual(reasons, ["no_completed_requests phase=contended model=a late=1"])
    }

    func testNonPassthroughPolicyWithNoArbiterWaitFails() {
        let measured: [MultiModelCheckFloors.Measured] = [.init(phase: "contended", model: "a", stats: soloStats())]
        XCTAssertEqual(
            floorReasons(measured: measured, alwaysProceeds: false, waits: [.init(phase: "contended", totalWaitSeconds: 0), .init(phase: "soak", totalWaitSeconds: nil)]),
            ["policy_not_exercised phase=contended policy=fairshare arbiter_wait_s=0.000",
             "policy_not_exercised phase=soak policy=fairshare arbiter_wait_s=n/a"])
        // Passthrough never waits; no floor applies.
        XCTAssertEqual(floorReasons(measured: measured, alwaysProceeds: true, waits: [.init(phase: "contended", totalWaitSeconds: 0)]), [])
    }

    func testTextComparisonFallbackFailsTheGate() {
        let reasons = floorReasons(
            measured: [],
            comparisons: [
                MultiModelCheckOutputComparison(model: "a", kind: "token_ids"),
                MultiModelCheckOutputComparison(model: "b", kind: "text"),
            ])
        XCTAssertEqual(reasons, ["token_ids_unavailable model=b compared=text"])
    }

    // MARK: Goal

    func testGoalIsUnavailableInsteadOfDefaultingAZeroRate() {
        let empty = stats([record(model: "b", start: 0, end: 5, chunks: [1, 2])])
        let outcome = MultiModelCheckRunner.goal(
            soloA: soloStats(), soloB: soloStats(model: "b"), measuredPhase: "contended",
            a: soloStats(), b: empty, intervalSeconds: 50)
        XCTAssertNil(outcome.goal)
        XCTAssertEqual(outcome.unavailable, "zero_rate phase=contended model=b")
    }

    func testGoalShareAndWorkShareOfASoloAgainstItself() throws {
        let solo = soloStats()
        let outcome = MultiModelCheckRunner.goal(
            soloA: solo, soloB: solo, measuredPhase: "soak", a: solo, b: solo, intervalSeconds: 50)
        let goal = try XCTUnwrap(outcome.goal)
        XCTAssertEqual(goal.share, 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(goal.aWork), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(goal.workShare), 2, accuracy: 1e-12)
        XCTAssertEqual(goal.source, "soak")
        XCTAssertTrue(goal.line.hasPrefix("GOAL share=1.0000 "), goal.line)
        XCTAssertTrue(goal.line.contains(" work_share=2.0000 "), goal.line)
        XCTAssertTrue(goal.line.contains(" main_solo_ttft_n=1 "), goal.line)
        XCTAssertTrue(goal.line.contains(" source=soak "), goal.line)
    }

    // MARK: Prefill credit and work_share

    func testPrefillTokensAreCreditedByTheShareOfTheSpanInsideTheInterval() {
        // 800 prefilled tokens (1000 less 200 cached) over [5, 15]; half inside [10, 60].
        let result = MultiModelCheckWork.prefill(
            records: [record(start: 5, end: 30, chunks: [15, 20], prompt: 1000, cached: 200)],
            segments: window)
        XCTAssertEqual(result.tokens, 400, accuracy: 1e-9)
        XCTAssertEqual(result.seconds, 5, accuracy: 1e-9)
    }

    func testOverlappingPrefillSpansCountTheirSecondsOnce() {
        let result = MultiModelCheckWork.prefill(
            records: [
                record(start: 20, end: 40, chunks: [24, 30], prompt: 400),
                record(start: 22, end: 40, chunks: [26, 30], prompt: 400),
            ],
            segments: window)
        XCTAssertEqual(result.tokens, 800, accuracy: 1e-9)
        XCTAssertEqual(result.seconds, 6, accuracy: 1e-9)
    }

    func testSoloRatesAndSoloEquivalentSeconds() throws {
        let rates = MultiModelCheckWork.soloRates(decodeTokens: 400, prefillTokens: 2000, prefillSeconds: 10, intervalSeconds: 50)
        XCTAssertEqual(try XCTUnwrap(rates.decode), 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rates.prefill), 200, accuracy: 1e-12)
        // 200 decode tokens = 20 solo seconds, 1000 prefill tokens = 5.
        XCTAssertEqual(try XCTUnwrap(MultiModelCheckWork.soloEquivalentSeconds(
            decodeTokens: 200, prefillTokens: 1000, soloDecodeRate: 10, soloPrefillRate: 200)), 25, accuracy: 1e-12)
        // Prefill work with no solo prefill rate cannot be credited.
        XCTAssertNil(MultiModelCheckWork.soloEquivalentSeconds(decodeTokens: 200, prefillTokens: 10, soloDecodeRate: 10, soloPrefillRate: nil))
        // No prefill work needs no prefill rate.
        XCTAssertEqual(MultiModelCheckWork.soloEquivalentSeconds(decodeTokens: 200, prefillTokens: 0, soloDecodeRate: 10, soloPrefillRate: nil), 20)
    }

    func testSoloPhaseScoresExactlyOneAgainstItself() throws {
        let solo = soloStats()
        XCTAssertEqual(solo.tokensInInterval, 47)
        XCTAssertEqual(solo.promptTokensPrefilledInInterval, 1000, accuracy: 1e-9)
        XCTAssertEqual(solo.prefillSecondsInInterval, 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(solo.prefillTokensPerSecond), 250, accuracy: 1e-9)
        let fraction = MultiModelCheckWork.fraction(
            decodeTokens: solo.tokensInInterval, prefillTokens: solo.promptTokensPrefilledInInterval,
            solo: solo, intervalSeconds: 50)
        XCTAssertEqual(try XCTUnwrap(fraction), 1, accuracy: 1e-12)
    }

    func testPrefillHeavyContendedRunEarnsWorkCreditShareIgnores() throws {
        let solo = soloStats()
        // Same decode tokens, twice the prefill: share is unchanged, work is higher.
        let decodeRate = try XCTUnwrap(solo.decodeOnlyTokensPerSecond)
        let one = try XCTUnwrap(MultiModelCheckWork.fraction(decodeTokens: 23, prefillTokens: 1000, solo: solo, intervalSeconds: 50))
        let two = try XCTUnwrap(MultiModelCheckWork.fraction(decodeTokens: 23, prefillTokens: 2000, solo: solo, intervalSeconds: 50))
        XCTAssertEqual(one, (23 / decodeRate + 4) / 50, accuracy: 1e-12)
        XCTAssertEqual(two - one, 4.0 / 50, accuracy: 1e-12)
    }

    // MARK: Watchdog

    private func nanos(_ seconds: Double) -> UInt64 { UInt64(seconds * 1e9) }

    func testStreamingModelDoesNotMaskAStalledSibling() {
        let entries = [
            MultiModelCheckWatchdog.InFlight(model: "a", lastProgress: nanos(1_000 - 1)),
            MultiModelCheckWatchdog.InFlight(model: "b", lastProgress: nanos(1_000 - 130)),
        ]
        XCTAssertEqual(
            MultiModelCheckWatchdog.stalled(entries, now: nanos(1_000), limitSeconds: 120),
            MultiModelBenchStall(model: "b", idleSeconds: 130))
    }

    func testModelIsLiveWhenAnyOfItsRequestsProgressed() {
        let entries = [
            MultiModelCheckWatchdog.InFlight(model: "b", lastProgress: nanos(1_000 - 500)),
            MultiModelCheckWatchdog.InFlight(model: "b", lastProgress: nanos(1_000 - 10)),
        ]
        XCTAssertNil(MultiModelCheckWatchdog.stalled(entries, now: nanos(1_000), limitSeconds: 120))
        XCTAssertNil(MultiModelCheckWatchdog.stalled([], now: nanos(1_000), limitSeconds: 120))
    }

    func testLongestIdleModelIsNamedWhenBothStall() {
        let entries = [
            MultiModelCheckWatchdog.InFlight(model: "a", lastProgress: nanos(1_000 - 200)),
            MultiModelCheckWatchdog.InFlight(model: "b", lastProgress: nanos(1_000 - 150)),
        ]
        XCTAssertEqual(MultiModelCheckWatchdog.stalled(entries, now: nanos(1_000), limitSeconds: 120)?.model, "a")
    }

    // MARK: TTFT

    func testTTFTSummaryCarriesSampleCount() {
        let ttft = MultiModelCheckTTFT([400, 100, 300, 200])
        XCTAssertEqual(ttft.n, 4)
        XCTAssertEqual(ttft.medianMs, 250)
        XCTAssertEqual(ttft.p95Ms, 400)
        let empty = MultiModelCheckTTFT([])
        XCTAssertEqual(empty.n, 0)
        XCTAssertNil(empty.medianMs)
        XCTAssertNil(empty.p95Ms)
    }

    func testTTFTReportsFirstRequestSeparately() {
        // Earliest start is the first request, wherever it sits in the array.
        let ttft = MultiModelCheckTTFT(records: [
            record(start: 20, end: 30, chunks: [20.2]),
            record(start: 0, end: 10, chunks: [3]),
            record(start: 40, end: 50, chunks: [40.4]),
        ])
        XCTAssertEqual(ttft.firstMs ?? 0, 3000, accuracy: 1e-6)
        XCTAssertEqual(ttft.n, 2)
        XCTAssertEqual(ttft.medianMs ?? 0, 300, accuracy: 1e-6)
        XCTAssertEqual(ttft.p95Ms ?? 0, 400, accuracy: 1e-6)

        let only = MultiModelCheckTTFT(records: [record(start: 0, end: 10, chunks: [3])])
        XCTAssertEqual(only.n, 0)
        XCTAssertNil(only.medianMs)
        XCTAssertEqual(only.firstMs ?? 0, 3000, accuracy: 1e-6)
        let line = MultiModelCheckGoal.ttftFields("main", only)
        XCTAssertEqual(line, "main_ttft_n=0 main_ttft_first_ms=3000")
        XCTAssertTrue(MultiModelCheckGoal.ttftFields("main", ttft).contains(" main_ttft_first_ms=3000"))
    }

    // MARK: Aggregate gate and GOAL

    private func gate(_ reasons: [String]) -> MultiModelCheckGate {
        MultiModelCheckGate(pass: reasons.isEmpty, reasons: reasons, line: reasons.isEmpty ? "GATE pass" : "GATE fail reason=\(reasons[0])")
    }

    func testAggregateGateFailsWhenAnyPolicyFailsNotOnlyTheLast() {
        let aggregate = MultiModelCheckRunner.aggregateGate([
            ("fairshare", gate(["output_mismatch phase=contended model=a", "second"])),
            ("passthrough", gate([])),
        ])
        XCTAssertFalse(aggregate.pass)
        XCTAssertEqual(aggregate.line, "GATE fail policies=fairshare reason=output_mismatch phase=contended model=a")
        XCTAssertEqual(aggregate.reasons, ["policy=fairshare output_mismatch phase=contended model=a", "policy=fairshare second"])

        let both = MultiModelCheckRunner.aggregateGate([
            ("fairshare", gate(["output_mismatch"])),
            ("rr", gate(["hang"])),
        ])
        XCTAssertEqual(both.line, "GATE fail policies=fairshare|rr reason=output_mismatch other_policy=rr other_reason=hang")

        let pass = MultiModelCheckRunner.aggregateGate([("a", gate([])), ("b", gate([]))])
        XCTAssertTrue(pass.pass)
        XCTAssertEqual(pass.line, "GATE pass")
    }

    func testGoalLineNamesThePolicy() throws {
        let solo = soloStats()
        let goal = try XCTUnwrap(MultiModelCheckRunner.goal(
            soloA: solo, soloB: solo, measuredPhase: "contended", a: solo, b: solo, intervalSeconds: 50).goal)
        XCTAssertTrue(MultiModelCheckRunner.goalLine(spec: "passthrough", goal: goal, reasons: []).hasPrefix("GOAL policy=passthrough share=1.0000 "))
        XCTAssertEqual(
            MultiModelCheckRunner.goalLine(spec: "passthrough", goal: nil, reasons: ["x", "goal_unavailable no_contended_phase"]),
            "GOAL policy=passthrough unavailable reason=goal_unavailable no_contended_phase")
    }

    // MARK: Footprint over the wired limit (information only)

    private func memoryPhase(footprint: UInt64?, wired: Int?) -> MultiModelCheckPhaseResult {
        var phase = MultiModelCheckPhaseResult(phase: "contended", durationSeconds: 120)
        phase.physFootprintMaxBytes = footprint
        phase.memoryBudget = MultiModelCheckMemoryBudgetStats(
            limitBytes: nil, wiredLimitBytes: wired, cacheLimitBytes: 0, headroomMinBytes: nil,
            admissionRefusals: 0, rowsAdmittedPastBudget: 0, cacheClearsPerformed: 0, cacheClearsSkipped: 0,
            commandBufferBudgetSetBy: nil, commandBufferBudgetMb: nil, commandBufferConflicts: [], runtimes: [])
        return phase
    }

    func testFootprintOverWiredIsReportedNotGated() {
        let over = MultiModelCheckRunner.footprintOverWired(phases: [
            memoryPhase(footprint: 90, wired: 100), memoryPhase(footprint: 130, wired: 100),
        ])
        XCTAssertEqual(over.wiredLimitBytes, 100)
        XCTAssertEqual(over.overBytes, 30)
        let under = MultiModelCheckRunner.footprintOverWired(phases: [memoryPhase(footprint: 90, wired: 100)])
        XCTAssertEqual(under.overBytes, 0)
        let none = MultiModelCheckRunner.footprintOverWired(phases: [memoryPhase(footprint: 90, wired: nil)])
        XCTAssertNil(none.wiredLimitBytes)
        XCTAssertNil(none.overBytes)
    }

    // MARK: Row shape (the self-check's granted rows)

    private func shape(
        requested: Int, engine: String, served: Int, selfCheck: MultiModelCheckSelfCheck?, exact: Bool = false
    ) throws -> MultiModelCheckRowShape {
        try MultiModelCheckRowShape.resolve(
            slot: .b, requestedRows: requested, engine: engine, servedSlots: served, selfCheck: selfCheck, rowsExact: exact)
    }

    private func failure(_ body: () throws -> MultiModelCheckRowShape) -> String? {
        do { _ = try body(); return nil } catch { return (error as? MultiModelCheckFailure)?.reason }
    }

    func testCheckDrivesTheRowsTheSelfCheckGranted() throws {
        let cb = "continuous_batching"
        // The lab's cells: 2 -> refused no_net_gain (one serial row), 4 -> 3, 8 -> 5.
        let refused = try shape(requested: 2, engine: "serial_inference_gate", served: 1,
                                selfCheck: .init(outcome: "refused reason=no_net_gain", reason: "no_net_gain"))
        XCTAssertEqual(refused, .init(model: "b", requestedRows: 2, grantedRows: 1, selfCheckReason: "no_net_gain"))
        XCTAssertEqual(try shape(requested: 4, engine: cb, served: 3,
                                 selfCheck: .init(outcome: "granted slots=3", reason: "granted", grantedSlots: 3)).grantedRows, 3)
        let eight = try shape(requested: 8, engine: cb, served: 5, selfCheck: .init(outcome: "granted slots=5", reason: "granted", grantedSlots: 5))
        XCTAssertEqual(eight, .init(model: "b", requestedRows: 8, grantedRows: 5, selfCheckReason: "granted"))
        // Never more rows than requested; one row without a self-check.
        XCTAssertEqual(try shape(requested: 2, engine: cb, served: 4, selfCheck: nil).grantedRows, 2)
        XCTAssertEqual(try shape(requested: 1, engine: "serial_inference_gate", served: 1, selfCheck: nil).selfCheckReason, "none")
        XCTAssertEqual(
            MultiModelCheckRowShape.lineFields([refused, eight]),
            "b_rows_requested=2 b_rows_granted=1 b_self_check=no_net_gain b_rows_requested=8 b_rows_granted=5 b_self_check=granted")
    }

    func testCheckStillFailsOnARealEngineMismatchOrNoRows() {
        // Batching rows on a serialized engine.
        XCTAssertTrue(failure { try self.shape(requested: 4, engine: "serial_inference_gate", served: 4, selfCheck: nil) }?
            .hasPrefix("engine_mismatch model=b rows=4 requested_rows=4 engine=serial_inference_gate") == true)
        // A grant of several rows the engine does not serve with.
        XCTAssertTrue(failure { try self.shape(requested: 4, engine: "serial_inference_gate", served: 1,
                                               selfCheck: .init(outcome: "granted slots=3", reason: "granted", grantedSlots: 3)) }?
            .hasPrefix("engine_mismatch") == true)
        // A model that serves no row.
        XCTAssertTrue(failure { try self.shape(requested: 2, engine: "continuous_batching", served: 0, selfCheck: nil) }?
            .hasPrefix("no_rows model=b requested_rows=2 served_slots=0") == true)
    }

    func testRowsExactKeepsTheStrictRule() throws {
        let granted3 = MultiModelCheckSelfCheck(outcome: "granted slots=3", reason: "granted", grantedSlots: 3)
        XCTAssertTrue(failure { try self.shape(requested: 4, engine: "continuous_batching", served: 3, selfCheck: granted3, exact: true) }?
            .contains("rows_exact=true") == true)
        XCTAssertTrue(failure { try self.shape(requested: 2, engine: "serial_inference_gate", served: 1,
                                               selfCheck: .init(outcome: "refused reason=no_net_gain", reason: "no_net_gain"), exact: true) }?
            .hasPrefix("engine_mismatch") == true)
        XCTAssertEqual(try shape(requested: 4, engine: "continuous_batching", served: 4, selfCheck: nil, exact: true).grantedRows, 4)
        let parsed = try MultiModelBenchCommand.parse(["--model-a", "/a", "--model-b", "/b", "--check", "--rows-exact"])
        XCTAssertTrue(parsed.rowsExact)
        XCTAssertFalse(try MultiModelBenchCommand.parse(["--model-a", "/a", "--model-b", "/b", "--check"]).rowsExact)
    }

    func testGoalLineEndsWithTheRowShape() throws {
        let solo = soloStats()
        let goal = try XCTUnwrap(MultiModelCheckRunner.goal(
            soloA: solo, soloB: solo, measuredPhase: "contended", a: solo, b: solo, intervalSeconds: 50).goal)
        let shapes = [MultiModelCheckRowShape(model: "a", requestedRows: 1, grantedRows: 1, selfCheckReason: "single_row"),
                      MultiModelCheckRowShape(model: "b", requestedRows: 4, grantedRows: 3, selfCheckReason: "granted")]
        let line = MultiModelCheckRunner.goalLine(spec: "passthrough", goal: goal, reasons: [], rowShapes: shapes)
        XCTAssertTrue(line.hasSuffix(" a_rows_requested=1 a_rows_granted=1 a_self_check=single_row b_rows_requested=4 b_rows_granted=3 b_self_check=granted"), line)
        XCTAssertTrue(MultiModelCheckRunner.goalLine(spec: "passthrough", goal: nil, reasons: [], rowShapes: shapes)
            .hasSuffix("b_rows_granted=3 b_self_check=granted"))
    }

    // MARK: Build SHA

    func testBuildGitSHALookup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmc-sha-\(UUID().uuidString)").appendingPathComponent("work")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        XCTAssertEqual(MultiModelCheck.buildGitSHA(environment: [:], currentDirectory: directory.path, executableDirectory: nil), "unknown")

        let sha = "0000e04e056762139ce13b9b1e500fef89191faa"
        try Data("\(sha)\n".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent(MultiModelCheck.gitSHAFileName))
        XCTAssertEqual(MultiModelCheck.buildGitSHA(environment: [:], currentDirectory: directory.path, executableDirectory: nil), sha)

        XCTAssertEqual(
            MultiModelCheck.buildGitSHA(environment: [MultiModelCheck.gitSHAEnvironmentKey: "ABCDEF1"], currentDirectory: directory.path, executableDirectory: nil),
            "abcdef1")

        try Data("not a sha".utf8).write(to: directory.appendingPathComponent(MultiModelCheck.gitSHAFileName))
        // An invalid file is skipped; the parent's valid one is used.
        XCTAssertEqual(MultiModelCheck.buildGitSHA(environment: [:], currentDirectory: directory.path, executableDirectory: nil), sha)
    }
}

#endif
