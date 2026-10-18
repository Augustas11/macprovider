import SwiftUI

/// Settings screen copy (SPEC-025-R008).
enum SettingsPresentation {
    static let startupTitle = String(localized: "Startup & Dock", comment: "Settings section")
    static let openAtLogin = String(localized: "Open Malibu at login", comment: "Settings login toggle")
    static let dockNote = String(localized: "Malibu shows in the Dock and Cmd-Tab while a Malibu window is open, and stays in the menu bar otherwise. The provider service keeps running either way.", comment: "Settings Dock note")
    static let loginFailed = String(localized: "macOS did not accept the login item change. Try again, or check System Settings › General › Login Items.", comment: "Settings login toggle failure")
    static let updatesTitle = String(localized: "Provider software", comment: "Settings section")
    static let updatesNote = String(localized: "Provider software updates are signed and installed automatically when the network recommends a version.", comment: "Settings updates note")
    static let invitesTitle = String(localized: "Invites", comment: "Settings section")
    static let aboutTitle = String(localized: "About", comment: "Settings section")

    static func aboutRows(_ s: AgentSnapshot, appVersion: String) -> [(String, String)] {
        [
            (String(localized: "Malibu app", comment: "Settings about row"), appVersion),
            (String(localized: "Provider software", comment: "Settings about row"), AgentSnapshotPresenter.compatibilitySetLine(s)),
        ]
    }

    @MainActor
    static func screenStrings(_ s: AgentSnapshot, appVersion: String) -> [String] {
        var strings = [
            String(localized: "Settings", comment: "Settings title"),
            "Payout wallet",
            PayoutWalletSettingsSection.coolingOffNotice,
        ]
        if s.localProviderID != nil { strings.append(invitesTitle) }
        strings.append(contentsOf: [startupTitle, openAtLogin, dockNote, updatesTitle, updatesNote])
        if let status = AgentSnapshotPresenter.cliUpdateStatusLine(s) { strings.append(status) }
        strings.append(aboutTitle)
        strings.append(contentsOf: aboutRows(s, appVersion: appVersion).map { "\($0.0): \($0.1)" })
        return strings
    }
}

struct SettingsScreen: View {
    @ObservedObject var agent: MalibuAgent
    @State private var openAtLogin = AppLoginItem.isRegistered
    @State private var loginError: String?
    @State private var loginChangeInFlight = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(MalibuSection.settings.title)
                    .font(.title2.weight(.semibold))

                ShellPanel {
                    PayoutWalletSettingsSection(agent: agent)
                }

                if agent.snapshot.localProviderID != nil {
                    ReferralPanel(agent: agent)
                }

                ShellPanel(SettingsPresentation.startupTitle) {
                    Toggle(SettingsPresentation.openAtLogin, isOn: Binding(
                        get: { openAtLogin },
                        set: { setOpenAtLogin($0) }
                    ))
                    // One change at a time, so a slow unregister cannot land
                    // after a newer register.
                    .disabled(loginChangeInFlight)
                    Text(SettingsPresentation.dockNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let loginError {
                        Text(loginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ShellPanel(SettingsPresentation.updatesTitle) {
                    Text(SettingsPresentation.updatesNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status = AgentSnapshotPresenter.cliUpdateStatusLine(agent.snapshot) {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(agent.snapshot.cliUpdateLastError == nil ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if AgentSnapshotPresenter.updateAvailable(agent.snapshot) {
                        Button(agent.snapshot.cliUpdateInProgress
                               ? String(localized: "Installing latest provider software…", comment: "Settings update in progress")
                               : String(localized: "Install latest provider software", comment: "Settings update action")) {
                            Task { await agent.updateCLINow() }
                        }
                        .disabled(agent.snapshot.cliUpdateInProgress || agent.snapshot.providerSoftwareRepairInProgress)
                    }
                }

                ModelSettingsView()

                ShellPanel(SettingsPresentation.aboutTitle) {
                    ForEach(SettingsPresentation.aboutRows(agent.snapshot, appVersion: DiagnosticsPresentation.appVersion), id: \.0) { row in
                        MetricRow(title: row.0, value: row.1)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { openAtLogin = AppLoginItem.isRegistered }
        .accessibilityIdentifier("malibu.settings")
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        guard !loginChangeInFlight else { return }
        loginError = nil
        if enabled {
            do {
                try AppLoginItem.register()
            } catch {
                loginError = SettingsPresentation.loginFailed
            }
            openAtLogin = AppLoginItem.isRegistered
        } else {
            loginChangeInFlight = true
            Task {
                if await AppLoginItem.unregisterReturningError() != nil {
                    loginError = SettingsPresentation.loginFailed
                }
                openAtLogin = AppLoginItem.isRegistered
                loginChangeInFlight = false
            }
        }
    }
}

/// The SwiftUI Settings scene's content. Settings live in the main window;
/// this opens them there and closes itself.
struct SettingsRedirectView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Text(String(localized: "Settings are in the Malibu window.", comment: "Settings scene redirect"))
            .padding(24)
            .onAppear {
                AppDelegate.current?.presentDashboard(section: .settings)
                dismiss()
            }
    }
}
