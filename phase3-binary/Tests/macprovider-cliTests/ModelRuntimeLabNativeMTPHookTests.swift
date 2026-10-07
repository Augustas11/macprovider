#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelRuntimeLabNativeMTPHookTests: XCTestCase {
    private enum TestError: Error {
        case unexpectedLoad
    }

    func testLabHookInstallRetainsRuntimeHooksWithoutScheduler() async throws {
        let runtime = ModelRuntime(
            modelID: "fixture-model",
            warmSwapEnabled: false,
            loader: { _ in throw TestError.unexpectedLoad }
        )

        let installedTimingObserver = await runtime.installLabNativeMTPCommitTimingObserver(
            NativeMTPLabCommittedTokenTimingObserver()
        )
        let installedDecodeCap = await runtime.installLabNativeMTPDecodeOutputCap(
            NativeMTPLabDecodeOutputCap(capsByRequestID: ["req-1": 2])
        )
        let clearedTimingObserver = await runtime.installLabNativeMTPCommitTimingObserver(nil)
        let clearedDecodeCap = await runtime.installLabNativeMTPDecodeOutputCap(nil)

        XCTAssertTrue(installedTimingObserver)
        XCTAssertTrue(installedDecodeCap)
        XCTAssertTrue(clearedTimingObserver)
        XCTAssertTrue(clearedDecodeCap)
    }

    func testLabSerialEffectiveMaxTokensDerivesGenerationLimitWithoutMutatingRequestBudget() {
        XCTAssertEqual(ModelRuntime.labSerialEffectiveMaxTokens(requestMaxTokens: 8, labOutputCap: 3), 3)
        XCTAssertEqual(ModelRuntime.labSerialEffectiveMaxTokens(requestMaxTokens: 2, labOutputCap: 5), 2)
        XCTAssertEqual(ModelRuntime.labSerialEffectiveMaxTokens(requestMaxTokens: nil, labOutputCap: 4), 4)
        XCTAssertEqual(ModelRuntime.labSerialEffectiveMaxTokens(requestMaxTokens: 6, labOutputCap: nil), 6)
    }

    func testLabSerialLengthFinishUsesDerivedCap() {
        XCTAssertTrue(ModelRuntime.labSerialLengthFinish(
            generatedCompletionTokens: 3,
            requestMaxTokens: 8,
            labOutputCap: 3
        ))
        XCTAssertFalse(ModelRuntime.labSerialLengthFinish(
            generatedCompletionTokens: 3,
            requestMaxTokens: 8,
            labOutputCap: 4
        ))
        XCTAssertTrue(ModelRuntime.labSerialLengthFinish(
            generatedCompletionTokens: 8,
            requestMaxTokens: 8,
            labOutputCap: nil
        ))
    }

    func testLabSerialCommitTrackerRecordsEachVisiblePrefixOnce() {
        let observer = NativeMTPLabCommittedTokenTimingObserver()
        let tracker = ModelRuntime.LabSerialCommitTracker(requestID: "req-1", observer: observer)

        tracker.record(outputCount: 1)
        tracker.record(outputCount: 3)
        tracker.record(outputCount: 2)

        let events = observer.snapshot()
        XCTAssertEqual(events.map(\.requestID), ["req-1", "req-1", "req-1"])
        XCTAssertEqual(events.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(events.map(\.outputCount), [1, 2, 3])
        XCTAssertGreaterThan(events[0].monotonicNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(events[1].monotonicNanoseconds, events[0].monotonicNanoseconds)
        XCTAssertGreaterThanOrEqual(events[2].monotonicNanoseconds, events[1].monotonicNanoseconds)
    }

    func testLabSerialHooksFailClosedWithoutRequestID() {
        XCTAssertThrowsError(try ModelRuntime.labSerialDecodeHooks(
            requestID: nil,
            outputCap: nil,
            timingObserver: NativeMTPLabCommittedTokenTimingObserver()
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.code, "lab_serial_decode_hook_unsupported")
        }
    }

    func testLabSerialVisibleCommitCountFailsClosedForHarmonyPrefixAccounting() {
        XCTAssertThrowsError(try ModelRuntime.labSerialVisibleCommitCount(
            modelID: "openai/gpt-oss-20b",
            generatedTokenIDs: [1, 2],
            decodedText: "hidden",
            emittedText: nil,
            stopTokenFilter: StopTokenFilter(tokens: []),
            requestStops: []
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.code, "lab_serial_decode_hook_unsupported")
        }
    }

    func testLabSerialVisibleCommitCountFailsClosedWhenFiltersChangeOutput() {
        XCTAssertThrowsError(try ModelRuntime.labSerialVisibleCommitCount(
            modelID: "fixture-model",
            generatedTokenIDs: [1, 2],
            decodedText: "visible<eos>",
            emittedText: nil,
            stopTokenFilter: StopTokenFilter(tokens: ["<eos>"]),
            requestStops: []
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.code, "lab_serial_decode_hook_unsupported")
        }
    }

    func testLabSerialVisibleCommitCountFailsClosedWhenStreamingHasNotEmittedPrefix() {
        XCTAssertThrowsError(try ModelRuntime.labSerialVisibleCommitCount(
            modelID: "fixture-model",
            generatedTokenIDs: [1, 2],
            decodedText: "visible tail",
            emittedText: "visible",
            stopTokenFilter: StopTokenFilter(tokens: []),
            requestStops: []
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.code, "lab_serial_decode_hook_unsupported")
        }
    }
}
#endif
