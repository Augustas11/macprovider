import SwiftUI

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
    @State private var showLocalActivationConfirmation = false
    @State private var pendingAdmission: MalibuModelRow?
    @State private var showAdmissionConfirmation = false
    @State private var retryAdmission = false
    @State private var pendingCleanup: MalibuModelCatalogEconomicsDocument.Recovery?
    @State private var showCleanupConfirmation = false

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

            if store.catalogVerificationInProgress {
                HStack {
                    ProgressView()
                    Text(String(localized: "Verified bytes: \(store.catalogVerifiedBytes)", comment: "Local verification byte progress"))
                    Button(String(localized: "Stop verification", comment: "Stop owned local verification")) { store.stopCatalogVerification() }
                }
            }
            if store.catalogReadWaitingForExit {
                Text(String(localized: "Verification stopped; waiting for the reader to exit", comment: "Read child reclamation"))
            }
            if store.catalogResourcePreparationInProgress {
                HStack {
                    ProgressView()
                    Button(String(localized: "Stop preparation", comment: "Abandon resource preparation")) { store.cancelCatalogPreparation() }
                }
            }
            if store.pendingCatalogTransaction != nil {
                if store.catalogTransactionCancelRequested {
                    Text(String(localized: "Cancellation is pending until the provider confirms the outcome.", comment: "Cancellation pending disclosure"))
                        .font(.caption)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack {
                    ProgressView()
                    Button(String(localized: "Cancel operation", comment: "Transaction cancel button")) {
                        Task { await store.requestCatalogCancellation() }
                    }
                    .accessibilityHint(Text(String(localized: "Requests cancellation from the provider. A completed commit cannot be undone.", comment: "Transaction cancellation hint")))
                    Button(String(localized: "Check status", comment: "Transaction status button")) {
                        Task { await store.reconcileCatalogTransaction() }
                    }
                }
            }

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
            } else if store.rows.isEmpty && store.cleanupRecoveries.isEmpty {
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
                        if !store.cleanupRecoveries.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "Staging cleanup", comment: "Independent cleanup section")).font(.headline)
                                ForEach(store.cleanupRecoveries) { recovery in
                                    HStack {
                                        Text(recovery.targetModelID).font(.caption.monospaced()).textSelection(.enabled)
                                        Spacer()
                                        Button(String(localized: "Clean up staging", comment: "Independent cleanup action")) {
                                            pendingCleanup = recovery
                                            showCleanupConfirmation = true
                                        }
                                        .disabled(!store.canPerformCleanupRecovery)
                                        .accessibilityIdentifier(recovery.id)
                                    }
                                }
                            }
                        }
                        section(ModelFeatureUI.current, category: .current)
                        section(store.rows.contains(where: { $0.localActivation && $0.category == .ready })
                            ? String(localized: "Prepared models", comment: "Prepared models section") : ModelFeatureUI.ready, category: .ready)
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
            String(localized: "Confirm model action", comment: "Model confirmation title"),
            isPresented: $showConfirmation
        ) {
            Button(pendingOperationName == "revert"
                   ? ModelFeatureUI.revert
                   : (pendingSwitch?.catalogActionLabel ?? ModelFeatureUI.switchModel)) {
                if let row = pendingSwitch {
                    Task {
                        if row.catalogTransaction != nil { await store.performCatalogAction(row, confirmed: true) }
                        else { await store.switchTo(row, operationName: pendingOperationName) }
                    }
                }
            }
            Button(String(localized: "Cancel", comment: "Switch confirmation cancel"), role: .cancel) {}
        } message: {
            Text(confirmationMessage(for: pendingSwitch))
        }
        .confirmationDialog(String(localized: "Confirm local activation", comment: "Local activation title"), isPresented: $showLocalActivationConfirmation) {
            Button(String(localized: "Activate locally", comment: "Local activation action")) {
                Task { await store.adoptRecommendation() }
            }
            Button(String(localized: "Cancel", comment: "Activation cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Activate \(store.recommendation?.recommendedModel ?? "") using the verified signed MacProvider catalog and measured local recommendation. This changes the active model and does not authorize paid routing. Network admission and verified settlement remain separate.", comment: "Local activation confirmation"))
        }
        .confirmationDialog(String(localized: "Clean up staging", comment: "Cleanup confirmation title"), isPresented: $showCleanupConfirmation) {
            Button(String(localized: "Clean up staging", comment: "Cleanup confirmation action")) {
                if let recovery = pendingCleanup { Task { await store.performCleanupRecovery(recovery, confirmed: true) } }
            }
            Button(String(localized: "Cancel", comment: "Cleanup confirmation cancel"), role: .cancel) {}
        } message: {
            if let recovery = pendingCleanup { Text(store.cleanupConfirmation(recovery)) }
        }
        .confirmationDialog(String(localized: "Request network admission", comment: "Admission confirmation title"), isPresented: $showAdmissionConfirmation) {
            Button(String(localized: "Submit signed offer", comment: "Admission submit action")) {
                if let row = pendingAdmission { Task { await store.requestAdmission(for: row, confirmed: true, retry: retryAdmission) } }
            }
            Button(String(localized: "Cancel", comment: "Admission cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Submit \(pendingAdmission?.id ?? "") through the provider CLI. The coordinator independently checks admission and pricing. Submission does not establish settlement eligibility or credit.", comment: "Admission confirmation disclosure"))
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
            if !store.recommendationIsLocalActivation, let rationale = recommendation.displayRationale {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.recommendationIsLocalActivation {
                Text(String(localized: "Measured prepared model. Local activation does not authorize paid routing.", comment: "Local recommendation disclosure"))
                    .font(.callout)
            }
            ForEach(store.recommendationIsLocalActivation ? [] : recommendation.displayEvidenceLines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(localized: "Scope: signed catalog \(recommendation.inputs.candidateCatalogVersion) for \(recommendation.hardware.chip), \(recommendation.hardware.memoryGB) GB.", comment: "Recommendation evidence scope"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !store.recommendationIsLocalActivation, let prompt = recommendation.promptRateUSDPerMillionTokens,
               let completion = recommendation.completionRateUSDPerMillionTokens {
                Text(String(localized: "Estimated rates: prompt $\(prompt, format: .number.precision(.fractionLength(2...4))) / 1M; completion $\(completion, format: .number.precision(.fractionLength(2...4))) / 1M.", comment: "Recommendation estimated rates"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !store.recommendationIsLocalActivation, !recommendation.warnings.isEmpty {
                Text(String(localized: "Warnings: \(recommendation.warnings.joined(separator: ", "))", comment: "Recommendation warnings"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if recommendation.isRecommendationResult {
                    Button(ModelFeatureUI.adopt) {
                        if store.recommendationIsLocalActivation { showLocalActivationConfirmation = true }
                        else { Task { await store.adoptRecommendation() } }
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
                    ModelRowView(row: row, enabled: canAct) {
                        pendingSwitch = row
                        pendingOperationName = "switch"
                        showConfirmation = true
                    }
                    if row.needsLocalVerification {
                        Button(String(localized: "Verify local files", comment: "Verify exact local model")) { Task { await store.verifyLocalFiles(row) } }
                            .disabled(!store.canVerifyLocalFiles(row))
                    }
                    if row.category == .current && row.catalogModelKey != nil {
                        HStack {
                            Button(String(localized: "Request network admission", comment: "Admission action")) {
                                pendingAdmission = row
                                retryAdmission = false
                                showAdmissionConfirmation = true
                            }
                            .disabled(!store.canRequestAdmission(for: row))
                            Button(String(localized: "Retry qualification", comment: "Admission retry action")) {
                                pendingAdmission = row
                                retryAdmission = true
                                showAdmissionConfirmation = true
                            }
                            .disabled(!store.canRetryAdmission(for: row))
                            Button(String(localized: "Refresh admission", comment: "Admission refresh action")) {
                                Task { await store.refreshAdmission(for: row) }
                            }
                            .disabled(!store.canRefreshAdmission(for: row))
                        }
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
        if row.catalogTransaction != nil { return store.catalogConfirmation(for: row) }
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
                if let admission = row.admissionStatusLine {
                    Text(admission)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("model.admission.status")
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
            if row.action == .switchModel {
                Button(ModelFeatureUI.switchModel, action: onAction)
                    .disabled(!enabled)
                    .accessibilityHint(Text(String(localized: "Shows a confirmation before the provider changes its served model.", comment: "Switch accessibility hint")))
            } else if row.catalogTransaction != nil {
                Button(row.catalogActionLabel, action: onAction)
                    .disabled(!enabled)
                    .accessibilityLabel(Text("\(row.catalogActionLabel) \(row.displayID)"))
                    .accessibilityHint(Text(String(localized: "Shows the exact target, size, and trust source before confirmation.", comment: "Preparation accessibility hint")))
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
    @ObservedObject private var store = ModelManagementStore.shared

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
