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
    @State private var walletAddress: String = ""
    @State private var busy = false
    @State private var error: String?

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
            Text("Three quick steps and you're a node.")
                .foregroundStyle(.secondary)

            Divider()

            step(number: 1, title: "Link your node") {
                Button("Continue in browser") {
                    // AUDIT R1 SECURITY S1: generate a one-time nonce and pass
                    // it as `state=...`. The portal echoes it in the malibu://
                    // redirect and MalibuApp.consume rejects any callback that
                    // does not match this exact value.
                    let nonce: String
                    do { nonce = try PendingLinkState.beginLink() }
                    catch {
                        self.error = "Could not start link: \(error.localizedDescription)"
                        return
                    }
                    var comps = URLComponents(string: "https://portal.streamvc.live/onboard")!
                    comps.queryItems = [
                        URLQueryItem(name: "client", value: "mac"),
                        URLQueryItem(name: "state", value: nonce)
                    ]
                    guard let url = comps.url else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(MalibuBrand.coral)
            }

            step(number: 2, title: "Payout wallet address") {
                TextField("0x…", text: $walletAddress)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            step(number: 3, title: "Start earning") {
                Button {
                    Task { await finish() }
                } label: {
                    if busy { ProgressView().controlSize(.small) }
                    else { Text("Start earning") }
                }
                .buttonStyle(.borderedProminent)
                .tint(MalibuBrand.coral)
                .disabled(busy)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 560)
    }

    @ViewBuilder
    private func step<Content: View>(number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(MalibuBrand.coral).frame(width: 22, height: 22)
                    .overlay(Text("\(number)").font(.caption.bold()).foregroundStyle(MalibuBrand.cream))
                Text(title).font(.headline)
            }
            content().padding(.leading, 32)
        }
    }

    // AUDIT R3 CODE M2 fix: refuse to close the onboarding window or register
    // the login item unless the deep-link callback has actually landed AND
    // saved a matching Keychain token. Previously the user could click
    // "Start earning" before linking, the login item would register, the
    // onboarding window would close, and the app would sit in the menu bar
    // with no daemon running and no obvious next step.
    private func finish() async {
        busy = true
        defer { busy = false }
        guard await ProviderConfig.isConfigured else {
            self.error = "Not linked yet — click \"Continue in browser\" above and finish the portal step first."
            return
        }
        do {
            try AppLoginItem.register()
        } catch {
            self.error = "Login item registration failed: \(error.localizedDescription)"
            return
        }
        await agent.start()
        onDone()
    }
}
