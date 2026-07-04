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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                MalibuBrandTile()
                    .frame(width: 28, height: 28)
                Text("Malibu")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    // AUDIT R1 ARCHITECT A1: distinguish "not reported yet" from
                    // "$0.00". The CLI stub returns 0 for metrics_response until
                    // SPEC-025 §11 P1 wires real earnings; showing "$0.00" as
                    // authoritative would mislead the user.
                    Text(agent.snapshot.earningsUsdcToday.map { String(format: "$%.2f", $0) } ?? "$—")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text(agent.snapshot.malibuAccruedToday
                            .map { _ in AgentSnapshotPresenter.earningsLine(agent.snapshot) }
                            ?? "— MALIBU (metrics not implemented)")
                        .foregroundStyle(.secondary)
                    if let backlog = AgentSnapshotPresenter.backlogLine(agent.snapshot) {
                        Text(backlog)
                            .font(.caption)
                            .foregroundStyle(MalibuBrand.coral)
                    }
                    Button("Add wallet") { }
                        .disabled(agent.snapshot.walletBound)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(agent.snapshot.state.rawValue.capitalized)
                        .font(.headline)
                        .foregroundStyle(color(for: agent.snapshot.state))
                    if let model = agent.snapshot.currentModelID {
                        Text(model).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(MalibuBrand.coral.opacity(0.35), lineWidth: 1)
            )

            Text("Live log")
                .font(.headline)
            LogTailView()
                .frame(minHeight: 240)
            Spacer(minLength: 0)
        }
        .padding(20)
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

private struct LogTailView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let text = NSTextView()
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = "Logs stream here.\n"
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
