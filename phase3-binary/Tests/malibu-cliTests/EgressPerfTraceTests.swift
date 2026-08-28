import Foundation
import XCTest
@testable import malibu_cli

/// T0-03: Unit tests for the egress-profiling instrumentation.
///
/// Runbook requirement: "Unit test: flag defaults off, no trace output in normal tests"
final class EgressPerfTraceTests: XCTestCase {

    // MARK: - Feature flag (primary requirement)

    /// Verify MACPROVIDER_PERF_TRACE is absent / != "1" in the test environment.
    /// If this fails, unset MACPROVIDER_PERF_TRACE in your shell before running swift test.
    func testPerfTraceFlagDefaultsOff() {
        XCTAssertFalse(
            perfTraceEnabled,
            "MACPROVIDER_PERF_TRACE must be unset (or != '1') in normal test runs"
        )
    }

    // MARK: - Disabled trace: no-op contract

    func testDisabledTraceRecordsNothingWhenFlagOff() {
        let trace = EgressPerfTrace(enabled: false)
        trace.recordDecodeCallbackEntry()
        trace.recordDecodeCallbackEntry()
        trace.recordSeal(durationMicros: 300)
        trace.recordWSSend(durationMicros: 700)

        let counts = trace.sampleCounts()
        XCTAssertEqual(counts.decode, 0, "decode callbacks must not be stored when disabled")
        XCTAssertEqual(counts.seal, 0, "seal samples must not be stored when disabled")
        XCTAssertEqual(counts.wsSend, 0, "ws-send samples must not be stored when disabled")
    }

    func testDisabledPrintSummaryReturnsDisabled() {
        let trace = EgressPerfTrace(enabled: false)
        let verdict = trace.printSummary(requestID: "req-disabled", completionTokens: 10)
        XCTAssertEqual(verdict, "DISABLED")
    }

    // MARK: - Enabled trace: recording

    func testEnabledTraceRecordsSamples() {
        let trace = EgressPerfTrace(enabled: true)
        trace.recordDecodeCallbackEntry()
        trace.recordDecodeCallbackEntry()
        trace.recordDecodeCallbackEntry()
        trace.recordSeal(durationMicros: 200)
        trace.recordWSSend(durationMicros: 450)

        let counts = trace.sampleCounts()
        XCTAssertEqual(counts.decode, 3)
        XCTAssertEqual(counts.seal, 1)
        XCTAssertEqual(counts.wsSend, 1)
    }

    func testEmptyTraceReturnsGreen() {
        // Zero samples → 0 µs decode interval → egress % undefined; default GREEN.
        let trace = EgressPerfTrace(enabled: true)
        let verdict = trace.printSummary(requestID: "req-empty", completionTokens: 0)
        XCTAssertEqual(verdict, "GREEN")
    }

    // MARK: - Verdict thresholds (via synthetic samples)

    func testVerdictGreenWhenEgressBelow5Pct() {
        // 25 TPS → token period 40_000 µs; WS send 1_000 µs → 2.5% → GREEN
        let trace = EgressPerfTrace(enabled: true)
        trace.injectSamplesForTesting(tokenPeriodUs: 40_000, sealUs: 0, wsSendUs: 1_000, tokenCount: 50)
        let verdict = trace.printSummary(requestID: "req-green", completionTokens: 50)
        XCTAssertEqual(verdict, "GREEN")
    }

    func testVerdictYellowWhenEgressBetween5And15Pct() {
        // Token period 40_000 µs; seal 500 µs + WS 3_500 µs = 4_000 µs → 10% → YELLOW
        let trace = EgressPerfTrace(enabled: true)
        trace.injectSamplesForTesting(tokenPeriodUs: 40_000, sealUs: 500, wsSendUs: 3_500, tokenCount: 50)
        let verdict = trace.printSummary(requestID: "req-yellow", completionTokens: 50)
        XCTAssertEqual(verdict, "YELLOW")
    }

    func testVerdictRedWhenEgressAbove15Pct() {
        // Token period 40_000 µs; seal 1_000 µs + WS 7_000 µs = 8_000 µs → 20% → RED
        let trace = EgressPerfTrace(enabled: true)
        trace.injectSamplesForTesting(tokenPeriodUs: 40_000, sealUs: 1_000, wsSendUs: 7_000, tokenCount: 50)
        let verdict = trace.printSummary(requestID: "req-red", completionTokens: 50)
        XCTAssertEqual(verdict, "RED")
    }

    // MARK: - TaskLocal propagation

    func testTaskLocalNilByDefault() async {
        XCTAssertNil(EgressPerfTraceKey.current, "EgressPerfTraceKey.current must be nil outside withValue scope")
    }

    func testTaskLocalInjectedViaWithValue() async {
        let trace = EgressPerfTrace(enabled: true)
        let captured: EgressPerfTrace? = await EgressPerfTraceKey.$current.withValue(trace) {
            EgressPerfTraceKey.current
        }
        XCTAssertTrue(captured === trace, "withValue must inject the trace into TaskLocal")
    }

    func testTaskLocalRestoredAfterWithValueScope() async {
        let trace = EgressPerfTrace(enabled: true)
        await EgressPerfTraceKey.$current.withValue(trace) { }
        XCTAssertNil(EgressPerfTraceKey.current, "TaskLocal must be nil after withValue scope exits")
    }

    func testTaskLocalInheritedByChildTask() async {
        let trace = EgressPerfTrace(enabled: true)
        let childTrace: EgressPerfTrace? = await EgressPerfTraceKey.$current.withValue(trace) {
            await Task<EgressPerfTrace?, Never> {
                EgressPerfTraceKey.current
            }.value
        }
        XCTAssertTrue(childTrace === trace, "child Task must inherit parent's EgressPerfTrace via TaskLocal")
    }
}
