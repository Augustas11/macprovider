import Foundation

// malibu:// URL scheme handler.
//
// Supported endpoints (all ephemeral, portal-issued):
//   malibu://link?state=<nonce>&provider_id=<id>&token=<jwt-or-opaque>
//
// AUDIT R1 SECURITY S1 / CODE H3 / ARCHITECT A3 fix: `state` is now REQUIRED.
// The nonce must match the value we wrote via PendingLinkState.beginLink()
// before opening the portal, otherwise we refuse the payload. Nonce
// validation and the "already configured" check happen in `MalibuApp.consume`
// so this handler stays a pure URL parser.

enum URLSchemeHandler {
    enum Event {
        case providerLinked(state: String, providerID: String, token: String)
    }

    static func handle(_ url: URL, completion: @escaping (Event) -> Void) {
        guard url.scheme == "malibu",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }

        switch url.host {
        case "link":
            let items = components.queryItems ?? []
            guard
                let state = items.first(where: { $0.name == "state" })?.value,
                !state.isEmpty,
                let providerID = items.first(where: { $0.name == "provider_id" })?.value,
                let token = items.first(where: { $0.name == "token" })?.value
            else { return }
            completion(.providerLinked(state: state, providerID: providerID, token: token))
        default:
            break
        }
    }
}
