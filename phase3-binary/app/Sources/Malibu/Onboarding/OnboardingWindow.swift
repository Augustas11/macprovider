import AppKit
import SwiftUI

// Onboarding is a plain NSWindow hosting a SwiftUI view so we can open it
// without a Scene, from an LSUIElement app that otherwise has no windows.

@MainActor
enum OnboardingWindow {
    static func make(
        agent: MalibuAgent,
        replacementConfirmed: Bool = false,
        onDone: @escaping () -> Void
    ) -> NSWindow {
        let root = OnboardingRootView(
            agent: agent,
            replacementConfirmed: replacementConfirmed,
            onDone: onDone
        )
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

enum OnboardingCopy {
    static let intro = "Launch Provider installs and configures provider software on this Mac."
    static let introDetail = "Malibu monitors the background provider and shows earnings here while setup continues."
    static let idleDetail = "Installs provider software, picks a model, and registers this Mac for customer work."
    static let installingFallback = "Installing provider software. First model download and local checks can take 10-30 minutes with little visible progress."
    static let importingProviderAccess = "Confirming saved provider access before Malibu attaches."
    static let liveDetailPrefix = "Using"
    static let referralCaption = "Paste the code or malibu.tech/j#... link from the person who invited you. Malibu sends it once during setup and does not store the invite."
    static let referralChecking = "Checking provider software..."
    static let referralUnavailable = "Invite entry is unavailable with the currently installed provider software. Update Malibu and provider software, then check again."

    static func advancedFailureDiagnostics(
        message: String,
        installLogLines: [String],
        providerLogLines: [String]
    ) -> [String] {
        var details = [LogTailBuffer.redacted(message)]
        details.append(contentsOf: installLogLines.map(LogTailBuffer.redacted))
        details.append(contentsOf: providerLogLines.map(LogTailBuffer.redacted))
        return details.filter { !$0.isEmpty }
    }
}

private struct OnboardingRootView: View {
    @ObservedObject var agent: MalibuAgent
    let onDone: () -> Void
    @StateObject private var controller: LaunchProviderController

    init(agent: MalibuAgent, replacementConfirmed: Bool, onDone: @escaping () -> Void) {
        self.agent = agent
        self.onDone = onDone
        _controller = StateObject(
            wrappedValue: LaunchProviderController(
                agent: agent,
                replacementConfirmed: replacementConfirmed
            )
        )
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
            Text(OnboardingCopy.intro)
            Text(OnboardingCopy.introDetail)
                .foregroundStyle(.secondary)

            Divider()

            content
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 560)
        .task {
            await controller.refreshReferralInputAvailability()
            await controller.refreshFromExistingInstall()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.stage {
        case .idle:
            stageRow(title: "Ready", detail: OnboardingCopy.idleDetail) {
                VStack(alignment: .leading, spacing: 8) {
                    referralAvailability
                    launchButton(title: "Launch Provider")
                    Text("No wallet needed to start — add one anytime after.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .runningCLIInstall:
            stageRow(
                title: "Installing provider",
                detail: controller.installProgressHint
                    ?? OnboardingCopy.installingFallback
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
                    advancedLogDisclosure(lines: controller.installLogLines)
                }
            }
        case .startingAgent:
            stageRow(
                title: "Starting",
                detail: AgentSnapshotPresenter.publicErrorDetail(
                    agent.providerStartFailure ?? agent.snapshot.lastError
                )
                    ?? "Waiting for the background provider to become healthy."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView().controlSize(.small)
                    advancedLogDisclosure(lines: agent.logLines)
                }
            }
        case .importingProviderCredential:
            stageRow(
                title: "Confirming provider access",
                detail: OnboardingCopy.importingProviderAccess
            ) {
                ProgressView().controlSize(.small)
            }
        case let .live(model, _):
            VStack(alignment: .leading, spacing: 16) {
                stageRow(title: "Provider live", detail: "\(OnboardingCopy.liveDetailPrefix) \(model).") {
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
            stageRow(
                title: retryable ? "Needs retry" : "Setup failed",
                detail: AgentSnapshotPresenter.publicErrorDetail(message)
                    ?? "Details are available in Advanced diagnostics."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if stage == "referral" {
                        referralAvailability
                    }
                    if retryable {
                        launchButton(title: "Retry")
                    }
                    advancedFailureDisclosure(message: message)
                }
            }
        }
    }

    @ViewBuilder
    private func advancedLogDisclosure(lines: [String]) -> some View {
        if !lines.isEmpty {
            DisclosureGroup("Advanced diagnostics") {
                ScrollView {
                    Text(lines.suffix(20).map(LogTailBuffer.redacted).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
    }

    @ViewBuilder
    private func advancedFailureDisclosure(message: String) -> some View {
        let visibleDetails = OnboardingCopy.advancedFailureDiagnostics(
            message: message,
            installLogLines: controller.installLogLines,
            providerLogLines: agent.logLines
        )
        if !visibleDetails.isEmpty {
            DisclosureGroup("Advanced diagnostics") {
                ScrollView {
                    Text(visibleDetails.suffix(20).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
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

    private var referralField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Invite code (required for private pre-beta)")
                .font(.callout.weight(.medium))
            TextField("MAL1-S-… or invite link", text: $controller.referralInput)
                .textFieldStyle(.roundedBorder)
                .textContentType(.oneTimeCode)
                .disableAutocorrection(true)
            Text(OnboardingCopy.referralCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var referralAvailability: some View {
        if !controller.referralAvailabilityChecked {
            Text(OnboardingCopy.referralChecking)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if controller.referralInputAvailable {
            referralField
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(OnboardingCopy.referralUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check again") {
                    Task { await controller.refreshReferralInputAvailability() }
                }
                .buttonStyle(.link)
            }
        }
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
