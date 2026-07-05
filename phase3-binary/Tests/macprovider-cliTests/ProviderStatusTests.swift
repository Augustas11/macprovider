import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderStatusTests: XCTestCase {
    private func makeCapacity(maxConcurrency: Int = 4) -> ProviderCapacity {
        ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: maxConcurrency)
    }

    func testSpecDecodeStatusFieldsAreDisabledWithoutDraftConfig() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snap = await status.snapshot()
        let fields = RouterHandler.specDecodeTelemetryFields(snap)

        XCTAssertFalse(snap.specDecodeEnabled)
        XCTAssertNil(snap.specDecodeDraftModelID)
        XCTAssertNil(snap.specDecodeNumDraftTokens)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
        XCTAssertEqual(fields["spec_decode_enabled"] as? Bool, false)
        XCTAssertTrue(fields["spec_decode_draft_model_id"] is NSNull)
        XCTAssertTrue(fields["spec_decode_num_draft_tokens"] is NSNull)
        XCTAssertTrue(fields["spec_decode_acceptance_rate"] is NSNull)
    }

    func testSpecDecodeStatusFieldsExposeEnabledNoWindowShape() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let snap = await status.snapshot()
        let body = RouterHandler.statusResponse(snap, providerID: "provider-a", coordinatorURL: nil)

        XCTAssertTrue(snap.specDecodeEnabled)
        XCTAssertEqual(snap.specDecodeDraftModelID, "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertEqual(snap.specDecodeNumDraftTokens, 3)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
        XCTAssertEqual(body["spec_decode_enabled"] as? Bool, true)
        XCTAssertEqual(body["spec_decode_draft_model_id"] as? String, "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertEqual(body["spec_decode_num_draft_tokens"] as? Int, 3)
        XCTAssertTrue(body["spec_decode_acceptance_rate"] is NSNull)
    }

    func testStatusResponseUsesRuntimeModelDuringProviderStatusLag() async {
        let status = ProviderStatus(modelID: "old-model", modelLoaded: false, capacity: makeCapacity())
        let snap = await status.snapshot()
        let runtimeSnapshot = RuntimeSnapshot(state: .ready, container: nil, modelID: "new-model", modelHash: "new-hash")

        let body = RouterHandler.statusResponse(
            snap,
            providerID: "provider-a",
            coordinatorURL: nil,
            runtimeSnapshot: runtimeSnapshot
        )

        XCTAssertEqual(body["model"] as? String, "new-model")
        XCTAssertEqual(body["model_loaded"] as? Bool, true)
    }

    func testSpecDecodeStatusSuppressesTelemetryOnRuntimeGenerationMismatch() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let snap = await status.snapshot()

        let body = RouterHandler.statusResponse(
            snap,
            providerID: "provider-a",
            coordinatorURL: nil,
            specDecodeTelemetryMatchesRuntime: false
        )

        XCTAssertEqual(body["spec_decode_enabled"] as? Bool, false)
        XCTAssertTrue(body["spec_decode_draft_model_id"] is NSNull)
        XCTAssertTrue(body["spec_decode_num_draft_tokens"] is NSNull)
        XCTAssertEqual(body["spec_decode_drafted_tokens_since_last"] as? Int, 0)
        XCTAssertEqual(body["spec_decode_accepted_tokens_since_last"] as? Int, 0)
        XCTAssertTrue(body["spec_decode_acceptance_rate"] is NSNull)
    }

    func testSpecDecodeStatusSuppressesTelemetryWhenRuntimeNotRequestEligible() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let snap = await status.snapshot()

        let fields = RouterHandler.specDecodeTelemetryFields(snap, runtimeEligible: false)

        XCTAssertEqual(fields["spec_decode_enabled"] as? Bool, false)
        XCTAssertTrue(fields["spec_decode_draft_model_id"] is NSNull)
        XCTAssertTrue(fields["spec_decode_num_draft_tokens"] is NSNull)
        XCTAssertEqual(fields["spec_decode_drafted_tokens_since_last"] as? Int, 0)
        XCTAssertEqual(fields["spec_decode_accepted_tokens_since_last"] as? Int, 0)
        XCTAssertTrue(fields["spec_decode_acceptance_rate"] is NSNull)
    }

    func testSpecDecodeStatusWindowAggregatesAndResetsWithRequestWindow() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let startedAt = await status.beginRequest(requestID: "r-1")
        let generation = await status.currentSpecDecodeGeneration()
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                specDecodeDraftedTokens: 10,
                specDecodeAcceptedTokens: 4,
                specDecodeGeneration: generation
            ),
            failed: false,
            requestID: "r-1"
        )

        let snap = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snap.requestsServedSinceLast, 1)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 10)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 4)
        XCTAssertEqual(try XCTUnwrap(snap.specDecodeAcceptanceRate), 0.4, accuracy: 0.000_001)

        let afterReset = await status.snapshot()
        XCTAssertEqual(afterReset.requestsServedSinceLast, 0)
        XCTAssertEqual(afterReset.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(afterReset.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(afterReset.specDecodeAcceptanceRate)
    }

    func testSpecDecodeConfigResetDisablesAndClearsWindowOnTargetSwap() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let startedAt = await status.beginRequest(requestID: "r-1")
        let generation = await status.currentSpecDecodeGeneration()
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                specDecodeDraftedTokens: 8,
                specDecodeAcceptedTokens: 6,
                specDecodeGeneration: generation
            ),
            failed: false,
            requestID: "r-1"
        )

        await status.setSpecDecodeConfig(draftModelID: nil, numDraftTokens: nil)

        let snap = await status.snapshot()
        XCTAssertFalse(snap.specDecodeEnabled)
        XCTAssertNil(snap.specDecodeDraftModelID)
        XCTAssertNil(snap.specDecodeNumDraftTokens)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
    }

    func testSpecDecodeLateOldGenerationCompletionDoesNotPollutePostSwapWindow() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let oldGeneration = await status.currentSpecDecodeGeneration()

        await status.setSpecDecodeConfig(draftModelID: nil, numDraftTokens: nil)
        let startedAt = await status.beginRequest(requestID: "old-r-1")
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "late",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                specDecodeDraftedTokens: 12,
                specDecodeAcceptedTokens: 9,
                specDecodeGeneration: oldGeneration
            ),
            failed: false,
            requestID: "old-r-1"
        )

        let snap = await status.snapshot()
        XCTAssertFalse(snap.specDecodeEnabled)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
    }

    func testSpecDecodeDraftModelIDRedactsLocalPaths() {
        let local = "/Users/test/.cache/huggingface/hub/models--draft"
        let redacted = ProviderStatus.publicSpecDecodeDraftModelID(local)

        XCTAssertNotEqual(redacted, local)
        XCTAssertTrue(redacted?.hasPrefix("local:") ?? false)
        XCTAssertEqual(redacted?.count, "local:".count + 32)
        XCTAssertEqual(
            ProviderStatus.publicSpecDecodeDraftModelID("mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"),
            "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"
        )
    }

    func testSlotsFreeReportsZeroWhenThermallyThrottled() async {
        for state: ProcessInfo.ThermalState in [.serious, .critical] {
            let gate = ThermalGate(stateProvider: FixedThermalProvider(state: state))
            let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)
            let snap = await status.snapshot()
            XCTAssertEqual(snap.slotsFree, 0, "throttled state=\(state.label) must report slots_free=0")
            XCTAssertEqual(snap.status, .busy, "throttled state=\(state.label) must report status=busy")
            XCTAssertEqual(snap.slotsTotal, 4, "slots_total is hardware capacity, must stay constant")
            XCTAssertTrue(snap.thermallyThrottled)
        }
    }

    func testSlotsFreeUnthrottledReturnsAvailableCapacity() async {
        for state: ProcessInfo.ThermalState in [.nominal, .fair] {
            let gate = ThermalGate(stateProvider: FixedThermalProvider(state: state))
            let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)
            let snap = await status.snapshot()
            XCTAssertEqual(snap.slotsFree, 4, "unthrottled state=\(state.label) must report full capacity")
            XCTAssertEqual(snap.status, .ready, "unthrottled state=\(state.label) must report status=ready")
            XCTAssertFalse(snap.thermallyThrottled)
        }
    }

    func testTransitionFromNominalToSeriousDropsSlotsToZero() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        let before = await status.snapshot()
        XCTAssertEqual(before.slotsFree, 4)
        XCTAssertFalse(before.thermallyThrottled)

        await gate.inject(state: .serious)
        let throttled = await status.snapshot()
        XCTAssertEqual(throttled.slotsFree, 0)
        XCTAssertEqual(throttled.status, .busy)
        XCTAssertTrue(throttled.thermallyThrottled)

        await gate.inject(state: .fair)
        let restored = await status.snapshot()
        XCTAssertEqual(restored.slotsFree, 4)
        XCTAssertEqual(restored.status, .ready)
        XCTAssertFalse(restored.thermallyThrottled)
    }

    func testThrottleDoesNotDrainInFlightRequests() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        _ = await status.beginRequest(requestID: "r-1")
        _ = await status.beginRequest(requestID: "r-2")
        let inflightBefore = await status.snapshot()
        XCTAssertEqual(inflightBefore.requestsInFlight, 2)
        XCTAssertEqual(inflightBefore.slotsFree, 2)

        await gate.inject(state: .serious)
        let throttled = await status.snapshot()
        XCTAssertEqual(throttled.requestsInFlight, 2, "in-flight requests are NOT cancelled by throttle")
        XCTAssertEqual(throttled.slotsFree, 0, "but future admissions are gated")
    }

    func testTransitionLoggerFiresOnEdgeOnly() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let recorder = TransitionRecorder()
        await gate.setTransitionLogger { old, new in recorder.record(old: old, new: new) }

        await gate.inject(state: .nominal)
        XCTAssertEqual(recorder.count, 0, "no-op transition must not log")

        await gate.inject(state: .serious)
        await gate.inject(state: .critical)
        await gate.inject(state: .fair)
        XCTAssertEqual(recorder.transitions.map { "\($0.0.label)->\($0.1.label)" },
                       ["nominal->serious", "serious->critical", "critical->fair"])
    }

    func testSnapshotResetWindowSurvivesReentrancyDuringThermalGateAwait() async {
        // Regression for the round-1 finding: `snapshot(resetWindow:)` must
        // resolve the thermal-gate `await` BEFORE reading any window state.
        // We force the race by giving the gate a 50ms artificial delay
        // inside `isThrottled()`, then letting `finishRequest` enter the
        // actor while snapshot is suspended. If the await were AFTER the
        // window reads, the finish would be silently dropped on reset.
        let gate = ThermalGate(
            stateProvider: FixedThermalProvider(state: .nominal),
            isThrottledArtificialDelayNanos: 50_000_000
        )
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        let begin = await status.beginRequest(requestID: "r-1")
        let snapshotTask = Task { await status.snapshot(resetWindow: true) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await status.finishRequest(startedAt: begin, completion: nil, failed: false, requestID: "r-1")

        let snap = await snapshotTask.value
        XCTAssertEqual(snap.requestsServedSinceLast, 1,
                       "finishRequest landing during snapshot's await must be visible AND consumed by reset")

        let after = await status.snapshot(resetWindow: false)
        XCTAssertEqual(after.requestsServedSinceLast, 0, "window must reset cleanly after reentrant finishRequest")
    }

    func testRapidThermalTransitionsAllReachTheGate() async {
        // Regression: notifications captured at the edge feed a single
        // ordered drain task, so a rapid `.serious → .fair` doesn't drop
        // the throttled interval and its log line.
        let provider = MutableThermalProvider(initial: .nominal)
        let gate = ThermalGate(stateProvider: provider)
        let recorder = TransitionRecorder()
        await gate.setTransitionLogger { old, new in recorder.record(old: old, new: new) }
        await gate.startObserving()

        provider.set(.serious)
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        provider.set(.fair)
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        let deadline = Date().addingTimeInterval(2.0)
        while recorder.count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let labels = recorder.transitions.map { "\($0.0.label)->\($0.1.label)" }
        XCTAssertEqual(labels, ["nominal->serious", "serious->fair"],
                       "both transitions must be observed in FIFO order, including the throttled interval")
    }

    func testStartObservingReconcilesStateChangedBetweenInitAndStart() async {
        // Regression: if thermal state changes between `init` and
        // `startObserving()`, no NSNotification fires while we're listening.
        // `startObserving()` must reconcile synchronously on the actor so
        // an immediate `isThrottled()` reads the post-reconcile state with
        // no polling.
        let provider = MutableThermalProvider(initial: .nominal)
        let gate = ThermalGate(stateProvider: provider)
        let recorder = TransitionRecorder()
        await gate.setTransitionLogger { old, new in recorder.record(old: old, new: new) }

        provider.set(.serious)
        await gate.startObserving()

        let throttled = await gate.isThrottled()
        XCTAssertTrue(throttled, "isThrottled must reflect the reconciled state immediately after startObserving returns — no polling")
        XCTAssertEqual(recorder.transitions.map { "\($0.0.label)->\($0.1.label)" },
                       ["nominal->serious"],
                       "the missed-transition reconciliation must also fire the transition logger exactly once")
    }

    func testShouldThrottleThreshold() {
        XCTAssertFalse(ThermalGate.shouldThrottle(.nominal))
        XCTAssertFalse(ThermalGate.shouldThrottle(.fair))
        XCTAssertTrue(ThermalGate.shouldThrottle(.serious))
        XCTAssertTrue(ThermalGate.shouldThrottle(.critical))
    }
}

private struct FixedThermalProvider: ThermalStateProviding {
    let state: ProcessInfo.ThermalState
    func currentThermalState() -> ProcessInfo.ThermalState { state }
}

private final class MutableThermalProvider: ThermalStateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessInfo.ThermalState

    init(initial: ProcessInfo.ThermalState) { self.state = initial }

    func set(_ next: ProcessInfo.ThermalState) {
        lock.lock(); defer { lock.unlock() }
        state = next
    }

    func currentThermalState() -> ProcessInfo.ThermalState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

private final class TransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ProcessInfo.ThermalState, ProcessInfo.ThermalState)] = []

    func record(old: ProcessInfo.ThermalState, new: ProcessInfo.ThermalState) {
        lock.lock(); defer { lock.unlock() }
        entries.append((old, new))
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var transitions: [(ProcessInfo.ThermalState, ProcessInfo.ThermalState)] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
}
