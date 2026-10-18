import AppKit
import SwiftUI

/// Copy and row projection for the Models and Discover screens. Rates only:
/// no $/time figures and no income claims (SPEC-044-R004).
enum ModelsPresentation {
    static let rateDisclosure = String(localized: "Catalog rates are informational. Final provider credit depends on eligible demand, uptime, accepted requests, trust state, routing, token mix, settlement, and active policy status.", comment: "Catalog economics disclosure")
    static let switchingCost = String(localized: "Switching pauses new customer work while the new model loads: customers get a \"provider loading\" response (HTTP 503) until it is ready. Weights must already be on this Mac; switching never downloads.", comment: "Models footer switching cost")

    struct Section: Equatable {
        let category: MalibuModelRow.Category
        let title: String
        let rows: [MalibuModelRow]
    }

    static func sectionTitle(_ category: MalibuModelRow.Category) -> String {
        switch category {
        case .current: return String(localized: "Current", comment: "Model feature section")
        case .ready: return String(localized: "Ready to switch", comment: "Model feature section")
        case .networkCatalog: return String(localized: "Network catalog", comment: "Model feature section")
        case .needsPreparation: return String(localized: "Needs preparation", comment: "Model feature section")
        case .blocked: return String(localized: "Blocked", comment: "Model feature section")
        }
    }

    /// SPEC-044-R008 sections in their fixed order; rows keep the R005 order
    /// the store already applied. Empty sections are omitted.
    static func sections(_ rows: [MalibuModelRow], filter: String = "") -> [Section] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? rows : rows.filter { matches($0, needle) }
        let order: [MalibuModelRow.Category] = [.current, .ready, .networkCatalog, .needsPreparation, .blocked]
        return order.compactMap { category in
            let inSection = matching.filter { $0.category == category }
            return inSection.isEmpty ? nil : Section(category: category, title: sectionTitle(category), rows: inSection)
        }
    }

    static func matches(_ row: MalibuModelRow, _ needle: String) -> Bool {
        [row.displayID, row.catalogVerifiedModelKey, row.id]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// The name shown for a row: the catalog-verified key when the coordinator
    /// verified it, otherwise the provider-reported name.
    static func name(_ row: MalibuModelRow) -> String {
        row.catalogVerifiedModelKey ?? row.displayID
    }

    static func sizeText(_ row: MalibuModelRow) -> String {
        guard let gb = row.estimatedGB else { return "—" }
        return String(localized: "\(gb.formatted(.number.precision(.fractionLength(1)))) GB", comment: "Model size column")
    }

    static func fitText(_ row: MalibuModelRow) -> String {
        switch row.fit {
        case "fits": return String(localized: "Fits", comment: "Model fit status")
        case "tight": return String(localized: "Tight fit", comment: "Model fit status")
        case "wont_fit": return String(localized: "Does not fit", comment: "Model fit status")
        default: return String(localized: "Fit unknown", comment: "Model fit status")
        }
    }

    static func fitSymbol(_ row: MalibuModelRow) -> String {
        switch row.fit {
        case "fits": return "checkmark.circle"
        case "wont_fit": return "xmark.circle"
        default: return "questionmark.circle"
        }
    }

    static func statusText(_ row: MalibuModelRow) -> String {
        row.category == .current
            ? String(localized: "Serving", comment: "Model status column for the served model")
            : row.categoryLabel
    }

    static func rateText(_ row: MalibuModelRow) -> String {
        guard let rate = row.providerCompletionPayoutUSDPerMillionTokens else { return "—" }
        return "$" + rate.formatted(.number.precision(.significantDigits(2...4)))
    }

    /// One line with the provider share rate and the demand signal for a
    /// trusted row; nil when the row carries neither.
    static func rateAndDemand(_ row: MalibuModelRow, allRows: [MalibuModelRow]) -> String? {
        var parts: [String] = []
        if let completion = row.providerCompletionPayoutUSDPerMillionTokens {
            let formatted = completion.formatted(.number.precision(.significantDigits(2...4)))
            parts.append(String(localized: "Provider share rate $\(formatted) per 1M completion tokens", comment: "Rate and demand line: rate"))
        }
        if let rank = row.demandRank {
            parts.append(String(localized: "network demand rank \(rank)", comment: "Rate and demand line: demand rank"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Why the row can or cannot be served here, in one line.
    static func reason(_ row: MalibuModelRow) -> String? {
        if row.category == .current {
            return String(localized: "This Mac is serving this model.", comment: "Model reason for the served model")
        }
        if row.action == .switchModel {
            return String(localized: "On this Mac, fits, and ready for a live switch.", comment: "Model reason for a ready model")
        }
        return row.blockReason ?? row.earningDisclosure ?? row.admissionStateMeaning
    }

    static func localSummary(_ rows: [MalibuModelRow]) -> String {
        let local = rows.filter(\.weightsPresentLocally)
        let gb = local.compactMap(\.estimatedGB).reduce(0, +)
        let count = local.count == 1
            ? String(localized: "1 model on this Mac", comment: "Models header count")
            : String(localized: "\(local.count) models on this Mac", comment: "Models header count")
        guard gb > 0 else { return count }
        return count + " · " + String(localized: "about \(gb.formatted(.number.precision(.fractionLength(1)))) GB", comment: "Models header size")
    }

    /// The honest switching line that replaces "Checking whether switching is
    /// available" (#2029 §8.4).
    /// Switching depends on warm swap, not on whether some row has an action.
    static func switchingLine(listState: ModelManagementStore.ListState, warmSwapAvailable: Bool) -> String {
        switch listState {
        case .checking:
            return String(localized: "Checking whether switching is available…", comment: "Switching line")
        case .ready, .viewOnly:
            return warmSwapAvailable
                ? String(localized: "Switching available.", comment: "Switching line")
                : String(localized: "Switching off: warm swap is not running on this Mac.", comment: "Switching line")
        case .unavailable:
            return String(localized: "Switching unavailable right now.", comment: "Switching line")
        }
    }

    static var hostMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// Every visible string of the Models screen, for tests and the PR render.
    static func screenStrings(
        rows: [MalibuModelRow],
        listState: ModelManagementStore.ListState,
        warmSwapAvailable: Bool = true,
        filter: String = ""
    ) -> [String] {
        var strings = [
            String(localized: "Models", comment: "Models screen title"),
            localSummary(rows),
            switchingLine(listState: listState, warmSwapAvailable: warmSwapAvailable),
        ]
        if rows.contains(where: { $0.providerCompletionPayoutUSDPerMillionTokens != nil }) {
            strings.append(rateDisclosure)
        }
        for section in sections(rows, filter: filter) {
            strings.append(section.title)
            for row in section.rows {
                var line = [name(row), sizeText(row), fitText(row), statusText(row), rateText(row)]
                    .joined(separator: " | ")
                if let reason = reason(row) { line += " — " + reason }
                strings.append(line)
            }
        }
        strings.append(switchingCost)
        return strings
    }
}

/// Models section: the provider's model library in SPEC-044-R008 sections
/// with size, fit, status, provider share rate and one action per row
/// (SPEC-025-R004).
struct ModelsScreen: View {
    @ObservedObject var store: ModelManagementStore
    @ObservedObject var agent: MalibuAgent
    @State private var filter = ""
    @State private var switchRow: MalibuModelRow?
    @State private var switchIsRevert = false
    @State private var pendingEvaluate: MalibuModelRow?
    @State private var pendingWithdraw: MalibuModelRow?
    @State private var proposeRow: MalibuModelRow?
    @State private var proposePoolID = ""
    @State private var detailRow: MalibuModelRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
            Divider()
            content
            Divider()
            Text(ModelsPresentation.switchingCost)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .sheet(item: $switchRow) { row in
            ModelSwitchSheet(store: store, row: row, isRevert: switchIsRevert) { switchRow = nil }
        }
        .confirmationDialog(
            String(localized: "Run the offer preflight?", comment: "BYOM activation confirmation title"),
            isPresented: Binding(get: { pendingEvaluate != nil }, set: { if !$0 { pendingEvaluate = nil } })
        ) {
            Button(String(localized: "Run offer preflight", comment: "BYOM guided activation action")) {
                if let row = pendingEvaluate { Task { await store.activate(row) } }
                pendingEvaluate = nil
            }
            Button(String(localized: "Cancel", comment: "Switch confirmation cancel"), role: .cancel) { pendingEvaluate = nil }
        } message: {
            Text(String(localized: "Malibu will run evaluate, offer dry-run, and offer through provider CLI typed transactions. No action will start until you confirm.", comment: "BYOM guided activation confirmation"))
        }
        .confirmationDialog(
            String(localized: "Withdraw this offer?", comment: "BYOM withdraw confirmation title"),
            isPresented: Binding(get: { pendingWithdraw != nil }, set: { if !$0 { pendingWithdraw = nil } })
        ) {
            Button(String(localized: "Withdraw", comment: "BYOM withdraw action"), role: .destructive) {
                if let row = pendingWithdraw { Task { await store.withdraw(row) } }
                pendingWithdraw = nil
            }
            Button(String(localized: "Cancel", comment: "Withdraw confirmation cancel"), role: .cancel) { pendingWithdraw = nil }
        } message: {
            Text(String(localized: "The coordinator stops routing to this model, in the network and in any Trusted Pool, until you offer it again.", comment: "BYOM withdraw confirmation message"))
        }
        .sheet(item: $proposeRow) { row in
            PoolProposeSheet(row: row, poolID: $proposePoolID) {
                proposeRow = nil
                let poolID = proposePoolID
                Task { await store.propose(row, poolID: poolID) }
            } onCancel: {
                proposeRow = nil
            }
        }
        .sheet(item: Binding(get: { store.poolProposal }, set: { if $0 == nil { store.dismissPoolProposal() } })) { proposal in
            PoolProposalResultSheet(proposal: proposal) { store.dismissPoolProposal() }
        }
        .accessibilityIdentifier("malibu.models")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Models", comment: "Models screen title"))
                    .font(.title2.weight(.semibold))
                Text(ModelsPresentation.localSummary(store.rows))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(String(localized: "Filter", comment: "Models filter field"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("malibu.models.filter")
            }
            HStack(spacing: 8) {
                Text(ModelsPresentation.switchingLine(listState: store.listState, warmSwapAvailable: store.warmSwapAvailable))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                if store.catalogProjectionRetryAvailable {
                    Button(String(localized: "Retry", comment: "Model feature retry button")) {
                        Task {
                            await store.refresh(
                                currentModelID: agent.snapshot.currentModelID,
                                peer: MalibuModelPeerEvidence(snapshot: agent.snapshot)
                            )
                        }
                    }
                    .accessibilityLabel(Text(String(localized: "Retry model catalog refresh", comment: "Catalog retry accessibility label")))
                }
                if store.listState == .checking {
                    ProgressView().controlSize(.small)
                }
            }
            if store.statusLine != ModelsPresentation.switchingLine(listState: store.listState, warmSwapAvailable: store.warmSwapAvailable) {
                Text(store.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let sections = ModelsPresentation.sections(store.rows, filter: filter)
        if store.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.listState == .checking
                     ? String(localized: "Loading models…", comment: "Models empty while loading")
                     : String(localized: "No models are listed yet. The model this Mac serves stays visible in the sidebar.", comment: "Models empty"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.rows.contains(where: { $0.providerCompletionPayoutUSDPerMillionTokens != nil }) {
                        // SPEC-044-R004: persistently visible beside the rates.
                        Text(ModelsPresentation.rateDisclosure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                    columnHeader
                    ForEach(sections, id: \.category) { section in
                        Text(section.title)
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(section.rows) { row in
                            libraryRow(row)
                            Divider().padding(.leading, 20)
                        }
                    }
                    revertAndHistory
                        .padding(20)
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Model", comment: "Models column")).frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "Size", comment: "Models column")).frame(width: 70, alignment: .trailing)
            Text(String(localized: "Fit", comment: "Models column")).frame(width: 90, alignment: .leading)
            Text(String(localized: "Status", comment: "Models column")).frame(width: 120, alignment: .leading)
            Text(String(localized: "Rate / 1M out", comment: "Models column")).frame(width: 100, alignment: .trailing)
            Text(String(localized: "Action", comment: "Models column")).frame(width: 150, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.06))
    }

    private func libraryRow(_ row: MalibuModelRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if row.category == .current {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }
                    Text(ModelsPresentation.name(row))
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.displayID)
                }
                if let reason = ModelsPresentation.reason(row) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ModelsPresentation.sizeText(row))
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Label(ModelsPresentation.fitText(row), systemImage: ModelsPresentation.fitSymbol(row))
                .font(.callout)
                .frame(width: 90, alignment: .leading)
            Text(ModelsPresentation.statusText(row))
                .font(.callout)
                .frame(width: 120, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ModelsPresentation.rateText(row))
                    .font(.callout.monospacedDigit())
                if row.nonEarningDisclosure != nil {
                    Text(String(localized: "No provider credit yet", comment: "Short non-earning caveat beside a rate"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 100, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.economicsAccessibilityLabel
                ?? String(localized: "No network catalog rate", comment: "Rate column accessibility label without a rate")))
            actionCell(row)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .popover(isPresented: Binding(
            get: { detailRow?.id == row.id },
            set: { if !$0 { detailRow = nil } }
        )) {
            ModelRowView(
                row: row,
                enabled: store.canPerformModelAction,
                byomEnabled: store.canPerformBYOMAction,
                poolEligibilityLine: row.poolEligibilityDisplayLine(binding: store.poolBindings[row.id]),
                onAction: { detailRow = nil; start(row) },
                onWithdraw: { detailRow = nil; pendingWithdraw = row },
                onPropose: { detailRow = nil; proposePoolID = ""; proposeRow = row }
            )
            .frame(width: 420)
            .padding(8)
        }
    }

    @ViewBuilder
    private func actionCell(_ row: MalibuModelRow) -> some View {
        HStack(spacing: 6) {
            switch row.action {
            case .switchModel:
                Button(String(localized: "Switch", comment: "Model feature action")) { start(row) }
                    .disabled(!store.canPerformModelAction)
                    .accessibilityHint(Text(String(localized: "Shows a confirmation before the provider changes its served model.", comment: "Switch accessibility hint")))
            case .evaluate:
                Button(String(localized: "Preflight", comment: "Short BYOM activation action")) { start(row) }
                    .disabled(!store.canPerformModelAction)
                    .accessibilityLabel(Text(String(localized: "Evaluate \(row.displayID)", comment: "Evaluation accessibility label")))
            case .none:
                EmptyView()
            }
            Button {
                detailRow = row
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Why this model can or can't be served here", comment: "Model details help"))
            .accessibilityLabel(Text(String(localized: "Details for \(row.displayID)", comment: "Model details accessibility label")))
        }
    }

    private func start(_ row: MalibuModelRow) {
        switch row.action {
        case .switchModel:
            switchIsRevert = false
            switchRow = row
        case .evaluate:
            pendingEvaluate = row
        case .none:
            break
        }
    }

    @ViewBuilder
    private var revertAndHistory: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let previous = store.previousModelID {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Previous confirmed model", comment: "Revert section"))
                        .font(.headline)
                    Text(previous)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button(String(localized: "Revert to \(previous)", comment: "Revert action with target model")) {
                        if let row = store.rows.first(where: {
                            $0.id.lowercased(with: nil) == previous.lowercased(with: nil)
                        }) {
                            switchIsRevert = true
                            switchRow = row
                        } else {
                            Task { await store.revert() }
                        }
                    }
                    .disabled(!store.canRevert)
                    .accessibilityLabel(Text(String(localized: "Revert to previous model", comment: "Revert accessibility label")))
                    if let reason = store.revertUnavailableReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !store.history.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(String(localized: "Model activity", comment: "Model feature section")).font(.headline)
                    ForEach(Array(store.history.suffix(5).reversed())) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "\(ModelsPresentation.operationLabel(entry.operation)): \(ModelsPresentation.outcomeLabel(entry.outcome))", comment: "Model history operation and outcome"))
                                .font(.caption.weight(.semibold))
                            Text(String(localized: "From \(entry.fromModelID ?? "No previous model") to \(entry.toModelID)", comment: "Model history transition"))
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

extension ModelsPresentation {
    static func operationLabel(_ raw: String) -> String {
        switch raw {
        case "revert": return String(localized: "Revert", comment: "Model history operation")
        case "adopt": return String(localized: "Adopt", comment: "Model history operation")
        case "withdraw": return String(localized: "Withdraw", comment: "Model history operation")
        case "propose": return String(localized: "Propose to pool", comment: "Model history operation")
        case "evaluate": return String(localized: "Offer", comment: "Model history operation")
        default: return String(localized: "Switch", comment: "Model history operation")
        }
    }

    static func outcomeLabel(_ raw: String) -> String {
        raw == "failed"
            ? String(localized: "Failed", comment: "Model history outcome")
            : String(localized: "Success", comment: "Model history outcome")
    }
}
