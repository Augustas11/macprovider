import Foundation
import Security

// AUDIT R1 SECURITY S1 / CODE H3 / ARCHITECT A3 fix, hardened in R2:
//
// Before opening the portal we generate a one-time nonce, hold it IN MEMORY
// (never on disk — see R2 SEC S1-R2 finding), and pass it in the portal URL
// as `state=<nonce>`. When the portal redirects back via
//   malibu://link?state=<nonce>&provider_id=<id>&token=<jwt>
// the app requires:
//   1. A pending nonce exists.
//   2. `state` matches it exactly (constant-time compare).
//   3. The app is NOT already configured — a second link callback while
//      configured is treated as an attack, not a legitimate rebind.
//
// The nonce is single-use: consumed on successful validation OR discarded
// on any failure. Old nonces older than `expirationSeconds` are also
// refused so a phishing URL from days ago cannot replay.
//
// R2 note: the R1 implementation persisted the nonce to
// ~/Library/Application Support/Malibu/pending-link.state with chmod 0600,
// which any process running as the same user could read. Same-user malware
// could then race the real callback and defeat S1. Keeping the nonce in
// memory means an app restart cancels an in-flight link — the user has to
// re-click "Continue in browser" to get a new nonce. That's a small UX
// regression vs. a real attacker capability.

enum PendingLinkState {
    private static let expirationSeconds: TimeInterval = 15 * 60 // 15 minutes

    private struct Pending {
        let nonce: String
        let createdAt: Date
    }

    // Access-guarded process-lifetime state. `nonisolated(unsafe)` opts out
    // of Swift-6 strict-concurrency for these two — we hand-serialize every
    // access through `lock`. NSLock is Sendable; the Pending struct is a
    // value type of immutable String + Date so escaping copies are safe.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: Pending?

    static func beginLink() throws -> String {
        let nonce = randomNonce(bytes: 32)
        lock.lock(); defer { lock.unlock() }
        pending = Pending(nonce: nonce, createdAt: Date())
        return nonce
    }

    enum ValidationError: Error, LocalizedError {
        case noPendingLink
        case expired
        case mismatch
        case alreadyConfigured
        var errorDescription: String? {
            switch self {
            case .noPendingLink:     return "No active link request. Open the portal from the app first."
            case .expired:           return "Link request expired. Please try again."
            case .mismatch:          return "Link callback did not match the request. Discarding for safety."
            case .alreadyConfigured: return "This Mac is already linked to a node. Uninstall first if you want to rebind."
            }
        }
    }

    static func consume(state received: String, appAlreadyConfigured: Bool) throws {
        lock.lock()
        let taken = pending
        // Always clear on any exit path — nonce is single-use even on failure.
        pending = nil
        lock.unlock()

        guard let taken else { throw ValidationError.noPendingLink }

        if appAlreadyConfigured {
            throw ValidationError.alreadyConfigured
        }
        let age = Date().timeIntervalSince(taken.createdAt)
        if age > expirationSeconds || age < 0 {
            throw ValidationError.expired
        }
        if !constantTimeEquals(taken.nonce, received) {
            throw ValidationError.mismatch
        }
    }

    static func discard() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
    }

    // MARK: - helpers

    private static func randomNonce(bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        if status != errSecSuccess {
            // Fallback — extraordinarily unlikely, but never emit a predictable nonce.
            for i in 0..<bytes { buf[i] = UInt8.random(in: 0...255) }
        }
        return buf.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        if ab.count != bb.count { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
