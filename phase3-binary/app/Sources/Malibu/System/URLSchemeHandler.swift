import Foundation

// malibu:// URL scheme handler.
//
// Supported endpoints (all ephemeral, portal-issued):
//   malibu://link?state=<nonce>&provider_id=<id>&token=<jwt-or-opaque>
//
// State validation is TODO for P0.1 — for the skeleton we accept any well-formed URL.

enum URLSchemeHandler {
    enum Event {
        case providerLinked(providerID: String, token: String)
    }

    static func handle(_ url: URL, completion: @escaping (Event) -> Void) {
        guard url.scheme == "malibu",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }

        switch url.host {
        case "link":
            let items = components.queryItems ?? []
            guard
                let providerID = items.first(where: { $0.name == "provider_id" })?.value,
                let token = items.first(where: { $0.name == "token" })?.value
            else { return }
            completion(.providerLinked(providerID: providerID, token: token))
        default:
            break
        }
    }
}
