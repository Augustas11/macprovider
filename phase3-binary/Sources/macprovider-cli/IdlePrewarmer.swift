import Foundation
import IOKit.ps
import MacProviderCore

struct IdlePrewarmConfig: Sendable, Equatable {
    let enabled: Bool
    let idleThresholdSeconds: Double
    let tickSeconds: Double
    let maxTokens: Int
    let prompt: String
    let runOnBattery: Bool

    init(
        enabled: Bool,
        idleThresholdSeconds: Double,
        tickSeconds: Double,
        maxTokens: Int,
        prompt: String,
        runOnBattery: Bool
    ) {
        self.enabled = enabled
        self.idleThresholdSeconds = idleThresholdSeconds
        self.tickSeconds = tickSeconds
        self.maxTokens = min(8, max(1, maxTokens))
        self.prompt = prompt
        self.runOnBattery = runOnBattery
    }

    init(appConfig: AppConfig) {
        self.init(
            enabled: appConfig.idlePrewarmEnabled,
            idleThresholdSeconds: appConfig.idlePrewarmIdleThresholdSeconds,
            tickSeconds: appConfig.idlePrewarmTickSeconds,
            maxTokens: appConfig.idlePrewarmMaxTokens,
            prompt: appConfig.idlePrewarmPrompt,
            runOnBattery: appConfig.idlePrewarmRunOnBattery
        )
    }
}

enum PowerSourceState: Sendable, Equatable {
    case battery
    case external
    case unknown

    var isBatteryOnly: Bool { self == .battery }

    var wireValue: String {
        switch self {
        case .battery: "battery"
        case .external: "external"
        case .unknown: "unknown"
        }
    }
}

protocol PowerSourceReporting: Sendable {
    func currentPowerSourceState() -> PowerSourceState
}

struct SystemPowerSourceReporter: PowerSourceReporting {
    func currentPowerSourceState() -> PowerSourceState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            if type == kIOPMBatteryPowerKey { return .battery }
            if type == kIOPMACPowerKey || type == kIOPMUPSPowerKey { return .external }
        }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }
        var sawExternal = false
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String
            else {
                continue
            }
            if state == (kIOPSBatteryPowerValue as String) {
                return .battery
            }
            if state == (kIOPSACPowerValue as String) {
                sawExternal = true
            }
        }
        return sawExternal ? .external : .unknown
    }
}

private final class IdlePrewarmCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct IdlePrewarmRun: Sendable {
    let id: UUID
    let startedAt: Date
    let token: IdlePrewarmCancellationToken
    let task: Task<Void, Never>
}

struct IdlePrewarmLogger: Sendable {
    let emit: @Sendable ([String: Any]) -> Void

    static let stdout = IdlePrewarmLogger { object in
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

actor IdlePrewarmer {
    private let modelRuntime: ModelRuntime
    private let providerStatus: ProviderStatus
    private let thermalGate: ThermalGate
    private let powerSource: PowerSourceReporting
    private let config: IdlePrewarmConfig
    private let logger: IdlePrewarmLogger
    private var loopTask: Task<Void, Never>?
    private var inflight: IdlePrewarmRun?
    private var stopped = false

    init(
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        thermalGate: ThermalGate,
        powerSource: PowerSourceReporting,
        config: IdlePrewarmConfig,
        clock _: any Clock = ContinuousClock()
    ) {
        self.init(
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            thermalGate: thermalGate,
            powerSource: powerSource,
            config: config,
            logger: .stdout
        )
    }

    init(
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        thermalGate: ThermalGate,
        powerSource: PowerSourceReporting,
        config: IdlePrewarmConfig,
        logger: IdlePrewarmLogger
    ) {
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.thermalGate = thermalGate
        self.powerSource = powerSource
        self.config = config
        self.logger = logger
    }

    func start() {
        guard loopTask == nil else { return }
        stopped = false
        let tickNanoseconds = Self.nanoseconds(config.tickSeconds)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: tickNanoseconds)
                } catch {
                    break
                }
                await self?.runTick()
            }
        }
    }

    func stop() async {
        stopped = true
        let task = loopTask
        task?.cancel()
        loopTask = nil
        let run = inflight
        inflight = nil
        run?.token.cancel()
        run?.task.cancel()
        await task?.value
        await run?.task.value
    }

    func cancelInflightPrewarm() async {
        cancelInflight(logRealRequest: true)
    }

    func runOneTickForTest() async {
        await runTick()
    }

    private func runTick() async {
        guard !shouldStopTick() else { return }
        guard inflight == nil else { return }
        guard config.enabled else {
            logSkipped("disabled")
            return
        }

        let snapshot = await providerStatus.snapshot()
        guard !shouldStopTick() else { return }
        guard snapshot.requestsInFlight == 0 else {
            logSkipped("busy")
            return
        }

        let idleSeconds = await providerStatus.secondsSinceLastActivityOrPrewarm()
        guard !shouldStopTick() else { return }
        guard idleSeconds >= config.idleThresholdSeconds else {
            logSkipped("not_idle_yet")
            return
        }

        let thermalState = await thermalGate.currentState()
        guard !shouldStopTick() else { return }
        guard !ThermalGate.shouldThrottle(thermalState) else {
            logSkipped("thermal_pressure")
            return
        }

        let powerState = powerSource.currentPowerSourceState()
        let onBattery = powerState.isBatteryOnly
        guard !onBattery || config.runOnBattery else {
            logSkipped("on_battery")
            return
        }

        let isLoaded = await modelRuntime.isLoaded
        guard !shouldStopTick() else { return }
        let loadedModelHash = await modelRuntime.loadedModelHash
        guard !shouldStopTick() else { return }
        guard isLoaded, loadedModelHash != nil else {
            logSkipped("model_not_loaded")
            return
        }

        let finalSnapshot = await providerStatus.snapshot()
        guard !shouldStopTick() else { return }
        guard finalSnapshot.requestsInFlight == 0 else {
            logSkipped("busy")
            return
        }
        let finalIdleSeconds = await providerStatus.secondsSinceLastActivityOrPrewarm()
        guard !shouldStopTick() else { return }
        guard finalIdleSeconds >= config.idleThresholdSeconds else {
            logSkipped("not_idle_yet")
            return
        }

        fireWarmup(idleSeconds: finalIdleSeconds, thermalState: thermalState, onBattery: onBattery)
    }

    private func fireWarmup(idleSeconds: Double, thermalState: ProcessInfo.ThermalState, onBattery: Bool) {
        let id = UUID()
        let startedAt = Date()
        let token = IdlePrewarmCancellationToken()
        let maxTokens = config.maxTokens
        let prompt = config.prompt
        log([
            "event": "idle_prewarm_fired",
            "idle_seconds": idleSeconds,
            "max_tokens": maxTokens,
            "thermal_state": thermalState.label,
            "on_battery": onBattery,
        ])
        let task = Task { [modelRuntime, providerStatus, weak self, token] in
            await providerStatus.noteInternalPrewarm(at: startedAt, elapsedMS: 0)
            do {
                let result = try await modelRuntime.runInternalWarmup(
                    maxTokens: maxTokens,
                    prompt: prompt,
                    shouldCancel: { token.isCancelled }
                )
                await providerStatus.noteInternalPrewarm(at: startedAt, elapsedMS: result.totalElapsedMS)
                await self?.completeWarmup(id: id, result: result)
            } catch is CancellationError {
                await self?.clearWarmup(id: id)
            } catch {
                await self?.failWarmup(id: id, error: error, startedAt: startedAt)
            }
        }
        inflight = IdlePrewarmRun(id: id, startedAt: startedAt, token: token, task: task)
    }

    private func completeWarmup(id: UUID, result: InternalWarmupResult) {
        guard inflight?.id == id else { return }
        inflight = nil
        log([
            "event": "idle_prewarm_completed",
            "elapsed_ms": result.totalElapsedMS,
            "tokens_generated": result.tokensGenerated,
            "first_token_ms": result.firstTokenElapsedMS,
        ])
    }

    private func failWarmup(id: UUID, error: Error, startedAt: Date) {
        guard inflight?.id == id else { return }
        inflight = nil
        log([
            "event": "idle_prewarm_failed",
            "error_class": String(describing: type(of: error)),
            "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
        ])
    }

    private func clearWarmup(id: UUID) {
        guard inflight?.id == id else { return }
        inflight = nil
    }

    private func cancelInflight(logRealRequest: Bool) {
        guard let run = inflight else { return }
        inflight = nil
        run.token.cancel()
        run.task.cancel()
        if logRealRequest {
            log([
                "event": "idle_prewarm_cancelled_by_real_request",
                "elapsed_ms": Self.elapsedMilliseconds(since: run.startedAt),
            ])
        }
    }

    private func logSkipped(_ reason: String) {
        log([
            "event": "idle_prewarm_skipped",
            "reason": reason,
        ])
    }

    private func log(_ object: [String: Any]) {
        logger.emit(object)
    }

    private func shouldStopTick() -> Bool {
        stopped || Task.isCancelled
    }

    private static func elapsedMilliseconds(since date: Date) -> Double {
        max(0, Date().timeIntervalSince(date) * 1000.0)
    }

    private static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}
