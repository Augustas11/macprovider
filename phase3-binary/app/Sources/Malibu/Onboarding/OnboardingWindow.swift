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

    init(agent: MalibuAgent, onDone: @escaping () -> Void) {
        self.agent = agent
        self.onDone = onDone
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/macprovider-cli")
        _controller = StateObject(wrappedValue: LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: bundled,
            agent: agent
        ))
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
    }

    @ViewBuilder
    private var content: some View {
        switch controller.stage {
        case .idle:
            stageRow(title: "Ready", detail: "Installs the provider CLI, picks a model, and registers a background service.") {
                VStack(alignment: .leading, spacing: 8) {
                    launchButton(title: "Launch Provider")
                    Text("No wallet needed to start — add one anytime after.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .runningCLIInstall:
            stageRow(title: "Installing provider", detail: "Running the macprovider installer. This can take several minutes on first model download.") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView().controlSize(.small)
                    if !controller.installLogLines.isEmpty {
                        ScrollView {
                            Text(controller.installLogLines.suffix(12).joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 140)
                    }
                }
            }
        case .identityReady:
            stageRow(title: "Identity ready", detail: "Local provider identity created in Keychain.") {
                ProgressView().controlSize(.small)
            }
        case .registering:
            stageRow(title: "Registering", detail: "Requesting a provider token from the coordinator.") {
                ProgressView().controlSize(.small)
            }
        case .autotuning:
            stageRow(title: "Autotuning", detail: "Selecting the recommended local model.") {
                ProgressView().controlSize(.small)
            }
        case let .downloadingCLI(progress):
            stageRow(title: "Provider binary", detail: "Bundled provider binary is ready.") {
                ProgressView(value: progress)
            }
        case let .downloadingModel(name, progress):
            stageRow(title: "Model", detail: "Preparing \(name).") {
                ProgressView(value: progress)
                if let line = EarningsEstimateFormatter.line(
                    modelName: name,
                    range: controller.currentEarningsEstimate
                ) {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .startingAgent:
            stageRow(title: "Starting", detail: "Waiting for the background provider to become healthy.") {
                ProgressView().controlSize(.small)
            }
        case .authenticating:
            stageRow(title: "Authenticating", detail: "Completing provider authentication.") {
                ProgressView().controlSize(.small)
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
        case let .failed(_, retryable, message):
            stageRow(title: retryable ? "Needs retry" : "Setup paused", detail: message) {
                if retryable {
                    launchButton(title: "Retry")
                }
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
}
