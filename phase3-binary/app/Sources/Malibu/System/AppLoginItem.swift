import Foundation
import ServiceManagement

@MainActor
enum AppLoginItem {
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func register() throws {
        try SMAppService.mainApp.register()
    }

    static func unregister() async {
        do {
            try await SMAppService.mainApp.unregister()
        } catch {
            // If the service was never registered, macOS returns an error we can swallow.
        }
    }
}
