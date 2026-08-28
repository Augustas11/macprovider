import Foundation

/// SPEC-020-R005 accepted-but-stuck session recovery counter.
///
/// Tracks consecutive coordinator-recommendation forward-progress failures for
/// the *current* recommendation identity `(recommended_binary_version,
/// recommended_compatibility_set_id)`. A single failure cycle is EITHER one
/// recorded cooldown/failure for a recommended target OR one observation that the
/// recommendation yields no installable compatibility-set target (a missing
/// `recommended_compatibility_set_id`). Both kinds increment the same counter.
///
/// The provider becomes eligible to invoke the SPEC-020-R001 signed recovery rail
/// only once the count reaches `failureThreshold` (default 3) for the current
/// recommendation. The counter resets to zero when the recommendation identity
/// changes or the coordinator-recommendation path next makes forward progress, so
/// recovery eligibility never persists past the stuck condition.
///
/// This value type is the single place the R005 counter state lives; it is pure
/// and owned by `CoordinatorClient` (which serializes access via its actor
/// isolation and emits the R-6.8 observability events returned here).
struct AcceptedSessionRecoveryTracker {
    static let defaultFailureThreshold = 3

    let failureThreshold: Int
    private(set) var identity: String?
    private(set) var consecutiveFailureCount = 0

    init(failureThreshold: Int = AcceptedSessionRecoveryTracker.defaultFailureThreshold) {
        self.failureThreshold = max(1, failureThreshold)
    }

    /// True once the current recommendation has accumulated at least
    /// `failureThreshold` consecutive forward-progress failures.
    var isEligible: Bool { consecutiveFailureCount >= failureThreshold }

    enum IncrementReason: String, Equatable {
        /// The coordinator advertised a recommended version with no installable
        /// compatibility-set target.
        case missingTarget = "missing_target"
        /// A recorded target failure (compat mismatch, prepare/download, topology).
        case recordedFailure = "recorded_failure"
        /// An active discovery/target cooldown skipped the attempt.
        case cooldown
    }

    enum ResetReason: String, Equatable {
        case identityChanged = "identity_changed"
        case forwardProgress = "forward_progress"
    }

    /// Observability events (R-6.8) produced by a single `register` call, each
    /// carrying the counter value at the moment it was emitted.
    enum Event: Equatable {
        case increment(reason: IncrementReason, count: Int)
        case reset(reason: ResetReason, count: Int)
        case eligible(count: Int, threshold: Int)
    }

    struct Transition: Equatable {
        var events: [Event]
        var identity: String
        var count: Int
        var eligible: Bool
    }

    /// Fold a coordinator-recommendation outcome into the counter, returning the
    /// observability events the caller must emit and the resulting state.
    mutating func register(
        outcome: AutoUpdater.RecommendationOutcome,
        identity newIdentity: String
    ) -> Transition {
        var events: [Event] = []

        // Identity change resets the counter before the new outcome is applied:
        // a fresh recommendation starts its own consecutive-failure run.
        if identity != newIdentity {
            if consecutiveFailureCount != 0 {
                consecutiveFailureCount = 0
                events.append(.reset(reason: .identityChanged, count: 0))
            }
            identity = newIdentity
        }

        // Prior-eligibility is measured AFTER the identity reset so that a new
        // identity which arms within this same call (e.g. threshold == 1) still
        // emits a becoming-eligible event.
        let wasEligible = isEligible

        switch outcome {
        case .notAttempted:
            // Never engaged a real target: leave the counter unchanged.
            break
        case .forwardProgress:
            if consecutiveFailureCount != 0 {
                consecutiveFailureCount = 0
                events.append(.reset(reason: .forwardProgress, count: 0))
            }
        case .missingTarget:
            consecutiveFailureCount += 1
            events.append(.increment(reason: .missingTarget, count: consecutiveFailureCount))
        case .forwardProgressFailure:
            consecutiveFailureCount += 1
            events.append(.increment(reason: .recordedFailure, count: consecutiveFailureCount))
        case .cooldownActive:
            consecutiveFailureCount += 1
            events.append(.increment(reason: .cooldown, count: consecutiveFailureCount))
        }

        // Distinct becoming-eligible event, only on the transition into
        // eligibility (never re-emitted while the count stays at/above threshold).
        if !wasEligible, isEligible {
            events.append(.eligible(count: consecutiveFailureCount, threshold: failureThreshold))
        }

        return Transition(
            events: events,
            identity: newIdentity,
            count: consecutiveFailureCount,
            eligible: isEligible
        )
    }
}
