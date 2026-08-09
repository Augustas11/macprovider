import SwiftUI

private enum ModelFeatureUI {
    static let model = String(localized: "Model", comment: "Model feature label")
    static let checking = String(localized: "Checking…", comment: "Model feature loading state")
    static let changeModel = String(localized: "Change Model…", comment: "Model feature entry button")
    static let modelSwitcher = String(localized: "Model switcher", comment: "Model feature sheet title")
    static let currentModel = String(localized: "Current model", comment: "Model feature header")
    static let current = String(localized: "Current", comment: "Model feature section")
    static let ready = String(localized: "Ready to switch", comment: "Model feature section")
    static let needsPreparation = String(localized: "Needs preparation", comment: "Model feature section")
    static let blocked = String(localized: "Blocked", comment: "Model feature section")
    static let history = String(localized: "Model activity", comment: "Model feature section")
    static let close = String(localized: "Close", comment: "Model feature dismiss button")
    static let switchModel = String(localized: "Switch", comment: "Model feature action")
    static let evaluate = String(localized: "Evaluate this model", comment: "Model feature action")
    static let revert = String(localized: "Revert", comment: "Model feature action")
    static let settingsModels = String(localized: "Models", comment: "Model settings section")
    static let backgroundRecommendations = String(localized: "Background recommendations", comment: "Model settings toggle")
    static let backgroundExplanation = String(localized: "Malibu checks only when the provider advertises the isolated recommendation adapter and local conditions are safe. Manual model switching remains available.", comment: "Model settings explanation")
    static let updateRequired = String(localized: "Recommendation checks require a provider update. Model switching is still available when the provider is running with warm swap.", comment: "Model recommendation capability state")

    static func operationLabel(_ raw: String) -> String {
        switch raw {
        case "revert": return String(localized: "Revert", comment: "Model history operation")
        case "adopt": return String(localized: "Adopt", comment: "Model history operation")
        default: return String(localized: "Switch", comment: "Model history operation")
        }
    }

    static func outcomeLabel(_ raw: String) -> String {
        switch raw {
        case "failed": return String(localized: "Failed", comment: "Model history outcome")
        default: return String(localized: "Success", comment: "Model history outcome")
        }
    }
}

struct ModelSwitcherSheet: View {
    @ObservedObject var store: ModelManagementStore
    @ObservedObject var agent: MalibuAgent
    @Binding var isPresented: Bool
    @State private var pendingSwitch: MalibuModelRow?
    @State private var pendingOperationName = "switch"
    @State private var showConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ModelFeatureUI.modelSwitcher)
                        .font(.title3.weight(.semibold))
                    Text(ModelFeatureUI.currentModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.currentModelID ?? agent.snapshot.currentModelID ?? ModelFeatureUI.checking)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(ModelFeatureUI.currentModel))
                }
                Spacer()
                Button(ModelFeatureUI.close) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }

            Text(store.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)

            if store.listState == .checking {
                ProgressView(ModelFeatureUI.checking)
                    .accessibilityLabel(Text(ModelFeatureUI.checking))
            } else if store.rows.isEmpty {
                Text(String(localized: "No supported models were returned by the provider.", comment: "Empty model catalog"))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section(ModelFeatureUI.current, category: .current)
                        section(ModelFeatureUI.ready, category: .ready)
                        section(ModelFeatureUI.needsPreparation, category: .needsPreparation)
                        section(ModelFeatureUI.blocked, category: .blocked)
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
                                        pendingSwitch = row
                                        pendingOperationName = "revert"
                                        showConfirmation = true
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
                        historyView
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 620)
        .confirmationDialog(
            String(localized: "Confirm model switch", comment: "Switch confirmation title"),
            isPresented: $showConfirmation
        ) {
            Button(pendingOperationName == "revert"
                   ? ModelFeatureUI.revert
                   : (pendingSwitch?.category == .ready ? ModelFeatureUI.switchModel : ModelFeatureUI.evaluate)) {
                if let row = pendingSwitch {
                    Task { await store.switchTo(row, operationName: pendingOperationName) }
                }
            }
            Button(String(localized: "Cancel", comment: "Switch confirmation cancel"), role: .cancel) {}
        } message: {
            Text(confirmationMessage(for: pendingSwitch))
        }
        .task(id: "\(agent.snapshot.localProviderID ?? "unknown"):\(agent.snapshot.statusObservationID ?? "unknown")") {
            await store.refresh(
                currentModelID: agent.snapshot.currentModelID,
                peer: MalibuModelPeerEvidence(snapshot: agent.snapshot)
            )
            store.startBackgroundCheckIfEligible(thermalState: agent.snapshot.thermalState)
        }
    }

    private var canAct: Bool {
        store.canPerformModelAction
    }

    @ViewBuilder
    private func section(_ title: String, category: MalibuModelRow.Category) -> some View {
        let matching = store.rows.filter { $0.category == category }
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(matching) { row in
                    ModelRowView(row: row, enabled: canAct) {
                        pendingSwitch = row
                        pendingOperationName = "switch"
                        showConfirmation = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyView: some View {
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(ModelFeatureUI.history).font(.headline)
                ForEach(store.history.prefix(5)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Model activity: \(ModelFeatureUI.operationLabel(entry.operation)), outcome: \(ModelFeatureUI.outcomeLabel(entry.outcome))", comment: "Model history operation and outcome"))
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

    private func confirmationMessage(for row: MalibuModelRow?) -> String {
        guard let row else {
            return String(localized: "No model is selected.", comment: "Switch confirmation empty state")
        }
        if row.category == .ready {
            return String(localized: "Switch from \(store.currentModelID ?? "the current model") to \(row.id). No download is expected; the provider may load the local weights while serving, then drain active work before committing the new model.", comment: "Ready model switch confirmation")
        }
        return String(localized: "This model needs preparation. An explicit recommendation check is required before adoption. No action will start until you confirm.", comment: "Preparation model confirmation")
    }
}

private struct ModelRowView: View {
    let row: MalibuModelRow
    let enabled: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayID)
                    .font(.body.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(row.categoryLabel)
                        Text(String(localized: "Fit: \(fitLabel(row.fit))", comment: "Model fit status"))
                    if let estimatedGB = row.estimatedGB {
                        let formattedSize = estimatedGB.formatted(.number.precision(.fractionLength(1)))
                        Text(String(localized: "Approximately \(formattedSize) GB", comment: "Model size"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let blockReason = row.blockReason {
                    Text(blockReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if row.action == .switchModel {
                Button(ModelFeatureUI.switchModel, action: onAction)
                    .disabled(!enabled)
                    .accessibilityHint(Text(String(localized: "Shows a confirmation before the provider changes its served model.", comment: "Switch accessibility hint")))
            } else if row.action == .evaluate {
                Button(ModelFeatureUI.evaluate, action: onAction)
                    .disabled(true)
                    .help(ModelFeatureUI.updateRequired)
                    .accessibilityLabel(Text(String(localized: "Evaluate \(row.displayID)", comment: "Evaluation accessibility label")))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }

    private func fitLabel(_ fit: String) -> String {
        switch fit {
        case "fits": return String(localized: "Fits", comment: "Model fit status")
        case "tight": return String(localized: "Tight fit", comment: "Model fit status")
        case "wont_fit": return String(localized: "Does not fit", comment: "Model fit status")
        default: return String(localized: "Fit unknown", comment: "Model fit status")
        }
    }
}

struct ModelSettingsView: View {
    @StateObject private var store = ModelManagementStore()

    var body: some View {
        Form {
            Section(ModelFeatureUI.settingsModels) {
                Toggle(
                    ModelFeatureUI.backgroundRecommendations,
                    isOn: Binding(
                        get: { store.backgroundRecommendationsEnabled },
                        set: { store.setBackgroundRecommendationsEnabled($0) }
                    )
                )
                Text(ModelFeatureUI.backgroundExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(store.recommendationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .accessibilityElement(children: .contain)
    }
}
