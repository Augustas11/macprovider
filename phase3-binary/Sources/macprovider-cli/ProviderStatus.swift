import Darwin
import CryptoKit
import Dispatch
import Foundation
import IOKit

enum ProviderHealthState: String, Sendable {
    case ready
    case busy
    case degraded
    case draining
    case unavailable
}

enum ProviderMemoryPressure: String, Sendable {
    case normal
    case warning
    case critical
}

protocol MemoryPressureProviding: Sendable {
    func currentMemoryPressure() -> ProviderMemoryPressure
}

struct ProviderWorkloadTelemetry: Sendable, Equatable {
    let cpuUtilizationPercent: Double?
    let gpuUtilizationPercent: Double?
    let gpuUtilizationScope: String
    let powerSource: PowerSourceState
}

protocol ProviderWorkloadTelemetryProviding: Sendable {
    func currentWorkloadTelemetry() -> ProviderWorkloadTelemetry
}

final class SystemProviderWorkloadTelemetryMonitor: ProviderWorkloadTelemetryProviding, @unchecked Sendable {
    static let shared = SystemProviderWorkloadTelemetryMonitor()

    private let lock = NSLock()
    private let powerSource: PowerSourceReporting
    private let gpuSampler: DispatchSourceTimer
    private var priorCPUSeconds: Double?
    private var priorWallTime: TimeInterval?
    private var cachedGPU: (sampledAt: TimeInterval, value: Double?)?

    init(powerSource: PowerSourceReporting = SystemPowerSourceReporter()) {
        self.powerSource = powerSource
        self.gpuSampler = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "live.streamvc.macprovider.gpu-telemetry", qos: .utility)
        )
        self.priorCPUSeconds = Self.processCPUSeconds()
        self.priorWallTime = ProcessInfo.processInfo.systemUptime
        gpuSampler.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        gpuSampler.setEventHandler { [weak self] in
            let sampledAt = ProcessInfo.processInfo.systemUptime
            let value = Self.readGPUUtilizationPercent()
            self?.lock.withLock { self?.cachedGPU = (sampledAt, value) }
        }
        gpuSampler.resume()
    }

    deinit {
        gpuSampler.cancel()
    }

    func currentWorkloadTelemetry() -> ProviderWorkloadTelemetry {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            let cpu = Self.processCPUSeconds().flatMap { total -> Double? in
                defer {
                    priorCPUSeconds = total
                    priorWallTime = now
                }
                guard let previousCPU = priorCPUSeconds,
                      let previousWall = priorWallTime,
                      now > previousWall,
                      total >= previousCPU else {
                    return nil
                }
                let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
                return Self.clampPercent(((total - previousCPU) / (now - previousWall)) * 100.0 / cores)
            }
            let gpu = cachedGPU.flatMap { now - $0.sampledAt <= 3.0 ? $0.value : nil }
            return ProviderWorkloadTelemetry(
                cpuUtilizationPercent: cpu,
                gpuUtilizationPercent: gpu,
                // Apple exposes AGX utilization for the host device, not a
                // process counter. The canary treats this conservatively and
                // permits exactly one provider per host.
                gpuUtilizationScope: "host",
                powerSource: powerSource.currentPowerSourceState()
            )
        }
    }

    private static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        return user + system
    }

    private static func readGPUUtilizationPercent() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        ), let statistics = raw.takeRetainedValue() as? [String: Any],
              let value = statistics["Device Utilization %"] as? NSNumber else {
            return nil
        }
        return clampPercent(value.doubleValue)
    }

    private static func clampPercent(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(100.0, max(0.0, value))
    }
}

final class SystemMemoryPressureMonitor: MemoryPressureProviding, @unchecked Sendable {
    static let shared = SystemMemoryPressureMonitor()

    private let lock = NSLock()
    private var current: ProviderMemoryPressure = .normal
    private let source: DispatchSourceMemoryPressure

    private init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "live.streamvc.macprovider.memory-pressure")
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            let next: ProviderMemoryPressure
            if event.contains(.critical) {
                next = .critical
            } else if event.contains(.warning) {
                next = .warning
            } else {
                next = .normal
            }
            self.lock.withLock { self.current = next }
        }
        source.resume()
    }

    func currentMemoryPressure() -> ProviderMemoryPressure {
        lock.withLock { current }
    }
}

struct ProviderCapacity: Sendable {
    static let maxConcurrencyOverrideLimit = 8

    let ramGB: Int
    let ramTier: String
    let maxContextTokens: Int
    let maxConcurrency: Int
    let throughputTPSEstimate: Double

    init(maxContextOverride: Int?, maxConcurrencyOverride: Int?, throughputTPSEstimate: Double = 0.0) {
        let physicalMemoryGB = Self.systemMemoryGB()
        self.ramGB = physicalMemoryGB

        let defaults = Self.defaults(forPhysicalMemoryGB: physicalMemoryGB)

        self.ramTier = defaults.tier
        self.maxContextTokens = maxContextOverride ?? defaults.context
        self.maxConcurrency = maxConcurrencyOverride ?? defaults.concurrency
        self.throughputTPSEstimate = throughputTPSEstimate
    }

    func withThroughputEstimate(_ value: Double) -> ProviderCapacity {
        ProviderCapacity(
            maxContextOverride: maxContextTokens,
            maxConcurrencyOverride: maxConcurrency,
            throughputTPSEstimate: value
        )
    }

    func modelParamsB(modelID: String?) -> Double {
        guard let modelID else { return 0.0 }
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: modelID, range: NSRange(modelID.startIndex..., in: modelID)),
              let range = Range(match.range(at: 1), in: modelID)
        else {
            return 0.0
        }
        return Double(modelID[range]) ?? 0.0
    }

    private static func systemMemoryGB() -> Int {
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0, memsize > 0 {
            return max(1, Int((memsize + 1_073_741_823) / 1_073_741_824))
        }
        return max(1, Int((ProcessInfo.processInfo.physicalMemory + 1_073_741_823) / 1_073_741_824))
    }

    static func defaults(forPhysicalMemoryGB physicalMemoryGB: Int) -> (tier: String, context: Int, concurrency: Int) {
        switch physicalMemoryGB {
        case ...12:
            return ("8GB", 20_000, 1)
        case ...24:
            return ("16GB", 50_000, 2)
        case ...48:
            return ("32GB", 120_000, 4)
        default:
            return ("64GB+", 200_000, 8)
        }
    }

    static func defaultContextTokens(forPhysicalMemoryGB physicalMemoryGB: Int) -> Int {
        defaults(forPhysicalMemoryGB: physicalMemoryGB).context
    }

    static func draftContextCap(forPhysicalMemoryGB physicalMemoryGB: Int) -> Int {
        switch physicalMemoryGB {
        case ...12:
            return 8_192
        case ...24:
            return 20_000
        case ...48:
            return 50_000
        default:
            return 120_000
        }
    }

    static func defaultContextTokensForCurrentHost() -> Int {
        defaultContextTokens(forPhysicalMemoryGB: systemMemoryGB())
    }

    static func draftContextCapForCurrentHost() -> Int {
        draftContextCap(forPhysicalMemoryGB: systemMemoryGB())
    }
}

struct ProviderSnapshot: Sendable {
    let status: ProviderHealthState
    let modelID: String?
    let modelHash: String?
    let modelHashAlgorithm: String?
    let weightsManifestSHA256: String?
    let weightsManifestAlgorithm: String?
    let modelLoaded: Bool
    let uptimeSeconds: Int
    let requestsTotal: Int
    let requestsToday: Int
    let inputTokensToday: Int64
    let outputTokensToday: Int64
    let inputTokensAllTime: Int64
    let outputTokensAllTime: Int64
    let requestsInFlight: Int
    let requestsQueued: Int
    let errorsTotal: Int
    let restartCount: Int
    let memoryRSSMB: Int
    let memoryPressure: ProviderMemoryPressure
    let cpuUtilizationPercent: Double?
    let gpuUtilizationPercent: Double?
    let gpuUtilizationScope: String
    let powerSource: PowerSourceState
    let capacity: ProviderCapacity
    let requestsServedSinceLast: Int
    let avgLatencyMSSinceLast: Double?
    let throughputTPSSinceLast: Double?
    let coordinatorConnected: Bool
    let coordinatorAssignedID: String?
    let coordinatorTier: String?
    let coordinatorIdentityAdmissionMode: String?
    let recommendedBinaryVersion: String?
    let catalogCompatibilityConfirmed: Bool
    let activeRequestIDCount: Int
    let thermallyThrottled: Bool
    let thermalState: String
    let lastActivityAt: Date
    let lastPrewarmAt: Date?
    let specDecodeEnabled: Bool
    let specDecodeDraftModelID: String?
    let specDecodeNumDraftTokens: Int?
    let specDecodeDraftedTokensSinceLast: Int
    let specDecodeAcceptedTokensSinceLast: Int
    let specDecodeAcceptanceRate: Double?
    let specDecodeGeneration: Int
    let transitionID: String
    let transitionAt: Date
    let transitionReason: String

    var slotsFree: Int {
        if thermallyThrottled { return 0 }
        return max(0, capacity.maxConcurrency - requestsInFlight)
    }

    var slotsTotal: Int {
        capacity.maxConcurrency
    }

    func safetyTelemetry(
        providerID: String?,
        modelID: String?,
        modelLoaded: Bool? = nil,
        binaryVersion: String? = nil,
        compatibilitySetID: String? = nil,
        modelHash: String? = nil,
        modelHashAlgorithm: String? = nil,
        weightsManifestSHA256: String? = nil,
        observationID: String,
        observedAt: String,
        validForMS: Int
    ) -> [String: Any] {
        let hasV2Identity = binaryVersion?.isEmpty == false
            && compatibilitySetID?.isEmpty == false
            && modelHash?.isEmpty == false
            && coordinatorAssignedID?.isEmpty == false
        var telemetry: [String: Any] = [
            "schema_version": hasV2Identity ? 2 : 1,
            "provider_id": providerID ?? NSNull(),
            "model_id": modelID ?? NSNull(),
            "model_loaded": modelLoaded ?? self.modelLoaded,
            "runtime_state": status.rawValue,
            "hardware_tier": capacity.ramTier,
            "requests_in_flight": requestsInFlight,
            "requests_queued": requestsQueued,
            "memory_rss_mb": memoryRSSMB,
            "memory_capacity_mb": capacity.ramGB * 1024,
            "memory_pressure": memoryPressure.rawValue,
            "thermal_state": thermalState,
            "thermally_throttled": thermallyThrottled,
            "restart_count": restartCount,
            "uptime_s": uptimeSeconds,
            "coordinator_connected": coordinatorConnected,
            "observation_id": observationID,
            "observed_at": observedAt,
            "valid_for_ms": validForMS,
        ]
        if hasV2Identity {
            telemetry["coordinator_session_id"] = coordinatorAssignedID!
            telemetry["cpu_utilization_pct"] = cpuUtilizationPercent ?? NSNull()
            telemetry["gpu_utilization_pct"] = gpuUtilizationPercent ?? NSNull()
            telemetry["gpu_utilization_scope"] = gpuUtilizationScope
            telemetry["power_source"] = powerSource.wireValue
            telemetry["binary_version"] = binaryVersion!
            telemetry["compatibility_set_id"] = compatibilitySetID!
            telemetry["model_hash"] = modelHash!
            if let modelHashAlgorithm {
                telemetry["model_hash_algorithm"] = modelHashAlgorithm
            }
            if let weightsManifestSHA256 {
                telemetry["weights_manifest_sha256"] = weightsManifestSHA256
                telemetry["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
            }
        }
        return telemetry
    }
}

actor ProviderStatus {
    private let startedAt = Date()
    private var modelID: String?
    private var modelHash: String?
    private var modelHashAlgorithm: String?
    private var weightsManifestSHA256: String?
    private var modelLoaded: Bool
    private var capacity: ProviderCapacity
    private var status: ProviderHealthState
    private var requestsTotal = 0
    private var requestsToday = 0
    private var tokensTodayDayStart = Calendar.current.startOfDay(for: Date())
    private let statsStore: ProviderStatsStore?
    private let persistedProviderID: String?
    private var inputTokensToday: Int64 = 0
    private var outputTokensToday: Int64 = 0
    private var inputTokensAllTime: Int64 = 0
    private var outputTokensAllTime: Int64 = 0
    private var requestsInFlight = 0
    private var errorsTotal = 0
    private var restartCount = 0
    private var windowRequests = 0
    private var windowLatencyMS = 0.0
    private var windowCompletionTokens = 0
    private var windowGenerationSeconds = 0.0
    private var coordinatorConnected = false
    private var coordinatorAssignedID: String?
    private var coordinatorTier: String?
    private var coordinatorIdentityAdmissionMode: String?
    private var recommendedBinaryVersion: String?
    private var catalogCompatibilityConfirmed = false
    private var activeRequestIDs = Set<String>()
    private let thermalGate: ThermalGate?
    private let memoryPressureProvider: MemoryPressureProviding
    private let workloadTelemetryProvider: ProviderWorkloadTelemetryProviding
    private var lastActivityAt = Date()
    private var lastPrewarmAt: Date?
    private var lastPrewarmElapsedMS: Double?
    private var specDecodeEnabled: Bool
    private var specDecodeDraftModelID: String?
    private var specDecodeNumDraftTokens: Int?
    private var specDecodeWindowDraftedTokens = 0
    private var specDecodeWindowAcceptedTokens = 0
    private var specDecodeGeneration = 0
    private var transitionID = UUID().uuidString.lowercased()
    private var transitionAt = Date()
    private var transitionReason: String
    private var lastObservedThermalThrottle = false

    init(
        modelID: String?,
        modelLoaded: Bool,
        capacity: ProviderCapacity,
        modelHash: String? = nil,
        modelHashAlgorithm: String? = nil,
        weightsManifestSHA256: String? = nil,
        thermalGate: ThermalGate? = nil,
        memoryPressureProvider: MemoryPressureProviding = SystemMemoryPressureMonitor.shared,
        workloadTelemetryProvider: ProviderWorkloadTelemetryProviding = SystemProviderWorkloadTelemetryMonitor.shared,
        specDecodeDraftModelID: String? = nil,
        specDecodeNumDraftTokens: Int? = nil,
        providerID: String? = nil,
        statsStore: ProviderStatsStore? = nil
    ) {
        self.modelID = modelID
        self.modelHash = modelHash
        self.modelHashAlgorithm = modelHashAlgorithm
        self.weightsManifestSHA256 = weightsManifestSHA256
        self.modelLoaded = modelLoaded
        self.capacity = capacity
        self.status = modelLoaded ? .ready : .unavailable
        self.thermalGate = thermalGate
        self.memoryPressureProvider = memoryPressureProvider
        self.workloadTelemetryProvider = workloadTelemetryProvider
        self.specDecodeEnabled = modelLoaded && specDecodeDraftModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        self.specDecodeDraftModelID = Self.publicSpecDecodeDraftModelID(specDecodeDraftModelID)
        self.specDecodeNumDraftTokens = self.specDecodeEnabled ? specDecodeNumDraftTokens : nil
        self.transitionReason = modelLoaded ? "model_ready" : "model_not_loaded"
        let trimmedProviderID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedProviderID, !trimmedProviderID.isEmpty {
            persistedProviderID = trimmedProviderID
            self.statsStore = statsStore ?? ProviderStatsStore(providerID: trimmedProviderID)
            bootstrapPersistedStats()
        } else {
            persistedProviderID = nil
            self.statsStore = nil
        }
    }

    func beginRequest(requestID: String? = nil) -> Date {
        noteRealRequestStart()
        requestsInFlight += 1
        if let requestID {
            activeRequestIDs.insert(requestID)
        }
        refreshAvailabilityState()
        return Date()
    }

    /// Atomically fences new work once an operator pause or drain begins.
    /// Requests admitted before the transition remain counted and are drained;
    /// requests racing after it are rejected without entering the runtime.
    func beginRequestIfAccepting(requestID: String? = nil) -> Date? {
        guard status != .draining, status != .unavailable else { return nil }
        return beginRequest(requestID: requestID)
    }

    func finishRequest(startedAt: Date, completion: CompletionResult?, failed: Bool, requestID: String? = nil) {
        noteRealRequestEnd()
        requestsInFlight = max(0, requestsInFlight - 1)
        if let requestID {
            activeRequestIDs.remove(requestID)
        }
        rolloverDayCountersIfNeeded()
        requestsTotal += 1
        requestsToday += 1
        if failed {
            errorsTotal += 1
        }

        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        windowRequests += 1
        windowLatencyMS += elapsed * 1000.0
        if let completion {
            windowCompletionTokens += completion.completionTokens
            windowGenerationSeconds += elapsed
            if completion.specDecodeGeneration == specDecodeGeneration {
                specDecodeWindowDraftedTokens += completion.specDecodeDraftedTokens
                specDecodeWindowAcceptedTokens += completion.specDecodeAcceptedTokens
            }
            recordTokenUsage(
                promptTokens: completion.promptTokens,
                completionTokens: completion.completionTokens
            )
        }
        refreshAvailabilityState()
        persistStats()
    }

    func currentSpecDecodeGeneration() -> Int {
        specDecodeGeneration
    }

    func resetSpecDecodeWindow() {
        specDecodeWindowDraftedTokens = 0
        specDecodeWindowAcceptedTokens = 0
    }

    func setSpecDecodeConfig(draftModelID: String?, numDraftTokens: Int?) {
        specDecodeGeneration += 1
        let enabled = modelLoaded && draftModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        specDecodeEnabled = enabled
        specDecodeDraftModelID = enabled ? Self.publicSpecDecodeDraftModelID(draftModelID) : nil
        specDecodeNumDraftTokens = enabled ? numDraftTokens : nil
        resetSpecDecodeWindow()
    }

    func completeTargetSwap(
        modelID: String,
        modelHash: String?,
        modelHashAlgorithm: String? = nil,
        weightsManifestSHA256: String? = nil,
        specDecodeDraftModelID: String? = nil,
        specDecodeNumDraftTokens: Int? = nil
    ) {
        self.modelID = modelID
        self.modelHash = modelHash
        self.modelHashAlgorithm = modelHashAlgorithm
        self.weightsManifestSHA256 = weightsManifestSHA256
        modelLoaded = true
        if status == .unavailable {
            transition(to: .ready, reason: "target_swap_completed")
        }
        setSpecDecodeConfig(draftModelID: specDecodeDraftModelID, numDraftTokens: specDecodeNumDraftTokens)
        refreshAvailabilityState()
    }

    func recordError() {
        errorsTotal += 1
        persistStats()
    }

    func noteRealRequestStart() {
        lastActivityAt = Date()
    }

    func noteRealRequestEnd() {
        lastActivityAt = Date()
    }

    func secondsSinceLastRealActivity() -> Double {
        max(0, Date().timeIntervalSince(lastActivityAt))
    }

    func secondsSinceLastActivityOrPrewarm() -> Double {
        let now = Date()
        let secondsSinceActivity = max(0, now.timeIntervalSince(lastActivityAt))
        guard let lastPrewarmAt else { return secondsSinceActivity }
        return min(secondsSinceActivity, max(0, now.timeIntervalSince(lastPrewarmAt)))
    }

    func noteInternalPrewarm(at: Date = Date(), elapsedMS: Double) {
        lastPrewarmAt = at
        lastPrewarmElapsedMS = elapsedMS
    }

    func setState(_ newState: ProviderHealthState, reason: String = "state_update") {
        transition(to: newState, reason: reason)
    }

    func setCoordinatorSession(
        connected: Bool,
        assignedID: String? = nil,
        tier: String? = nil,
        identityAdmissionMode: String? = nil,
        recommendedBinaryVersion: String? = nil
    ) {
        coordinatorConnected = connected
        if !connected {
            catalogCompatibilityConfirmed = false
            coordinatorIdentityAdmissionMode = nil
        }
        if let assignedID {
            coordinatorAssignedID = assignedID
        }
        if let tier {
            coordinatorTier = tier
        }
        if let identityAdmissionMode {
            coordinatorIdentityAdmissionMode = identityAdmissionMode
        }
        if let recommendedBinaryVersion {
            self.recommendedBinaryVersion = recommendedBinaryVersion
        }
    }

    func setCatalogCompatibilityConfirmed(_ confirmed: Bool) {
        catalogCompatibilityConfirmed = confirmed
    }

    func snapshot(resetWindow: Bool = false) async -> ProviderSnapshot {
        rolloverDayCountersIfNeeded()
        // Resolve thermal state BEFORE reading any actor-isolated mutable
        // state. Actors are reentrant across `await`, so a `finishRequest`
        // running during the suspension could mutate `windowRequests` and
        // friends between read and reset.
        let throttled = await thermalGate?.isThrottled() ?? false
        let thermalState = await thermalGate?.currentState() ?? ProcessInfo.processInfo.thermalState
        let memoryPressure = memoryPressureProvider.currentMemoryPressure()
        let workload = workloadTelemetryProvider.currentWorkloadTelemetry()
        if throttled != lastObservedThermalThrottle {
            lastObservedThermalThrottle = throttled
            transitionID = UUID().uuidString.lowercased()
            transitionAt = Date()
            transitionReason = throttled ? "thermal_throttled" : "thermal_recovered"
        }
        let avgLatency = windowRequests > 0 ? windowLatencyMS / Double(windowRequests) : nil
        let throughput = windowGenerationSeconds > 0 ? Double(windowCompletionTokens) / windowGenerationSeconds : nil
        let specAcceptanceRate = specDecodeWindowDraftedTokens > 0
            ? Double(specDecodeWindowAcceptedTokens) / Double(specDecodeWindowDraftedTokens)
            : nil
        let effectiveStatus: ProviderHealthState = (throttled && (status == .ready || status == .busy)) ? .busy : status
        let snapshot = ProviderSnapshot(
            status: effectiveStatus,
            modelID: modelID,
            modelHash: modelHash,
            modelHashAlgorithm: modelHashAlgorithm,
            weightsManifestSHA256: weightsManifestSHA256,
            weightsManifestAlgorithm: weightsManifestSHA256 == nil
                ? nil
                : ModelArtifactIdentity.safetensorsManifestV1,
            modelLoaded: modelLoaded,
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
            requestsTotal: requestsTotal,
            requestsToday: requestsToday,
            inputTokensToday: inputTokensToday,
            outputTokensToday: outputTokensToday,
            inputTokensAllTime: inputTokensAllTime,
            outputTokensAllTime: outputTokensAllTime,
            requestsInFlight: requestsInFlight,
            requestsQueued: max(0, requestsInFlight - capacity.maxConcurrency),
            errorsTotal: errorsTotal,
            restartCount: restartCount,
            memoryRSSMB: Self.memoryRSSMB(),
            memoryPressure: memoryPressure,
            cpuUtilizationPercent: workload.cpuUtilizationPercent,
            gpuUtilizationPercent: workload.gpuUtilizationPercent,
            gpuUtilizationScope: workload.gpuUtilizationScope,
            powerSource: workload.powerSource,
            capacity: capacity,
            requestsServedSinceLast: windowRequests,
            avgLatencyMSSinceLast: avgLatency,
            throughputTPSSinceLast: throughput,
            coordinatorConnected: coordinatorConnected,
            coordinatorAssignedID: coordinatorAssignedID,
            coordinatorTier: coordinatorTier,
            coordinatorIdentityAdmissionMode: coordinatorIdentityAdmissionMode,
            recommendedBinaryVersion: recommendedBinaryVersion,
            catalogCompatibilityConfirmed: catalogCompatibilityConfirmed,
            activeRequestIDCount: activeRequestIDs.count,
            thermallyThrottled: throttled,
            thermalState: thermalState.label,
            lastActivityAt: lastActivityAt,
            lastPrewarmAt: lastPrewarmAt,
            specDecodeEnabled: specDecodeEnabled,
            specDecodeDraftModelID: specDecodeEnabled ? specDecodeDraftModelID : nil,
            specDecodeNumDraftTokens: specDecodeEnabled ? specDecodeNumDraftTokens : nil,
            specDecodeDraftedTokensSinceLast: specDecodeWindowDraftedTokens,
            specDecodeAcceptedTokensSinceLast: specDecodeWindowAcceptedTokens,
            specDecodeAcceptanceRate: specAcceptanceRate,
            specDecodeGeneration: specDecodeGeneration,
            transitionID: transitionID,
            transitionAt: transitionAt,
            transitionReason: transitionReason
        )
        if resetWindow {
            windowRequests = 0
            windowLatencyMS = 0
            windowCompletionTokens = 0
            windowGenerationSeconds = 0
            specDecodeWindowDraftedTokens = 0
            specDecodeWindowAcceptedTokens = 0
        }
        return snapshot
    }

    func waitUntilDrained(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutSeconds)))
        while requestsInFlight > 0 {
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private func refreshAvailabilityState() {
        guard modelLoaded, status == .ready || status == .busy else {
            return
        }
        transition(
            to: requestsInFlight >= capacity.maxConcurrency ? .busy : .ready,
            reason: requestsInFlight >= capacity.maxConcurrency ? "request_capacity_full" : "request_capacity_available"
        )
    }

    private func transition(to newState: ProviderHealthState, reason: String) {
        guard status != newState else { return }
        status = newState
        transitionID = UUID().uuidString.lowercased()
        transitionAt = Date()
        transitionReason = reason
    }

    private func rolloverDayCountersIfNeeded(now: Date = Date()) {
        let dayStart = Calendar.current.startOfDay(for: now)
        guard dayStart > tokensTodayDayStart else { return }
        tokensTodayDayStart = dayStart
        requestsToday = 0
        inputTokensToday = 0
        outputTokensToday = 0
    }

    private func recordTokenUsage(promptTokens: Int, completionTokens: Int) {
        rolloverDayCountersIfNeeded()
        let input = Int64(max(0, promptTokens))
        let output = Int64(max(0, completionTokens))
        inputTokensToday += input
        outputTokensToday += output
        inputTokensAllTime += input
        outputTokensAllTime += output
    }

    private static func memoryRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return max(0, Int(info.resident_size / 1_048_576))
    }

    static func publicSpecDecodeDraftModelID(_ modelID: String?) -> String? {
        guard let raw = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if isPublicHuggingFaceModelID(raw) {
            return raw
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return "local:\(prefix)"
    }

    private func bootstrapPersistedStats() {
        guard let statsStore, let persistedProviderID else { return }
        if let record = statsStore.load(), record.providerID == persistedProviderID {
            applyLoadedStats(record)
            restartCount = record.restartCount + 1
        } else {
            restartCount = 0
        }
        persistStats()
    }

    private func applyLoadedStats(_ record: ProviderStatsRecord) {
        requestsTotal = max(0, record.requestsTotal)
        requestsToday = max(0, record.requestsToday)
        tokensTodayDayStart = record.requestsTodayDayStart
        inputTokensToday = max(0, record.inputTokensToday)
        outputTokensToday = max(0, record.outputTokensToday)
        inputTokensAllTime = max(0, record.inputTokensAllTime)
        outputTokensAllTime = max(0, record.outputTokensAllTime)
        errorsTotal = max(0, record.errorsTotal)
        rolloverDayCountersIfNeeded()
    }

    private func persistStats(now: Date = Date()) {
        guard let statsStore, let persistedProviderID else { return }
        rolloverDayCountersIfNeeded(now: now)
        statsStore.save(
            ProviderStatsRecord(
                version: ProviderStatsRecord.currentVersion,
                providerID: persistedProviderID,
                requestsTotal: requestsTotal,
                requestsToday: requestsToday,
                requestsTodayDayStart: tokensTodayDayStart,
                inputTokensToday: inputTokensToday,
                outputTokensToday: outputTokensToday,
                inputTokensAllTime: inputTokensAllTime,
                outputTokensAllTime: outputTokensAllTime,
                errorsTotal: errorsTotal,
                restartCount: restartCount,
                updatedAt: now
            )
        )
    }

    private static func isPublicHuggingFaceModelID(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return false
        }
        let expanded = (value as NSString).expandingTildeInPath
        return !expanded.hasPrefix("/")
            && !expanded.hasPrefix(".")
            && !FileManager.default.fileExists(atPath: expanded)
    }
}
