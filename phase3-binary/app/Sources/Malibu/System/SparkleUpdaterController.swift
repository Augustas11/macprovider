import AppKit
import Combine
import Sparkle

/// Owns Sparkle whole-bundle updates for Malibu.app (SPEC-025 §3.3, §12).
@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    @Published private(set) var updateAvailable = false

    private let agentProvider: () -> MalibuAgent?
    private lazy var standardController: SPUStandardUpdaterController = {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = 86_400
        return controller
    }()

    init(agentProvider: @escaping () -> MalibuAgent?) {
        self.agentProvider = agentProvider
        super.init()
        _ = standardController
    }

    var canCheckForUpdates: Bool {
        standardController.updater.canCheckForUpdates
    }

    func checkForUpdates(_ sender: Any?) {
        standardController.checkForUpdates(sender)
    }

    private func shutdownProviderBeforeUpdate() async {
        await agentProvider()?.shutdown(gracefulSeconds: 15)
    }
}

extension SparkleUpdaterController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.updateAvailable = true
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateAvailable = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in
            await self.shutdownProviderBeforeUpdate()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor in
            await self.shutdownProviderBeforeUpdate()
            immediateInstallHandler()
        }
        return true
    }
}
