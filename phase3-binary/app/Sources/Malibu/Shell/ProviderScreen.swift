import SwiftUI

/// Continuous batching and native MTP state from the CLI's `/v1/status`.
/// Only the fields the Provider screen shows are kept; diagnostic counters,
/// policy digests and signer ids stay in exported diagnostics.
struct ProviderEngineStatus: Equatable, Sendable {
    let continuousBatchingMode: String?
    let continuousBatchingActive: Bool?
    let continuousBatchingUnsupportedReason: String?
    let slotsTotal: Int?
    let slotsFree: Int?
    let waitingRequests: Int?
    let nativeMTPSupported: Bool?
    let nativeMTPEnabled: Bool?
    let nativeMTPMode: String?
    let nativeMTPMeanAcceptedLength: Double?

    static func decode(status object: [String: Any]) -> ProviderEngineStatus? {
        let cb = object["continuous_batching"] as? [String: Any]
        let mtp = object["native_mtp"] as? [String: Any]
        guard cb != nil || mtp != nil else { return nil }
        let scheduler = cb?["scheduler"] as? [String: Any]
        func int(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let int = number.intValue
            return int >= 0 ? int : nil
        }
        func bool(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        func token(_ value: Any?) -> String? {
            guard let string = value as? String, !string.isEmpty, string.count <= 64,
                  string.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) })
            else { return nil }
            return string
        }
        let meanAccepted = (mtp?["mean_accepted_length"] as? NSNumber)
            .flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return ProviderEngineStatus(
            continuousBatchingMode: token(cb?["mode"]),
            continuousBatchingActive: bool(cb?["active"]),
            continuousBatchingUnsupportedReason: token(cb?["unsupported_reason"]),
            slotsTotal: int(scheduler?["slots_total"]),
            slotsFree: int(scheduler?["slots_free"]),
            waitingRequests: int(scheduler?["waiting_count"]),
            nativeMTPSupported: bool(mtp?["supported"]),
            nativeMTPEnabled: bool(mtp?["enabled"]),
            nativeMTPMode: token(mtp?["mode"]),
            nativeMTPMeanAcceptedLength: meanAccepted
        )
    }
}

/// Provider screen copy (SPEC-025-R006). Reported values only; an absent
/// value is omitted, never shown as zero.
enum ProviderScreenPresentation {
    struct Row: Equatable {
        let title: String
        let value: String
    }

    static let endpointsNote = String(localized: "These endpoints answer only on this Mac (loopback). Customers reach this Mac through the Malibu network, not through these.", comment: "Provider endpoints note")

    static func continuousBatchingLine(_ engine: ProviderEngineStatus?) -> String? {
        guard let engine, let mode = engine.continuousBatchingMode else { return nil }
        if engine.continuousBatchingActive == true {
            var line = String(localized: "On", comment: "Continuous batching on")
            if let total = engine.slotsTotal, total > 0 {
                line += " · " + String(localized: "\(engine.slotsFree ?? 0) of \(total) rows free", comment: "Continuous batching rows")
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
        guard let engine, engine.nativeMTPSupported != nil || engine.nativeMTPMode != nil else { return nil }
        guard engine.nativeMTPSupported == true else {
            return String(localized: "Not available for this model.", comment: "Native MTP unsupported")
        }
        switch engine.nativeMTPMode {
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
            return engine.nativeMTPEnabled == true
                ? String(localized: "On", comment: "Native MTP active")
                : String(localized: "Off", comment: "Native MTP off")
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
