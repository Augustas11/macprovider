import SwiftUI

/// Settings › Payout wallet (#2029 P1-16). Changing the wallet lives here,
/// not on the dashboard, and the cooling-off rule is stated before the user
/// opens the signer.
struct PayoutWalletSettingsSection: View {
    @ObservedObject var agent: MalibuAgent
    @State private var showWalletSheet = false

    static let coolingOffNotice = "Changing the payout wallet starts a cooling-off period. Payouts cannot go to the new address until it ends."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payout wallet")
                .font(.headline)
            if let address = agent.snapshot.payoutRegisteredAddress {
                Text(address)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let pending = agent.snapshot.payoutPendingUntilUTC,
                   let end = Self.parseUTC(pending), end > Date() {
                    Text("Cooling off until \(end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No payout wallet is registered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(Self.coolingOffNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agent.snapshot.payoutsEnabled == false {
                Text("Payouts are not enabled yet in beta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(agent.snapshot.payoutRegisteredAddress == nil ? "Add wallet…" : "Change wallet…") {
                showWalletSheet = true
            }
            .disabled(agent.snapshot.payoutRegistrationInProgress || agent.snapshot.localProviderID == nil)
            if let status = agent.snapshot.payoutLastStatus, agent.snapshot.payoutLastError == nil {
                Text(status == "rotated" ? "Wallet rotated." : "Wallet registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showWalletSheet) {
            AddWalletSheet(agent: agent, isPresented: $showWalletSheet)
        }
    }

    static func parseUTC(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// Settings window content: payout wallet (when a provider is attached) and
/// the existing model settings.
struct MalibuSettingsView: View {
    let agent: MalibuAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let agent {
                PayoutWalletSettingsSection(agent: agent)
                    .padding([.horizontal, .top], 20)
            }
            ModelSettingsView()
        }
    }
}
