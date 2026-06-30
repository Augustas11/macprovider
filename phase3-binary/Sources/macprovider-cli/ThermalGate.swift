import Foundation

protocol ThermalStateProviding: Sendable {
    func currentThermalState() -> ProcessInfo.ThermalState
}

struct SystemThermalStateProvider: ThermalStateProviding {
    func currentThermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}

/// Gates `ProviderStatus.slotsFree` to zero when macOS reports `.serious` or
/// `.critical` thermal pressure. In-flight requests are intentionally NOT
/// drained — throttling affects future admissions only (the coordinator's
/// router naturally migrates new buyer traffic off a `slots_free=0` provider).
actor ThermalGate {
    private let stateProvider: ThermalStateProviding
    private var current: ProcessInfo.ThermalState
    private var observer: NSObjectProtocol?
    private var transitionLogger: (@Sendable (ProcessInfo.ThermalState, ProcessInfo.ThermalState) -> Void)?

    init(stateProvider: ThermalStateProviding = SystemThermalStateProvider()) {
        self.stateProvider = stateProvider
        self.current = stateProvider.currentThermalState()
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }
    }

    func setTransitionLogger(_ handler: @escaping @Sendable (ProcessInfo.ThermalState, ProcessInfo.ThermalState) -> Void) {
        transitionLogger = handler
    }

    func currentState() -> ProcessInfo.ThermalState { current }

    func isThrottled() -> Bool { Self.shouldThrottle(current) }

    /// Test seam: drive a transition without an NSNotification.
    func inject(state: ProcessInfo.ThermalState) {
        applyTransition(to: state)
    }

    private func refresh() {
        applyTransition(to: stateProvider.currentThermalState())
    }

    private func applyTransition(to newState: ProcessInfo.ThermalState) {
        let old = current
        guard old != newState else { return }
        current = newState
        transitionLogger?(old, newState)
    }

    static func shouldThrottle(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
