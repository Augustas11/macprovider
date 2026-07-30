import ArgumentParser
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class IdlePrewarmerTests: XCTestCase {
    func testPrewarmFiresAfterIdleThreshold() async throws {
        let fixture = try await Fixture(idleThreshold: 0.03)
        try await Task.sleep(nanoseconds: 40_000_000)

        await fixture.prewarmer.runOneTickForTest()
        try await waitUntil { await fixture.probe.calls == 1 }

        let snapshot = await fixture.status.snapshot()
        XCTAssertNotNil(snapshot.lastPrewarmAt)
        let prompts = await fixture.probe.prompts
        XCTAssertEqual(prompts, ["warm"])
    }

    func testPrewarmDoesNotFireWhileBusy() async throws {
        let fixture = try await Fixture(idleThreshold: 0)
        let startedAt = await fixture.status.beginRequest()

        await fixture.prewarmer.runOneTickForTest()
        await fixture.status.finishRequest(startedAt: startedAt, completion: nil, failed: false)

        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fixture.events.names, ["idle_prewarm_skipped"])
        XCTAssertEqual(fixture.events.last?["reason"] as? String, "busy")
    }

    func testPrewarmDoesNotFireBeforeIdleThreshold() async throws {
        let fixture = try await Fixture(idleThreshold: 30)

        await fixture.prewarmer.runOneTickForTest()

        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fixture.events.last?["reason"] as? String, "not_idle_yet")
    }

    func testPrewarmSkipsOnSerious() async throws {
        let fixture = try await Fixture(idleThreshold: 0, thermalState: .serious)

        await fixture.prewarmer.runOneTickForTest()

        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fixture.events.last?["reason"] as? String, "thermal_pressure")
    }

    func testPrewarmSkipsOnCritical() async throws {
        let fixture = try await Fixture(idleThreshold: 0, thermalState: .critical)

        await fixture.prewarmer.runOneTickForTest()

        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fixture.events.last?["reason"] as? String, "thermal_pressure")
    }

    func testBatteryGateHonorsRunOnBatteryConfig() async throws {
        let off = try await Fixture(idleThreshold: 0, powerState: .battery, runOnBattery: false)
        await off.prewarmer.runOneTickForTest()
        let offCalls = await off.probe.calls
        XCTAssertEqual(offCalls, 0)
        XCTAssertEqual(off.events.last?["reason"] as? String, "on_battery")

        let on = try await Fixture(idleThreshold: 0, powerState: .battery, runOnBattery: true)
        await on.prewarmer.runOneTickForTest()
        try await waitUntil { await on.probe.calls == 1 }
    }

    func testDisabledProducesNoWarmupCallsAcrossTicks() async throws {
        let fixture = try await Fixture(enabled: false, idleThreshold: 0)

        for _ in 0..<10 {
            await fixture.prewarmer.runOneTickForTest()
        }

        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fixture.events.names.filter { $0 == "idle_prewarm_skipped" }.count, 10)
    }

    func testInflightPrewarmCanBeCancelledByRealRequest() async throws {
        let fixture = try await Fixture(idleThreshold: 0, blocksWarmup: true)
        await fixture.prewarmer.runOneTickForTest()
        try await waitUntil { await fixture.probe.calls == 1 }

        await fixture.prewarmer.cancelInflightPrewarm()
        try await waitUntil { fixture.events.names.contains("idle_prewarm_cancelled_by_real_request") }

        XCTAssertLessThan((fixture.events.last?["elapsed_ms"] as? Double) ?? 1_000, 500)
    }

    func testRunInternalWarmupDoesNotTouchRequestCountersSlotsOrReceiptAudit() async throws {
        let fixture = try await Fixture(idleThreshold: 0)
        let before = await fixture.status.snapshot(resetWindow: true)
        let receiptBytes = DataCapture()

        _ = try await ReceiptAudit.withSink({ receiptBytes.append($0) }) {
            try await fixture.runtime.runInternalWarmup(maxTokens: 99, prompt: "warm", shouldCancel: { false })
        }

        let after = await fixture.status.snapshot(resetWindow: false)
        XCTAssertEqual(after.requestsTotal, before.requestsTotal)
        XCTAssertEqual(after.requestsInFlight, before.requestsInFlight)
        XCTAssertEqual(after.requestsServedSinceLast, 0)
        XCTAssertNil(after.avgLatencyMSSinceLast)
        XCTAssertNil(after.throughputTPSSinceLast)
        XCTAssertEqual(after.slotsFree, before.slotsFree)
        XCTAssertTrue(receiptBytes.isEmpty)
        let maxTokens = await fixture.probe.maxTokens
        XCTAssertEqual(maxTokens, [8])
    }

    func testPrewarmDoesNotFireAgainWithinIdleThreshold() async throws {
        let fixture = try await Fixture(idleThreshold: 0.08)
        try await Task.sleep(nanoseconds: 90_000_000)
        await fixture.prewarmer.runOneTickForTest()
        try await waitUntil { await fixture.probe.calls == 1 }
        try await waitUntil { (await fixture.status.snapshot()).lastPrewarmAt != nil }

        await fixture.prewarmer.runOneTickForTest()

        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.events.last?["reason"] as? String, "not_idle_yet")
    }

    func testPrewarmFiresAgainAfterIdleThresholdSincePrewarm() async throws {
        let fixture = try await Fixture(idleThreshold: 0.08)
        try await Task.sleep(nanoseconds: 90_000_000)
        await fixture.prewarmer.runOneTickForTest()
        try await waitUntil { fixture.events.names.contains("idle_prewarm_completed") }

        try await Task.sleep(nanoseconds: 90_000_000)
        await fixture.prewarmer.runOneTickForTest()

        try await waitUntil { await fixture.probe.calls == 2 }
    }

    func testStructuredEventsCoverAllCategories() async throws {
        let success = try await Fixture(idleThreshold: 0)
        await success.prewarmer.runOneTickForTest()
        try await waitUntil { success.events.names.contains("idle_prewarm_completed") }

        let skipped = try await Fixture(enabled: false, idleThreshold: 0)
        await skipped.prewarmer.runOneTickForTest()

        let cancelled = try await Fixture(idleThreshold: 0, blocksWarmup: true)
        await cancelled.prewarmer.runOneTickForTest()
        try await waitUntil { await cancelled.probe.calls == 1 }
        await cancelled.prewarmer.cancelInflightPrewarm()

        let failed = try await Fixture(idleThreshold: 0, warmupError: TestWarmupError.failed)
        await failed.prewarmer.runOneTickForTest()
        try await waitUntil { failed.events.names.contains("idle_prewarm_failed") }

        let names = Set(success.events.names + skipped.events.names + cancelled.events.names + failed.events.names)
        XCTAssertTrue(names.isSuperset(of: [
            "idle_prewarm_fired",
            "idle_prewarm_completed",
            "idle_prewarm_skipped",
            "idle_prewarm_cancelled_by_real_request",
            "idle_prewarm_failed",
        ]))
    }

    func testConfigValidationRejectsInvalidIdlePrewarmValues() {
        let cases = [
            ("idle_prewarm:\n  enabled: maybe\n", "enabled"),
            ("idle_prewarm:\n  idle_threshold_seconds: 4\n", "idle_prewarm.idle_threshold_seconds"),
            ("idle_prewarm:\n  tick_seconds: 0\n", "idle_prewarm.tick_seconds"),
            ("idle_prewarm:\n  max_tokens: 9\n", "idle_prewarm.max_tokens"),
            ("idle_prewarm:\n  prompt: \"\"\n", "idle_prewarm.prompt"),
            ("idle_prewarm:\n  run_on_battery: maybe\n", "run_on_battery"),
        ]

        for (yaml, field) in cases {
            XCTAssertThrowsError(try ConfigLoader.load(
                cli: CLIOverrides(),
                environment: [:],
                fileExists: { _ in true },
                readFile: { _ in yaml }
            ), field) { error in
                XCTAssertTrue(String(describing: error).contains(field), String(describing: error))
            }
        }
    }

    func testNoIdlePrewarmOnBatteryOverridesYamlTrue() throws {
        let disabled = try ServeCommand.parse(["--no-idle-prewarm-on-battery"])
        XCTAssertEqual(disabled.idlePrewarmRunOnBattery, false)
        let enabled = try ServeCommand.parse(["--idle-prewarm-on-battery"])
        XCTAssertEqual(enabled.idlePrewarmRunOnBattery, true)

        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(idlePrewarmRunOnBattery: disabled.idlePrewarmRunOnBattery),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "idle_prewarm:\n  run_on_battery: true\n" }
        )

        XCTAssertFalse(loaded.idlePrewarmRunOnBattery)
    }

    func testTickSkipsWhenPrewarmAlreadyInflight() async throws {
        let fixture = try await Fixture(idleThreshold: 0, blocksWarmup: true)
        await fixture.prewarmer.runOneTickForTest()
        try await waitUntil { await fixture.probe.calls == 1 }

        await fixture.prewarmer.runOneTickForTest()

        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, 1)
        await fixture.prewarmer.stop()
    }

    func testStopCancelsBackgroundLoopAndInflightWarmup() async throws {
        let fixture = try await Fixture(idleThreshold: 0, tickSeconds: 0.02, blocksWarmup: true)
        await fixture.prewarmer.start()
        try await waitUntil { await fixture.probe.calls == 1 }

        let start = Date()
        await fixture.prewarmer.stop()
        try await waitUntil { await fixture.probe.cancelledCompletions == 1 }

        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let callsAfterStop = await fixture.probe.calls
        try await Task.sleep(nanoseconds: 60_000_000)
        let calls = await fixture.probe.calls
        XCTAssertEqual(calls, callsAfterStop)
    }

    func testShutdownDuringInflightPrewarmCompletesWithinBoundedTime() async throws {
        let fixture = try await Fixture(idleThreshold: 0, blocksWarmup: true)
        await fixture.prewarmer.runOneTickForTest()
        try await waitUntil { await fixture.probe.calls == 1 }

        let start = Date()
        await fixture.prewarmer.stop()

        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let cancelledCompletions = await fixture.probe.cancelledCompletions
        XCTAssertEqual(cancelledCompletions, 1)
    }

    func testSlotsFreeInvariantBeforeDuringAfterPrewarm() async throws {
        let fixture = try await Fixture(idleThreshold: 0, blocksWarmup: true, maxConcurrency: 4)
        let before = await fixture.status.snapshot()
        await fixture.prewarmer.runOneTickForTest()
        try await waitUntil { await fixture.probe.calls == 1 }
        let during = await fixture.status.snapshot()

        await fixture.prewarmer.stop()
        let after = await fixture.status.snapshot()

        XCTAssertEqual(before.slotsFree, 4)
        XCTAssertEqual(during.slotsFree, before.slotsFree)
        XCTAssertEqual(after.slotsFree, before.slotsFree)
    }
}

private struct Fixture {
    let runtime: ModelRuntime
    let status: ProviderStatus
    let prewarmer: IdlePrewarmer
    let probe: WarmupProbe
    let events: EventCapture

    init(
        enabled: Bool = true,
        idleThreshold: Double,
        tickSeconds: Double = 1,
        thermalState: ProcessInfo.ThermalState = .nominal,
        powerState: PowerSourceState = .external,
        runOnBattery: Bool = false,
        blocksWarmup: Bool = false,
        warmupError: Error? = nil,
        maxConcurrency: Int = 1
    ) async throws {
        let probe = WarmupProbe(blocks: blocksWarmup, error: warmupError)
        let hash = String(repeating: "a", count: 64)
        let runtime = ModelRuntime(
            modelID: "model-a",
            modelHash: hash,
            warmSwapEnabled: false,
            loader: { _ in throw TestWarmupError.unexpectedLoad },
            testCompletion: { _, request in
                try await probe.complete(request: request)
            }
        )
        let thermalGate = ThermalGate(stateProvider: FixedThermalProvider(state: thermalState))
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: maxConcurrency),
            modelHash: hash,
            thermalGate: thermalGate
        )
        await runtime.setProviderStatus(status)
        let events = EventCapture()
        let prewarmer = IdlePrewarmer(
            modelRuntime: runtime,
            providerStatus: status,
            thermalGate: thermalGate,
            powerSource: FixedPowerSource(state: powerState),
            config: IdlePrewarmConfig(
                enabled: enabled,
                idleThresholdSeconds: idleThreshold,
                tickSeconds: tickSeconds,
                maxTokens: 1,
                prompt: "warm",
                runOnBattery: runOnBattery
            ),
            logger: IdlePrewarmLogger { events.append($0) }
        )
        self.runtime = runtime
        self.status = status
        self.prewarmer = prewarmer
        self.probe = probe
        self.events = events
    }
}

private actor WarmupProbe {
    private let blocks: Bool
    private let error: Error?
    private var callCount = 0
    private var cancelledCount = 0
    private var seenPrompts: [String] = []
    private var seenMaxTokens: [Int] = []

    init(blocks: Bool, error: Error?) {
        self.blocks = blocks
        self.error = error
    }

    var calls: Int { callCount }
    var cancelledCompletions: Int { cancelledCount }
    var prompts: [String] { seenPrompts }
    var maxTokens: [Int] { seenMaxTokens }

    func complete(request: ChatCompletionRequest) async throws -> CompletionResult {
        callCount += 1
        seenPrompts.append(request.messages.last?.content ?? "")
        seenMaxTokens.append(request.maxTokens ?? 0)
        if let error {
            throw error
        }
        if blocks {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            } catch is CancellationError {
                cancelledCount += 1
                throw CancellationError()
            }
            cancelledCount += 1
            throw CancellationError()
        }
        return CompletionResult(content: "ok", finishReason: "stop", promptTokens: 1, completionTokens: 1, ttftMilliseconds: 1)
    }
}

private final class EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Any]] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0["event"] as? String }
    }

    var last: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    func append(_ event: [String: Any]) {
        lock.lock()
        values.append(event)
        lock.unlock()
    }
}

private final class DataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.isEmpty
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}

private struct FixedPowerSource: PowerSourceReporting {
    let state: PowerSourceState
    func currentPowerSourceState() -> PowerSourceState { state }
}

private struct FixedThermalProvider: ThermalStateProviding {
    let state: ProcessInfo.ThermalState
    func currentThermalState() -> ProcessInfo.ThermalState { state }
}

private enum TestWarmupError: Error {
    case failed
    case unexpectedLoad
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ predicate: () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await predicate() {
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for condition")
}
