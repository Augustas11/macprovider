import Darwin
import CryptoKit
import Foundation

enum ProviderHealthState: String, Sendable {
    case ready
    case busy
    case degraded
    case draining
    case unavailable
}

struct ProviderCapacity: Sendable {
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
    let modelLoaded: Bool
    let uptimeSeconds: Int
    let requestsTotal: Int
    let requestsInFlight: Int
    let requestsQueued: Int
    let errorsTotal: Int
    let memoryRSSMB: Int
    let capacity: ProviderCapacity
    let requestsServedSinceLast: Int
    let avgLatencyMSSinceLast: Double?
    let throughputTPSSinceLast: Double?
    let coordinatorConnected: Bool
    let coordinatorAssignedID: String?
    let coordinatorTier: String?
    let recommendedBinaryVersion: String?
    let activeRequestIDCount: Int
    let thermallyThrottled: Bool
    let lastActivityAt: Date
    let lastPrewarmAt: Date?
    let specDecodeEnabled: Bool
    let specDecodeDraftModelID: String?
    let specDecodeNumDraftTokens: Int?
    let specDecodeDraftedTokensSinceLast: Int
    let specDecodeAcceptedTokensSinceLast: Int
    let specDecodeAcceptanceRate: Double?
    let specDecodeGeneration: Int

    var slotsFree: Int {
        if thermallyThrottled { return 0 }
        return max(0, capacity.maxConcurrency - requestsInFlight)
    }

    var slotsTotal: Int {
        capacity.maxConcurrency
    }
}

actor ProviderStatus {
    private let startedAt = Date()
    private var modelID: String?
    private var modelHash: String?
    private var modelLoaded: Bool
    private var capacity: ProviderCapacity
    private var status: ProviderHealthState
    private var requestsTotal = 0
    private var requestsInFlight = 0
    private var requestsQueued = 0
    private var errorsTotal = 0
    private var windowRequests = 0
    private var windowLatencyMS = 0.0
    private var windowCompletionTokens = 0
    private var windowGenerationSeconds = 0.0
    private var coordinatorConnected = false
    private var coordinatorAssignedID: String?
    private var coordinatorTier: String?
    private var recommendedBinaryVersion: String?
    private var activeRequestIDs = Set<String>()
    private let thermalGate: ThermalGate?
    private var lastActivityAt = Date()
    private var lastPrewarmAt: Date?
    private var lastPrewarmElapsedMS: Double?
    private var specDecodeEnabled: Bool
    private var specDecodeDraftModelID: String?
    private var specDecodeNumDraftTokens: Int?
    private var specDecodeWindowDraftedTokens = 0
    private var specDecodeWindowAcceptedTokens = 0
    private var specDecodeGeneration = 0

    init(
        modelID: String?,
        modelLoaded: Bool,
        capacity: ProviderCapacity,
        modelHash: String? = nil,
        thermalGate: ThermalGate? = nil,
        specDecodeDraftModelID: String? = nil,
        specDecodeNumDraftTokens: Int? = nil
    ) {
        self.modelID = modelID
        self.modelHash = modelHash
        self.modelLoaded = modelLoaded
        self.capacity = capacity
        self.status = modelLoaded ? .ready : .unavailable
        self.thermalGate = thermalGate
        self.specDecodeEnabled = modelLoaded && specDecodeDraftModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        self.specDecodeDraftModelID = Self.publicSpecDecodeDraftModelID(specDecodeDraftModelID)
        self.specDecodeNumDraftTokens = self.specDecodeEnabled ? specDecodeNumDraftTokens : nil
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

    func finishRequest(startedAt: Date, completion: CompletionResult?, failed: Bool, requestID: String? = nil) {
        noteRealRequestEnd()
        requestsInFlight = max(0, requestsInFlight - 1)
        if let requestID {
            activeRequestIDs.remove(requestID)
        }
        requestsTotal += 1
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
        }
        refreshAvailabilityState()
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

    func completeTargetSwap(modelID: String, modelHash: String?) {
        self.modelID = modelID
        self.modelHash = modelHash
        modelLoaded = true
        if status == .unavailable {
            status = .ready
        }
        setSpecDecodeConfig(draftModelID: nil, numDraftTokens: nil)
        refreshAvailabilityState()
    }

    func recordError() {
        errorsTotal += 1
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

    func setState(_ newState: ProviderHealthState) {
        status = newState
    }

    func setCoordinatorSession(connected: Bool, assignedID: String? = nil, tier: String? = nil, recommendedBinaryVersion: String? = nil) {
        coordinatorConnected = connected
        if let assignedID {
            coordinatorAssignedID = assignedID
        }
        if let tier {
            coordinatorTier = tier
        }
        if let recommendedBinaryVersion {
            self.recommendedBinaryVersion = recommendedBinaryVersion
        }
    }

    func snapshot(resetWindow: Bool = false) async -> ProviderSnapshot {
        // Resolve thermal state BEFORE reading any actor-isolated mutable
        // state. Actors are reentrant across `await`, so a `finishRequest`
        // running during the suspension could mutate `windowRequests` and
        // friends between read and reset.
        let throttled = await thermalGate?.isThrottled() ?? false
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
            modelLoaded: modelLoaded,
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
            requestsTotal: requestsTotal,
            requestsInFlight: requestsInFlight,
            requestsQueued: requestsQueued,
            errorsTotal: errorsTotal,
            memoryRSSMB: Self.memoryRSSMB(),
            capacity: capacity,
            requestsServedSinceLast: windowRequests,
            avgLatencyMSSinceLast: avgLatency,
            throughputTPSSinceLast: throughput,
            coordinatorConnected: coordinatorConnected,
            coordinatorAssignedID: coordinatorAssignedID,
            coordinatorTier: coordinatorTier,
            recommendedBinaryVersion: recommendedBinaryVersion,
            activeRequestIDCount: activeRequestIDs.count,
            thermallyThrottled: throttled,
            lastActivityAt: lastActivityAt,
            lastPrewarmAt: lastPrewarmAt,
            specDecodeEnabled: specDecodeEnabled,
            specDecodeDraftModelID: specDecodeEnabled ? specDecodeDraftModelID : nil,
            specDecodeNumDraftTokens: specDecodeEnabled ? specDecodeNumDraftTokens : nil,
            specDecodeDraftedTokensSinceLast: specDecodeWindowDraftedTokens,
            specDecodeAcceptedTokensSinceLast: specDecodeWindowAcceptedTokens,
            specDecodeAcceptanceRate: specAcceptanceRate,
            specDecodeGeneration: specDecodeGeneration
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
        status = requestsInFlight >= capacity.maxConcurrency ? .busy : .ready
    }

    private static func memoryRSSMB() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0
        }
        return max(0, Int(usage.ru_maxrss / 1_048_576))
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
