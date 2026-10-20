import SwiftUI

/// Settings screen copy (SPEC-025-R008).
enum SettingsPresentation {
    static let startupTitle = String(localized: "Startup & Dock", comment: "Settings section")
    static let openAtLogin = String(localized: "Open Malibu at login", comment: "Settings login toggle")
    static let menuBarIcon = String(localized: "Show menu-bar icon", comment: "Settings menu-bar toggle")
    static let dockIcon = String(localized: "Keep Malibu in the Dock", comment: "Settings Dock toggle")
    static let appearanceNote = String(localized: "Malibu always keeps at least one shortcut visible. The provider service keeps running when the app window is closed.", comment: "Settings appearance note")
    static let preferenceSaveFailed = String(localized: "Malibu could not save these appearance and update preferences. Check that your Application Support folder is writable, then try again.", comment: "Settings preference persistence failure")
    static let loginFailed = String(localized: "macOS did not accept the login item change. Try again, or check System Settings › General › Login Items.", comment: "Settings login toggle failure")
    static let updatesTitle = String(localized: "Provider software", comment: "Settings section")
    static let updatesNote = String(localized: "Provider software updates are signed and installed automatically when the network recommends a version.", comment: "Settings updates note")
    static let updateChannel = String(localized: "Update channel", comment: "Settings update-channel label")
    static let stableChannelNote = String(localized: "Stable is the supported public update channel. Preview releases are not offered to providers.", comment: "Settings stable update channel note")
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
        strings.append(contentsOf: [startupTitle, openAtLogin, menuBarIcon, dockIcon, appearanceNote, updatesTitle, updateChannel, AppPreferences.UpdateChannel.stable.title, updatesNote, stableChannelNote])
        if let status = AgentSnapshotPresenter.cliUpdateStatusLine(s) { strings.append(status) }
        strings.append(aboutTitle)
        strings.append(contentsOf: aboutRows(s, appVersion: appVersion).map { "\($0.0): \($0.1)" })
        return strings
    }
}

struct SettingsScreen: View {
    @ObservedObject var agent: MalibuAgent
    @ObservedObject var preferences: AppPreferences = .shared
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
                    Toggle(SettingsPresentation.menuBarIcon, isOn: Binding(
                        get: { preferences.showsMenuBarIcon },
                        set: { preferences.setShowsMenuBarIcon($0) }
                    ))
                    Toggle(SettingsPresentation.dockIcon, isOn: Binding(
                        get: { preferences.keepsDockIcon },
                        set: { preferences.setKeepsDockIcon($0) }
                    ))
                    Text(SettingsPresentation.appearanceNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let loginError {
                        Text(loginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if preferences.persistenceFailed {
                        Text(SettingsPresentation.preferenceSaveFailed)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ShellPanel(SettingsPresentation.updatesTitle) {
                    Picker(SettingsPresentation.updateChannel, selection: Binding(
                        get: { preferences.updateChannel },
                        set: { preferences.setUpdateChannel($0) }
                    )) {
                        ForEach(AppPreferences.UpdateChannel.allCases) { channel in
                            Text(channel.title).tag(channel)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(SettingsPresentation.stableChannelNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
