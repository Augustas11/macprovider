import SwiftUI

@main
struct MalibuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let agent = MalibuAgent()
    private var menuBar: MenuBarController!
    private var onboardingWindow: NSWindow?
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(agent: agent) { [weak self] action in
            self?.handle(action)
        }

        Task { [agent] in
            if await ProviderConfig.isConfigured {
                await agent.start()
            } else {
                await MainActor.run { self.presentOnboarding() }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "malibu" {
            URLSchemeHandler.handle(url) { [weak self] event in
                Task { @MainActor in
                    self?.consume(event)
                }
            }
        }
    }

    // MARK: - UI actions

    private func handle(_ action: MenuBarController.Action) {
        switch action {
        case .openDashboard: presentDashboard()
        case .openOnboarding: presentOnboarding()
        case .pause: Task { await agent.pause() }
        case .resume: Task { await agent.resume() }
        case .quitAndUninstall: Task { await performUninstall() }
        }
    }

    private func consume(_ event: URLSchemeHandler.Event) {
        switch event {
        case let .providerLinked(providerID, token):
            Task {
                try? await ProviderConfig.saveProviderIdentity(providerID: providerID, token: token)
                await agent.start()
            }
        }
    }

    private func presentOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindow.make(agent: agent) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentDashboard() {
        if dashboardWindow == nil {
            dashboardWindow = DashboardWindow.make(agent: agent)
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func performUninstall() async {
        await agent.shutdown(gracefulSeconds: 30)
        await AppLoginItem.unregister()
        try? ProviderConfig.wipeAppOwnedState()
        NSApp.terminate(nil)
    }
}
