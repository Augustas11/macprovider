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

    // AUDIT R1 SECURITY S7 fix: surface unregister failures so the uninstall
    // path can report them instead of the app auto-launching on next login
    // while the user believed it was gone.
    static func unregisterReturningError() async -> Error? {
        do {
            try await SMAppService.mainApp.unregister()
            return nil
        } catch {
            // Was-never-registered is a legitimately-swallowed case; anything
            // else is residue the user should see.
            let ns = error as NSError
            if ns.domain == "SMAppServiceErrorDomain" && ns.code == 108 /* not registered */ {
                return nil
            }
            return error
        }
    }
}
