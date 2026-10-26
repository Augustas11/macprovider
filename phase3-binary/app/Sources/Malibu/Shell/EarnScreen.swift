import SwiftUI

/// Earn retains the Dashboard cards and exposes the complete R007 details on demand.
struct EarnScreen: View {
    @ObservedObject var agent: MalibuAgent
    let navigate: (MalibuSection) -> Void
    let browseModels: () -> Void
    let onThisMacModels: () -> Void
    let onExportDiagnostics: () -> Void
    let onResetProvider: () -> Void

    var body: some View {
        dashboard.accessibilityIdentifier("malibu.earn")
    }

    var dashboard: DashboardView {
        DashboardView(
            agent: agent,
            navigate: navigate,
            onExportDiagnostics: onExportDiagnostics,
            onResetProvider: onResetProvider,
            browseModels: browseModels,
            onThisMacModels: onThisMacModels,
            includesProviderDetails: true
        )
    }
}
