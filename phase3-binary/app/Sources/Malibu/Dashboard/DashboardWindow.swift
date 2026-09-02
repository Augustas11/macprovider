import AppKit
import SwiftUI

@MainActor
enum DashboardWindow {
    static func make(
        agent: MalibuAgent,
        onExportDiagnostics: @escaping () -> Void,
        onResetProvider: @escaping () -> Void
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: DashboardView(
            agent: agent,
            onExportDiagnostics: onExportDiagnostics,
            onResetProvider: onResetProvider
        ))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Malibu"
        window.contentMinSize = NSSize(width: 640, height: 520)
        window.setContentSize(NSSize(width: 780, height: 740))
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}

enum DashboardCopy {
    static let currentStateTitle = "Current state"
    static let meaningTitle = "What this means"
    static let nextActionTitle = "Next safe action"
    static let miningHealthTitle = "Mining Health"
    static let miningReasonTitle = "Reason"
    static let miningRewardsTitle = "Rewards"
    static let miningEligibilityTitle = "Eligibility"
    static let resetProviderTitle = "Reset provider service"
    static let exportDiagnosticsTitle = "Export diagnostics…"
    static let recoveryHelpTitle = "If something is stuck"
    static let resetProviderConfirmTitle = "Reset the provider service on this Mac?"
    static let resetProviderConfirmDetail = "Repairs the background service and keeps your provider identity and downloaded models. Use this if setup is stuck or the provider will not start."
    static let resetProviderConfirmButton = "Reset provider service"
    static let resetProviderCancelButton = "Cancel"

    static func modelRowStatusLine(
        currentModelID: String?,
        listState: ModelManagementStore.ListState
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
            return String(localized: "Serving this model. Checking whether switching is available.", comment: "Dashboard model checking switch")
        case .ready:
            return String(localized: "Serving this model. Change Model lists other options.", comment: "Dashboard model ready to switch")
        case .viewOnly:
            return String(localized: "Serving this model. Live switching is off until warm swap is running.", comment: "Dashboard model view-only")
        case .unavailable:
            return String(localized: "Serving this model. Open Change Model to see why switching is unavailable.", comment: "Dashboard model switch unavailable")
        }
    }

    static func defaultPublicStrings(_ snapshot: AgentSnapshot) -> [String] {
        let status = AgentSnapshotPresenter.consolidatedStatus(snapshot)
        let mining = AgentSnapshotPresenter.miningHealth(snapshot)
        return [
            currentStateTitle,
            status.label,
            meaningTitle,
            status.meaning,
            nextActionTitle,
            status.nextAction,
            miningHealthTitle,
            mining.status,
            miningReasonTitle,
            mining.reason,
            miningRewardsTitle,
            mining.rewardSummary,
            miningEligibilityTitle,
            mining.trustSummary,
            mining.nextAction,
        ].compactMap { $0 }
    }

    static func advancedDiagnosticsStrings(_ snapshot: AgentSnapshot, logLines: [String]) -> [String] {
        var strings = ["Advanced diagnostics"]
        strings.append(contentsOf: AgentSnapshotPresenter.diagnosticFindingLines(snapshot))
        strings.append(contentsOf: logLines.map(LogTailBuffer.redacted))
        strings.append(AgentSnapshotPresenter.modelLine(snapshot))
        strings.append(AgentSnapshotPresenter.compatibilitySetLine(snapshot))
        return strings
    }
}

private struct DashboardView: View {
    @ObservedObject var agent: MalibuAgent
    let onExportDiagnostics: () -> Void
    let onResetProvider: () -> Void
    @State private var showAddWalletSheet = false
    @State private var showModelSheet = false
    @ObservedObject private var modelStore = ModelManagementStore.shared

    @State private var advancedDiagnosticsExpanded = true

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MalibuBrandTile()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Malibu")
                        .font(.system(size: 15, weight: .semibold))
                    if let subtitle = AgentSnapshotPresenter.dashboardSubtitle(agent.snapshot) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                let status = AgentSnapshotPresenter.consolidatedStatus(agent.snapshot)
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: status.tone))
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "Model", comment: "Dashboard model row label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(modelStore.currentModelID
                         ?? agent.snapshot.currentModelID
                         ?? String(localized: "Checking…", comment: "Dashboard model loading state"))
                        .font(.body.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityLabel(Text(String(localized: "Current provider model", comment: "Dashboard model accessibility label")))
                    Text(DashboardCopy.modelRowStatusLine(
                        currentModelID: modelStore.currentModelID ?? agent.snapshot.currentModelID,
                        listState: modelStore.listState
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                AppKitActionButton(
                    title: String(localized: "Change Model…", comment: "Dashboard model action"),
                    accessibilityIdentifier: "malibu.dashboard.change-model",
                    action: { showModelSheet = true }
                )
                .fixedSize()
                .accessibilityHint(Text(String(localized: "Opens the model switcher and shows provider guards before any action.", comment: "Dashboard model action hint")))
                Button {
                    SettingsWindowPresenter.shared.present()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Settings", comment: "Dashboard settings help"))
                .accessibilityIdentifier("malibu.dashboard.settings")
                .accessibilityLabel(Text(String(localized: "Settings", comment: "Dashboard settings action")))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))

            if let recommendation = modelStore.recommendation {
                VStack(alignment: .leading, spacing: 7) {
                    Text(recommendation.isRecommendationResult
                        ? String(localized: "Recommended installed model", comment: "Dashboard recommendation title")
                        : String(localized: "No installed model recommendation", comment: "Dashboard no recommendation title"))
                        .font(.caption.weight(.semibold))
                    if let target = recommendation.displayModelID {
                        Text(target)
                            .font(.body.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if let rationale = recommendation.displayRationale {
                        Text(rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recommendation.displayEvidenceLines, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(localized: "Scope: signed catalog \(recommendation.inputs.candidateCatalogVersion) for \(recommendation.hardware.chip), \(recommendation.hardware.memoryGB) GB.", comment: "Recommendation evidence scope"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let prompt = recommendation.promptRateUSDPerMillionTokens,
                       let completion = recommendation.completionRateUSDPerMillionTokens {
                        Text(String(localized: "Estimated rates: prompt $\(prompt, format: .number.precision(.fractionLength(2...4))) / 1M; completion $\(completion, format: .number.precision(.fractionLength(2...4))) / 1M.", comment: "Recommendation estimated rates"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !recommendation.warnings.isEmpty {
                        Text(String(localized: "Warnings: \(recommendation.warnings.joined(separator: ", "))", comment: "Recommendation warnings"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let unavailableReason = modelStore.recommendationAdoptionUnavailableReason {
                        Text(unavailableReason)
                            .font(.caption2)
                            .foregroundStyle(recommendation.isActionable ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if recommendation.isRecommendationResult {
                            Button(String(localized: "Adopt", comment: "Dashboard recommendation action")) {
                                Task { await modelStore.adoptRecommendation() }
                            }
                            .disabled(!modelStore.canAdoptRecommendation)
                            Button(String(localized: "Not now", comment: "Dashboard recommendation snooze")) {
                                modelStore.snoozeRecommendation()
                            }
                        }
                        Button(String(localized: "Stop background recommendations", comment: "Dashboard recommendation opt-out")) {
                            modelStore.stopBackgroundRecommendations()
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.09)))
                .accessibilityElement(children: .contain)
            }

            miningHealthPanel

            HStack(alignment: .top, spacing: 16) {
                panel {
                    let rewardVerdict = AgentSnapshotPresenter.rewardVerdict(agent.snapshot)
                    Text(AgentSnapshotPresenter.usdcPeriodLabel(agent.snapshot, verdict: rewardVerdict))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AgentSnapshotPresenter.usdcTodayDisplay(agent.snapshot, verdict: rewardVerdict))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(AgentSnapshotPresenter.usdcFullLine(agent.snapshot, verdict: rewardVerdict))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    if let caption = AgentSnapshotPresenter.usdcAccrualCaption(agent.snapshot, verdict: rewardVerdict) {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(AgentSnapshotPresenter.malibuFullLine(agent.snapshot, verdict: rewardVerdict))
                        .foregroundStyle(
                            AgentSnapshotPresenter.malibuRewardTextColorIsLocked(rewardVerdict)
                                ? MalibuBrand.coral
                                : .secondary
                        )
                        .font(.callout)
                    if let availability = AgentSnapshotPresenter.malibuAvailabilityLine(agent.snapshot, verdict: rewardVerdict) {
                        Text(availability)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let hold = AgentSnapshotPresenter.malibuHoldLine(agent.snapshot, verdict: rewardVerdict) {
                        Text(hold)
                            .font(.caption)
                            .foregroundStyle(MalibuBrand.coral)
                    }
                    if let backlog = AgentSnapshotPresenter.backlogLine(agent.snapshot, verdict: rewardVerdict) {
                        Text(backlog)
                            .font(.caption)
                            .foregroundStyle(MalibuBrand.coral)
                    }
                    if let eligibility = AgentSnapshotPresenter.eligibilityLine(agent.snapshot, verdict: rewardVerdict) {
                        Text(eligibility)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let address = agent.snapshot.payoutRegisteredAddress {
                        Text("Payout wallet \(PayoutWalletFlow.truncateAddress(address))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let pending = agent.snapshot.payoutPendingUntilUTC,
                           let end = Self.parseUTC(pending),
                           end > Date() {
                            Text("Cooling off until \(end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(agent.snapshot.payoutRegistrationInProgress
                           ? (agent.snapshot.payoutRegistrationCanCancel
                              ? "Waiting for wallet…"
                              : "Registering wallet…")
                           : (agent.snapshot.payoutRegisteredAddress == nil ? "Add wallet" : "Change wallet")) {
                        showAddWalletSheet = true
                    }
                    .disabled(agent.snapshot.payoutRegistrationInProgress
                              || agent.snapshot.localProviderID == nil)
                    if let error = agent.snapshot.payoutLastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let status = agent.snapshot.payoutLastStatus {
                        Text(status == "rotated" ? "Wallet rotated." : "Wallet registered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                statsPanel {
                    let status = AgentSnapshotPresenter.consolidatedStatus(agent.snapshot)
                    MetricRow(title: DashboardCopy.currentStateTitle, value: status.label)
                    MetricRow(title: DashboardCopy.meaningTitle, value: status.meaning)
                    if let action = status.nextAction {
                        MetricRow(title: DashboardCopy.nextActionTitle, value: action)
                    }
                    primaryActionButton
                    recoveryActions
                    DisclosureGroup("Advanced diagnostics", isExpanded: $advancedDiagnosticsExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            MetricRow(title: "Running model", value: AgentSnapshotPresenter.modelLine(agent.snapshot))
                            if let path = agent.snapshot.weightsPath {
                                DisclosureGroup("Weights path") {
                                    Text(path)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            } else if agent.snapshot.state == .serving || agent.snapshot.state == .paused {
                                MetricRow(title: "Weights path", value: "Managed by provider")
                            }
                            MetricRow(title: "Trust tier", value: AgentSnapshotPresenter.trustLine(agent.snapshot))
                            MetricRow(
                                title: "Malibu app",
                                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Version unknown"
                            )
                            MetricRow(title: "Provider software", value: AgentSnapshotPresenter.compatibilitySetLine(agent.snapshot))
                            MetricRow(title: "Customer capacity", value: AgentSnapshotPresenter.advertisedCapacityLine(agent.snapshot))
                            if let lifecycle = AgentSnapshotPresenter.lifecycleLine(agent.snapshot) {
                                MetricRow(title: "Provider status", value: lifecycle)
                            }
                            if let event = agent.snapshot.lifecycleLastRestart {
                                MetricRow(
                                    title: "Last restart",
                                    value: AgentSnapshotPresenter.lifecycleEventDisplay(event)
                                )
                            } else {
                                MetricRow(title: "Last restart", value: "Not recorded this session")
                            }
                            if let event = agent.snapshot.lifecycleLastRejection {
                                MetricRow(
                                    title: "Last setup failure",
                                    value: AgentSnapshotPresenter.lifecycleEventDisplay(event)
                                )
                            } else {
                                MetricRow(title: "Last setup failure", value: "None recorded")
                            }
                            if let event = agent.snapshot.lifecycleLastUpdate {
                                MetricRow(
                                    title: "Last update",
                                    value: AgentSnapshotPresenter.lifecycleEventDisplay(event)
                                )
                            }
                            if let event = agent.snapshot.lifecycleLastWatchdog {
                                MetricRow(
                                    title: "Last provider recovery",
                                    value: AgentSnapshotPresenter.lifecycleEventDisplay(event)
                                )
                            }
                            MetricRow(title: "Provider access", value: AgentSnapshotPresenter.credentialLine(agent.snapshot))
                            MetricRow(title: "Network verification", value: AgentSnapshotPresenter.admissionIdentityLine(agent.snapshot))
                            if agent.snapshot.credentialRepairInProgress
                                || agent.snapshot.admissionIdentityRecoveryInProgress {
                                ProgressView("Repairing provider...")
                                    .controlSize(.small)
                            }
                            if let error = agent.snapshot.credentialRepairLastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if let instruction = agent.snapshot.admissionIdentityRecoveryApprovalInstruction {
                                Text(instruction)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let request = agent.snapshot.admissionIdentityRecoveryOperatorRequest {
                                Text(request)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let error = agent.snapshot.admissionIdentityRecoveryLastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if let status = AgentSnapshotPresenter.cliUpdateStatusLine(agent.snapshot) {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(
                                        agent.snapshot.cliUpdateLastError == nil
                                            && agent.snapshot.providerSoftwareRepairLastError == nil
                                            ? Color.secondary
                                            : Color.red
                                    )
                            }
                            ForEach(
                                Array(AgentSnapshotPresenter.diagnosticFindingLines(agent.snapshot).enumerated()),
                                id: \.offset
                            ) { _, line in
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            if !agent.logLines.isEmpty {
                                LogTailView(lines: agent.logLines)
                                    .frame(minHeight: 120, maxHeight: 180)
                            }
                            MetricRow(title: "Requests", value: AgentSnapshotPresenter.requestsLine(agent.snapshot))
                            MetricRow(title: "Tokens", value: AgentSnapshotPresenter.tokenLine(agent.snapshot))
                            MetricRow(title: "Current run", value: AgentSnapshotPresenter.uptimeLine(agent.snapshot))
                            HStack(spacing: 8) {
                                MetricChip(text: AgentSnapshotPresenter.queueChip(agent.snapshot), tone: queueTone)
                                MetricChip(text: AgentSnapshotPresenter.thermalChip(agent.snapshot), tone: thermalTone)
                                MetricChip(text: AgentSnapshotPresenter.gpuChip(agent.snapshot), tone: .neutral)
                                MetricChip(text: AgentSnapshotPresenter.latencyChip(agent.snapshot), tone: .neutral)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("malibu.dashboard.advanced-diagnostics")
                }
            }

            if agent.snapshot.localProviderID != nil {
                ReferralPanel(agent: agent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .accessibilityIdentifier("malibu.dashboard.scroll")
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .sheet(isPresented: $showAddWalletSheet) {
            AddWalletSheet(agent: agent, isPresented: $showAddWalletSheet)
        }
        .sheet(isPresented: $showModelSheet) {
            ModelSwitcherSheet(store: modelStore, agent: agent, isPresented: $showModelSheet)
        }
        .task(id: "\(agent.snapshot.localProviderID ?? "unknown"):\(agent.snapshot.statusObservationID ?? "unknown")") {
            if agent.snapshot.localProviderID != nil {
                await agent.refreshPayoutRegistration()
            }
            await modelStore.refresh(
                currentModelID: agent.snapshot.currentModelID,
                peer: MalibuModelPeerEvidence(snapshot: agent.snapshot)
            )
            await modelStore.startBackgroundCheckIfEligible(thermalState: agent.snapshot.thermalState)
        }
    }

    private var miningHealthPanel: some View {
        let rewardVerdict = AgentSnapshotPresenter.rewardVerdict(agent.snapshot)
        let mining = AgentSnapshotPresenter.miningHealth(agent.snapshot, verdict: rewardVerdict)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(DashboardCopy.miningHealthTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(mining.status)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(miningTone(mining.reasonCode))
                    .accessibilityIdentifier("malibu.dashboard.mining-status")
            }
            VStack(alignment: .leading, spacing: 8) {
                MetricRow(title: DashboardCopy.miningReasonTitle, value: mining.reason)
                MetricRow(title: DashboardCopy.miningRewardsTitle, value: mining.rewardSummary)
                MetricRow(title: DashboardCopy.miningEligibilityTitle, value: mining.trustSummary)
                MetricRow(title: DashboardCopy.nextActionTitle, value: mining.nextAction)
            }
        }
        .padding(12)
        .background(panelBackground)
        .accessibilityElement(children: .contain)
    }

    private func miningTone(_ reasonCode: String) -> Color {
        switch reasonCode {
        case "earning", "trusted_withdrawable":
            return .green
        case "idle_no_work", "eligible_waiting_settlement", "customer_availability_pending":
            return .secondary
        case "not_running", "provider_paused", "reward_projection_unavailable":
            return MalibuBrand.sunnyYellow
        default:
            return MalibuBrand.coral
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

    @ViewBuilder
    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DashboardCopy.recoveryHelpTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button(DashboardCopy.resetProviderTitle) {
                        onResetProvider()
                    }
                    Button(DashboardCopy.exportDiagnosticsTitle) {
                        onExportDiagnostics()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button(DashboardCopy.resetProviderTitle) {
                        onResetProvider()
                    }
                    Button(DashboardCopy.exportDiagnosticsTitle) {
                        onExportDiagnostics()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .padding(16)
        .background(panelBackground)
    }

    @ViewBuilder
    private func statsPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .padding(16)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(MalibuBrand.coral.opacity(0.25), lineWidth: 1)
            )
    }

    private var queueTone: MetricChip.Tone {
        (agent.snapshot.queueDepth ?? 0) > 0 ? .attention : .neutral
    }

    private var thermalTone: MetricChip.Tone {
        switch agent.snapshot.thermalState {
        case .serious, .critical: return .attention
        default: return .neutral
        }
    }

    private func color(for state: AgentSnapshot.State) -> Color {
        switch state {
        case .serving: return .green
        case .starting, .reconnecting: return MalibuBrand.coral
        case .paused: return MalibuBrand.sunnyYellow
        case .error: return .red
        case .idle: return .secondary
        }
    }

    private func color(for tone: AgentSnapshotPresenter.ConsolidatedStatus.Tone) -> Color {
        switch tone {
        case .positive: return .green
        case .neutral: return .secondary
        case .attention: return MalibuBrand.coral
        }
    }

    private static func parseUTC(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

enum PayoutRegistrationPresentation {
    static func isCancellable(inProgress: Bool, canCancel: Bool) -> Bool {
        !inProgress || canCancel
    }
}

private struct AddWalletSheet: View {
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

private struct ReferralPanel: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Invite providers")
                        .font(.headline)
                    Text(ReferralPanelPresenter.pathChrome)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ReferralPanelPresenter.headline(availability: availability, status: status))
                        .font(.callout.weight(.semibold))
                    Text(ReferralPanelPresenter.detail(availability: availability, status: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if agent.snapshot.referralActionInProgress {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") {
                    Task { await agent.refreshReferralStatus() }
                }
                .disabled(!agent.snapshot.hasTrustedReferralBoundary() || agent.snapshot.referralActionInProgress)
            }

            if availability == .available, let status {
                Text(ReferralPanelPresenter.capacity(status))
                    .font(.caption.monospacedDigit())

                HStack(spacing: 8) {
                    Button("Copy private invite") {
                        guard status.isCurrent(), let invite = status.availableInviteURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.absoluteString, forType: .string)
                    }
                    .disabled(!status.isCurrent() || status.availableInviteURL == nil)

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
                        .strokeBorder(MalibuBrand.coral.opacity(0.25), lineWidth: 1)
                )
        )
        .task(id: agent.snapshot.localProviderID) {
            guard agent.snapshot.hasTrustedReferralBoundary() else { return }
            await agent.refreshReferralStatus()
        }
    }
}

private struct AppKitActionButton: NSViewRepresentable {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.run))
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func run() {
            action()
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct MetricChip: View {
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

private struct LogTailView: NSViewRepresentable {
    let lines: [String]

    func makeNSView(context: Context) -> NSScrollView {
        let text = NSTextView()
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        scroll.borderType = .lineBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let text = nsView.documentView as? NSTextView else { return }
        let shouldStickToBottom = isNearBottom(nsView)
        let next = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        if text.string != next {
            text.string = next
            if shouldStickToBottom {
                text.scrollToEndOfDocument(nil)
            }
        }
    }

    private func isNearBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= document.bounds.height - 24
    }
}
