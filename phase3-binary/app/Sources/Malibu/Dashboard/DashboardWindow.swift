import AppKit
import SwiftUI

@MainActor
enum DashboardWindow {
    static func make(agent: MalibuAgent) -> NSWindow {
        let hosting = NSHostingController(rootView: DashboardView(agent: agent))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Malibu"
        window.setContentSize(NSSize(width: 780, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct DashboardView: View {
    @ObservedObject var agent: MalibuAgent

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

                panel {
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
                    if AgentSnapshotPresenter.updateAvailable(agent.snapshot) {
                        Button(agent.snapshot.cliUpdateInProgress ? "Updating…" : updateButtonTitle) {
                            Task { await agent.updateCLINow() }
                        }
                        .disabled(agent.snapshot.cliUpdateInProgress)
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
            .frame(minHeight: 260)

            LogTailView(lines: agent.logLines)
                .frame(minHeight: 170)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(MalibuBrand.coral.opacity(0.25), lineWidth: 1)
        )
    }

    private var queueTone: MetricChip.Tone {
        (agent.snapshot.queueDepth ?? 0) > 0 ? .attention : .neutral
    }

    private var updateButtonTitle: String {
        if let target = AgentSnapshotPresenter.updateTargetVersion(agent.snapshot) {
            return "Update to v\(target)"
        }
        return "Update CLI"
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
