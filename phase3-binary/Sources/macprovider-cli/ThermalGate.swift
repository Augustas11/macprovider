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
    nonisolated private let stateProvider: ThermalStateProviding
    nonisolated private let isThrottledSuspensionHook: (@Sendable () async -> Void)?
    private var current: ProcessInfo.ThermalState
    private var observer: NSObjectProtocol?
    private var drainTask: Task<Void, Never>?
    private var transitionLogger: (@Sendable (ProcessInfo.ThermalState, ProcessInfo.ThermalState) -> Void)?

    /// `isThrottledSuspensionHook` is a test-only seam: `isThrottled()` awaits
    /// it before reading state, so a test can hold a caller parked inside the
    /// thermal await and deterministically drive another `ProviderStatus`
    /// entry during that suspension (snapshot reentrancy coverage). A sleep
    /// here would make the interleaving depend on executor scheduling.
    init(stateProvider: ThermalStateProviding = SystemThermalStateProvider(),
         isThrottledSuspensionHook: (@Sendable () async -> Void)? = nil) {
        self.stateProvider = stateProvider
        self.isThrottledSuspensionHook = isThrottledSuspensionHook
        self.current = stateProvider.currentThermalState()
    }

    /// Captures the thermal state at notification edge and feeds captured
    /// states through a single ordered drain task. This guarantees we don't
    /// drop intermediate states (e.g. `.nominal → .serious → .fair` in quick
    /// succession): each notification yields the edge-captured state into a
    /// FIFO `AsyncStream`, and a single drain task awaits them in order.
    func startObserving() {
        guard observer == nil else { return }
        var capturedContinuation: AsyncStream<ProcessInfo.ThermalState>.Continuation!
        let stream = AsyncStream<ProcessInfo.ThermalState> { continuation in
            capturedContinuation = continuation
        }
        let provider = stateProvider
        let continuation = capturedContinuation!
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            continuation.yield(provider.currentThermalState())
        }
        drainTask = Task { [weak self] in
            for await state in stream {
                await self?.applyTransition(to: state)
            }
        }
        // Reconcile any transition that happened between `init`'s initial
        // read and observer registration — apply synchronously on the actor
        // so callers awaiting startObserving see the reconciled state via
        // `isThrottled()` / next snapshot, without racing the drain task.
        // The observer is already registered above, so any real notification
        // firing during this window is queued in the stream and processed
        // idempotently (the `old != new` guard makes a duplicate yield a
        // no-op).
        applyTransition(to: provider.currentThermalState())
    }

    func setTransitionLogger(_ handler: @escaping @Sendable (ProcessInfo.ThermalState, ProcessInfo.ThermalState) -> Void) {
        transitionLogger = handler
    }

    func currentState() -> ProcessInfo.ThermalState { current }

    func isThrottled() async -> Bool {
        if let isThrottledSuspensionHook {
            await isThrottledSuspensionHook()
        }
        return Self.shouldThrottle(current)
    }

    /// Test seam: drive a transition without an NSNotification.
    func inject(state: ProcessInfo.ThermalState) {
        applyTransition(to: state)
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
