import AppKit
import SwiftUI

@MainActor
enum DashboardWindow {
    static func make(
        agent: MalibuAgent,
        onExportDiagnostics: @escaping () -> Void
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: DashboardView(
            agent: agent,
            onExportDiagnostics: onExportDiagnostics
        ))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Malibu"
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

    static func defaultPublicStrings(_ snapshot: AgentSnapshot) -> [String] {
        let publicStatus = AgentSnapshotPresenter.publicStatus(snapshot)
        return [
            currentStateTitle,
            publicStatus.title,
            meaningTitle,
            publicStatus.detail,
            nextActionTitle,
            publicStatus.safeNextAction,
        ].compactMap { $0 }
    }

    static func advancedDiagnosticsStrings(_ snapshot: AgentSnapshot, logLines: [String]) -> [String] {
        var strings = ["Advanced diagnostics"]
        strings.append(contentsOf: logLines.map(LogTailBuffer.redacted))
        strings.append(AgentSnapshotPresenter.modelLine(snapshot))
        strings.append(AgentSnapshotPresenter.compatibilitySetLine(snapshot))
        return strings
    }
}

private struct DashboardView: View {
    @ObservedObject var agent: MalibuAgent
    let onExportDiagnostics: () -> Void
    @State private var showAddWalletSheet = false

    var body: some View {
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
                Text(AgentSnapshotPresenter.dashboardHeadline(agent.snapshot))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: agent.snapshot.state))
            }

            HStack(alignment: .top, spacing: 16) {
                panel {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(AgentSnapshotPresenter.usdcTodayDisplay(agent.snapshot))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text(AgentSnapshotPresenter.usdcFullLine(agent.snapshot))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Text(AgentSnapshotPresenter.malibuFullLine(agent.snapshot))
                        .foregroundStyle(agent.snapshot.trustTier == .provisional ? MalibuBrand.coral : .secondary)
                        .font(.callout)
                    if let backlog = AgentSnapshotPresenter.backlogLine(agent.snapshot) {
                        Text(backlog)
                            .font(.caption)
                            .foregroundStyle(MalibuBrand.coral)
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
                           ? "Waiting for wallet…"
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
                    let publicStatus = AgentSnapshotPresenter.publicStatus(agent.snapshot)
                    MetricRow(title: DashboardCopy.currentStateTitle, value: publicStatus.title)
                    if let detail = publicStatus.detail {
                        MetricRow(title: DashboardCopy.meaningTitle, value: detail)
                    }
                    if let action = publicStatus.safeNextAction {
                        MetricRow(title: DashboardCopy.nextActionTitle, value: action)
                    }
                    primaryActionButton
                    DisclosureGroup("Advanced diagnostics") {
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
                                MetricRow(title: "Last restart", value: AgentSnapshotPresenter.lifecycleEventLine(event))
                            }
                            if let event = agent.snapshot.lifecycleLastRejection {
                                MetricRow(title: "Last rejection", value: AgentSnapshotPresenter.lifecycleEventLine(event))
                            }
                            if let event = agent.snapshot.lifecycleLastUpdate {
                                MetricRow(title: "Last update", value: AgentSnapshotPresenter.lifecycleEventLine(event))
                            }
                            if let event = agent.snapshot.lifecycleLastWatchdog {
                                MetricRow(title: "Last provider recovery", value: AgentSnapshotPresenter.lifecycleEventLine(event))
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
                                    .foregroundStyle(agent.snapshot.cliUpdateLastError == nil ? Color.secondary : Color.red)
                            }
                            if !agent.logLines.isEmpty {
                                LogTailView(lines: agent.logLines)
                                    .frame(minHeight: 120, maxHeight: 180)
                            }
                            Button("Export redacted diagnostics...") {
                                onExportDiagnostics()
                            }
                            MetricRow(title: "Requests", value: AgentSnapshotPresenter.requestsLine(agent.snapshot))
                            MetricRow(title: "Tokens", value: AgentSnapshotPresenter.tokenLine(agent.snapshot))
                            MetricRow(title: "Uptime", value: AgentSnapshotPresenter.uptimeLine(agent.snapshot))
                            HStack(spacing: 8) {
                                MetricChip(text: AgentSnapshotPresenter.queueChip(agent.snapshot), tone: queueTone)
                                MetricChip(text: AgentSnapshotPresenter.thermalChip(agent.snapshot), tone: thermalTone)
                                MetricChip(text: AgentSnapshotPresenter.gpuChip(agent.snapshot), tone: .neutral)
                                MetricChip(text: AgentSnapshotPresenter.latencyChip(agent.snapshot), tone: .neutral)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            if agent.snapshot.localProviderID != nil {
                ReferralPanel(agent: agent)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .sheet(isPresented: $showAddWalletSheet) {
            AddWalletSheet(agent: agent, isPresented: $showAddWalletSheet)
        }
        .task(id: agent.snapshot.localProviderID) {
            guard agent.snapshot.localProviderID != nil else { return }
            await agent.refreshPayoutRegistration()
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
                Button(agent.snapshot.cliUpdateInProgress ? "Updating provider software..." : "Update provider software") {
                    Task { await agent.updateCLINow() }
                }
                .disabled(agent.snapshot.cliUpdateInProgress)
            }
        case .repairCredential:
            Button("Repair saved access") {
                Task { await agent.repairProviderCredential() }
            }
        case .repairAdmissionIdentity:
            Button(AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(agent.snapshot)) {
                Task { await agent.repairAdmissionIdentity() }
            }
        case .exportDiagnostics:
            Button("Export redacted diagnostics...") {
                onExportDiagnostics()
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .padding(16)
        .background(panelBackground)
    }

    @ViewBuilder
    private func statsPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
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

    private static func parseUTC(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
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
                ProgressView("Waiting for browser wallet signature…")
                    .controlSize(.small)
            }

            HStack(spacing: 10) {
                Button("Open browser wallet") {
                    localError = nil
                    Task {
                        await agent.registerPayoutWallet()
                        if agent.snapshot.payoutLastError == nil,
                           agent.snapshot.payoutRegisteredAddress != nil {
                            isPresented = false
                        }
                    }
                }
                .disabled(agent.snapshot.payoutRegistrationInProgress)
                .keyboardShortcut(.defaultAction)

                Button("Cancel") {
                    isPresented = false
                }
                .disabled(agent.snapshot.payoutRegistrationInProgress)
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
                        Task {
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
                            await agent.registerPayoutWallet(pasted: payload)
                            if agent.snapshot.payoutLastError == nil,
                               agent.snapshot.payoutRegisteredAddress != nil {
                                isPresented = false
                            }
                        }
                    }
                    .disabled(
                        agent.snapshot.payoutRegistrationInProgress
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
                       agent.snapshot.localStatusCapabilities.contains("referral_advocacy_v1") {
                        Button("Share on X for \(ReferralPanelPresenter.invitePhrase(status.configuredBonusCapacity))") {
                            Task { await agent.startReferralChallenge() }
                        }
                        .disabled(agent.snapshot.referralActionInProgress)
                    } else if status.socialState == ReferralStatusProjection.matured,
                              status.socialBonusEnabled,
                              status.bonusCapacity > 0 {
                        Text("X bonus already awarded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
