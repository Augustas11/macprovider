import CryptoKit
import Foundation

/// SPEC-023 §3.8 (SPEC-023-R028): the signed catalog release manifest.
///
/// `release.json` binds every feed of one catalog release by `sha256`,
/// `bytes`, `version` and `signer_key_id`; `release.json.sig` is one detached
/// Ed25519 signature over its exact bytes, served at `/v1/catalog-release`
/// (+ `.sig`). A feed body that a verified manifest binds is authenticated by
/// its digest, so its per-feed sidecar is not fetched. When no verified
/// manifest is available (an older coordinator or a release cut before §3.8),
/// every feed is verified by its per-feed sidecar exactly as before.
struct CatalogReleaseManifest: Equatable {
    struct Feed: Equatable {
        let sha256: String
        let bytes: Int
        let signerKeyID: String
        let version: String
    }

    enum Verdict: Equatable {
        /// The body is the bound feed; its signer is the manifest-bound key.
        case authenticated(signerKeyID: String)
        /// The manifest binds this feed to different bytes.
        case mismatch
        /// The manifest does not bind this feed.
        case unbound
    }

    static let schemaVersion = "macprovider.autotune-release.v1"
    static let routeName = "catalog-release"
    static let maxManifestBytes = 256 * 1024
    static let maxSignatureBytes = 16 * 1024
    /// The Tier-2 catalog is bound by digest but signed by its own Tier-2 key.
    static let tier2FeedName = "tier2-catalog.json"

    /// Served route name (`/v1/<name>`) to the name `release.json` binds.
    static let boundFeedNames: [String: String] = [
        "autotune-candidates": "autotune-candidates.json",
        "demand-rank": "demand-rank.json",
        "rate-card": "rate-card.json",
        "continuous-batching-policy": "continuous-batching-policy.json",
        "catalog-artifacts": "autotune-artifacts.json",
        "native-mtp-admission": "native-mtp-admission.json",
    ]

    let releaseID: String
    let signerKeyID: String
    let feeds: [String: Feed]

    func authenticate(routeName: String, body: Data) -> Verdict {
        guard let boundName = Self.boundFeedNames[routeName], let entry = feeds[boundName] else {
            return .unbound
        }
        guard entry.bytes == body.count, entry.sha256 == Self.sha256Hex(body) else {
            return .mismatch
        }
        return .authenticated(signerKeyID: entry.signerKeyID)
    }

    /// Verifies the detached signature over the exact manifest bytes, then
    /// parses the manifest as a closed document. Returns nil on any failure,
    /// which makes the caller fall back to per-feed sidecars.
    static func verified(
        manifestData: Data,
        signatureData: Data,
        trustedPublicKeys: [String: String]
    ) -> CatalogReleaseManifest? {
        guard manifestData.count <= maxManifestBytes, signatureData.count <= maxSignatureBytes,
              let keyID = verifySignature(payload: manifestData, sidecar: signatureData, trustedPublicKeys: trustedPublicKeys)
        else {
            return nil
        }
        return parse(manifestData, signerKeyID: keyID)
    }

    private static func verifySignature(payload: Data, sidecar: Data, trustedPublicKeys: [String: String]) -> String? {
        guard (try? AutotuneStrictJSON.rejectDuplicateKeys(sidecar)) != nil,
              let object = try? JSONSerialization.jsonObject(with: sidecar) as? [String: Any],
              Set(object.keys) == Set(["key_id", "alg", "signature"]),
              let keyID = object["key_id"] as? String,
              !keyID.isEmpty,
              keyID == keyID.trimmingCharacters(in: .whitespacesAndNewlines),
              object["alg"] as? String == "ed25519",
              let encodedSignature = object["signature"] as? String,
              let signature = Data(base64Encoded: encodedSignature),
              signature.count == 64,
              signature.base64EncodedString() == encodedSignature,
              let encodedPublicKey = trustedPublicKeys[keyID],
              let publicKeyBytes = Data(base64Encoded: encodedPublicKey),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == encodedPublicKey,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes),
              publicKey.isValidSignature(signature, for: payload)
        else {
            return nil
        }
        return keyID
    }

    private static func parse(_ data: Data, signerKeyID: String) -> CatalogReleaseManifest? {
        guard (try? AutotuneStrictJSON.rejectDuplicateKeys(data)) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["feeds", "generated_at", "policy_version", "release_id", "schema_version"]),
              root["schema_version"] as? String == schemaVersion,
              let releaseID = root["release_id"] as? String, !releaseID.isEmpty,
              let generatedAt = root["generated_at"] as? String, !generatedAt.isEmpty,
              let policyVersion = root["policy_version"] as? String, !policyVersion.isEmpty,
              let rawFeeds = root["feeds"] as? [String: Any], !rawFeeds.isEmpty
        else {
            return nil
        }
        var feeds: [String: Feed] = [:]
        for (name, value) in rawFeeds {
            guard let entry = value as? [String: Any],
                  Set(entry.keys) == Set(["bytes", "sha256", "signer_key_id", "version"]),
                  let bytesNumber = entry["bytes"] as? NSNumber,
                  CFGetTypeID(bytesNumber) != CFBooleanGetTypeID(),
                  let bytes = Int(exactly: bytesNumber.doubleValue), bytes > 0,
                  let sha256 = entry["sha256"] as? String, isLowerHex64(sha256),
                  let signer = entry["signer_key_id"] as? String, !signer.isEmpty,
                  let version = entry["version"] as? String, !version.isEmpty
            else {
                return nil
            }
            // One signature stands for every static feed, so each names the
            // manifest signer; only the Tier-2 catalog keeps its own key.
            if name != tier2FeedName, signer != signerKeyID {
                return nil
            }
            feeds[name] = Feed(sha256: sha256, bytes: bytes, signerKeyID: signer, version: version)
        }
        guard feeds["autotune-candidates.json"] != nil else { return nil }
        return CatalogReleaseManifest(releaseID: releaseID, signerKeyID: signerKeyID, feeds: feeds)
    }

    private static func isLowerHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds the last verified manifest per origin so one load fetches it once.
/// Shared by copies of `AutotuneStaticInputs` (a reference). A cached
/// manifest older than `reuseInterval` is refetched, and a digest mismatch
/// against a cached manifest refetches once, so a release rollover between
/// fetches never strands a long-lived caller on the previous manifest.
final class CatalogReleaseManifestSource: @unchecked Sendable {
    static let reuseInterval: TimeInterval = 60

    private struct Entry {
        let manifest: CatalogReleaseManifest?
        let fetchedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    fileprivate func cached(for origin: String, now: Date) -> CatalogReleaseManifest?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[origin],
              entry.fetchedAt <= now,
              now.timeIntervalSince(entry.fetchedAt) < Self.reuseInterval
        else {
            return nil
        }
        return .some(entry.manifest)
    }

    fileprivate func store(_ manifest: CatalogReleaseManifest?, for origin: String, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        entries[origin] = Entry(manifest: manifest, fetchedAt: now)
    }
}

extension AutotuneStaticInputs {
    /// SPEC-023 §3.8 verdict for one fetched feed body.
    enum ReleaseManifestCheck: Equatable {
        case authenticated(signerKeyID: String)
        /// A verified manifest binds this feed to other bytes: an integrity
        /// failure for the feed, exactly as a bad per-feed signature.
        case mismatch
        /// No verified manifest binds the feed: verify its per-feed sidecar.
        case unavailable
    }

    func fetchReleaseManifest(baseURL: URL) async -> CatalogReleaseManifest? {
        guard let manifestData = try? await fetch(Self.staticFeedURL(baseURL: baseURL, name: CatalogReleaseManifest.routeName)),
              let signatureData = try? await fetch(Self.staticFeedURL(baseURL: baseURL, name: CatalogReleaseManifest.routeName + ".sig"))
        else {
            return nil
        }
        return CatalogReleaseManifest.verified(
            manifestData: manifestData,
            signatureData: signatureData,
            trustedPublicKeys: trustedPublicKeys
        )
    }

    func checkReleaseManifest(routeName: String, body: Data, baseURL: URL) async -> ReleaseManifestCheck {
        let origin = baseURL.absoluteString
        var manifest: CatalogReleaseManifest?
        var fresh = false
        if let cached = releaseManifests.cached(for: origin, now: now()) {
            manifest = cached
        } else {
            manifest = await fetchReleaseManifest(baseURL: baseURL)
            releaseManifests.store(manifest, for: origin, at: now())
            fresh = true
        }
        guard let current = manifest else { return .unavailable }
        var verdict = current.authenticate(routeName: routeName, body: body)
        if verdict == .mismatch, !fresh {
            guard let refreshed = await fetchReleaseManifest(baseURL: baseURL) else {
                releaseManifests.store(nil, for: origin, at: now())
                return .unavailable
            }
            releaseManifests.store(refreshed, for: origin, at: now())
            verdict = refreshed.authenticate(routeName: routeName, body: body)
        }
        switch verdict {
        case .authenticated(let signerKeyID):
            return .authenticated(signerKeyID: signerKeyID)
        case .mismatch:
            return .mismatch
        case .unbound:
            return .unavailable
        }
    }
}
