import AppKit
import SwiftUI

/// Discover: every signed catalog model, filtered to what this Mac can serve,
/// with rates, provider share, demand rank and provider count only where the
/// projection carries a trusted or catalog-reference rate (SPEC-044-R004,
/// SPEC-044-R013, SPEC-044-R014, SPEC-025-R006).
enum DiscoverPresentation {
    enum Sort: String, CaseIterable, Identifiable {
        /// The SPEC-044-R005 order the store already applied.
        case catalog
        case demand
        case rate
        case size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .catalog: return String(localized: "Catalog order", comment: "Discover sort")
            case .demand: return String(localized: "Demand", comment: "Discover sort")
            case .rate: return String(localized: "Provider rate", comment: "Discover sort")
            case .size: return String(localized: "Size", comment: "Discover sort")
            }
        }
    }

    static let emptyCatalog = String(localized: "No signed catalog models are available right now. Models lists every row with the reason it can or can't be served.", comment: "Discover empty catalog")
    static let emptyFilter = String(localized: "No catalog model matches. Turn off \"Fits this Mac\" or clear the search to see more.", comment: "Discover empty after filter")
    static let otherMLXTitle = String(localized: "Other MLX models (not earnable)", comment: "Discover HF section title")
    static let otherMLXExplainer = String(localized: "Search results from Hugging Face mlx-community. These are not in the Malibu catalog: they carry no rate, earn nothing on the network, and can't be switched to from Malibu.", comment: "Discover HF section explainer")

    /// Signed catalog models only (SPEC-044-R013 item 1): trusted catalog
    /// rows, catalog-only rows and local candidates with a verified catalog
    /// key. Candidates without a catalog identity stay in Models.
    static func catalogRows(_ rows: [MalibuModelRow]) -> [MalibuModelRow] {
        rows.filter(\.isSignedCatalogEntry)
    }

    /// The selected row: the provider's choice while it stays visible,
    /// otherwise the first visible row.
    static func selection(_ visible: [MalibuModelRow], selectedID: String?) -> MalibuModelRow? {
        visible.first(where: { $0.id == selectedID }) ?? visible.first
    }

    /// Search, fit filter and a provider-chosen sort. Every non-default sort
    /// keeps the R005 order as its tie-break (stable sort over R005 input).
    static func visibleRows(
        _ rows: [MalibuModelRow],
        search: String,
        fitsOnly: Bool,
        sort: Sort
    ) -> [MalibuModelRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = catalogRows(rows).filter { row in
            (!fitsOnly || row.fit == "fits")
                && (needle.isEmpty || ModelsPresentation.matches(row, needle))
        }
        let indexed = Array(filtered.enumerated())
        func ordered(_ key: (MalibuModelRow) -> Double?, descending: Bool) -> [MalibuModelRow] {
            indexed.sorted { lhs, rhs in
                switch (key(lhs.element), key(rhs.element)) {
                case let (l?, r?) where l != r: return descending ? l > r : l < r
                case (.some, .none): return true
                case (.none, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }.map(\.element)
        }
        switch sort {
        case .catalog: return filtered
        case .demand: return ordered({ $0.demandRank.map(Double.init) }, descending: false)
        case .rate: return ordered({ $0.providerCompletionPayoutUSDPerMillionTokens }, descending: true)
        case .size: return ordered({ $0.estimatedGB }, descending: false)
        }
    }

    static func listSubtitle(_ row: MalibuModelRow) -> String {
        var parts = [ModelsPresentation.sizeText(row), ModelsPresentation.fitText(row)]
        if row.category != .current {
            parts.append(row.weightsPresentLocally
                ? String(localized: "on this Mac", comment: "Discover list local state")
                : String(localized: "not downloaded", comment: "Discover list local state"))
        }
        if row.providerCompletionPayoutUSDPerMillionTokens != nil {
            parts.append(ModelsPresentation.rateText(row) + " / 1M out")
        }
        if let rank = row.demandRank {
            parts.append(String(localized: "demand #\(rank)", comment: "Discover list demand rank"))
        }
        return parts.joined(separator: " · ")
    }

    static func memoryLine(_ row: MalibuModelRow, hostMemoryGB: Int) -> String {
        let size = row.estimatedGB.map {
            String(localized: "About \($0.formatted(.number.precision(.fractionLength(1)))) GB of weights", comment: "Discover size")
        } ?? String(localized: "Size unknown", comment: "Discover size unknown")
        let fit: String
        switch row.fit {
        case "fits": fit = String(localized: "fits this Mac's \(hostMemoryGB) GB", comment: "Discover fit")
        case "wont_fit": fit = String(localized: "does not fit this Mac's \(hostMemoryGB) GB", comment: "Discover fit")
        default: fit = String(localized: "fit on this Mac's \(hostMemoryGB) GB is unknown", comment: "Discover fit")
        }
        return "\(size) · \(fit)"
    }

    /// The detail pane, top to bottom. Rates, share, demand rank and provider
    /// count only; no amounts per hour, day or month.
    static func detailLines(_ row: MalibuModelRow, hostMemoryGB: Int) -> [String] {
        var lines = [memoryLine(row, hostMemoryGB: hostMemoryGB)]
        lines.append(contentsOf: row.economicsRateLines)
        if let share = row.providerShareBPS {
            let percent = (Double(share) / 100).formatted(.number.precision(.fractionLength(0...2)))
            lines.append(String(localized: "Provider share: \(percent)% of the catalog rate.", comment: "Discover provider share"))
        }
        if let rank = row.demandRank {
            lines.append(String(localized: "Network demand rank \(rank).", comment: "Discover demand rank"))
        }
        if let count = row.readyProviderCount {
            lines.append(count == 1
                ? String(localized: "1 provider is ready to serve it.", comment: "Discover provider count")
                : String(localized: "\(count) providers are ready to serve it.", comment: "Discover provider count"))
        }
        if let caveat = row.nonEarningDisclosure { lines.append(caveat) }
        if let verdict = row.earningVerdict { lines.append(verdict) }
        lines.append(row.weightsPresentLocally
            ? String(localized: "Weights are on this Mac.", comment: "Discover local state")
            : String(localized: "Weights are not on this Mac.", comment: "Discover local state"))
        // The served row's action line already says it is serving.
        if row.category != .current, let reason = ModelsPresentation.reason(row) { lines.append(reason) }
        return lines
    }

    enum PrimaryAction: Equatable {
        case serving
        case switchModel
        /// SPEC-044-R014: a typed `prepare_model` download on this row.
        case download
        case none
    }

    static func primaryAction(_ row: MalibuModelRow) -> PrimaryAction {
        if row.category == .current { return .serving }
        if row.action == .switchModel { return .switchModel }
        if row.action == .download { return .download }
        return .none
    }

    static func screenStrings(
        rows: [MalibuModelRow],
        search: String = "",
        fitsOnly: Bool = true,
        sort: Sort = .catalog,
        hostMemoryGB: Int
    ) -> [String] {
        var strings = [String(localized: "Discover", comment: "Discover title")]
        let visible = visibleRows(rows, search: search, fitsOnly: fitsOnly, sort: sort)
        if catalogRows(rows).isEmpty {
            strings.append(emptyCatalog)
        } else if visible.isEmpty {
            strings.append(emptyFilter)
        } else {
            strings.append(ModelsPresentation.rateDisclosure)
        }
        for row in visible {
            strings.append(ModelsPresentation.title(row) + " (" + ModelsPresentation.name(row) + ") — " + listSubtitle(row))
        }
        if let first = visible.first {
            strings.append("[\(ModelsPresentation.title(first))]")
            strings.append(contentsOf: detailLines(first, hostMemoryGB: hostMemoryGB))
            if primaryAction(first) == .download {
                strings.append(ModelsPresentation.downloadConfirmationMessage(first))
            }
        }
        strings.append(otherMLXTitle)
        return strings
    }
}

struct DiscoverScreen: View {
    @ObservedObject var store: ModelManagementStore
    @ObservedObject var agent: MalibuAgent
    @State private var search = ""
    @State private var fitsOnly = true
    @State private var sort: DiscoverPresentation.Sort = .catalog
    @State private var selectedID: String?
    @State private var switchRow: MalibuModelRow?
    @State private var pendingDownload: MalibuModelRow?
    @State private var otherQuery = ""
    @State private var otherExpanded = false

    private var visible: [MalibuModelRow] {
        DiscoverPresentation.visibleRows(store.rows, search: search, fitsOnly: fitsOnly, sort: sort)
    }

    private var selected: MalibuModelRow? {
        DiscoverPresentation.selection(visible, selectedID: selectedID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
            if store.catalogRefreshFailed {
                // SPEC-044-R008: a failed refresh keeps the last good
                // projection on screen and says so.
                HStack(spacing: 8) {
                    Text(String(localized: "Showing the last catalog update.", comment: "Catalog refresh failed; cached projection shown"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .accessibilityIdentifier("malibu.discover.cachedProjection")
            }
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 260, idealWidth: 320)
                detail
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .sheet(item: $switchRow) { row in
            ModelSwitchSheet(store: store, row: row, isRevert: false) { switchRow = nil }
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
        .accessibilityIdentifier("malibu.discover")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(String(localized: "Discover", comment: "Discover title"))
                .font(.title2.weight(.semibold))
            Spacer()
            TextField(String(localized: "Search catalog", comment: "Discover search"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Picker(String(localized: "Sort", comment: "Discover sort label"), selection: $sort) {
                ForEach(DiscoverPresentation.Sort.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 200)
            Toggle(String(localized: "Fits this Mac", comment: "Discover fit filter"), isOn: $fitsOnly)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
        // Pinned above the list, and only for a signed catalog model, so a
        // recommendation's rates never appear for a non-catalog model.
        if let recommendation = store.recommendation,
           DiscoverPresentation.showsRecommendation(recommendation.displayModelID, rows: visible) {
            recommendationCallout(recommendation)
                .padding(12)
            Divider()
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if DiscoverPresentation.catalogRows(store.rows).isEmpty {
                    Text(store.listState == .checking
                         ? String(localized: "Loading the catalog…", comment: "Discover loading")
                         : DiscoverPresentation.emptyCatalog)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                } else if visible.isEmpty {
                    Text(DiscoverPresentation.emptyFilter)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                } else {
                    // SPEC-044-R004: visible in the same scroll container.
                    Text(ModelsPresentation.rateDisclosure)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    ForEach(visible) { row in
                        Button {
                            selectedID = row.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if row.category == .current {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 7))
                                            .foregroundStyle(.green)
                                            .accessibilityHidden(true)
                                    }
                                    Text(ModelsPresentation.title(row))
                                        .font(.callout.weight(.medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(ModelsPresentation.name(row))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(DiscoverPresentation.listSubtitle(row))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selected?.id == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selected?.id == row.id ? .isSelected : [])
                    }
                }
                Divider().padding(.vertical, 6)
                otherMLXSection
                    .padding(12)
            }
        }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let row = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ModelsPresentation.title(row))
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ModelsPresentation.name(row))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if row.catalogVerifiedModelKey != nil, row.displayID != row.catalogVerifiedModelKey {
                        Text(String(localized: "Provider-reported: \(ShellText.display(row.displayID))", comment: "Provider-reported model name shown under the catalog-verified identity"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(DiscoverPresentation.detailLines(row, hostMemoryGB: ModelsPresentation.hostMemoryGB).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(line == row.nonEarningDisclosure ? Color.orange : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(ModelsPresentation.rateDisclosure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    primaryAction(row)
                        .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(String(localized: "Select a model to see why this Mac can or can't serve it.", comment: "Discover detail placeholder"))
                .foregroundStyle(.secondary)
                .padding(20)
        }
    }

    @ViewBuilder
    private func primaryAction(_ row: MalibuModelRow) -> some View {
        if store.download?.rowID == row.id, row.action != .download {
            ModelDownloadControl(store: store, row: row, showsSize: true) {}
        }
        if let result = store.downloadResult, result.rowID == row.id, result.succeeded {
            Label(result.message, systemImage: "checkmark.circle")
                .font(.callout)
        }
        switch DiscoverPresentation.primaryAction(row) {
        case .serving:
            Label(String(localized: "This Mac is serving this model.", comment: "Discover serving"), systemImage: "checkmark.circle")
        case .switchModel:
            VStack(alignment: .leading, spacing: 4) {
                Button(String(localized: "Switch to this model…", comment: "Discover switch action")) { switchRow = row }
                    .disabled(!store.canPerformModelAction)
                Text(ModelsPresentation.switchingLine(listState: store.listState, warmSwapAvailable: store.warmSwapAvailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .download:
            VStack(alignment: .leading, spacing: 4) {
                ModelDownloadControl(store: store, row: row, showsSize: true) { pendingDownload = row }
                Text(ModelsPresentation.downloadConfirmationMessage(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .none:
            EmptyView()
        }
    }

    private var otherMLXSection: some View {
        DisclosureGroup(DiscoverPresentation.otherMLXTitle, isExpanded: $otherExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(DiscoverPresentation.otherMLXExplainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(String(localized: "Family, e.g. qwen", comment: "Discover HF search field"), text: $otherQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await store.browseOtherMLXModels(query: otherQuery) } }
                    Button(String(localized: "Search", comment: "Discover HF search button")) {
                        Task { await store.browseOtherMLXModels(query: otherQuery) }
                    }
                    .disabled(store.otherMLXState == .loading)
                }
                switch store.otherMLXState {
                case .idle:
                    EmptyView()
                case .loading:
                    ProgressView().controlSize(.small)
                case .unavailable(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .loaded:
                    if store.otherMLXModels.isEmpty {
                        Text(String(localized: "No matching MLX models.", comment: "Discover HF empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.otherMLXModels) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ShellText.display(model.id))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text(DiscoverPresentation.otherMLXSubtitle(model))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
        .accessibilityIdentifier("malibu.discover.other-mlx")
    }

    private func recommendationCallout(_ recommendation: MalibuRecommendationDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recommendation.isRecommendationResult
                ? String(localized: "Recommended for this Mac", comment: "Discover recommendation title")
                : String(localized: "No installed model recommendation", comment: "No recommendation callout title"))
                .font(.headline)
            if let target = recommendation.displayModelID {
                Text(ShellText.display(target))
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let rationale = recommendation.displayRationale {
                Text(ShellText.display(rationale, maxLength: 600))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(recommendation.displayEvidenceLines, id: \.self) { line in
                Text(ShellText.display(line, maxLength: 600))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = recommendation.promptRateUSDPerMillionTokens,
               let completion = recommendation.completionRateUSDPerMillionTokens {
                Text(String(localized: "Estimated rates: prompt $\(prompt, format: .number.precision(.fractionLength(2...4))) / 1M; completion $\(completion, format: .number.precision(.fractionLength(2...4))) / 1M.", comment: "Recommendation estimated rates"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // SPEC-044-R004: the disclosure travels with these rates.
                Text(ModelsPresentation.rateDisclosure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recommendation.warnings.isEmpty {
                Text(String(localized: "Warnings: \(recommendation.warnings.map { ShellText.display($0) }.joined(separator: ", "))", comment: "Recommendation warnings"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let unavailableReason = store.recommendationAdoptionUnavailableReason {
                Text(ShellText.display(unavailableReason, maxLength: 600))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if recommendation.isRecommendationResult {
                    Button(String(localized: "Adopt", comment: "Recommendation action")) {
                        Task { await store.adoptRecommendation() }
                    }
                    .disabled(!store.canAdoptRecommendation)
                    .accessibilityHint(Text(String(localized: "The provider validates, applies, switches, and verifies this recommendation as one transaction.", comment: "Adopt accessibility hint")))
                    Button(String(localized: "Not now", comment: "Recommendation snooze action")) {
                        store.snoozeRecommendation()
                    }
                }
                Button(String(localized: "Stop", comment: "Recommendation opt-out short action")) {
                    store.stopBackgroundRecommendations()
                }
                .help(String(localized: "Stop background recommendations", comment: "Recommendation opt-out action"))
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.09)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("malibu.discover.recommendation")
    }
}

extension DiscoverPresentation {
    /// The recommendation is shown only when it names a trusted catalog row.
    static func showsRecommendation(_ target: String?, rows: [MalibuModelRow]) -> Bool {
        guard let target else { return false }
        let key = target.lowercased()
        return catalogRows(rows).contains { row in
            row.id.lowercased() == key || row.catalogVerifiedModelKey?.lowercased() == key
        }
    }

    static func otherMLXSubtitle(_ model: MalibuOtherMLXModel) -> String {
        let size = model.estimatedGB.map {
            String(localized: "\($0.formatted(.number.precision(.fractionLength(1)))) GB", comment: "HF model size")
        } ?? String(localized: "size unknown", comment: "HF model size unknown")
        let fit: String
        switch model.fit {
        case "fits": fit = String(localized: "fits", comment: "HF model fit")
        case "tight": fit = String(localized: "tight fit", comment: "HF model fit")
        case "wont_fit": fit = String(localized: "does not fit", comment: "HF model fit")
        default: fit = String(localized: "fit unknown", comment: "HF model fit")
        }
        return "\(size) · \(fit) · " + String(localized: "not earnable", comment: "HF model not earnable")
    }
}
