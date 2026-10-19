import AppKit
import SwiftUI

/// Diagnostics screen copy (SPEC-025-R007): findings, events and identity,
/// filtered logs and status, with Export and Reset always reachable here.
enum DiagnosticsPresentation {
    enum Tab: String, CaseIterable, Identifiable {
        case findings
        case events
        case logs
        case status

        var id: String { rawValue }

        var title: String {
            switch self {
            case .findings: return String(localized: "Findings", comment: "Diagnostics tab")
            case .events: return String(localized: "Events & identity", comment: "Diagnostics tab")
            case .logs: return String(localized: "Logs", comment: "Diagnostics tab")
            case .status: return String(localized: "Status", comment: "Diagnostics tab")
            }
        }
    }

    enum LogFilter: String, CaseIterable, Identifiable {
        case all
        case problems

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return String(localized: "All", comment: "Diagnostics log filter")
            case .problems: return String(localized: "Problems", comment: "Diagnostics log filter")
            }
        }
    }

    static let noFindings = String(localized: "No findings. The provider has not reported a problem.", comment: "Diagnostics empty findings")
    static let logsNote = String(localized: "Recent provider log lines, with paths and secrets removed. Export diagnostics to share the full set with support.", comment: "Diagnostics logs note")

    static func findings(_ s: AgentSnapshot) -> [String] {
        let lines = AgentSnapshotPresenter.diagnosticFindingLines(s).map { ShellText.display($0, maxLength: 600) }
        return lines.isEmpty ? [noFindings] : lines
    }

    struct Row: Equatable {
        let title: String
        let value: String

        init(title: String, value: String) {
            self.title = title
            self.value = ShellText.display(value, maxLength: 600)
        }
    }

    static func eventRows(_ s: AgentSnapshot) -> [Row] {
        var rows: [Row] = []
        if let event = s.lifecycleLastRestart {
            rows.append(Row(title: String(localized: "Last restart", comment: "Diagnostics row"), value: AgentSnapshotPresenter.lifecycleEventDisplay(event)))
        }
        if let event = AgentSnapshotPresenter.currentSetupFailure(s) {
            rows.append(Row(title: String(localized: "Setup failure", comment: "Diagnostics row"), value: AgentSnapshotPresenter.lifecycleEventDisplay(event)))
        }
        if let event = AgentSnapshotPresenter.currentLastUpdate(s) {
            rows.append(Row(title: String(localized: "Last update", comment: "Diagnostics row"), value: AgentSnapshotPresenter.lastUpdateDisplay(event)))
        }
        if let event = s.lifecycleLastWatchdog {
            rows.append(Row(title: String(localized: "Last provider recovery", comment: "Diagnostics row"), value: AgentSnapshotPresenter.lifecycleEventDisplay(event)))
        }
        rows.append(Row(title: String(localized: "Provider access", comment: "Diagnostics row"), value: AgentSnapshotPresenter.credentialLine(s)))
        rows.append(Row(title: String(localized: "Network verification", comment: "Diagnostics row"), value: AgentSnapshotPresenter.admissionIdentityLine(s)))
        if let update = AgentSnapshotPresenter.cliUpdateStatusLine(s) {
            rows.append(Row(title: String(localized: "Provider software", comment: "Diagnostics row"), value: update))
        }
        return rows
    }

    static func statusRows(_ s: AgentSnapshot, appVersion: String) -> [Row] {
        var rows = [
            Row(title: String(localized: "Malibu app", comment: "Diagnostics row"), value: appVersion),
            Row(title: String(localized: "Provider software", comment: "Diagnostics row"), value: AgentSnapshotPresenter.compatibilitySetLine(s)),
            Row(title: String(localized: "Status contract", comment: "Diagnostics row"), value: AgentSnapshotPresenter.statusContractLine(s)),
        ]
        if let lifecycle = AgentSnapshotPresenter.lifecycleLine(s) {
            rows.append(Row(title: String(localized: "Provider status", comment: "Diagnostics row"), value: lifecycle))
        }
        rows.append(Row(title: String(localized: "Customer slots", comment: "Diagnostics row"), value: AgentSnapshotPresenter.advertisedCapacityLine(s)))
        return rows
    }

    struct FilteredLog: Equatable {
        let lines: [String]
        let hiddenIdlePrewarm: Int
    }

    private static let problemMarkers = ["error", "fail", "warn", "refus", "denied", "timeout", "timed out", "crash"]

    /// Idle-prewarm ticks are collapsed into a count; "Problems" keeps only
    /// lines that name an error, failure, warning, refusal or timeout.
    /// At most this many lines, each at most `maxLogLineLength` characters,
    /// reach the screen.
    static let maxLogLines = 300
    static let maxLogLineLength = 500

    static func filteredLog(_ lines: [String], filter: LogFilter) -> FilteredLog {
        var kept: [String] = []
        var hidden = 0
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("idle_prewarm") {
                hidden += 1
                continue
            }
            if filter == .problems, !problemMarkers.contains(where: lower.contains) {
                continue
            }
            kept.append(ShellText.display(line, maxLength: maxLogLineLength))
        }
        return FilteredLog(lines: Array(kept.suffix(maxLogLines)), hiddenIdlePrewarm: hidden)
    }

    static func hiddenLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 idle warm-up line hidden.", comment: "Diagnostics idle prewarm counter")
            : String(localized: "\(count) idle warm-up lines hidden.", comment: "Diagnostics idle prewarm counter")
    }

    static func screenStrings(_ s: AgentSnapshot, appVersion: String) -> [String] {
        var strings = [String(localized: "Diagnostics", comment: "Diagnostics title")]
        strings.append(contentsOf: Tab.allCases.map(\.title))
        strings.append(contentsOf: findings(s))
        strings.append(contentsOf: eventRows(s).map { "\($0.title): \($0.value)" })
        strings.append(contentsOf: statusRows(s, appVersion: appVersion).map { "\($0.title): \($0.value)" })
        strings.append(DashboardCopy.resetProviderTitle)
        strings.append(DashboardCopy.exportDiagnosticsTitle)
        return strings
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? String(localized: "Version unknown", comment: "App version unknown")
    }
}

struct DiagnosticsScreen: View {
    @ObservedObject var agent: MalibuAgent
    let onExportDiagnostics: () -> Void
    let onResetProvider: () -> Void
    @State private var tab: DiagnosticsPresentation.Tab = .findings
    @State private var logFilter: DiagnosticsPresentation.LogFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(MalibuSection.diagnostics.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(DashboardCopy.exportDiagnosticsTitle) { onExportDiagnostics() }
                Button(DashboardCopy.resetProviderTitle) { onResetProvider() }
            }
            Picker(String(localized: "Section", comment: "Diagnostics tab picker"), selection: $tab) {
                ForEach(DiagnosticsPresentation.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("malibu.diagnostics")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .findings:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(DiagnosticsPresentation.findings(agent.snapshot).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .events:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DiagnosticsPresentation.eventRows(agent.snapshot), id: \.title) { row in
                        MetricRow(title: row.title, value: row.value)
                    }
                    identityRecovery
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .logs:
            logs
        case .status:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DiagnosticsPresentation.statusRows(agent.snapshot, appVersion: DiagnosticsPresentation.appVersion), id: \.title) { row in
                        MetricRow(title: row.title, value: row.value)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var identityRecovery: some View {
        if agent.snapshot.credentialRepairInProgress || agent.snapshot.admissionIdentityRecoveryInProgress {
            ProgressView(String(localized: "Repairing provider…", comment: "Diagnostics repair progress"))
                .controlSize(.small)
        }
        ForEach(Array([
            agent.snapshot.credentialRepairLastError,
            agent.snapshot.admissionIdentityRecoveryLastError,
        ].compactMap { $0 }.enumerated()), id: \.offset) { _, error in
            Text(ShellText.display(error, maxLength: 600))
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let instruction = agent.snapshot.admissionIdentityRecoveryApprovalInstruction {
            Text(ShellText.display(instruction, maxLength: 600))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        if let request = agent.snapshot.admissionIdentityRecoveryOperatorRequest {
            Text(ShellText.display(request, maxLength: 2_000))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var logs: some View {
        let filtered = DiagnosticsPresentation.filteredLog(agent.logLines, filter: logFilter)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(String(localized: "Show", comment: "Diagnostics log filter label"), selection: $logFilter) {
                    ForEach(DiagnosticsPresentation.LogFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                if let hidden = DiagnosticsPresentation.hiddenLine(filtered.hiddenIdlePrewarm) {
                    Text(hidden)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(DiagnosticsPresentation.logsNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(filtered.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
            .accessibilityIdentifier("malibu.diagnostics.logs")
        }
    }
}
