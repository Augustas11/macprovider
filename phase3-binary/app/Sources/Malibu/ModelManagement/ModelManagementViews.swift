import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ModelFeatureUI {
    static let switchModel = String(localized: "Switch", comment: "Model feature action")
    static let settingsModels = String(localized: "Models", comment: "Model settings section")
    static let backgroundRecommendations = String(localized: "Background recommendations", comment: "Model settings toggle")
    static let backgroundExplanation = String(localized: "Malibu checks only when the provider advertises the isolated recommendation adapter and local conditions are safe. Manual model switching remains available.", comment: "Model settings explanation")
    static let activate = String(localized: "Run offer preflight", comment: "BYOM guided activation action")
    static let withdraw = String(localized: "Withdraw", comment: "BYOM withdraw action")
    static let proposeToPool = String(localized: "Propose to pool…", comment: "BYOM propose-to-pool action")
    static let localRuntimes = String(localized: "Local runtimes", comment: "BYOM adapter settings section")
}

struct ModelRowView: View {
    let row: MalibuModelRow
    let enabled: Bool
    let byomEnabled: Bool
    var downloadEnabled = false
    let poolEligibilityLine: String?
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
                Text(ModelsPresentation.title(row))
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let catalogVerifiedModelKey = row.catalogVerifiedModelKey {
                    // Present the coordinator-verified catalog identity as the
                    // authoritative name; the provider-reported display name is
                    // shown as clearly-labelled secondary text so it can never be
                    // mistaken for a catalog-verified identity.
                    Text(ShellText.display(catalogVerifiedModelKey))
                        .font(.caption.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(String(localized: "Provider-reported: \(ShellText.display(row.displayID))", comment: "Provider-reported model name shown under the catalog-verified identity"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text(ShellText.display(row.displayID))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                if let poolEligibilityLine {
                    Text(poolEligibilityLine)
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
                } else if row.action == .download {
                    Button(String(localized: "Download…", comment: "Model download action in details"), action: onAction)
                        .disabled(!downloadEnabled)
                } else if row.action == .evaluate {
                    Button(ModelFeatureUI.activate, action: onAction)
                        .disabled(!enabled)
                        .accessibilityLabel(Text(String(localized: "Evaluate \(ShellText.display(row.displayID))", comment: "Evaluation accessibility label")))
                }
                if row.canProposeToPool {
                    Button(ModelFeatureUI.proposeToPool, action: onPropose)
                        .disabled(!byomEnabled)
                        .accessibilityLabel(Text(String(localized: "Propose \(ShellText.display(row.displayID)) to a Trusted Pool", comment: "Propose accessibility label")))
                }
                if row.canWithdraw {
                    Button(ModelFeatureUI.withdraw, role: .destructive, action: onWithdraw)
                        .disabled(!byomEnabled)
                        .accessibilityLabel(Text(String(localized: "Withdraw the offer for \(ShellText.display(row.displayID))", comment: "Withdraw accessibility label")))
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
struct PoolProposeSheet: View {
    let row: MalibuModelRow
    @Binding var poolID: String
    let onPropose: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Propose to a Trusted Pool", comment: "Propose sheet title"))
                .font(.title3.weight(.semibold))
            Text(ShellText.display(row.displayID))
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
struct PoolProposalResultSheet: View {
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
