import AppKit
import SwiftUI

/// Copy and row projection for the Models and Discover screens. Rates only:
/// no $/time figures and no income claims (SPEC-044-R004).
enum ModelsPresentation {
    static let rateDisclosure = String(localized: "Catalog rates are informational. Final provider credit depends on eligible demand, uptime, accepted requests, trust state, routing, token mix, settlement, and any active sanctions or probation.", comment: "Catalog economics disclosure")
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
        case .needsPreparation: return String(localized: "Not downloaded", comment: "Model feature section")
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
        [row.displayID, row.catalogVerifiedModelKey, row.id, title(row)]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// The exact identifier behind a row: the catalog-verified key when the
    /// coordinator verified it, otherwise the provider-reported name.
    static func name(_ row: MalibuModelRow) -> String {
        ShellText.display(row.catalogVerifiedModelKey ?? row.displayID)
    }

    /// The readable title for a row (SPEC-025-R004), read from the same
    /// identifier as `name`. Display text only, not a verified attribute.
    static func title(_ row: MalibuModelRow) -> String {
        readableTitle(row.catalogVerifiedModelKey ?? row.displayID)
    }

    /// "mlx-community/Qwen3-8B-4bit" -> "Qwen3 8B · 4-bit". The family keeps
    /// its own spelling; size tokens read "8B" or "A3B"; quantization tokens
    /// move after a middle dot; the "mlx" marker is dropped. Falls back to the
    /// last path component when nothing is left.
    static func readableTitle(_ identifier: String) -> String {
        let base = String(ShellText.display(identifier).split(separator: "/").last ?? "")
        let tokens = base.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        var words: [String] = []
        var quantization: [String] = []
        for token in tokens {
            let lower = token.lowercased()
            if lower == "mlx" { continue }
            if let bits = lower.wholeMatch(of: /(\d+)bits?/) {
                quantization.append("\(bits.1)-bit")
            } else if lower.wholeMatch(of: /(bf16|fp16|f16|fp8|fp32|f32|mxfp4|nvfp4|dwq|awq|gptq|int4|int8|q\d[a-z0-9_]*)/) != nil {
                quantization.append(token.uppercased())
            } else if lower.wholeMatch(of: /a?\d+(\.\d+)?[bm]/) != nil {
                words.append(token.uppercased())
            } else {
                words.append(token)
            }
        }
        // Join the family (the words before the first size) with "-" so
        // "gpt-oss" and "Llama-3.2" keep their spelling.
        let firstSize = words.firstIndex { $0.wholeMatch(of: /A?\d+(\.\d+)?[BM]/) != nil }
        var parts: [String] = []
        if let firstSize, firstSize > 0 {
            parts.append(words[..<firstSize].joined(separator: "-"))
            parts.append(contentsOf: words[firstSize...])
        } else if firstSize == nil {
            if !words.isEmpty { parts.append(words.joined(separator: "-")) }
        } else {
            parts.append(contentsOf: words)
        }
        var title = parts.joined(separator: " ")
        if !quantization.isEmpty {
            title += (title.isEmpty ? "" : " · ") + quantization.joined(separator: " ")
        }
        return title.isEmpty ? base : title
    }

    static func downloadSizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The Download confirmation (SPEC-044-R014-5).
    static func downloadConfirmationTitle(_ row: MalibuModelRow) -> String {
        String(localized: "Download \(title(row))?", comment: "Model download confirmation title")
    }

    static func downloadConfirmationMessage(_ row: MalibuModelRow) -> String {
        let size = row.downloadTransaction.map { downloadSizeText($0.estimatedBytes) }
            ?? String(localized: "an unknown amount of data", comment: "Model download size unavailable")
        return String(localized: "Malibu downloads \(size) for catalog key \(ShellText.display(row.modelKey)) (\(ShellText.display(row.displayID))) to this Mac and verifies the files against the signed catalog. Downloading does not change the model this Mac serves, does not offer this model to the network, and does not start earning.", comment: "Model download confirmation message")
    }

    /// One progress line for a running download.
    static func downloadProgressText(_ state: ModelManagementStore.DownloadState) -> String {
        switch state.phase {
        case .starting:
            return String(localized: "Starting the download…", comment: "Model download progress")
        case .cancelling:
            return String(localized: "Cancelling the download…", comment: "Model download progress")
        case .delayed:
            return String(localized: "Waiting for the provider software to report progress…", comment: "Model download delayed")
        case .running:
            let done = state.bytesCompleted.map(downloadSizeText) ?? downloadSizeText(0)
            if let expected = state.bytesExpected, expected > 0 {
                return String(localized: "Downloaded \(done) of \(downloadSizeText(expected))", comment: "Model download progress with total")
            }
            return String(localized: "Downloaded \(done)", comment: "Model download progress")
        }
    }

    static func downloadFraction(_ state: ModelManagementStore.DownloadState) -> Double? {
        guard state.phase == .running, let done = state.bytesCompleted,
              let expected = state.bytesExpected, expected > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(expected)))
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
                var line = [title(row), name(row), sizeText(row), fitText(row), statusText(row), rateText(row)]
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
    @State private var pendingDownload: MalibuModelRow?

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
        .confirmationDialog(
            pendingDownload.map(ModelsPresentation.downloadConfirmationTitle) ?? "",
            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } })
        ) {
            Button(String(localized: "Download", comment: "Model download confirm action")) {
                if let row = pendingDownload { Task { await store.startDownload(row) } }
                pendingDownload = nil
            }
            Button(String(localized: "Cancel", comment: "Model download confirmation cancel"), role: .cancel) { pendingDownload = nil }
        } message: {
            Text(pendingDownload.map(ModelsPresentation.downloadConfirmationMessage) ?? "")
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
            ModelDownloadBanner(store: store)
            HStack(spacing: 8) {
                Text(ModelsPresentation.switchingLine(listState: store.listState, warmSwapAvailable: store.warmSwapAvailable))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                if store.catalogRefreshFailed {
                    // SPEC-044-R008: the last good projection stays on screen.
                    Text(String(localized: "Showing the last catalog update.", comment: "Catalog refresh failed; cached projection shown"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("malibu.models.cachedProjection")
                }
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
            Text(String(localized: "Action", comment: "Models column")).frame(width: 170, alignment: .trailing)
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
                    Text(ModelsPresentation.title(row))
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .help(ShellText.display(row.displayID))
                }
                Text(ModelsPresentation.name(row))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
                .frame(width: 170, alignment: .trailing)
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
            // A running download keeps its progress and Cancel even if a
            // refresh or a switch changed the row's action meanwhile.
            if store.download?.modelKey == row.modelKey, row.action != .download {
                ModelDownloadControl(store: store, row: row, showsSize: true) {}
            }
            switch row.action {
            case .switchModel:
                Button(String(localized: "Switch", comment: "Model feature action")) { start(row) }
                    .disabled(!store.canPerformModelAction)
                    .accessibilityHint(Text(String(localized: "Shows a confirmation before the provider changes its served model.", comment: "Switch accessibility hint")))
            case .evaluate:
                Button(String(localized: "Preflight", comment: "Short BYOM activation action")) { start(row) }
                    .disabled(!store.canPerformModelAction)
                    .accessibilityLabel(Text(String(localized: "Evaluate \(ShellText.display(row.displayID))", comment: "Evaluation accessibility label")))
            case .download:
                ModelDownloadControl(store: store, row: row, showsSize: true) { pendingDownload = row }
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
            .accessibilityLabel(Text(String(localized: "Details for \(ShellText.display(row.displayID))", comment: "Model details accessibility label")))
        }
    }

    private func start(_ row: MalibuModelRow) {
        switch row.action {
        case .switchModel:
            switchIsRevert = false
            switchRow = row
        case .evaluate:
            pendingEvaluate = row
        case .download:
            pendingDownload = row
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
                    Text(ShellText.display(previous))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button(String(localized: "Revert to \(ShellText.display(previous))", comment: "Revert action with target model")) {
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
                            Text(String(localized: "From \(entry.fromModelID.map { ShellText.display($0) } ?? "No previous model") to \(ShellText.display(entry.toModelID))", comment: "Model history transition"))
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
        case "download": return String(localized: "Download", comment: "Model history operation")
        default: return String(localized: "Switch", comment: "Model history operation")
        }
    }

    static func outcomeLabel(_ raw: String) -> String {
        switch raw {
        case "failed": return String(localized: "Failed", comment: "Model history outcome")
        case "cancelled": return String(localized: "Cancelled", comment: "Model history outcome")
        default: return String(localized: "Success", comment: "Model history outcome")
        }
    }
}

/// The Download button with its size, or the running download's progress and
/// Cancel (SPEC-044-R014-5). Shared by Models and Discover.
struct ModelDownloadControl: View {
    @ObservedObject var store: ModelManagementStore
    let row: MalibuModelRow
    var showsSize = false
    let onDownload: () -> Void

    var body: some View {
        if let download = store.download, download.modelKey == row.modelKey {
            VStack(alignment: .trailing, spacing: 3) {
                if let fraction = ModelsPresentation.downloadFraction(download) {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(ModelsPresentation.downloadProgressText(download))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                Button(String(localized: "Cancel", comment: "Cancel a model download")) { store.cancelDownload() }
                    .disabled(download.phase == .cancelling)
                    .accessibilityLabel(Text(String(localized: "Cancel downloading \(ModelsPresentation.title(row))", comment: "Cancel download accessibility label")))
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                downloadButton
                if let result = store.downloadResult, result.modelKey == row.modelKey, !result.succeeded {
                    Text(result.message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var downloadButton: some View {
        Button(buttonTitle, action: onDownload)
            .disabled(!store.canStartDownload)
            .help(store.download == nil
                  ? ModelsPresentation.downloadConfirmationMessage(row)
                  : String(localized: "Another download is running.", comment: "Download disabled while another runs"))
            .accessibilityLabel(Text(String(localized: "Download \(ModelsPresentation.title(row))", comment: "Download accessibility label")))
    }

    private var buttonTitle: String {
        guard showsSize, let bytes = row.downloadTransaction?.estimatedBytes else {
            return String(localized: "Download", comment: "Model download action")
        }
        return String(localized: "Download \(ModelsPresentation.downloadSizeText(bytes))", comment: "Model download action with size")
    }
}

/// The running download's title, progress and Cancel, shown above the list
/// whatever the projection holds: a refresh, an expiry or a row that turned
/// into a local candidate never hides Cancel (SPEC-044-R014-5).
struct ModelDownloadBanner: View {
    @ObservedObject var store: ModelManagementStore

    var body: some View {
        if let download = store.download {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Downloading \(download.title)", comment: "Model download banner title"))
                        .font(.callout.weight(.medium))
                    Text(ModelsPresentation.downloadProgressText(download))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let fraction = ModelsPresentation.downloadFraction(download) {
                    ProgressView(value: fraction).frame(maxWidth: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button(String(localized: "Cancel", comment: "Cancel a model download")) { store.cancelDownload() }
                    .disabled(download.phase == .cancelling)
                    .accessibilityLabel(Text(String(localized: "Cancel downloading \(download.title)", comment: "Cancel download accessibility label")))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("malibu.models.download")
        }
    }
}
