import Foundation

/// The origin and trust root of every SPEC-023 signed static feed the
/// provider fetches: candidate catalog, demand rank, rate card, CB policy,
/// artifact feed, native-MTP admission set, and native-MTP revocations.
///
/// Release builds always use the canonical production origin and the baked
/// keyring. A lab build (`DEBUG || MACPROVIDER_LAB_HARNESS`) may redirect all
/// of them to an isolated loopback coordinator signed by a throwaway test key,
/// so the enablement rehearsal exercises the production fetch and verify code
/// without the production signing key (SPEC-048 R014 rehearsal, #1770).
enum StaticFeedOrigin {
    static let production = URL(string: "https://coordinator.malibu.tech")!

    /// The base URL feed paths are resolved against (`<base>/v1/<name>`).
    static var base: URL {
        labOverride?.origin ?? production
    }

    /// True only for a lab build's loopback override origin; release builds
    /// accept nothing but https.
    static func isLabLoopback(_ url: URL) -> Bool {
        guard let override = labOverride else { return false }
        return url.scheme == override.origin.scheme
            && url.host == override.origin.host
            && url.port == override.origin.port
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    static let labOverride: LabStaticFeedOverride? = readLabStaticFeedOverride(
        ProcessInfo.processInfo.environment
    )
    #else
    static let labOverride: LabStaticFeedOverride? = nil
    #endif
}

/// A lab build's static-feed redirect. Release builds never construct one.
struct LabStaticFeedOverride: Equatable {
    let origin: URL
    let keyID: String
    let publicKeyBase64: String
}

#if DEBUG || MACPROVIDER_LAB_HARNESS
let labStaticFeedOriginKey = "MACPROVIDER_LAB_STATIC_FEED_ORIGIN"
let labStaticFeedKeyIDKey = "MACPROVIDER_LAB_STATIC_FEED_KEY_ID"
let labStaticFeedPublicKeyKey = "MACPROVIDER_LAB_STATIC_FEED_PUBLIC_KEY"

/// All three variables or none. The origin must be `http(s)://127.0.0.1:<port>`
/// with no path, so a lab override can never reach a remote host; the key
/// must be a raw 32-byte Ed25519 public key. Anything else is rejected
/// loudly on stderr and ignored, so a misconfigured lab run stays on the
/// production trust root and fails visibly instead of silently.
func readLabStaticFeedOverride(_ environment: [String: String]) -> LabStaticFeedOverride? {
    let values = [labStaticFeedOriginKey, labStaticFeedKeyIDKey, labStaticFeedPublicKeyKey].map { environment[$0] }
    guard values.contains(where: { $0 != nil }) else { return nil }
    guard let rawOrigin = values[0], let keyID = values[1], let publicKey = values[2],
          let origin = URL(string: rawOrigin),
          origin.scheme == "http" || origin.scheme == "https",
          origin.host == "127.0.0.1",
          origin.port != nil,
          origin.path.isEmpty || origin.path == "/",
          origin.query == nil, origin.fragment == nil, origin.user == nil, origin.password == nil,
          !keyID.isEmpty, keyID.utf8.count <= 128,
          keyID.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
          Data(base64Encoded: publicKey)?.count == 32
    else {
        FileHandle.standardError.write(Data(
            "event=lab_static_feed_override action=ignored reason=invalid_override\n".utf8
        ))
        return nil
    }
    var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
    components?.path = ""
    guard let normalized = components?.url else { return nil }
    FileHandle.standardError.write(Data(
        "event=lab_static_feed_override action=active origin=\(normalized.absoluteString) key_id=\(keyID)\n".utf8
    ))
    return LabStaticFeedOverride(origin: normalized, keyID: keyID, publicKeyBase64: publicKey)
}
#endif
