import SwiftUI

/// Provider screen copy (SPEC-025-R007). Reported values only; an absent
/// value is omitted, never shown as zero.
enum ProviderScreenPresentation {
    struct Row: Equatable {
        let title: String
        let value: String

        init(title: String, value: String) {
            self.title = title
            self.value = ShellText.display(value, maxLength: 600)
        }
    }

    static let endpointsNote = String(localized: "These endpoints answer only on this Mac (loopback). Customers reach this Mac through the Malibu network, not through these.", comment: "Provider endpoints note")

    static func continuousBatchingLine(_ engine: ProviderEngineStatus?) -> String? {
        guard let engine, let mode = engine.continuousBatchingMode else { return nil }
        if engine.continuousBatchingActive == true {
            var line = String(localized: "On", comment: "Continuous batching on")
            if let total = engine.slotsTotal, total > 0, let free = engine.slotsFree {
                line += " · " + String(localized: "\(free) of \(total) rows free", comment: "Continuous batching rows")
            }
            if let waiting = engine.waitingRequests, waiting > 0 {
                line += " · " + String(localized: "\(waiting) waiting", comment: "Continuous batching waiting")
            }
            return line
        }
        if mode == "off" {
            return String(localized: "Off: requests run one at a time per slot.", comment: "Continuous batching off")
        }
        if engine.continuousBatchingUnsupportedReason != nil {
            return String(localized: "Not active: this model or Mac did not pass the batching check.", comment: "Continuous batching unsupported")
        }
        return String(localized: "Not active yet.", comment: "Continuous batching inactive")
    }

    static func nativeMTPLine(_ engine: ProviderEngineStatus?) -> String? {
        guard let engine, let supported = engine.nativeMTPSupported else { return nil }
        guard supported else {
            return String(localized: "Not available for this model.", comment: "Native MTP unsupported")
        }
        guard let mode = engine.nativeMTPMode else { return nil }
        switch mode {
        case "active":
            if let mean = engine.nativeMTPMeanAcceptedLength, mean > 0 {
                return String(localized: "On · \(mean.formatted(.number.precision(.fractionLength(2)))) tokens accepted per step", comment: "Native MTP active with acceptance")
            }
            return String(localized: "On", comment: "Native MTP active")
        case "eligible":
            return String(localized: "Ready; turns on when the signed policy allows it.", comment: "Native MTP eligible")
        case "degraded_depth_zero":
            return String(localized: "Paused after a verification fallback; serving continues without it.", comment: "Native MTP degraded")
        default:
            return String(localized: "Off", comment: "Native MTP off")
        }
    }

    static func rows(_ s: AgentSnapshot) -> [Row] {
        var rows: [Row] = []
        if let lifecycle = AgentSnapshotPresenter.lifecycleLine(s) {
            rows.append(Row(title: String(localized: "Provider status", comment: "Provider row"), value: lifecycle))
        }
        rows.append(Row(title: String(localized: "Customer slots", comment: "Provider row"), value: AgentSnapshotPresenter.advertisedCapacityLine(s)))
        if let cb = continuousBatchingLine(s.providerEngine) {
            rows.append(Row(title: String(localized: "Continuous batching", comment: "Provider row"), value: cb))
        }
        if let mtp = nativeMTPLine(s.providerEngine) {
            rows.append(Row(title: String(localized: "Native MTP (speculative decoding)", comment: "Provider row"), value: mtp))
        }
        let chips = AgentSnapshotPresenter.diagnosticChips(s)
        if !chips.isEmpty {
            rows.append(Row(title: String(localized: "Right now", comment: "Provider row"), value: chips.joined(separator: " · ")))
        }
        rows.append(Row(title: String(localized: "Requests", comment: "Provider row"), value: AgentSnapshotPresenter.requestsLine(s)))
        rows.append(Row(title: String(localized: "Tokens", comment: "Provider row"), value: AgentSnapshotPresenter.tokenLine(s)))
        rows.append(Row(title: String(localized: "Current run", comment: "Provider row"), value: AgentSnapshotPresenter.runLine(s)))
        return rows
    }

    static let endpoints = ["POST /v1/chat/completions", "POST /v1/responses"]

    static func screenStrings(_ s: AgentSnapshot) -> [String] {
        var strings = [
            String(localized: "Provider", comment: "Provider screen title"),
            AgentSnapshotPresenter.statusPill(s).label,
        ]
        for row in rows(s) {
            strings.append("\(row.title): \(row.value)")
        }
        strings.append(String(localized: "Endpoints (this Mac only)", comment: "Provider endpoints title"))
        strings.append(contentsOf: endpoints)
        strings.append(endpointsNote)
        return strings
    }

    /// Pause is offered while serving, Resume while paused; nothing otherwise.
    enum PauseAction: Equatable { case pause, resume, none }

    static func pauseAction(_ s: AgentSnapshot) -> PauseAction {
        switch s.state {
        case .serving, .reconnecting: return .pause
        case .paused: return .resume
        default: return .none
        }
    }
}

struct ProviderScreen: View {
    @ObservedObject var agent: MalibuAgent
    let navigate: (MalibuSection) -> Void
    @State private var confirmPause = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(MalibuSection.provider.title)
                        .font(.title2.weight(.semibold))
                    StatusPillView(pill: AgentSnapshotPresenter.statusPill(agent.snapshot))
                    Spacer()
                    switch ProviderScreenPresentation.pauseAction(agent.snapshot) {
                    case .pause:
                        Button(String(localized: "Pause customer work…", comment: "Provider pause action")) { confirmPause = true }
                    case .resume:
                        Button(String(localized: "Resume customer work", comment: "Provider resume action")) {
                            Task { await agent.resume() }
                        }
                    case .none:
                        EmptyView()
                    }
                }
                ShellPanel {
                    ForEach(ProviderScreenPresentation.rows(agent.snapshot), id: \.title) { row in
                        MetricRow(title: row.title, value: row.value)
                    }
                }
                ShellPanel(String(localized: "Endpoints (this Mac only)", comment: "Provider endpoints title")) {
                    ForEach(ProviderScreenPresentation.endpoints, id: \.self) { endpoint in
                        Text(endpoint)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    Text(ProviderScreenPresentation.endpointsNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(String(localized: "Logs and events are in Diagnostics", comment: "Provider link to Diagnostics")) {
                    navigate(.diagnostics)
                }
                .buttonStyle(.link)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            String(localized: "Pause customer work on this Mac?", comment: "Provider pause confirmation title"),
            isPresented: $confirmPause
        ) {
            Button(String(localized: "Pause", comment: "Provider pause confirm")) {
                Task { await agent.pause() }
            }
            Button(String(localized: "Cancel", comment: "Provider pause cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This Mac stops taking new customer requests until you resume. Requests already running finish. No paid customer work runs while paused.", comment: "Provider pause confirmation message"))
        }
        .accessibilityIdentifier("malibu.provider")
    }
}
