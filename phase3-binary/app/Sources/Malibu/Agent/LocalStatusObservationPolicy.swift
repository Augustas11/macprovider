import Foundation

/// Bounds how long a trusted local `/v1/status` observation may still drive
/// Malibu's public ready/serving projection between background polls.
///
/// The CLI observation lease (`valid_for_ms`, typically 5000) is shorter than
/// Malibu's health/status refresh cadence. Without a display retention floor,
/// a healthy `buyer_serving` provider flickers Serving ↔ Connected.
enum LocalStatusObservationPolicy {
    /// Single source of truth for MalibuAgent health/status poll sleep.
    static let pollIntervalSeconds: TimeInterval = 15
    /// Margin beyond the poll interval so a healthy observation remains
    /// display-current until the next successful refresh.
    static let pollMarginSeconds: TimeInterval = 5

    static var pollIntervalNanoseconds: UInt64 {
        UInt64(pollIntervalSeconds * 1_000_000_000)
    }

    static var displayRetentionSeconds: TimeInterval {
        pollIntervalSeconds + pollMarginSeconds
    }

    static func effectiveValidForSeconds(reportedValidForMS: Int) -> TimeInterval {
        max(Double(reportedValidForMS) / 1_000.0, displayRetentionSeconds)
    }

    /// Bounded diagnostic when public status demotes solely because the
    /// observation retention window elapsed (not a harder failure).
    static let observationExpiryDiagnostic = "public_status_transition cause=status_observation_expired"
}

/// Tracks public short-status transitions and emits the bounded observation-
/// expiry diagnostic from any presentation path (menu bar, etc.).
@MainActor
enum PublicStatusTransitionDiagnostics {
    private static var lastShort: String?
    private static var lastDiagnosticAt: Date?

    static func resetForTests() {
        lastShort = nil
        lastDiagnosticAt = nil
    }

    /// Call whenever a snapshot is presented. Emits at most once per 60s when
    /// short status demotes Serving → Connected solely due to observation
    /// retention expiry while the last known network state is still
    /// `buyer_serving`.
    @discardableResult
    static func notePresentedSnapshot(_ snapshot: AgentSnapshot, now: Date = Date()) -> Bool {
        let short = AgentSnapshotPresenter.short(snapshot, at: now)
        defer { lastShort = short }
        guard let previous = lastShort, previous != short else { return false }

        let wasServingLabel = previous == "Serving" || previous.hasPrefix("$")
        let expiryDemotion = wasServingLabel
            && short == "Connected"
            && snapshot.state == .serving
            && snapshot.networkState == "buyer_serving"
            && snapshot.statusObservationFresh != false
            && !snapshot.isLocalStatusObservationCurrent(at: now)
        guard expiryDemotion else { return false }

        if let last = lastDiagnosticAt, now.timeIntervalSince(last) < 60 {
            return false
        }
        lastDiagnosticAt = now
        NSLog("[malibu] %@", LocalStatusObservationPolicy.observationExpiryDiagnostic)
        return true
    }
}
