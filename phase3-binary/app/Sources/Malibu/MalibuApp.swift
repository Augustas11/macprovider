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
        // AUDIT R1 ARCHITECT A4 fix: log both authorities' versions on startup so
        // support can tell a Sparkle-only update from a get.streamvc.live-only one.
        logStartupProvenance()

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
                    await self?.consume(event)
                }
            }
        }
    }

    // AUDIT R2 CODE H2 + R3 CODE M1 + R4 hardening: intercept every
    // termination (Quit menu, Cmd-Q, logout, killall by name) and route the
    // running child through the same shutdown drain as Quit-and-Uninstall.
    // Concurrent Quit + Uninstall orderings:
    //   A) Uninstall only            → performUninstall drives termination.
    //   B) Quit only                 → agent.shutdown, then reply.
    //   C) Uninstall then Quit       → await uninstallTask, then reply.
    //   D) Quit then Uninstall       → shutdown + await uninstallTask if it
    //                                  appears mid-flight.
    // In every ordering, cleanup completes before NSApp.reply.
    // AUDIT R4 CODE M1: any second/third termination request (double Cmd-Q,
    // logout on top of Quit menu, programmatic NSApp.terminate) MUST also
    // return .terminateLater. Returning .terminateNow on re-entry would
    // bypass the in-flight drain and truncate Keychain/config cleanup.
    // NSApp.reply(toApplicationShouldTerminate:) is idempotent — the first
    // drain's completion covers every waiting terminate request.
    private var terminationDrain: Task<Void, Never>?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationDrain == nil {
            terminationDrain = Task { @MainActor [weak self] in
                guard let self else { NSApp.reply(toApplicationShouldTerminate: true); return }
                // Always drain the CLI daemon first. shutdown() is idempotent —
                // if performUninstall already called it, isShuttingDown makes
                // this a no-op.
                await self.agent.shutdown(gracefulSeconds: 15)
                // If an uninstall was in-flight (or started concurrently), wait
                // for it to complete before signalling termination.
                if let uninstall = self.uninstallTask {
                    _ = await uninstall.value
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // MARK: - UI actions

    // AUDIT R3 CODE M1: uninstall runs in a tracked Task so a concurrent
    // Quit/Cmd-Q from applicationShouldTerminate does not exit the process
    // before Keychain/config cleanup finishes.
    private var uninstallTask: Task<Void, Never>?

    private func handle(_ action: MenuBarController.Action) {
        switch action {
        case .openDashboard: presentDashboard()
        case .openOnboarding: presentOnboarding()
        case .pause: Task { await agent.pause() }
        case .resume: Task { await agent.resume() }
        case .quitAndUninstall:
            guard uninstallTask == nil else { return }
            uninstallTask = Task { @MainActor [weak self] in
                await self?.performUninstall()
            }
        }
    }

    // AUDIT R1 SECURITY S1 / CODE H3 / ARCHITECT A3 fix: validate the pending
    // nonce and refuse if the app is already configured. Any invalid callback
    // is treated as an attack — surface an error, do not overwrite state.
    private func consume(_ event: URLSchemeHandler.Event) async {
        switch event {
        case let .providerLinked(state, providerID, token):
            let alreadyConfigured = await ProviderConfig.isConfigured
            do {
                try PendingLinkState.consume(state: state, appAlreadyConfigured: alreadyConfigured)
            } catch {
                await MainActor.run { self.presentLinkError(error) }
                return
            }
            do {
                try await ProviderConfig.saveProviderIdentity(providerID: providerID, token: token)
            } catch {
                await MainActor.run { self.presentLinkError(error) }
                return
            }
            await agent.start()
        }
    }

    private func presentLinkError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Link request rejected"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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

    // AUDIT R1 CODE M2 / SECURITY S3 / ARCHITECT A6 + R3 CODE M1 fix:
    // uninstall runs to completion (residue reporting included) BEFORE any
    // termination path resolves. If applicationShouldTerminate is already
    // awaiting `uninstallTask`, we let it drive termination; otherwise we
    // request termination ourselves.
    private func performUninstall() async {
        await agent.shutdown(gracefulSeconds: 30)
        let unregisterFailure = await AppLoginItem.unregisterReturningError()
        PendingLinkState.discard()
        let residue = await ProviderConfig.wipeAppOwnedState()

        if !residue.clean || unregisterFailure != nil {
            self.presentUninstallResidue(residue, loginItem: unregisterFailure)
        }

        if terminationDrain != nil {
            // applicationShouldTerminate is awaiting `uninstallTask.value`.
            // Returning from here completes the task; that side will call
            // NSApp.reply(toApplicationShouldTerminate: true).
            return
        }
        NSApp.terminate(nil)
    }

    private func presentUninstallResidue(_ residue: ProviderConfig.UninstallResidue,
                                         loginItem: Error?) {
        var bullets: [String] = []
        if let e = residue.configRemoveFailed { bullets.append("Config file: \(e.localizedDescription)") }
        if let e = residue.appSupportRemoveFailed { bullets.append("App Support: \(e.localizedDescription)") }
        if let e = residue.keychainDeleteFailed { bullets.append("Keychain: \(e.localizedDescription)") }
        if let e = loginItem { bullets.append("Login item: \(e.localizedDescription)") }
        let alert = NSAlert()
        alert.messageText = "Uninstall finished with residue"
        alert.informativeText = bullets.isEmpty
            ? "Cleanup reported success but is being surfaced defensively."
            : bullets.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func logStartupProvenance() {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        NSLog("[malibu] startup app_version=%@ build=%@ managed_by=malibu-app",
              appVersion, buildNumber)
    }
}
