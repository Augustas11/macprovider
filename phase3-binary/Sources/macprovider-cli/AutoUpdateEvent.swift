import CryptoKit
import Foundation

enum AutoUpdateSource: String, CaseIterable, Sendable {
    case coordinator
    case githubPoll = "github_poll"
    case manual
}

enum AutoUpdateOutcome: String, CaseIterable, Sendable {
    case success
    case failure
    case skipped
    case noop
    case inProgress = "in_progress"
}

enum AutoUpdatePhase: String, CaseIterable, Sendable {
    case detection
    case eligibility
    case cooldown
    case freeSpace = "free_space"
    case download
    case signature
    case checksum
    case archive
    case selfTest = "self_test"
    case drain
    case backup
    case swap
    case restart
    case postStart = "post_start"
    case rollback
}

enum AutoUpdateFailureClass: String, CaseIterable, Sendable {
    case rollbackObserverUnavailable = "rollback_observer_unavailable"
    case unsupportedInstallTopology = "unsupported_install_topology"
    case targetReleaseNotFound = "target_release_not_found"
    case releaseAssetMissing = "release_asset_missing"
    case recommendedVersionInvalid = "recommended_version_invalid"
    case versionTooLong = "version_too_long"
    case versionComponentTooLong = "version_component_too_long"
    case autoupdateAlreadyPending = "autoupdate_already_pending"
    case orphanedPendingMarker = "orphaned_pending_marker"
    case orphanedSuccessSentinel = "orphaned_success_sentinel"
    case rollbackBackupCorrupt = "rollback_backup_corrupt"
    case targetRevokedOrBelowMinimum = "target_revoked_or_below_minimum"
    case signatureInvalid = "signature_invalid"
    case checksumMismatch = "checksum_mismatch"
    case selfTestFailed = "self_test_failed"
    case drainTimeout = "drain_timeout"
    case trustStateLost = "trust_state_lost"
    case postStartCrash = "post_start_crash"
    case postStartHealthFailed = "post_start_health_failed"
    case postStartRejoinTimeout = "post_start_rejoin_timeout"
    case insufficientDiskSpace = "insufficient_disk_space"
    case eventPayloadTooLarge = "event_payload_too_large"
    case other
}

struct AutoUpdateEvent: Sendable {
    static let maxWireBytes = 4096

    let updateID: String
    let currentVersion: String
    let targetVersion: String
    let source: AutoUpdateSource
    let phase: AutoUpdatePhase
    let outcome: AutoUpdateOutcome
    let reason: String
    let attempt: Int
    let timestamp: Date
    let failureClass: AutoUpdateFailureClass?
    let inflightRequests: Int?
    let recommendedBinaryVersionSHA256: String?
    let extraMetadata: [String: String]
    let attemptHistory: [String]
    let releaseURL: String?

    init(
        updateID: String,
        currentVersion: String,
        targetVersion: String,
        source: AutoUpdateSource = .coordinator,
        phase: AutoUpdatePhase,
        outcome: AutoUpdateOutcome,
        reason: String,
        attempt: Int,
        timestamp: Date = Date(),
        failureClass: AutoUpdateFailureClass? = nil,
        inflightRequests: Int? = nil,
        recommendedBinaryVersionSHA256: String? = nil,
        extraMetadata: [String: String] = [:],
        attemptHistory: [String] = [],
        releaseURL: String? = nil
    ) {
        self.updateID = updateID
        self.currentVersion = currentVersion
        self.targetVersion = targetVersion
        self.source = source
        self.phase = phase
        self.outcome = outcome
        self.reason = AutoUpdateEvent.redact(reason)
        self.attempt = attempt
        self.timestamp = timestamp
        self.failureClass = failureClass
        self.inflightRequests = inflightRequests
        self.recommendedBinaryVersionSHA256 = recommendedBinaryVersionSHA256
        self.extraMetadata = extraMetadata.mapValues(Self.redact)
        self.attemptHistory = attemptHistory.map(Self.redact)
        self.releaseURL = releaseURL.flatMap(Self.redactedURL)
    }

    func wireObject() -> [String: Any] {
        let minimalReason = reason.isEmpty ? "\(phase.rawValue)_\(outcome.rawValue)" : reason
        var object = baseObject(reason: minimalReason)
        object["extra_metadata"] = extraMetadata
        object["attempt_history"] = attemptHistory
        if let releaseURL {
            object["release_url"] = releaseURL
        }
        if Self.encodedByteCount(object) <= Self.maxWireBytes {
            return object
        }
        object.removeValue(forKey: "extra_metadata")
        if Self.encodedByteCount(object) <= Self.maxWireBytes {
            return object
        }
        object.removeValue(forKey: "attempt_history")
        if Self.encodedByteCount(object) <= Self.maxWireBytes {
            return object
        }
        object.removeValue(forKey: "release_url")
        if Self.encodedByteCount(object) <= Self.maxWireBytes {
            return object
        }
        object["reason"] = "\(phase.rawValue)_\(outcome.rawValue)"
        if Self.encodedByteCount(object) <= Self.maxWireBytes {
            return object
        }
        return [
            "event": "provider_autoupdate",
            "update_id": updateID,
            "current_version": currentVersion,
            "target_version": targetVersion,
            "source": source.rawValue,
            "phase": AutoUpdatePhase.eligibility.rawValue,
            "outcome": AutoUpdateOutcome.failure.rawValue,
            "reason": "event_payload_too_large",
            "attempt": attempt,
            "timestamp": Self.format(timestamp),
            "failure_class": AutoUpdateFailureClass.eventPayloadTooLarge.rawValue,
        ]
    }

    func emitLocal() {
        var object = wireObject()
        object["event"] = "provider_autoupdate"
        if var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            data.append(0x0A)
            FileHandle.standardError.write(data)
        }
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func baseObject(reason: String) -> [String: Any] {
        var object: [String: Any] = [
            "event": "provider_autoupdate",
            "update_id": updateID,
            "current_version": currentVersion,
            "target_version": targetVersion,
            "source": source.rawValue,
            "phase": phase.rawValue,
            "outcome": outcome.rawValue,
            "reason": reason,
            "attempt": attempt,
            "timestamp": Self.format(timestamp),
        ]
        if let failureClass {
            object["failure_class"] = failureClass.rawValue
        }
        if let inflightRequests {
            object["inflight_requests"] = inflightRequests
        }
        if let recommendedBinaryVersionSHA256 {
            object["recommended_binary_version_sha256"] = recommendedBinaryVersionSHA256
        }
        return object
    }

    private static func encodedByteCount(_ object: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: object, options: [])).map(\.count) ?? Int.max
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func redactedURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }

    private static func redact(_ value: String) -> String {
        var redacted = value
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(redacted.startIndex ..< redacted.endIndex, in: redacted)
            for match in detector.matches(in: redacted, options: [], range: range).reversed() {
                guard let url = match.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                components.path = ""
                components.query = nil
                components.fragment = nil
                components.user = nil
                components.password = nil
                if let hostOnly = components.string,
                   let swiftRange = Range(match.range, in: redacted)
                {
                    redacted.replaceSubrange(swiftRange, with: hostOnly)
                }
            }
        }
        let patterns = [
            #"(?i)authorization:\s*bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(token|password|secret|credential)=([^&\s]+)"#,
            #"/Users/[^ \n\t:]+"#,
            #"/private/(tmp|var)/[^ \n\t:]+"#,
            #"/tmp/[^ \n\t:]+"#,
            #"file://[^ \n\t]+"#,
            #"\b[0-9a-fA-F]{17,}\b"#,
            #"-----BEGIN [A-Z ]+PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+PRIVATE KEY-----"#,
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return redacted
    }
}

actor AutoUpdateEventStore {
    static let shared = AutoUpdateEventStore()
    private var last: AutoUpdateEvent?

    func record(_ event: AutoUpdateEvent) {
        last = event
        event.emitLocal()
    }

    func lastWireObject() -> [String: Any]? {
        last?.wireObject()
    }
}
