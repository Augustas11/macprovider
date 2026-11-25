import AppKit
import SwiftUI

/// Discover: every signed catalog model, filtered to what this Mac can serve,
/// with rates, provider share, demand rank and provider count only where the
/// projection carries a trusted or catalog-reference rate (SPEC-044-R004,
/// SPEC-044-R013, SPEC-044-R014, SPEC-025-R006).
enum DiscoverPresentation {
    enum Sort: String, CaseIterable, Identifiable {
        /// The SPEC-044-R005 order the store already applied.
        case bestMatch
        case demand
        case rate
        /// `estimated_gb` descending among rows that fit; the rest last.
        case largestFits

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bestMatch: return String(localized: "Best match", comment: "Discover sort")
            case .demand: return String(localized: "Demand", comment: "Discover sort")
            case .rate: return String(localized: "Rate", comment: "Discover sort")
            case .largestFits: return String(localized: "Largest that fits", comment: "Discover sort")
            }
        }
    }

    /// Recommended lists the first rows of the fitting catalog only.
    static let recommendedLimit = 5

    static let emptyCatalog = String(localized: "No signed catalog models are available right now. Models lists every row with the reason it can or can't be served.", comment: "Discover empty catalog")
    static let emptyRecommended = String(localized: "No recommended model fits this Mac. Browse all catalog models in Models › Browse.", comment: "Recommended empty state")
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
        sorted(filteredRows(rows, search: search, fitsOnly: fitsOnly), by: sort)
    }

    /// Signed catalog rows matching the search and fit filter, in R005 order.
    static func filteredRows(_ rows: [MalibuModelRow], search: String, fitsOnly: Bool) -> [MalibuModelRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalogRows(rows).filter { row in
            (!fitsOnly || row.fit == "fits")
                && (needle.isEmpty || ModelsPresentation.matches(row, needle))
        }
    }

    /// Reorders rows that arrive in R005 order; ties keep that order.
    static func sorted(_ rows: [MalibuModelRow], by sort: Sort) -> [MalibuModelRow] {
        let indexed = Array(rows.enumerated())
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
        case .bestMatch: return rows
        case .demand: return ordered({ $0.demandRank.map(Double.init) }, descending: false)
        case .rate: return ordered({ $0.providerCompletionPayoutUSDPerMillionTokens }, descending: true)
        case .largestFits:
            return ordered({ $0.estimatedGB }, descending: true).filter { $0.fit == "fits" }
                + rows.filter { $0.fit != "fits" }
        }
    }

    // MARK: Best for this Mac

    /// The share of this Mac's memory a pick may use.
    static let bestPickMemoryShare = 0.8
    /// A local pick wins when it scores at least this share of the best one,
    /// so the owner is not asked to download many GB for a small gain.
    static let localPickScoreShare = 0.9

    /// Rate times demand weight: `demand_weight`, else 1 / `demand_rank`,
    /// else 0. Nil for a row with no completion rate.
    static func bestPickScore(_ row: MalibuModelRow) -> Double? {
        guard let rate = row.providerCompletionPayoutUSDPerMillionTokens else { return nil }
        let weight = row.demandWeight ?? row.demandRank.flatMap { $0 > 0 ? 1 / Double($0) : nil } ?? 0
        return rate * weight
    }

    /// Signed catalog rows this Mac can serve now or after one confirmed
    /// action, with a rate, using at most 80% of its memory.
    static func bestPickCandidates(_ rows: [MalibuModelRow], hostMemoryGB: Int) -> [MalibuModelRow] {
        catalogRows(rows).filter { row in
            guard row.fit == "fits",
                  let gb = row.estimatedGB, gb <= bestPickMemoryShare * Double(hostMemoryGB),
                  row.providerCompletionPayoutUSDPerMillionTokens != nil else { return false }
            return row.category == .current || row.action == .switchModel || row.action == .download
        }
    }

    /// The pinned "Best for this Mac" row. Client-computed presentation
    /// only: it never starts an action. A store recommendation that names a
    /// candidate wins; otherwise the highest score wins, unless a row already
    /// on this Mac scores within 10% of it. Ties keep the R005 order.
    static func bestPick(_ rows: [MalibuModelRow], hostMemoryGB: Int, recommendedID: String? = nil) -> MalibuModelRow? {
        let candidates = bestPickCandidates(rows, hostMemoryGB: hostMemoryGB)
        if let key = recommendedID?.lowercased(),
           let recommended = candidates.first(where: { $0.id.lowercased() == key || $0.catalogVerifiedModelKey?.lowercased() == key }) {
            return recommended
        }
        func best(_ rows: [MalibuModelRow]) -> (row: MalibuModelRow, score: Double)? {
            var top: (row: MalibuModelRow, score: Double)?
            for row in rows {
                let score = bestPickScore(row) ?? 0
                if let current = top, score <= current.score { continue }
                top = (row: row, score: score)
            }
            return top
        }
        guard let top = best(candidates) else { return nil }
        if let local = best(candidates.filter { $0.weightsPresentLocally || $0.category == .current }),
           local.score >= localPickScoreShare * top.score {
            return local.row
        }
        return top.row
    }

    static let bestPickTitle = String(localized: "Best for this Mac", comment: "Recommended pinned card title")

    // MARK: Rows

    /// Row demand: ranks 1-5 read "High demand", 6-20 "Steady demand",
    /// anything else nothing. The detail pane keeps the exact rank.
    static func demandLabel(_ rank: Int?) -> String? {
        guard let rank, rank >= 1 else { return nil }
        if rank <= 5 { return String(localized: "High demand", comment: "Discover row demand label for ranks 1-5") }
        if rank <= 20 { return String(localized: "Steady demand", comment: "Discover row demand label for ranks 6-20") }
        return nil
    }

    /// A row's small badge: serving, already local, or tight on memory.
    static func rowBadge(_ row: MalibuModelRow, hostMemoryGB: Int) -> String? {
        if row.category == .current { return String(localized: "Serving", comment: "Discover row badge") }
        if row.weightsPresentLocally { return String(localized: "On this Mac", comment: "Discover row badge") }
        if let gb = row.estimatedGB, gb > 0.75 * Double(hostMemoryGB) {
            return String(localized: "Tight", comment: "Discover row badge: uses most of this Mac's memory")
        }
        return nil
    }

    static func gbText(_ gb: Double) -> String {
        gb.formatted(.number.precision(.fractionLength(1)))
    }

    /// "uses 4.6 GB of 32 GB", or "won't fit" for a row that does not fit.
    static func memoryUse(_ row: MalibuModelRow, hostMemoryGB: Int) -> String {
        if row.fit == "wont_fit" { return String(localized: "won't fit", comment: "Discover row: model does not fit this Mac") }
        let use = row.estimatedGB.map {
            String(localized: "uses \(gbText($0)) GB of \(hostMemoryGB) GB", comment: "Discover row memory use")
        } ?? String(localized: "size unknown", comment: "Discover row size unknown")
        return row.fit == "fits" ? use : use + " · " + String(localized: "fit unknown", comment: "Discover row fit unknown")
    }

    /// "network rate $0.36 / 1M out": the catalog rate, never a claim that
    /// this Mac is earning it (SPEC-044-R014 item 2).
    static func rowRate(_ row: MalibuModelRow) -> String? {
        guard row.providerCompletionPayoutUSDPerMillionTokens != nil else { return nil }
        guard row.nonEarningDisclosure != nil else {
            return ModelsPresentation.rateText(row) + " / 1M out"
        }
        return String(localized: "network rate \(ModelsPresentation.rateText(row)) / 1M out", comment: "Discover row rate")
    }

    /// A row's second line: memory use, rate and demand.
    static func rowMeta(_ row: MalibuModelRow, hostMemoryGB: Int) -> String {
        [memoryUse(row, hostMemoryGB: hostMemoryGB), rowRate(row), demandLabel(row.demandRank)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The not-earning caveat for a listed row that shows a rate.
    static func listCaveat(_ row: MalibuModelRow) -> String? {
        row.providerCompletionPayoutUSDPerMillionTokens == nil ? nil : row.nonEarningDisclosure
    }

    /// A row's accessibility label: both lines and the caveat beside the rate.
    static func rowAccessibilityLabel(_ row: MalibuModelRow, hostMemoryGB: Int) -> String {
        [ModelsPresentation.title(row), rowBadge(row, hostMemoryGB: hostMemoryGB),
         rowMeta(row, hostMemoryGB: hostMemoryGB), listCaveat(row)]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    // MARK: Detail

    /// One label and value in the detail pane's fact grid. A secondary fact
    /// (a caveat or reason) has no label and reads in secondary colour.
    struct Fact: Equatable {
        let label: String
        let value: String
        var secondary = false
    }

    static func statusText(_ row: MalibuModelRow) -> String {
        if row.category == .current { return String(localized: "Serving", comment: "Discover status") }
        if row.action == .switchModel { return String(localized: "On this Mac · ready to switch", comment: "Discover status") }
        if !row.weightsPresentLocally {
            return row.action == .download
                ? String(localized: "Not on this Mac · not earning yet", comment: "Discover status")
                : String(localized: "Not on this Mac", comment: "Discover status")
        }
        return String(localized: "On this Mac", comment: "Discover status")
    }

    /// The detail pane's facts, top to bottom. Rates, share, demand rank and
    /// provider count only; no amounts per hour, day or month.
    static func detailFacts(_ row: MalibuModelRow, hostMemoryGB: Int) -> [Fact] {
        var facts: [Fact] = []
        var memory = row.estimatedGB.map {
            String(localized: "\(gbText($0)) GB of \(hostMemoryGB) GB", comment: "Discover detail memory")
        } ?? String(localized: "Size unknown · this Mac has \(hostMemoryGB) GB", comment: "Discover detail memory unknown")
        if row.fit == "wont_fit" {
            memory += " · " + String(localized: "won't fit", comment: "Discover detail fit")
        } else if row.fit != "fits" {
            memory += " · " + String(localized: "fit unknown", comment: "Discover detail fit")
        }
        facts.append(Fact(label: String(localized: "Memory", comment: "Discover detail label"), value: memory))
        if let share = row.providerShareBPS {
            let percent = (Double(share) / 100).formatted(.number.precision(.fractionLength(0...2)))
            facts.append(Fact(label: String(localized: "Your share", comment: "Discover detail label"),
                              value: String(localized: "\(percent)% of the catalog rate", comment: "Discover detail share")))
        }
        let rates = [
            row.providerCompletionPayoutUSDPerMillionTokens.map {
                String(localized: "$\($0.formatted(.number.precision(.significantDigits(2...4)))) out", comment: "Discover detail completion rate")
            },
            row.providerPromptPayoutUSDPerMillionTokens.map {
                String(localized: "$\($0.formatted(.number.precision(.significantDigits(2...4)))) in", comment: "Discover detail prompt rate")
            },
        ].compactMap { $0 }
        if !rates.isEmpty {
            facts.append(Fact(label: String(localized: "Rate", comment: "Discover detail label"),
                              value: rates.joined(separator: " · ") + " " + String(localized: "per 1M tokens", comment: "Discover detail rate unit")))
            if let caveat = row.nonEarningDisclosure { facts.append(Fact(label: "", value: caveat, secondary: true)) }
        }
        var demand: [String] = []
        if let rank = row.demandRank { demand.append(String(localized: "rank \(rank)", comment: "Discover detail demand rank")) }
        if let count = row.readyProviderCount {
            demand.append(count == 1
                ? String(localized: "1 provider ready", comment: "Discover detail provider count")
                : String(localized: "\(count) providers ready", comment: "Discover detail provider count"))
        }
        if !demand.isEmpty {
            facts.append(Fact(label: String(localized: "Demand", comment: "Discover detail label"), value: demand.joined(separator: " · ")))
        }
        facts.append(Fact(label: String(localized: "Status", comment: "Discover detail label"), value: statusText(row)))
        // A catalog-only row's verdict repeats the status line.
        if !row.isCatalogOnly, row.category != .current, let verdict = row.earningVerdict {
            facts.append(Fact(label: "", value: verdict, secondary: true))
        }
        // R013 item 2: a row with no typed action states why.
        if primaryAction(row) == PrimaryAction.none,
           let reason = ModelsPresentation.reason(row), reason != row.nonEarningDisclosure {
            facts.append(Fact(label: "", value: reason, secondary: true))
        }
        return facts
    }

    static func factLine(_ fact: Fact) -> String {
        fact.label.isEmpty ? fact.value : fact.label + ": " + fact.value
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

    /// The pinned card's lines: title, badge, one meta line.
    static func bestPickLines(_ row: MalibuModelRow, hostMemoryGB: Int) -> [String] {
        var lines = [bestPickTitle, ModelsPresentation.title(row)]
        if let badge = rowBadge(row, hostMemoryGB: hostMemoryGB) { lines.append(badge) }
        lines.append(rowMeta(row, hostMemoryGB: hostMemoryGB))
        return lines
    }

    static func screenStrings(
        rows: [MalibuModelRow],
        mode: ModelsHubTab = .browse,
        search: String = "",
        fitsOnly: Bool = true,
        sort: Sort = .bestMatch,
        hostMemoryGB: Int
    ) -> [String] {
        var strings = [String(localized: "Discover", comment: "Discover title")]
        let visible = ModelsHubPresentation.discoveryRows(for: mode, rows: rows, search: search, fitsOnly: fitsOnly, sort: sort)
        if catalogRows(rows).isEmpty {
            strings.append(emptyCatalog)
        } else if visible.isEmpty {
            strings.append(mode == .recommended ? emptyRecommended : emptyFilter)
        } else {
            strings.append(ModelsPresentation.rateDisclosure)
        }
        if mode == .recommended, let pick = bestPick(rows, hostMemoryGB: hostMemoryGB) {
            strings.append(contentsOf: bestPickLines(pick, hostMemoryGB: hostMemoryGB))
        }
        for row in visible {
            let badge = rowBadge(row, hostMemoryGB: hostMemoryGB).map { " [\($0)]" } ?? ""
            strings.append(ModelsPresentation.title(row) + badge + " — " + rowMeta(row, hostMemoryGB: hostMemoryGB))
        }
        if let first = visible.first {
            strings.append("[\(ModelsPresentation.title(first))]")
            strings.append(ModelsPresentation.name(first))
            strings.append(contentsOf: detailFacts(first, hostMemoryGB: hostMemoryGB).map(factLine))
        }
        if mode == .browse { strings.append(otherMLXTitle) }
        return strings
    }
}

struct DiscoverScreen: View {
    @ObservedObject var store: ModelManagementStore
    @ObservedObject var agent: MalibuAgent
    @State private var search = ""
    @State private var fitsOnly: Bool
    private let mode: ModelsHubTab
    let browseModels: (() -> Void)?
    @State private var sort: DiscoverPresentation.Sort = .bestMatch
    @State private var selectedID: String?
    @State private var switchRow: MalibuModelRow?
    @State private var pendingDownload: MalibuModelRow?
    @State private var otherQuery = ""
    @State private var otherExpanded = false

    init(store: ModelManagementStore, agent: MalibuAgent, mode: ModelsHubTab = .recommended, browseModels: (() -> Void)? = nil) {
        self.store = store
        self.agent = agent
        self.mode = mode
        self.browseModels = browseModels
        _fitsOnly = State(initialValue: mode == .recommended)
    }

    private var visible: [MalibuModelRow] {
        ModelsHubPresentation.discoveryRows(for: mode, rows: store.rows, search: search, fitsOnly: fitsOnly, sort: sort)
    }

    private var selected: MalibuModelRow? {
        DiscoverPresentation.selection(visible, selectedID: selectedID)
    }

    private var hostMemoryGB: Int { ModelsPresentation.hostMemoryGB }

    /// Recommended only. When the autotune recommendation callout is shown it
    /// is this Mac's pick (with its Adopt action), so the card stays hidden
    /// and the screen never shows two competing "best" models.
    private var bestPick: MalibuModelRow? {
        guard mode == .recommended else { return nil }
        if let recommendation = store.recommendation,
           DiscoverPresentation.showsRecommendation(recommendation.displayModelID, rows: store.rows) {
            return nil
        }
        let recommended = store.recommendation.flatMap { $0.isRecommendationResult ? $0.displayModelID : nil }
        return DiscoverPresentation.bestPick(store.rows, hostMemoryGB: hostMemoryGB, recommendedID: recommended)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
            ModelDownloadBanner(store: store)
                .padding(.horizontal, 20)
                .padding(.bottom, store.download == nil && store.downloadResult == nil ? 0 : 10)
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
            Text(mode.title)
                .font(.title2.weight(.semibold))
            Spacer()
            TextField(String(localized: "Search catalog", comment: "Discover search"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Picker(String(localized: "Sort", comment: "Discover sort label"), selection: $sort) {
                ForEach(DiscoverPresentation.Sort.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 200)
            if mode == .browse {
                Toggle(String(localized: "Fits this Mac", comment: "Discover fit filter"), isOn: $fitsOnly)
            }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(mode == .recommended ? DiscoverPresentation.emptyRecommended : DiscoverPresentation.emptyFilter)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if mode == .recommended, let browseModels {
                            Button("Browse all models", action: browseModels)
                                .accessibilityIdentifier("malibu.models.recommended.browse")
                        }
                    }
                    .padding(12)
                } else {
                    // SPEC-044-R004: visible once at the top of the scroll
                    // container that holds every rate.
                    Text(ModelsPresentation.rateDisclosure)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    if let pick = bestPick {
                        bestPickCard(pick)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    ForEach(visible) { row in
                        Button {
                            selectedID = row.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(ModelsPresentation.title(row))
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let badge = DiscoverPresentation.rowBadge(row, hostMemoryGB: hostMemoryGB) {
                                        badgeView(badge)
                                    }
                                }
                                Text(DiscoverPresentation.rowMeta(row, hostMemoryGB: hostMemoryGB))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected?.id == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The exact repo id stays one hover away and in the
                        // detail pane, not as a third line on every row.
                        .help(ModelsPresentation.name(row))
                        .accessibilityElement(children: .combine)
                        // SPEC-044-R014: the not-earning caveat travels in
                        // the row's accessibility label.
                        .accessibilityLabel(Text(DiscoverPresentation.rowAccessibilityLabel(row, hostMemoryGB: hostMemoryGB)))
                        .accessibilityAddTraits(selected?.id == row.id ? .isSelected : [])
                    }
                }
                if mode == .browse {
                    Divider().padding(.vertical, 6)
                    otherMLXSection
                        .padding(12)
                }
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
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(Array(DiscoverPresentation.detailFacts(row, hostMemoryGB: hostMemoryGB).enumerated()), id: \.offset) { _, fact in
                            GridRow {
                                Text(fact.label)
                                    .foregroundStyle(.secondary)
                                Text(fact.value)
                                    .font(fact.secondary ? Font.caption : Font.callout)
                                    .foregroundStyle(fact.secondary ? Color.secondary : Color.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.top, 4)
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
        if store.download?.modelKey == row.modelKey, row.action != .download {
            ModelDownloadControl(store: store, row: row, showsSize: true) {}
        }
        switch DiscoverPresentation.primaryAction(row) {
        case .serving:
            // The Status fact already says "Serving".
            EmptyView()
        case .switchModel:
            VStack(alignment: .leading, spacing: 4) {
                Button(String(localized: "Switch to this model…", comment: "Discover switch action")) { switchRow = row }
                    .disabled(!store.canPerformModelAction)
                Text(ModelsPresentation.switchingLine(listState: store.listState, warmSwapAvailable: store.warmSwapAvailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .download:
            // The confirmation dialog explains what Download does.
            ModelDownloadControl(store: store, row: row, showsSize: true) { pendingDownload = row }
        case .none:
            EmptyView()
        }
    }

    private func badgeView(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    /// The pinned pick: title, badge, one meta line and the row's own gated
    /// action (the same Switch sheet or Download confirmation as the list).
    private func bestPickCard(_ row: MalibuModelRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DiscoverPresentation.bestPickTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(ModelsPresentation.title(row))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let badge = DiscoverPresentation.rowBadge(row, hostMemoryGB: hostMemoryGB) {
                    badgeView(badge)
                }
            }
            Text(DiscoverPresentation.rowMeta(row, hostMemoryGB: hostMemoryGB))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch DiscoverPresentation.primaryAction(row) {
            case .switchModel:
                Button(String(localized: "Switch to this model…", comment: "Discover switch action")) { switchRow = row }
                    .disabled(!store.canPerformModelAction)
                    .padding(.top, 2)
            case .download:
                ModelDownloadControl(store: store, row: row, showsSize: true) { pendingDownload = row }
                    .padding(.top, 2)
            case .serving, .none:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.09)))
        .help(ModelsPresentation.name(row))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(DiscoverPresentation.bestPickTitle + ". " + DiscoverPresentation.rowAccessibilityLabel(row, hostMemoryGB: hostMemoryGB)))
        .accessibilityIdentifier("malibu.discover.bestPick")
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
