import Combine
@preconcurrency import Foundation

enum MalibuThermalState: String, Equatable {
    case nominal
    case fair
    case serious
    case critical

    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Throttled"
        }
    }

    var isMenuBarAttention: Bool {
        self == .serious || self == .critical
    }

    init(processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .fair
        }
    }
}

@MainActor
final class ThermalMonitor: ObservableObject {
    @Published private(set) var state: MalibuThermalState

    private let stateProvider: () -> ProcessInfo.ThermalState
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        stateProvider: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    ) {
        self.notificationCenter = notificationCenter
        self.stateProvider = stateProvider
        self.state = MalibuThermalState(processInfoState: stateProvider())
        observer = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    func refresh() {
        state = MalibuThermalState(processInfoState: stateProvider())
    }
}
