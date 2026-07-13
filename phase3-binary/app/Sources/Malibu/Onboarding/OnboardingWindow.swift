import AppKit
import SwiftUI

// Onboarding is a plain NSWindow hosting a SwiftUI view so we can open it
// without a Scene, from an LSUIElement app that otherwise has no windows.

@MainActor
enum OnboardingWindow {
    static func make(agent: MalibuAgent, onDone: @escaping () -> Void) -> NSWindow {
        let root = OnboardingRootView(agent: agent, onDone: onDone)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Set up Malibu"
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct OnboardingRootView: View {
    @ObservedObject var agent: MalibuAgent
    let onDone: () -> Void
    @StateObject private var controller: LaunchProviderController
    // PROD-M6: gate the destructive "Start New" behind an explicit confirmation.
    @State private var showStartFreshConfirm = false

    init(agent: MalibuAgent, onDone: @escaping () -> Void) {
        self.agent = agent
        self.onDone = onDone
        _controller = StateObject(wrappedValue: LaunchProviderController(agent: agent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                MalibuBrandTile()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Malibu")
                        .font(.system(size: 13, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text("Earn from your Mac.")
                        .font(.system(size: 28, weight: .semibold))
                }
            }
            Text("Launch Provider installs and configures the macprovider CLI on this Mac.")
            Text("Malibu monitors the background provider and shows earnings here — setup runs via the same installer as the terminal path.")
                .foregroundStyle(.secondary)

            Divider()

            content
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 560)
        .task {
            // PROD-H6: an app-owned identity with a missing bearer takes over
            // the stage; skip the invite flow when it does.
            if await controller.evaluateExistingIdentityState() { return }
            await controller.refreshReferralPolicy()
            await controller.refreshFromExistingInstall()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.stage {
        case .idle:
            stageRow(
                title: controller.referralRequired ? "Invite-only pre-beta" : "Set up Malibu",
                detail: controller.referralRequired
                    ? "Enter an invite to install the provider CLI and register this Mac."
                    : "Install the provider CLI and register this Mac."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if let retired = controller.retiredIdentity {
                        retiredIdentityBanner(retired)
                    }
                    if controller.showsReferralField {
                        HStack(spacing: 8) {
                            TextField("MAL1-… or invite link", text: $controller.referralCode)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .accessibilityLabel("Malibu invite code")
                            Button("Paste code") {
                                if let value = NSPasteboard.general.string(forType: .string) {
                                    controller.referralCode = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                        }
                        if !controller.referralRequired {
                            // PROD-M3: policy is unknown/optional — the invite is
                            // not blocking; registration decides.
                            Text("Have an invite? Paste it here. Registration will confirm whether one is required.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !controller.normalizedReferralCode.isEmpty && !controller.referralCodeIsValid {
                            Text("That invite code does not match Malibu's expected format.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    launchButton(title: "Launch Provider")
                        .disabled(controller.referralRequired && !controller.referralCodeIsValid)
                    Text("No wallet needed to start — add one anytime after.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .runningCLIInstall:
            stageRow(
                title: "Installing provider",
                detail: controller.installProgressHint
                    ?? "Running the macprovider installer. Autotune and first model download can take 10–30 minutes with little log output."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        if let started = controller.installStartedAt {
                            Text("Elapsed \(formattedElapsed(since: started))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if !controller.installLogLines.isEmpty {
                        ScrollView {
                            Text(controller.installLogLines.suffix(20).joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
        case .startingAgent:
            stageRow(
                title: "Starting",
                detail: agent.providerStartFailure
                    ?? agent.snapshot.lastError
                    ?? "Waiting for the background provider to become healthy."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView().controlSize(.small)
                    if !agent.logLines.isEmpty {
                        ScrollView {
                            Text(agent.logLines.suffix(20).joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
        case .importingProviderIdentity:
            stageRow(
                title: "Importing provider identity",
                detail: "Saving the provider identity to Keychain before connecting Malibu."
            ) {
                ProgressView().controlSize(.small)
            }
        case let .existingIdentityMissingBearer(providerID):
            stageRow(
                title: "Provider credential missing",
                detail: "This Mac already has a Malibu provider identity"
                    + (providerID.isEmpty ? "" : " (\(providerID))")
                    + ", but its saved credential is gone. Recover it, or start over as a new provider."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if let notice = controller.recoveryNotice {
                        // PROD-H2: a prior recovery attempt could not restore the
                        // credential — say so and steer to Start New instead of
                        // looping on the recover button.
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(MalibuBrand.coral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(controller.recoveryNotice == nil ? "Recover this provider" : "Try recovery again") {
                        Task { await controller.recoverExistingIdentity() }
                    }
                    .prominentButton(controller.recoveryNotice == nil)
                    .tint(MalibuBrand.coral)
                    Text("Tries to restore the existing provider's credential. No new invite needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Button("Start as a new provider") {
                        showStartFreshConfirm = true
                    }
                    .prominentButton(controller.recoveryNotice != nil)
                    .tint(MalibuBrand.coral)
                    Text("Moves the existing provider aside and sets up a fresh one. This does not delete your earnings history, but the old provider identity is retired on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog(
                    "Retire this provider and start new?",
                    isPresented: $showStartFreshConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Retire and start new", role: .destructive) {
                        Task { await controller.startAsNewProvider() }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(startFreshConfirmationMessage(providerID: providerID))
                }
            }
        case let .live(model, tier):
            VStack(alignment: .leading, spacing: 16) {
                stageRow(title: "Provider live", detail: "Serving \(model). Trust tier: \(tier.rawValue).") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                HStack(spacing: 12) {
                    metric(title: "USDC", value: "$—")
                    metric(title: "MALIBU", value: "Locked", footnote: "Unlocks at Trusted")
                    Button("Add wallet") { }
                        .buttonStyle(.bordered)
                        .disabled(true)
                }
                Button("Open Dashboard") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .tint(MalibuBrand.coral)
            }
        case let .failed(stage, retryable, message):
            stageRow(title: retryable ? "Needs retry" : "Setup failed", detail: message) {
                if retryable {
                    if stage == "referral" || (stage == "cliInstall" && controller.referralRequired) {
                        // PROD-M2: when the server demanded an invite, entering a
                        // new invite code is required — not optional.
                        Text(stage == "referral" ? "Enter a new invite code" : "Change invite code")
                            .font(.caption.weight(.semibold))
                        TextField("MAL1-… or invite link", text: $controller.referralCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        // PROD-M6: no working inviter? Offer a non-authorizing
                        // request-access affordance.
                        Link("No working invite? Request access", destination: LaunchProviderController.requestAccessURL)
                            .font(.caption)
                    }
                    launchButton(title: "Retry")
                        .disabled(controller.referralRequired && (stage == "referral" || stage == "cliInstall") && !controller.referralCodeIsValid)
                }
            }
        }
    }

    // PROD-M6: name the affected provider, the identity/earnings consequence,
    // and where the bundle is archived so a destructive click is informed.
    private func startFreshConfirmationMessage(providerID: String) -> String {
        let subject = providerID.isEmpty ? "This Mac's provider identity" : "Provider \(providerID)"
        return "\(subject) will be archived under ~/.config/macprovider and retired on this Mac. "
            + "Your earnings history is not deleted, but this Mac stops serving under that identity until you restore it. "
            + "You can undo this immediately afterward while the archive is still on disk."
    }

    // PROD-M6: session-scoped undo affordance after a "Start New". The archive
    // stays on disk, so even after this session it can be restored manually from
    // the shown path.
    @ViewBuilder
    private func retiredIdentityBanner(_ retired: LaunchProviderController.RetiredIdentity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(retired.providerID.isEmpty
                ? "Previous provider retired and archived."
                : "Retired provider \(retired.providerID) and archived it.")
                .font(.caption.weight(.semibold))
            Text("Archive: \(retired.archivePath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            Button("Undo — restore the retired provider") {
                Task { await controller.undoStartAsNewProvider() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(MalibuBrand.sunnyYellow.opacity(0.15)))
    }

    @ViewBuilder
    private func stageRow<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.headline)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
            content()
        }
    }

    private func metric(title: String, value: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }

    private func launchButton(title: String) -> some View {
        Button {
            Task {
                if case .failed = controller.stage {
                    await controller.retry()
                } else {
                    await controller.launch()
                }
            }
        } label: {
            Text(title)
        }
        .buttonStyle(.borderedProminent)
        .tint(MalibuBrand.coral)
    }

    private func formattedElapsed(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private extension View {
    // A ternary over `.borderedProminent`/`.bordered` doesn't type-check
    // (distinct ButtonStyle types), so branch on the concrete style instead.
    @ViewBuilder
    func prominentButton(_ prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
