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
        .task {
            await referralInvites.refresh()
            // PROD-M3: keep polling while the state can still advance on its own
            // — the pre-serving lock and a pending X review (which the
            // coordinator's reconciler promotes or retries on its own interval)
            // both resolve without user action, so the pending-review panel
            // never shows a stale past time.
            while !Task.isCancelled,
                  !referralInvites.dismissed,
                  referralInvites.autoRefreshes {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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
                Button("Not now") { referralInvites.dismissed = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if referralInvites.isLoading && referralInvites.status == nil {
                ProgressView().controlSize(.small)
            } else if let status = referralInvites.status {
                switch status.advocacyStatus {
                case "locked_until_first_serving":
                    Text("Your invite unlocks after your first verified serving. Provider access and earnings do not depend on sharing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Refresh eligibility") { Task { await referralInvites.refresh() } }
                        .buttonStyle(.bordered)
                case "verified":
                    Text("X post verified. You have \(status.remaining) invite use\(status.remaining == 1 ? "" : "s") remaining.")
                        .font(.callout)
                    Button(status.remaining > 0 ? "Copy private invite" : "Invite used") { referralInvites.copyPrivateInvite() }
                        .buttonStyle(.bordered)
                        .disabled(status.remaining == 0)
                case "revoked":
                    Text("This invite has been retired. Your provider remains live; contact Malibu if you need a new invite.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case ProviderReferralStatus.pendingSocialReview:
                    // PROD-M3: a valid X post is submitted and under review.
                    // `review_due_at` is the earliest ELIGIBILITY instant, not a
                    // completion time — after it passes the reconciler keeps
                    // checking. Label it accordingly and distinguish
                    // still-queued from now-eligible/retrying, always repeating
                    // the keep-public requirement. The dashboard auto-refreshes
                    // this state (see the .task poll loop) so it can't go stale.
                    Text("Your X post was received and is being verified.")
                        .font(.callout)
                    Text(pendingReviewDetail(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let next = status.reviewNextAttemptAt, next > Date() {
                        Text("Next check around \(next.formatted(date: .omitted, time: .shortened)).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh status") { Task { await referralInvites.refresh() } }
                        .buttonStyle(.bordered)
                case ProviderReferralStatus.socialReviewFailed:
                    // PROD-M4: terminal failure. Show the reason-specific
                    // corrective action (decoded from the coordinator's failure
                    // reason code, generic fallback when absent), keep the
                    // provider-still-live reassurance, and offer an actionable
                    // route: a re-challenge CTA when the coordinator permits one
                    // after a fixable failure, otherwise an appeal/support CTA.
                    Text("Your X post could not be verified for the bonus.")
                        .font(.callout)
                    Text(status.reviewFailureCorrectiveAction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Your provider remains live and your private invite still works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(status.remaining > 0 ? "Copy private invite" : "Invite used") { referralInvites.copyPrivateInvite() }
                            .buttonStyle(.bordered)
                            .disabled(status.remaining == 0)
                        if status.socialBonusEnabled, status.reviewRetryAllowed == true {
                            Button("Try posting again") {
                                Task { await referralInvites.shareOnX() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MalibuBrand.coral)
                            .disabled(referralInvites.isSharing)
                        } else {
                            Link("Appeal or contact support", destination: Self.reviewAppealURL)
                                .font(.callout)
                        }
                    }
                default:
                    Text(status.remaining == 0
                        ? (status.socialBonusEnabled
                            ? "Your private invite has been used. Optionally share on X to unlock \(status.shareIncentivePhrase)."
                            : "Your private invite has been used.")
                        : (status.socialBonusEnabled
                            ? "Your provider is live. Share privately, or optionally post on X to unlock \(status.shareIncentivePhrase)."
                            : "Your provider is live. You can share this invite privately."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(status.remaining > 0 ? "Copy private invite" : "Invite used") { referralInvites.copyPrivateInvite() }
                            .buttonStyle(.bordered)
                            .disabled(status.remaining == 0)
                        if status.socialBonusEnabled {
                            // ADV-M2: disable while a challenge request is in
                            // flight so a double-click can't start two.
                            Button("Share on X") {
                                Task { await referralInvites.shareOnX() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MalibuBrand.coral)
                            .disabled(referralInvites.isSharing)
                        }
                    }
                    if referralInvites.pendingChallenge != nil {
                        Text("After posting, copy the URL of your published X post and paste it below to verify the bonus. Your provider remains live and keeps serving if you skip this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let expiry = referralInvites.pendingExpiryText {
                            Text(expiry).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            TextField("https://x.com/…/status/…", text: $referralInvites.postURL)
                                .textFieldStyle(.roundedBorder)
                            Button("Verify post") {
                                Task { await referralInvites.verifyPost() }
                            }
                            .disabled(!referralInvites.canVerify || referralInvites.isLoading)
                        }
                        // PROD-L1: this reopens the X compose window (intent URL),
                        // not the already-published post — label it accordingly.
                        HStack(spacing: 8) {
                            Button("Reopen post composer") { referralInvites.reopenPostComposer() }
                            Button("Start over") { Task { await referralInvites.startOver() } }
                        }
                        .buttonStyle(.plain)
                    }
                }
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

    // PROD-M4: appeal/support destination for a terminal X-review failure the
    // user believes was wrong. A mailto avoids the dead-web-CTA hazard flagged
    // in R4-H1 (a branded web page that 404s). If a hosted appeal page ships,
    // point this at it and keep the Go branded-page CTA in sync.
    static let reviewAppealURL = URL(string:
        "mailto:support@malibu.tech?subject=Malibu%20X%20verification%20appeal")!

    // PROD-M3: `review_due_at` is the earliest ELIGIBILITY instant, not a
    // completion time. Before it passes the review is simply queued; after it
    // passes the reconciler is actively (re)checking. Either way the post must
    // stay public. Degrades to a generic "checking periodically" line when the
    // coordinator advertises no eligibility time.
    private func pendingReviewDetail(_ status: ProviderReferralStatus) -> String {
        let keepPublic =
            " Keep your X post public until it's verified — deleting or hiding it before review cancels the bonus."
        guard let due = status.reviewDueAt else {
            return "In review — Malibu is checking periodically (usually within about 30–35 minutes)." + keepPublic
        }
        let time = due.formatted(date: .omitted, time: .shortened)
        if due > Date() {
            return "Eligible for review around \(time)." + keepPublic
        }
        return "Now eligible for review — Malibu is checking periodically (eligible since \(time))." + keepPublic
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
