import AppKit
import SwiftUI

enum DashboardCopy {
    static let earningsTitle = "Earnings (USDC)"
    static let malibuTitle = "MALIBU (beta points)"
    static let macHealthTitle = "This Mac"
    static let yourModelTitle = "Your model"
    static let changeWalletInSettings = "Change the payout wallet in Settings."
    static let resetProviderTitle = "Reset provider service"
    static let exportDiagnosticsTitle = "Export diagnostics…"
    static let recoveryHelpTitle = "If something is stuck"
    static let resetProviderConfirmTitle = "Reset the provider service on this Mac?"
    static let resetProviderConfirmDetail = "Repairs the background service and keeps your provider identity and downloaded models. Use this if setup is stuck or the provider will not start."
    static let resetProviderConfirmButton = "Reset provider service"
    static let resetProviderCancelButton = "Cancel"
    static let openModels = String(localized: "Models", comment: "Dashboard link to the Models section")
    static let compareInDiscover = String(localized: "Browse models", comment: "Dashboard link to the Discover section")
    static let openDiagnostics = String(localized: "Diagnostics", comment: "Dashboard link to the Diagnostics section")
    static let invitesNudge = String(localized: "You have provider invites to share.", comment: "Dashboard invite nudge")
    static let openInvites = String(localized: "Invites in Settings", comment: "Dashboard link to Settings invites")

    static func modelRowStatusLine(
        currentModelID: String?,
        listState: ModelManagementStore.ListState,
        warmSwapAvailable: Bool = true
    ) -> String {
        guard currentModelID != nil else {
            switch listState {
            case .checking:
                return String(localized: "Checking current model…", comment: "Dashboard model loading status")
            case .unavailable:
                return String(localized: "Current model is not available from provider status.", comment: "Dashboard model missing status")
            case .ready, .viewOnly:
                return String(localized: "No current model reported.", comment: "Dashboard no current model")
            }
        }
        switch listState {
        case .checking:
            return String(localized: "Serving this model. Checking whether switching is available…", comment: "Dashboard model checking switch")
        case .ready, .viewOnly:
            return warmSwapAvailable
                ? String(localized: "Serving this model. Switching is available.", comment: "Dashboard model ready to switch")
                : String(localized: "Serving this model. Switching is off until warm swap is running.", comment: "Dashboard model view-only")
        case .unavailable:
            return String(localized: "Serving this model. Switching is unavailable right now; open Models to retry.", comment: "Dashboard model switch unavailable")
        }
    }

    /// Whether the dashboard shows the status notice (meaning, next action
    /// and recovery) under the header. A serving Mac shows only the pill.
    static func showsStatusNotice(_ snapshot: AgentSnapshot) -> Bool {
        AgentSnapshotPresenter.statusPill(snapshot).label != "Serving"
    }

    /// Reset and Export appear on the main surface only in an error state;
    /// otherwise they live in Diagnostics.
    static func showsRecoveryOnMainSurface(_ snapshot: AgentSnapshot) -> Bool {
        snapshot.state == .error
    }

    /// The invite nudge appears only while a current invite link can be copied.
    static func showsInviteNudge(_ snapshot: AgentSnapshot) -> Bool {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.referralAvailability == .available,
              let status = snapshot.referralStatus,
              status.isCurrent() else { return false }
        return status.availableInviteURL != nil
    }

    /// The "Your model" card: the served model, its catalog rate and demand
    /// when trusted, and whether switching is available. No $/time figures
    /// (SPEC-044-R004).
    static func yourModelLines(
        currentModelID: String?,
        listState: ModelManagementStore.ListState,
        warmSwapAvailable: Bool = true,
        rows: [MalibuModelRow]
    ) -> [String] {
        var lines: [String] = [
            currentModelID.map { ShellText.display($0) }
                ?? String(localized: "No model reported", comment: "Dashboard model absent"),
            modelRowStatusLine(currentModelID: currentModelID, listState: listState, warmSwapAvailable: warmSwapAvailable),
        ]
        if let current = rows.first(where: { $0.category == .current }),
           let summary = ModelsPresentation.rateAndDemand(current, allRows: rows) {
            lines.append(summary)
            lines.append(ModelsPresentation.rateDisclosure)
        }
        return lines
    }

    /// Every string the default dashboard shows, in order. Used by tests and
    /// by the text render in the PR evidence.
    static func defaultPublicStrings(
        _ snapshot: AgentSnapshot,
        listState: ModelManagementStore.ListState = .checking,
        rows: [MalibuModelRow] = [],
        now: Date = Date()
    ) -> [String] {
        let pill = AgentSnapshotPresenter.statusPill(snapshot)
        let status = AgentSnapshotPresenter.consolidatedStatus(snapshot)
        let card = AgentSnapshotPresenter.earningsCard(snapshot, now: now)
        var strings = ["Earn"]
        if let subtitle = AgentSnapshotPresenter.dashboardSubtitle(snapshot, now: now) { strings.append(subtitle) }
        strings.append(pill.label)
        if showsStatusNotice(snapshot) {
            strings.append(status.meaning)
            if let action = status.nextAction { strings.append(action) }
        }
        strings.append(earningsTitle)
        strings.append(card.usdcSummary)
        if let payout = card.payoutLine { strings.append(payout) }
        if let address = snapshot.payoutRegisteredAddress {
            strings.append("Payout wallet \(PayoutWalletFlow.truncateAddress(address))")
        }
        strings.append(malibuTitle)
        strings.append(contentsOf: card.malibuLines)
        if let trust = card.trustLine { strings.append(trust) }
        if let blocker = card.hardwareBlocker { strings.append(blocker) }
        strings.append(yourModelTitle)
        strings.append(contentsOf: yourModelLines(
            currentModelID: snapshot.currentModelID,
            listState: listState,
            rows: rows
        ))
        if let health = AgentSnapshotPresenter.macHealthLine(snapshot) {
            strings.append(macHealthTitle)
            strings.append(health)
        }
        if showsInviteNudge(snapshot) { strings.append(invitesNudge) }
        return strings
    }
}

/// Dashboard section of the main window: the Phase 1 status pill and
/// Earnings card, the served model, Mac health and, in an error state, the
/// single recovery action (SPEC-025-R003).
struct DashboardView: View {
    @ObservedObject var agent: MalibuAgent
    let navigate: (MalibuSection) -> Void
    let onExportDiagnostics: () -> Void
    let onResetProvider: () -> Void
    var browseModels: (() -> Void)? = nil
    var onThisMacModels: (() -> Void)? = nil
    var includesProviderDetails = false
    @State var providerDetailsExpanded = false
    @State private var showAddWalletSheet = false
    @State private var rewardActivityExpanded = false
    @ObservedObject private var modelStore = ModelManagementStore.shared

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            header

            if DashboardCopy.showsStatusNotice(agent.snapshot) {
                statusNotice
            }

            earningsPanel

            HStack(alignment: .top, spacing: 16) {
                yourModelPanel
                macHealthPanel
            }

            if let recommendation = modelStore.recommendation,
               recommendation.isRecommendationResult,
               recommendation.isActionable,
               let target = recommendation.displayModelID {
                ShellPanel(String(localized: "Tip", comment: "Dashboard tip title")) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(localized: "Recommended for this Mac: \(target)", comment: "Dashboard recommendation tip"))
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button(DashboardCopy.compareInDiscover) { (browseModels ?? { navigate(.models) })() }
                    }
                }
            }

            if DashboardCopy.showsInviteNudge(agent.snapshot) {
                HStack {
                    Text(DashboardCopy.invitesNudge)
                        .font(.callout)
                    Spacer()
                    Button(DashboardCopy.openInvites) { navigate(.settings) }
                }
                .padding(.horizontal, 4)
            }
            if includesProviderDetails {
                DisclosureGroup("Provider details", isExpanded: $providerDetailsExpanded) {
                    ProviderDetailsContent(agent: agent, navigate: navigate)
                }
                .accessibilityIdentifier("malibu.earn.provider-details")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .accessibilityIdentifier("malibu.dashboard.scroll")
        .sheet(isPresented: $showAddWalletSheet) {
            AddWalletSheet(agent: agent, isPresented: $showAddWalletSheet)
        }
        .task(id: agent.rewardAuditSupported) {
            if agent.rewardAuditSupported,
               agent.rewardActivityEvents.isEmpty,
               !agent.rewardActivityLoading {
                await agent.loadRewardActivity()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MalibuSection.earn.title)
                    .font(.title2.weight(.semibold))
                if let subtitle = AgentSnapshotPresenter.dashboardSubtitle(agent.snapshot) {
                    Text(ShellText.display(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            StatusPillView(pill: AgentSnapshotPresenter.statusPill(agent.snapshot))
            if includesProviderDetails { ProviderPauseControl(agent: agent) }
        }
    }

    private var statusNotice: some View {
        let status = AgentSnapshotPresenter.consolidatedStatus(agent.snapshot)
        return VStack(alignment: .leading, spacing: 8) {
            Text(status.meaning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let action = status.nextAction {
                Text(action)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            primaryActionButton
            if DashboardCopy.showsRecoveryOnMainSurface(agent.snapshot) {
                RecoveryActions(onExportDiagnostics: onExportDiagnostics, onResetProvider: onResetProvider)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(panelBackground)
        .accessibilityElement(children: .contain)
    }

    private var yourModelPanel: some View {
        let current = agent.snapshot.currentModelID
        let lines = DashboardCopy.yourModelLines(
            currentModelID: current,
            listState: modelStore.listState,
            warmSwapAvailable: modelStore.warmSwapAvailable,
            rows: modelStore.rows
        )
        return ShellPanel(DashboardCopy.yourModelTitle) {
            Text(lines[0])
                .font(.body.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel(Text(String(localized: "Current provider model", comment: "Dashboard model accessibility label")))
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(DashboardCopy.openModels) { (onThisMacModels ?? { navigate(.models) })() }
                    .accessibilityIdentifier("malibu.dashboard.open-models")
                Button(DashboardCopy.compareInDiscover) { (browseModels ?? { navigate(.models) })() }
                    .accessibilityIdentifier("malibu.dashboard.open-discover")
            }
        }
        .accessibilityIdentifier("malibu.dashboard.your-model")
    }

    private var macHealthPanel: some View {
        ShellPanel(DashboardCopy.macHealthTitle) {
            Text(AgentSnapshotPresenter.macHealthLine(agent.snapshot)
                 ?? String(localized: "Health appears while the provider runs.", comment: "Dashboard Mac health absent"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(DashboardCopy.openDiagnostics) { navigate(.diagnostics) }
                .accessibilityIdentifier("malibu.dashboard.open-diagnostics")
        }
        .accessibilityIdentifier("malibu.dashboard.mac-health")
    }

    private var earningsPanel: some View {
        let card = AgentSnapshotPresenter.earningsCard(agent.snapshot)
        return VStack(alignment: .leading, spacing: 10) {
            Text(DashboardCopy.earningsTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(card.usdcSummary)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let payout = card.payoutLine {
                Text(payout)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            walletRow
            Divider()
            Text(DashboardCopy.malibuTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(card.malibuLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let trust = card.trustLine {
                Text(trust)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("malibu.dashboard.trust-progress")
            }
            if let blocker = card.hardwareBlocker {
                VStack(alignment: .leading, spacing: 6) {
                    Text(blocker)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(DashboardCopy.exportDiagnosticsTitle) { onExportDiagnostics() }
                }
            }
            RewardActivityPanel(
                agent: agent,
                isExpanded: $rewardActivityExpanded
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(panelBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("malibu.dashboard.earnings")
    }

    @ViewBuilder
    private var walletRow: some View {
        if let address = agent.snapshot.payoutRegisteredAddress {
            Text("Payout wallet \(PayoutWalletFlow.truncateAddress(address))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(DashboardCopy.changeWalletInSettings)
            if let pending = agent.snapshot.payoutPendingUntilUTC,
               let end = PayoutWalletSettingsSection.parseUTC(pending),
               end > Date() {
                Text("Cooling off until \(end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button(agent.snapshot.payoutRegistrationInProgress ? "Registering wallet…" : "Add wallet") {
                showAddWalletSheet = true
            }
            .disabled(agent.snapshot.payoutRegistrationInProgress || agent.snapshot.localProviderID == nil)
        }
        if let error = agent.snapshot.payoutLastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        let status = AgentSnapshotPresenter.publicStatus(agent.snapshot)
        switch status.executableAction {
        case .retryHardwareVerification:
            VStack(alignment: .leading, spacing: 6) {
                Button(agent.snapshot.hardwareVerificationRetryInProgress
                       ? "Retrying provider setup..."
                       : "Retry provider setup while online") {
                    Task { await agent.retryHardwareVerification() }
                }
                .disabled(agent.snapshot.hardwareVerificationRetryInProgress)
                if let error = agent.snapshot.hardwareVerificationRetryLastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .updateProviderSoftware:
            if AgentSnapshotPresenter.updateAvailable(agent.snapshot) {
                Button(agent.snapshot.cliUpdateInProgress ? "Installing latest provider software…" : "Install latest provider software") {
                    Task { await agent.updateCLINow() }
                }
                .disabled(agent.snapshot.cliUpdateInProgress || agent.snapshot.providerSoftwareRepairInProgress)
            }
        case .repairProviderSoftware:
            Button(agent.snapshot.providerSoftwareRepairInProgress ? "Repairing provider software…" : "Repair provider software") {
                Task { await agent.repairProviderSoftware() }
            }
            .disabled(agent.snapshot.providerSoftwareRepairInProgress || agent.snapshot.cliUpdateInProgress)
        case .repairCredential:
            Button("Repair saved access") {
                Task { await agent.repairProviderCredential() }
            }
        case .repairAdmissionIdentity:
            Button(AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(agent.snapshot)) {
                Task { await agent.repairAdmissionIdentity() }
            }
        case .exportDiagnostics:
            Button(DashboardCopy.exportDiagnosticsTitle) {
                onExportDiagnostics()
            }
        case nil:
            EmptyView()
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.gray.opacity(0.18), lineWidth: 1)
            )
    }
}

/// Reset and Export, shared by the Dashboard error state and Diagnostics.
struct RecoveryActions: View {
    let onExportDiagnostics: () -> Void
    let onResetProvider: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DashboardCopy.recoveryHelpTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(DashboardCopy.resetProviderTitle) { onResetProvider() }
        Button(DashboardCopy.exportDiagnosticsTitle) { onExportDiagnostics() }
    }
}

enum PayoutRegistrationPresentation {
    static func isCancellable(inProgress: Bool, canCancel: Bool) -> Bool {
        !inProgress || canCancel
    }
}

private struct RewardActivityPanel: View {
    @ObservedObject var agent: MalibuAgent
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Reward activity", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if agent.rewardActivityLoading && agent.rewardActivityEvents.isEmpty {
                    ProgressView("Loading reward activity…")
                        .controlSize(.small)
                }

                if !agent.rewardActivityEvents.isEmpty {
                    ForEach(agent.rewardActivityEvents) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(RewardActivityPresentation.title(for: event))
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(RewardActivityPresentation.timeText(for: event))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(RewardActivityPresentation.detailLines(for: event), id: \.self) { line in
                                Text(line)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else if !agent.rewardActivityLoading, !agent.rewardAuditSupported {
                    Text("Reward activity is available after the provider software updates.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !agent.rewardActivityLoading, agent.rewardActivityError == nil {
                    Text("No reward activity has been reported yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let error = agent.rewardActivityError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry reward activity") {
                        Task { await agent.loadRewardActivity() }
                    }
                    .disabled(agent.rewardActivityLoading || !agent.rewardAuditSupported)
                    .accessibilityIdentifier("malibu.dashboard.reward-activity.retry")
                    .accessibilityHint("Retries the read-only reward activity request.")
                }

                HStack(spacing: 8) {
                    Button(agent.rewardActivityEvents.isEmpty ? "Refresh reward activity" : "Refresh") {
                        Task { await agent.loadRewardActivity() }
                    }
                    .disabled(agent.rewardActivityLoading || !agent.rewardAuditSupported)
                    .accessibilityIdentifier("malibu.dashboard.reward-activity.refresh")
                    .accessibilityHint("Refreshes read-only reward activity without changing balances or payout settings.")

                    if agent.rewardActivityNextBeforeID != nil {
                        Button("Load older activity") {
                            Task { await agent.loadRewardActivity(loadOlder: true) }
                        }
                        .disabled(agent.rewardActivityLoading || !agent.rewardAuditSupported)
                        .accessibilityIdentifier("malibu.dashboard.reward-activity.load-older")
                        .accessibilityHint("Loads an older page of read-only reward activity.")
                    }
                    if agent.rewardActivityLoading, !agent.rewardActivityEvents.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading reward activity")
                    }
                }
                .font(.caption)
            }
            .padding(.top, 4)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reward activity")
    }
}

struct AddWalletSheet: View {
    @ObservedObject var agent: MalibuAgent
    @Binding var isPresented: Bool
    @State private var pasteAddress = ""
    @State private var pasteSignature = ""
    @State private var pasteNonce = ""
    @State private var pasteTsUtc = ""
    @State private var showPaste = false
    @State private var localError: String?
    @State private var registrationTask: Task<Void, Never>?

    private var registrationIsCancellable: Bool {
        // Before the agent's task gets its first MainActor turn, inProgress is
        // still false. Treat that scheduling window as cancellable too. Once
        // registration crosses the remote commit boundary, inProgress stays
        // true while canCancel flips false and this correctly becomes Close.
        PayoutRegistrationPresentation.isCancellable(
            inProgress: agent.snapshot.payoutRegistrationInProgress,
            canCancel: agent.snapshot.payoutRegistrationCanCancel
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add payout wallet")
                .font(.title3.weight(.semibold))
            Text("Non-custodial: Malibu never sees your private key. You sign in your own browser wallet (MetaMask, Rabby, or any WalletConnect-compatible wallet). The connected account becomes your payout address.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Payouts stay off by default. This only registers the address; it does not send funds.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if agent.snapshot.payoutRegistrationInProgress {
                ProgressView(agent.snapshot.payoutRegistrationCanCancel
                    ? "Waiting for browser wallet signature…"
                    : "Registering payout wallet…")
                    .controlSize(.small)
            }

            HStack(spacing: 10) {
                Button("Open browser wallet") {
                    localError = nil
                    startRegistration()
                }
                .disabled(agent.snapshot.payoutRegistrationInProgress || registrationTask != nil)
                .keyboardShortcut(.defaultAction)

                Button(registrationIsCancellable ? "Cancel" : "Close") {
                    if registrationIsCancellable {
                        registrationTask?.cancel()
                    }
                    registrationTask = nil
                    isPresented = false
                }
            }

            DisclosureGroup("Paste signature instead", isExpanded: $showPaste) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If the browser cannot reach Malibu, paste the address and signature from the signer page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0x… address", text: $pasteAddress)
                        .textFieldStyle(.roundedBorder)
                    TextField("0x… signature (130 hex)", text: $pasteSignature)
                        .textFieldStyle(.roundedBorder)
                    TextField("0x… nonce (64 hex)", text: $pasteNonce)
                        .textFieldStyle(.roundedBorder)
                    TextField("ts_utc (unix seconds)", text: $pasteTsUtc)
                        .textFieldStyle(.roundedBorder)
                    Button("Submit pasted signature") {
                        guard let ts = UInt64(pasteTsUtc.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            localError = "ts_utc must be a unix-seconds integer."
                            return
                        }
                        localError = nil
                        let payload = PayoutSignedPayload(
                            address: pasteAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                            nonce: pasteNonce.trimmingCharacters(in: .whitespacesAndNewlines),
                            tsUtc: ts,
                            signature: pasteSignature.trimmingCharacters(in: .whitespacesAndNewlines),
                            state: "paste"
                        )
                        startRegistration(pasted: payload)
                    }
                    .disabled(
                        agent.snapshot.payoutRegistrationInProgress
                            || registrationTask != nil
                            || pasteAddress.isEmpty
                            || pasteSignature.isEmpty
                            || pasteNonce.isEmpty
                            || pasteTsUtc.isEmpty
                    )
                }
                .padding(.top, 6)
            }

            if let error = localError ?? agent.snapshot.payoutLastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear {
            if registrationIsCancellable {
                registrationTask?.cancel()
            }
            registrationTask = nil
        }
    }

    private func startRegistration(pasted: PayoutSignedPayload? = nil) {
        guard registrationTask == nil else { return }
        registrationTask = Task {
            await agent.registerPayoutWallet(pasted: pasted)
            guard !Task.isCancelled else { return }
            registrationTask = nil
            if agent.snapshot.payoutLastError == nil,
               agent.snapshot.payoutRegisteredAddress != nil {
                isPresented = false
            }
        }
    }
}

struct ReferralPanel: View {
    @ObservedObject var agent: MalibuAgent
    @State private var postURL = ""

    private var status: ReferralStatusProjection? { agent.snapshot.referralStatus }
    private var availability: ReferralAvailability {
        guard agent.snapshot.hasTrustedReferralBoundary() else { return .unsupported }
        if agent.snapshot.referralAvailability == .available,
           agent.snapshot.referralStatus?.isCurrent() != true {
            return .unavailable
        }
        return agent.snapshot.referralAvailability
    }

    /// An unlocked balance renders as one summary line; other states keep
    /// their headline and explanation.
    private var summaryStatus: ReferralStatusProjection? {
        guard availability == .available, let status, status.joinLinksEnabled,
              status.socialState != ReferralStatusProjection.locked,
              status.socialState != ReferralStatusProjection.revoked else { return nil }
        return status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Invite providers")
                        .font(.headline)
                    if ReferralPanelPresenter.showsPathChrome(status) {
                        Text(ReferralPanelPresenter.pathChrome)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let summaryStatus {
                        Text(ReferralPanelPresenter.summary(summaryStatus))
                            .font(.callout)
                    } else {
                        Text(ReferralPanelPresenter.headline(availability: availability, status: status))
                            .font(.callout.weight(.semibold))
                        Text(ReferralPanelPresenter.detail(availability: availability, status: status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if agent.snapshot.referralActionInProgress {
                    ProgressView().controlSize(.small)
                }
            }

            if availability == .available, let status {
                HStack(spacing: 8) {
                    Button("Copy private invite") {
                        guard status.isCurrent(), let invite = status.availableInviteURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.absoluteString, forType: .string)
                    }
                    .disabled(!status.isCurrent() || status.availableInviteURL == nil)
                    .help(status.isCurrent() && status.availableInviteURL != nil
                          ? "Copies your private invite link."
                          : ReferralPanelPresenter.copyInviteDisabledHelp)

                    if status.canStartSocialChallenge,
                       agent.snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
                       (status.socialState != ReferralStatusProjection.matured
                        || (agent.snapshot.localStatusCapabilities.contains("referral_repeatable_advocacy_v1")
                            && (status.socialBonusGrantsRemaining ?? 0) > 0)) {
                        Button("Share on X for \(ReferralPanelPresenter.invitePhrase(status.configuredBonusCapacity))") {
                            Task { await agent.startReferralChallenge() }
                        }
                        .disabled(agent.snapshot.referralActionInProgress)
                    }
                }

                if let challenge = status.pendingChallenge {
                    Divider()
                    Text(challenge.expiresAt > Date()
                         ? "Paste the public x.com post URL before \(challenge.expiresAt.formatted(date: .omitted, time: .shortened))."
                         : "This X verification link expired. Start over to create a new one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Reopen X composer") {
                            Task { await agent.reopenReferralChallenge() }
                        }
                        .disabled(challenge.expiresAt <= Date() || agent.snapshot.referralActionInProgress)
                        Button("Start over") {
                            Task { await agent.cancelReferralChallenge() }
                        }
                        .disabled(agent.snapshot.referralActionInProgress)
                    }
                    HStack(spacing: 8) {
                        TextField("https://x.com/you/status/…", text: $postURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Submit for verification") {
                            let submitted = postURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await agent.verifyReferralPost(submitted) }
                        }
                        .disabled(
                            postURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || challenge.expiresAt <= Date()
                                || agent.snapshot.referralActionInProgress
                        )
                    }
                }
            }

            if let error = AgentSnapshotPresenter.publicErrorDetail(agent.snapshot.referralLastError) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.gray.opacity(0.18), lineWidth: 1)
                )
        )
        .task(id: agent.snapshot.localProviderID) {
            guard agent.snapshot.hasTrustedReferralBoundary() else { return }
            await agent.refreshReferralStatus()
        }
    }
}

struct MetricChip: View {
    enum Tone { case neutral, attention }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch tone {
        case .neutral: return Color.gray.opacity(0.12)
        case .attention: return MalibuBrand.sunnyYellow.opacity(0.24)
        }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return .primary
        case .attention: return .primary
        }
    }
}
