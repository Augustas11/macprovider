import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ModelFeatureUI {
    static let model = String(localized: "Model", comment: "Model feature label")
    static let checking = String(localized: "Checking…", comment: "Model feature loading state")
    static let changeModel = String(localized: "Change Model…", comment: "Model feature entry button")
    static let modelSwitcher = String(localized: "Model switcher", comment: "Model feature sheet title")
    static let currentModel = String(localized: "Current model", comment: "Model feature header")
    static let current = String(localized: "Current", comment: "Model feature section")
    static let ready = String(localized: "Ready to switch", comment: "Model feature section")
    static let networkCatalog = String(localized: "Network catalog", comment: "Model feature section")
    static let needsPreparation = String(localized: "Needs preparation", comment: "Model feature section")
    static let blocked = String(localized: "Blocked", comment: "Model feature section")
    static let history = String(localized: "Model activity", comment: "Model feature section")
    static let close = String(localized: "Close", comment: "Model feature dismiss button")
    static let retry = String(localized: "Retry", comment: "Model feature retry button")
    static let switchModel = String(localized: "Switch", comment: "Model feature action")
    static let evaluate = String(localized: "Evaluate this model", comment: "Model feature action")
    static let revert = String(localized: "Revert", comment: "Model feature action")
    static let settingsModels = String(localized: "Models", comment: "Model settings section")
    static let backgroundRecommendations = String(localized: "Background recommendations", comment: "Model settings toggle")
    static let backgroundExplanation = String(localized: "Malibu checks only when the provider advertises the isolated recommendation adapter and local conditions are safe. Manual model switching remains available.", comment: "Model settings explanation")
    static let updateRequired = String(localized: "Recommendation checks require a provider update. Model switching is still available when the provider is running with warm swap.", comment: "Model recommendation capability state")
    static let recommended = String(localized: "Recommended", comment: "Recommendation callout title")
    static let adopt = String(localized: "Adopt", comment: "Recommendation action")
    static let notNow = String(localized: "Not now", comment: "Recommendation snooze action")
    static let stopBackground = String(localized: "Stop background recommendations", comment: "Recommendation opt-out action")
    static let activate = String(localized: "Run offer preflight", comment: "BYOM guided activation action")
    static let withdraw = String(localized: "Withdraw", comment: "BYOM withdraw action")
    static let proposeToPool = String(localized: "Propose to pool…", comment: "BYOM propose-to-pool action")
    static let localRuntimes = String(localized: "Local runtimes", comment: "BYOM adapter settings section")

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
    @State private var pendingWithdraw: MalibuModelRow?
    @State private var proposeRow: MalibuModelRow?
    @State private var proposePoolID = ""

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

            if let recommendation = store.recommendation {
                recommendationCallout(recommendation)
            }

            if store.listState == .checking {
                ProgressView(ModelFeatureUI.checking)
                    .accessibilityLabel(Text(ModelFeatureUI.checking))
            } else if store.catalogProjectionRetryAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Model catalog unavailable. Warning: projection_unavailable.", comment: "Catalog projection unavailable"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(ModelFeatureUI.retry) {
                        Task { await refreshFromSnapshot() }
                    }
                    .accessibilityLabel(Text(String(localized: "Retry model catalog refresh", comment: "Catalog retry accessibility label")))
                }
            } else if store.rows.isEmpty {
                Text(String(localized: "No supported models were returned by the provider.", comment: "Empty model catalog"))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.rows.contains(where: { $0.providerCompletionPayoutUSDPerMillionTokens != nil }) {
                            Text(String(localized: "Catalog rates are informational. Final provider credit depends on eligible demand, uptime, accepted requests, trust state, routing, token mix, settlement, and active policy status.", comment: "Catalog economics disclosure"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        section(ModelFeatureUI.current, category: .current)
                        section(ModelFeatureUI.ready, category: .ready)
                        section(ModelFeatureUI.networkCatalog, category: .networkCatalog)
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
                   : (pendingSwitch?.category == .ready ? ModelFeatureUI.switchModel : ModelFeatureUI.activate)) {
                if let row = pendingSwitch {
                    Task {
                        if row.action == .switchModel {
                            await store.switchTo(row, operationName: pendingOperationName)
                        } else {
                            await store.activate(row)
                        }
                    }
                }
            }
            Button(String(localized: "Cancel", comment: "Switch confirmation cancel"), role: .cancel) {}
        } message: {
            Text(confirmationMessage(for: pendingSwitch))
        }
        .confirmationDialog(
            String(localized: "Withdraw this offer?", comment: "BYOM withdraw confirmation title"),
            isPresented: Binding(get: { pendingWithdraw != nil }, set: { if !$0 { pendingWithdraw = nil } })
        ) {
            Button(ModelFeatureUI.withdraw, role: .destructive) {
                if let row = pendingWithdraw {
                    Task { await store.withdraw(row) }
                }
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
        .task(id: "\(agent.snapshot.localProviderID ?? "unknown"):\(agent.snapshot.statusObservationID ?? "unknown")") {
            await refreshFromSnapshot()
        }
    }

    private var canAct: Bool {
        store.canPerformModelAction
    }

    private func refreshFromSnapshot() async {
        await store.refresh(
            currentModelID: agent.snapshot.currentModelID,
            peer: MalibuModelPeerEvidence(snapshot: agent.snapshot)
        )
        await store.startBackgroundCheckIfEligible(thermalState: agent.snapshot.thermalState)
    }

    private func recommendationCallout(_ recommendation: MalibuRecommendationDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recommendation.isRecommendationResult
                ? ModelFeatureUI.recommended
                : String(localized: "No installed model recommendation", comment: "No recommendation callout title"))
                .font(.headline)
            if let target = recommendation.displayModelID {
                Text(target)
                    .font(.body.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let rationale = recommendation.displayRationale {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(recommendation.displayEvidenceLines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(localized: "Scope: signed catalog \(recommendation.inputs.candidateCatalogVersion) for \(recommendation.hardware.chip), \(recommendation.hardware.memoryGB) GB.", comment: "Recommendation evidence scope"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let prompt = recommendation.promptRateUSDPerMillionTokens,
               let completion = recommendation.completionRateUSDPerMillionTokens {
                Text(String(localized: "Estimated rates: prompt $\(prompt, format: .number.precision(.fractionLength(2...4))) / 1M; completion $\(completion, format: .number.precision(.fractionLength(2...4))) / 1M.", comment: "Recommendation estimated rates"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !recommendation.warnings.isEmpty {
                Text(String(localized: "Warnings: \(recommendation.warnings.joined(separator: ", "))", comment: "Recommendation warnings"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if recommendation.isRecommendationResult {
                    Button(ModelFeatureUI.adopt) {
                        Task { await store.adoptRecommendation() }
                    }
                    .disabled(!store.canAdoptRecommendation)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(Text(String(localized: "The provider validates, applies, switches, and verifies this recommendation as one transaction.", comment: "Adopt accessibility hint")))
                    Button(ModelFeatureUI.notNow) {
                        store.snoozeRecommendation()
                    }
                }
                Button(ModelFeatureUI.stopBackground) { store.stopBackgroundRecommendations() }
            }
            if let unavailableReason = store.recommendationAdoptionUnavailableReason {
                Text(unavailableReason)
                    .font(.caption2)
                    .foregroundStyle(recommendation.isActionable ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.09)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func section(_ title: String, category: MalibuModelRow.Category) -> some View {
        let matching = store.rows.filter { $0.category == category }
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(matching) { row in
                    ModelRowView(
                        row: row,
                        enabled: canAct,
                        byomEnabled: store.canPerformBYOMAction,
                        poolBindingLine: store.poolBindings[row.id].map(row.poolBindingLine),
                        onAction: {
                            pendingSwitch = row
                            pendingOperationName = "switch"
                            showConfirmation = true
                        },
                        onWithdraw: { pendingWithdraw = row },
                        onPropose: {
                            proposePoolID = ""
                            proposeRow = row
                        }
                    )
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
        return String(localized: "Malibu will run evaluate, offer dry-run, and offer through provider CLI typed transactions. No action will start until you confirm.", comment: "BYOM guided activation confirmation")
    }
}

private struct ModelRowView: View {
    let row: MalibuModelRow
    let enabled: Bool
    let byomEnabled: Bool
    let poolBindingLine: String?
    let onAction: () -> Void
    let onWithdraw: () -> Void
    let onPropose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let earningVerdict = row.earningVerdict {
                    Text(earningVerdict)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("byom.earning-verdict")
                }
                if let catalogVerifiedModelKey = row.catalogVerifiedModelKey {
                    // Present the coordinator-verified catalog identity as the
                    // authoritative name; the provider-reported display name is
                    // shown as clearly-labelled secondary text so it can never be
                    // mistaken for a catalog-verified identity.
                    Text(catalogVerifiedModelKey)
                        .font(.body.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(String(localized: "Provider-reported: \(row.displayID)", comment: "Provider-reported model name shown under the catalog-verified identity"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(row.displayID)
                        .font(.body.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Text(row.categoryLabel)
                    if let admissionStateLabel = row.admissionStateLabel {
                        Text(admissionStateLabel)
                    }
                    Text(String(localized: "Fit: \(fitLabel(row.fit))", comment: "Model fit status"))
                    if let estimatedGB = row.estimatedGB {
                        let formattedSize = estimatedGB.formatted(.number.precision(.fractionLength(1)))
                        Text(String(localized: "Approximately \(formattedSize) GB", comment: "Model size"))
                    }
                    if let demandRank = row.demandRank {
                        Text(String(localized: "Network demand signal: rank \(demandRank)", comment: "Network demand signal"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let admissionStateMeaning = row.admissionStateMeaning {
                    Text(admissionStateMeaning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let poolBindingLine {
                    Text(poolBindingLine)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("byom.pool-binding")
                }
                if let earningDisclosure = row.earningDisclosure {
                    Text(earningDisclosure)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let economicsAccessibilityLabel = row.economicsAccessibilityLabel {
                    // Rates and the non-earning caveat are one accessibility
                    // element voiced as a single announcement, so a catalog_priced
                    // (non-settlement) row's rates can never be read by VoiceOver
                    // without the "No provider credit yet …" caveat. The visible
                    // rows keep their individual styling; children are ignored for
                    // accessibility in favour of the composed label.
                    VStack(alignment: .leading, spacing: 3) {
                        // Visible rate rows derive from the same economicsRateLines
                        // source as economicsAccessibilityLabel, so the shown copy
                        // and the VoiceOver announcement cannot drift apart.
                        ForEach(row.economicsRateLines, id: \.self) { rateLine in
                            Text(rateLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let nonEarningDisclosure = row.nonEarningDisclosure {
                            Text(nonEarningDisclosure)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(economicsAccessibilityLabel))
                    .accessibilityIdentifier("byom.economics.summary")
                }
                if let blockReason = row.blockReason {
                    Text(blockReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 6) {
                if row.action == .switchModel {
                    Button(ModelFeatureUI.switchModel, action: onAction)
                        .disabled(!enabled)
                        .accessibilityHint(Text(String(localized: "Shows a confirmation before the provider changes its served model.", comment: "Switch accessibility hint")))
                } else if row.action == .evaluate {
                    Button(ModelFeatureUI.activate, action: onAction)
                        .disabled(!enabled)
                        .accessibilityLabel(Text(String(localized: "Evaluate \(row.displayID)", comment: "Evaluation accessibility label")))
                }
                if row.canProposeToPool {
                    Button(ModelFeatureUI.proposeToPool, action: onPropose)
                        .disabled(!byomEnabled)
                        .accessibilityLabel(Text(String(localized: "Propose \(row.displayID) to a Trusted Pool", comment: "Propose accessibility label")))
                }
                if row.canWithdraw {
                    Button(ModelFeatureUI.withdraw, role: .destructive, action: onWithdraw)
                        .disabled(!byomEnabled)
                        .accessibilityLabel(Text(String(localized: "Withdraw the offer for \(row.displayID)", comment: "Withdraw accessibility label")))
                }
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
    @ObservedObject private var store = ModelManagementStore.shared
    @State private var adapterDraft = MalibuBYOMAdapterSettings()
    @State private var adapterMessage: String?

    var body: some View {
        Form {
            Section(ModelFeatureUI.localRuntimes) {
                TextField(String(localized: "llama.cpp model folder", comment: "BYOM adapter setting"), text: $adapterDraft.llamacppModelRoot, prompt: Text("/Users/me/models"))
                TextField(String(localized: "llama.cpp model file (optional)", comment: "BYOM adapter setting"), text: $adapterDraft.llamacppModelPath, prompt: Text("/Users/me/models/model.gguf"))
                TextField(String(localized: "llama.cpp server", comment: "BYOM adapter setting"), text: $adapterDraft.llamacppOrigin, prompt: Text("http://127.0.0.1:8080"))
                TextField(String(localized: "LM Studio server", comment: "BYOM adapter setting"), text: $adapterDraft.lmstudioOrigin, prompt: Text("http://127.0.0.1:1234"))
                TextField(String(localized: "OpenAI-compatible server", comment: "BYOM adapter setting"), text: $adapterDraft.openaiCompatibleOrigin, prompt: Text("http://127.0.0.1:8000"))
                Text(String(localized: "Malibu passes these to the provider CLI when it discovers, offers, withdraws, or proposes local models. Servers must be loopback (127.0.0.1 or ::1) with a port; folders and files must be absolute paths. Leave a field empty to keep the CLI default.", comment: "BYOM adapter settings explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(String(localized: "Save", comment: "BYOM adapter settings save")) {
                        do {
                            try store.setBYOMAdapterSettings(adapterDraft)
                            adapterDraft = store.byomAdapterSettings
                            adapterMessage = String(localized: "Saved.", comment: "BYOM adapter settings saved")
                        } catch {
                            adapterMessage = String(localized: "Not saved: use loopback servers with a port and absolute paths.", comment: "BYOM adapter settings invalid")
                        }
                    }
                    if let adapterMessage {
                        Text(adapterMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
        .onAppear { adapterDraft = store.byomAdapterSettings }
    }
}

/// #1816: collects the Trusted Pool id before `models propose` runs.
private struct PoolProposeSheet: View {
    let row: MalibuModelRow
    @Binding var poolID: String
    let onPropose: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Propose to a Trusted Pool", comment: "Propose sheet title"))
                .font(.title3.weight(.semibold))
            Text(row.displayID)
                .font(.body.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            Text(String(localized: "Malibu asks the provider CLI to hash the served model's files, submit the network offer, and build a proposal for the pool creator. The creator must sign it into the pool before it can become eligible to earn there; qualifying settled requests are still required while the pool requirements are met. It is pool-attested, not network-verified.", comment: "Propose sheet explanation"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Pool id", comment: "Propose pool id field"), text: $poolID, prompt: Text(String(localized: "22-character pool id", comment: "Propose pool id prompt")))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Propose cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Propose", comment: "Propose confirm"), action: onPropose)
                    .keyboardShortcut(.defaultAction)
                    .disabled(poolID.trimmingCharacters(in: .whitespacesAndNewlines).range(of: MalibuBYOMPoolBinding.poolIDPattern, options: .regularExpression) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// #1816: shows the `pool_model_proposal.v1` bundle for copy or export.
private struct PoolProposalResultSheet: View {
    let proposal: MalibuPoolProposalResult
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Pool proposal", comment: "Proposal sheet title"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "Send this to the creator of pool \(proposal.poolID). They add the licence, confirm paid serving and the price, and sign it as \(proposal.poolModelID). Until then this model is not eligible to earn on that pool; after signing, qualifying settled requests are still required while the pool requirements are met.", comment: "Proposal sheet explanation"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(proposal.bundleJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
            HStack {
                Button(String(localized: "Copy", comment: "Proposal copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(proposal.bundleJSON, forType: .string)
                }
                Button(String(localized: "Export…", comment: "Proposal export")) {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = "pool-model-proposal-\(proposal.poolID).json"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? Data(proposal.bundleJSON.utf8).write(to: url, options: .atomic)
                    }
                }
                Spacer()
                Button(String(localized: "Done", comment: "Proposal done"), action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
