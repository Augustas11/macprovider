import SwiftUI

/// Presentation destinations only; the shared store remains the authority for
/// catalog projections, switching and preparation transactions.
enum ModelsHubTab: String, CaseIterable, Identifiable {
    case recommended
    case browse
    case onThisMac
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: return String(localized: "Recommended", comment: "Models tab")
        case .browse: return String(localized: "Browse", comment: "Models tab")
        case .onThisMac: return String(localized: "On this Mac", comment: "Models tab")
        case .downloads: return String(localized: "Downloads", comment: "Models tab")
        }
    }
}

enum ModelsHubPresentation {
    static let emptyDownloads = String(localized: "No downloads yet. Choose a model in Recommended or Browse to download it.", comment: "Downloads empty state")

    static func rows(for tab: ModelsHubTab, rows: [MalibuModelRow]) -> [MalibuModelRow] {
        switch tab {
        case .recommended, .browse:
            return DiscoverPresentation.visibleRows(rows, search: "", fitsOnly: tab == .recommended, sort: .catalog)
        case .onThisMac: return ModelsPresentation.sections(rows).flatMap(\.rows)
        case .downloads: return []
        }
    }

    static func recentDownloads(_ history: [ModelActivityEntry]) -> [ModelActivityEntry] {
        Array(history.filter { $0.operation == "download" }.suffix(20).reversed())
    }
}

struct ModelsHubScreen: View {
    @ObservedObject var store: ModelManagementStore
    @ObservedObject var agent: MalibuAgent
    @Binding var selection: ModelsHubTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(String(localized: "Models", comment: "Models tab picker"), selection: $selection) {
                ForEach(ModelsHubTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(20)
            .accessibilityIdentifier("malibu.models.tabs")
            Divider()
            switch selection {
            case .recommended, .browse:
                DiscoverScreen(store: store, agent: agent, mode: selection)
                    // Filters and selection belong to each discovery mode.
                    .id(selection)
            case .onThisMac:
                ModelsScreen(store: store, agent: agent)
            case .downloads:
                downloads
            }
        }
        .accessibilityIdentifier("malibu.models.hub")
    }

    private var downloads: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(ModelsHubTab.downloads.title)
                    .font(.title2.weight(.semibold))
                // This control survives catalog expiry and row replacement,
                // preserving progress and cancellation for the active transaction.
                ModelDownloadBanner(store: store)
                let recent = ModelsHubPresentation.recentDownloads(store.history)
                if store.download == nil && store.downloadResult == nil && recent.isEmpty {
                    Text(ModelsHubPresentation.emptyDownloads)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("malibu.models.downloads.empty")
                }
                ForEach(recent) { entry in
                    ShellPanel {
                        Text(ModelsPresentation.readableTitle(entry.toModelID))
                            .font(.headline)
                        Text(ShellText.display(entry.toModelID))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text(ModelsPresentation.outcomeLabel(entry.outcome))
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("malibu.models.downloads")
    }
}
