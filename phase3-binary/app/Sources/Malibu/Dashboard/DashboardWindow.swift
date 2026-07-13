import AppKit
import SwiftUI

@MainActor
enum DashboardWindow {
    static func make(agent: MalibuAgent, sparkleUpdater: SparkleUpdaterController) -> NSWindow {
        let hosting = NSHostingController(rootView: DashboardView(agent: agent, sparkleUpdater: sparkleUpdater))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Malibu"
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct DashboardView: View {
    @ObservedObject var agent: MalibuAgent
    @ObservedObject var sparkleUpdater: SparkleUpdaterController
    @StateObject private var referralInvites = ReferralInviteController()

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
                        Button("Add wallet") { }
                            .disabled(true)
                    }

                    statsPanel {
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
                        MetricRow(title: "Provider CLI", value: AgentSnapshotPresenter.cliVersionLine(agent.snapshot))
                        if let status = AgentSnapshotPresenter.cliUpdateStatusLine(agent.snapshot) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(agent.snapshot.cliUpdateLastError == nil ? Color.secondary : Color.red)
                        }
                        Button(sparkleUpdater.updateAvailable ? "Check for Updates… (available)" : "Check for Updates…") {
                            sparkleUpdater.checkForUpdates(nil)
                        }
                        .disabled(!sparkleUpdater.canCheckForUpdates)
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
                .frame(minHeight: 280)

                if referralInvites.isVisible {
                    referralInvitePanel
                }

                if !agent.logLines.isEmpty {
                    LogTailView(lines: agent.logLines)
                        .frame(minHeight: 120, maxHeight: 180)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .task {
            await referralInvites.refresh()
            while !Task.isCancelled {
                let interval: UInt64 = referralInvites.autoRefreshes ? 15 : 60
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await referralInvites.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await referralInvites.refresh() }
        }
    }

    @ViewBuilder
    private var referralInvitePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Invite someone to Malibu")
                    .font(.headline)
                Spacer()
                if referralInvites.status != nil {
                    Button("Refresh") { Task { await referralInvites.refresh() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            if referralInvites.isLoading && referralInvites.status == nil {
                ProgressView().controlSize(.small)
            } else if let status = referralInvites.status {
                referralStatusContent(status)
            }

            if let error = referralInvites.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(panelBackground)
    }

    @ViewBuilder
    private func referralStatusContent(_ status: ProviderReferralStatus) -> some View {
        switch status.socialState {
        case ProviderReferralStatus.locked:
            Text("Your invite unlocks after your first verified serving.")
                .font(.callout)
            Text("The coordinator has not confirmed a serving yet, so no invite link is shown. Provider access and earnings do not depend on sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case ProviderReferralStatus.revoked:
            Text("This invite has been revoked and no longer admits providers.")
                .font(.callout)
            Text("Your provider remains live. This invite stays unavailable until an operator issues a replacement.")
                .font(.caption)
                .foregroundStyle(.secondary)

        default:
            if let inviteURL = status.availableInviteURL {
                Text(inviteURL.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            } else {
                Text("The coordinator did not return an available invite link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                ReferralCapacityMetric(label: "Base", value: status.baseCapacity)
                if status.socialBonusEnabled {
                    ReferralCapacityMetric(label: "X bonus offered", value: status.configuredBonusCapacity)
                }
                ReferralCapacityMetric(label: "Bonus earned", value: status.bonusCapacity)
                ReferralCapacityMetric(label: "Redeemed", value: status.redemptions)
                ReferralCapacityMetric(label: "Remaining", value: status.remaining)
            }

            referralSocialStateContent(status)
        }
    }

    @ViewBuilder
    private func referralSocialStateContent(_ status: ProviderReferralStatus) -> some View {
        switch status.socialState {
        case ProviderReferralStatus.pending:
            Text("X post submitted — the bonus has not been earned yet.")
                .font(.callout.weight(.semibold))
            Text(pendingReviewDetail(status))
                .font(.caption)
                .foregroundStyle(.secondary)
            privateInviteButton

        case ProviderReferralStatus.matured:
            Text("X verification completed. The server added \(status.earnedBonusPhrase) to this invite.")
                .font(.callout)
            privateInviteButton

        case ProviderReferralStatus.failed:
            Text("X verification failed. No social bonus was added.")
                .font(.callout.weight(.semibold))
            Text("The post may have been unavailable, private, changed, or removed during review. Your provider and any remaining base invite capacity are unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                privateInviteButton
                if status.canStartSocialChallenge && referralInvites.pendingChallenge == nil {
                    Button("Try a new X post") { Task { await referralInvites.shareOnX() } }
                        .buttonStyle(.borderedProminent)
                        .tint(MalibuBrand.coral)
                        .disabled(!referralInvites.canShareOnX)
                }
            }

        case ProviderReferralStatus.eligible:
            if status.socialBonusEnabled && status.configuredBonusCapacity > 0 {
                Text("Sharing on X is optional. After Malibu verifies that the post remains public, the server can add \(status.configuredBonusPhrase).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Your provider is live. You can share the private invite while capacity remains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                privateInviteButton
                if status.canStartSocialChallenge && referralInvites.pendingChallenge == nil {
                    Button("Share on X") { Task { await referralInvites.shareOnX() } }
                        .buttonStyle(.borderedProminent)
                        .tint(MalibuBrand.coral)
                        .disabled(!referralInvites.canShareOnX)
                }
            }

        default:
            Text("The coordinator returned an unrecognized social verification state. No bonus is being claimed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            privateInviteButton
        }

        if referralInvites.pendingChallenge != nil {
            Text("After publishing, paste the public X post URL below. Verification only submits it for review; the bonus remains unearned until the server later reports it as matured.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let expiry = referralInvites.pendingExpiryText {
                Text(expiry)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("https://x.com/…/status/…", text: $referralInvites.postURL)
                    .textFieldStyle(.roundedBorder)
                Button("Submit for review") { Task { await referralInvites.verifyPost() } }
                    .disabled(!referralInvites.canVerify || referralInvites.isLoading)
            }
            HStack(spacing: 12) {
                Button("Reopen X composer") { referralInvites.reopenPostComposer() }
                Button("Start over") { Task { await referralInvites.startOver() } }
            }
            .buttonStyle(.plain)
        }
    }

    private var privateInviteButton: some View {
        Button(referralInvites.canCopyInvite ? "Copy private invite" : "No invite uses remaining") {
            referralInvites.copyPrivateInvite()
        }
        .buttonStyle(.bordered)
        .disabled(!referralInvites.canCopyInvite)
    }

    private func pendingReviewDetail(_ status: ProviderReferralStatus) -> String {
        let keepPublic = " Keep the post public and unchanged until verification completes."
        guard let due = status.reviewDueAt else {
            return "Malibu is reviewing it periodically." + keepPublic
        }
        let time = due.formatted(date: .omitted, time: .shortened)
        if due > Date() {
            return "It becomes eligible for the follow-up check around \(time)." + keepPublic
        }
        return "It is eligible for the follow-up check now (since \(time))." + keepPublic
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
}

private struct ReferralCapacityMetric: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(value)")
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
