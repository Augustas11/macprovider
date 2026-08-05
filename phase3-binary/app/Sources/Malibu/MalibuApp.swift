import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        // Log both installed versions so support can identify a partially
        // completed compatibility-set transaction without reading the bundle.
        logStartupProvenance()

        menuBar = MenuBarController(agent: agent) { [weak self] action in
            self?.handle(action)
        }

        // Host-based unit tests launch the real AppDelegate. Do not let that
        // test host inspect, start, repair, or terminate the user's installed
        // provider while XCTest is still executing.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.handleStartup()
        }
    }

    // SPEC-026 §7.3: browser deep-link onboarding retired.
    // The application(_:open:) implementation has been removed in v0.11 impl
    // step 2. Any deep-link scheme SPEC-027 needs (verified-email flow) is
    // that spec's normative surface, not SPEC-026's.

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
                // Always detach Malibu's observers first. Option 2 keeps the
                // launchd provider running on ordinary app quit. shutdown() is
                // idempotent; if uninstall already detached, this is a no-op.
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
        case .checkForUpdates, .updateCLI: Task { await agent.updateCLINow() }
        case .exportDiagnostics: exportDiagnostics()
        case .quitAndUninstall:
            guard uninstallTask == nil else { return }
            guard confirmUninstall() else { return }
            uninstallTask = Task { @MainActor [weak self] in
                await self?.performUninstall()
            }
        }
    }

    private func confirmUninstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Uninstall Malibu and stop this provider?"
        alert.informativeText = "This removes the background provider, Malibu settings, and local provider setup. It preserves saved provider access so the same provider ownership can be recovered by reinstalling. Downloaded model caches are not removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit and Uninstall")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // SPEC-026 §7.3: consume(_:) / presentLinkError(_:) retired along with
    // the browser callback handler. Provider onboarding now happens
    // in-App via LaunchProviderController (SPEC-026 §7.2, follow-up impl
    // in this same PR).

    private func presentOnboarding(replacementConfirmed: Bool = false) {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindow.make(
                agent: agent,
                replacementConfirmed: replacementConfirmed
            ) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleStartup() async {
        let route = await StartupState.detect().route()
        await handleStartupRoute(route)
    }

    private func handleStartupRoute(
        _ route: StartupRoute,
        replacementConfirmed: Bool = false
    ) async {
        switch route {
        case .startAgent:
            await agent.start()
        case .showOnboarding:
            presentOnboarding(replacementConfirmed: replacementConfirmed)
        case .quit:
            NSApp.terminate(nil)
        case .showImportDialog:
            while true {
                let decision = presentMigrationDialog()
                if decision == .startFresh, !presentStartFreshConfirmation() {
                    continue
                }
                do {
                    let result = try await StartupState.applyMigrationDecision(
                        decision,
                        deferStartFreshBackup: decision == .startFresh
                    )
                    if let backupPath = result.backupPath {
                        presentStartFreshBackup(path: backupPath)
                    }
                    await handleStartupRoute(
                        result.route,
                        replacementConfirmed: decision == .startFresh
                    )
                    return
                } catch {
                    guard presentMigrationError(error) else {
                        NSApp.terminate(nil)
                        return
                    }
                }
            }
        }
    }

    private func presentMigrationDialog() -> MigrationDecision {
        let alert = NSAlert()
        alert.messageText = MigrationDialogCopy.title
        alert.informativeText = MigrationDialogCopy.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: MigrationDialogCopy.useExistingButton)
        alert.addButton(withTitle: MigrationDialogCopy.startFreshButton)
        alert.addButton(withTitle: MigrationDialogCopy.cancelButton)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .importExisting
        case .alertSecondButtonReturn: return .startFresh
        default: return .cancel
        }
    }

    private func presentStartFreshBackup(path: String) {
        let alert = NSAlert()
        alert.messageText = StartFreshBackupCopy.title
        alert.informativeText = StartFreshBackupCopy.message(path: path)
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func presentStartFreshConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = StartFreshConfirmationCopy.title
        alert.informativeText = StartFreshConfirmationCopy.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: StartFreshConfirmationCopy.cancelButton)
        alert.addButton(withTitle: StartFreshConfirmationCopy.startFreshButton)
        return StartFreshConfirmationCopy.confirms(alert.runModal())
    }

    private func presentMigrationError(_ error: Error) -> Bool {
        let alert = NSAlert()
        alert.messageText = MigrationErrorCopy.title
        alert.informativeText = MigrationErrorCopy.message(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: MigrationErrorCopy.cancelButton)
        alert.addButton(withTitle: MigrationErrorCopy.retryButton)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func presentDashboard() {
        if dashboardWindow == nil {
            dashboardWindow = DashboardWindow.make(
                agent: agent,
                onExportDiagnostics: { [weak self] in self?.exportDiagnostics() }
            )
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "malibu-diagnostics-\(formatter.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? "unknown"
            let data = try ProviderDiagnosticsBundle.make(
                snapshot: agent.snapshot,
                providerLogLines: agent.logLines,
                watchdogLogURL: ProviderPaths.current.watchdogLog,
                appVersion: appVersion
            )
            try data.write(to: destination, options: [.atomic])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export diagnostics"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // Uninstall runs to completion (residue reporting included) BEFORE any
    // termination path resolves. If applicationShouldTerminate is already
    // awaiting `uninstallTask`, we let it drive termination; otherwise we
    // request termination ourselves.
    private func performUninstall() async {
        await agent.shutdown(gracefulSeconds: 30)
        let cliTeardown = await CLIInstallTeardown.uninstallBackgroundProvider()
        let unregisterFailure = await AppLoginItem.unregisterReturningError()
        var residue = await ProviderConfig.wipeAppOwnedState()
        residue.cliUninstallWarnings = cliTeardown.warnings

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
        for warning in residue.cliUninstallWarnings {
            bullets.append("Background provider: \(warning)")
        }
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

enum MigrationDialogCopy {
    static let title = "Use your existing provider?"
    static let message = """
    Malibu found an existing provider on this Mac. Use Existing Provider keeps the same provider identity, payment history, saved access, and local model setup.

    Start Fresh creates a new provider. The new provider will not reuse the previous identity, payment history, saved access, or local model setup unless you restore the old setup.
    """
    static let useExistingButton = "Use Existing Provider"
    static let startFreshButton = "Start Fresh"
    static let cancelButton = "Cancel"
}

enum StartFreshBackupCopy {
    static let title = "Old provider setup moved aside"

    static func message(path: String) -> String {
        """
        Backup: \(path)

        Keep this backup if you may need the previous provider identity, payment history, saved access, or local model setup restored later.
        """
    }
}

enum StartFreshConfirmationCopy {
    static let title = "Create a new provider instead?"
    static let message = """
    Malibu will keep the existing setup unchanged until the new provider is ready.

    The new provider will have a different identity and will not include the previous payment history, saved access, or local model setup unless you restore the old setup.
    """
    static let cancelButton = "Keep Existing Provider"
    static let startFreshButton = "Create New Provider"

    static func confirms(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }
}

enum MigrationErrorCopy {
    static let title = "Could not use existing provider"
    static let cancelButton = "Cancel"
    static let retryButton = "Try Again"

    static func message(_ error: Error) -> String {
        let reason: String
        if let handoffError = error as? ProviderCredentialHandoffRunner.Error {
            reason = publicHandoffReason(handoffError)
        } else {
            reason = AgentSnapshotPresenter.publicErrorDetail(error.localizedDescription)
                ?? "Technical details are available in Advanced diagnostics."
        }
        return "\(reason)\n\nYour current setup was not changed."
    }

    private static func publicHandoffReason(_ error: ProviderCredentialHandoffRunner.Error) -> String {
        switch error {
        case .cliNotFound, .invalidCLI, .importFailed, .freshProcessVerificationFailed,
             .statusFailed, .repairFailed, .admissionRecoveryFailed, .timedOut:
            return error.localizedDescription
        case .invalidOutput:
            return "The installed provider returned an incompatible import result. Update the provider and retry."
        case .launchFailed:
            return "Could not start provider import. Update the provider and retry."
        }
    }
}
