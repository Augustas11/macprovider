import Foundation

/// Sparkle feed + Ed25519 public key for Malibu.app whole-bundle updates (SPEC-025 §3.3).
enum MalibuUpdateConfiguration {
    /// Immutable versioned DMG on the download bucket; `latest.dmg` redirects here for humans.
    static let versionedDownloadBaseURL = URL(string: "https://download.malibu.tech")!

    /// Sparkle appcast served beside `latest.dmg` on the same bucket.
    static let appcastURL = versionedDownloadBaseURL.appendingPathComponent("appcast.xml")

    /// Base64-encoded Ed25519 public key (32 bytes) for `SUPublicEDKey`.
    /// Private key lives in GitHub Actions secret `SPARKLE_EDDSA_PRIVATE_KEY` (base64 seed).
    /// Regenerate with `scripts/generate-sparkle-signing-key.sh` and rotate both together.
    static let publicEdKeyBase64 = "JkTDWnRJfOI3YIlpfJKvasWkxb0O1j/7ObGYiIA7big="

    static func releaseDownloadURL(tag: String) -> URL {
        versionedDownloadBaseURL.appendingPathComponent("Malibu-\(tag).dmg")
    }

    static func releaseNotesURL(tag: String, repository: String = "Augustas11/macprovider") -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!
    }
}
