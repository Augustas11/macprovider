import ArgumentParser
import Foundation
import MacProviderCore

/// Issue #767 — offline-first provider diagnostics.
///
///     macprovider-cli doctor [--config PATH] [--json] [--offline]
///
/// The motivating failure: a build below the coordinator's
/// `required_binary_version` is closed with 4004 and (before #767) silently
/// reconnect-looped. An operator needed a way to ask "what version am I, what
/// does the coordinator demand, and am I above the line" WITHOUT a live
/// session. Everything except the last question is answered from local state,
/// so `doctor` is useful on a box that cannot reach the coordinator at all.
///
/// The reachable check reuses the coordinator's existing `/healthz`, which
/// publishes `recommended_binary_version` and (as of #767)
/// `required_binary_version`. No new coordinator endpoint was invented.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report this provider's binary version, coordinator endpoint, and version-floor standing."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Flag(help: "Emit a single JSON object instead of human-readable lines.")
    var json = false

    @Flag(help: "Skip the coordinator reachability + version-floor check entirely.")
    var offline = false

    @Option(help: "Seconds to wait for the coordinator /healthz probe.")
    var timeoutSeconds: Double = 3

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let report = await DoctorRunner(
            binaryVersion: CoordinatorClient.binaryVersion,
            coordinatorURL: resolved.coordinatorURL,
            providerID: resolved.providerID,
            configPath: resolved.configPath,
            offline: offline,
            fetch: DoctorRunner.liveFetch(timeout: timeoutSeconds)
        ).run()
        if json {
            DoctorReportPrinter.emitJSON(report)
        } else {
            DoctorReportPrinter.emitText(report)
        }
        // A build the coordinator would refuse is a real, actionable fault, so
        // doctor exits non-zero for it. Unreachable is NOT a fault: an
        // offline-first tool must not fail because the network is down.
        if report.floorStanding == .belowFloor {
            throw ExitCode(1)
        }
    }
}

/// The coordinator's published version standing for this binary.
enum DoctorFloorStanding: String, Equatable, Sendable {
    /// The coordinator was not consulted (--offline, or no usable URL).
    case notChecked = "not_checked"
    /// The coordinator could not be reached, or answered unusably.
    case unreachable
    /// The coordinator publishes no floor.
    case noFloorConfigured = "no_floor_configured"
    /// This binary satisfies the published floor.
    case aboveFloor = "above_floor"
    /// This binary is below the published floor — it will be closed with 4004.
    case belowFloor = "below_floor"
    /// A floor is published but one of the two versions could not be compared.
    case indeterminate
}

struct DoctorReport: Equatable, Sendable {
    let binaryVersion: String
    let configPath: String
    let coordinatorURL: String?
    let providerID: String?
    let healthzURL: String?
    let coordinatorVersion: String?
    let requiredBinaryVersion: String?
    let recommendedBinaryVersion: String?
    let floorStanding: DoctorFloorStanding
    let note: String?
}

/// What `/healthz` tells us. Kept separate from the transport so tests can
/// drive every branch without a network.
struct DoctorHealthz: Equatable, Sendable {
    let version: String?
    let requiredBinaryVersion: String?
    let recommendedBinaryVersion: String?
}

struct DoctorRunner: Sendable {
    let binaryVersion: String
    let coordinatorURL: String?
    let providerID: String?
    let configPath: String
    let offline: Bool
    /// Returns nil when the coordinator is unreachable or answers unusably.
    let fetch: @Sendable (URL) async -> DoctorHealthz?

    /// Derives the `/healthz` URL from the configured coordinator WebSocket URL.
    /// Copied from CoordinatorReadinessClient.readinessURL: reject embedded
    /// credentials, and permit plaintext only for loopback.
    static func healthzURL(coordinatorURL: String?) -> URL? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased()
        else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "wss", "https":
            components.scheme = "https"
        case "ws" where host == "localhost" || host == "127.0.0.1" || host == "::1",
             "http" where host == "localhost" || host == "127.0.0.1" || host == "::1":
            components.scheme = "http"
        default:
            return nil
        }
        components.path = "/healthz"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Compares this binary against a published floor. An unparseable version on
    /// either side is `indeterminate`, never a silent pass: doctor must not tell
    /// an operator they are fine when it could not actually check.
    static func standing(binaryVersion: String, requiredBinaryVersion: String?) -> DoctorFloorStanding {
        guard let required = requiredBinaryVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !required.isEmpty else {
            return .noFloorConfigured
        }
        guard isComparableVersion(binaryVersion), isComparableVersion(required) else {
            return .indeterminate
        }
        // Ordering itself is delegated to the CLI's existing comparator; this
        // adds only the strictness SelfUpdate.compareSemver lacks (it maps a
        // non-numeric component to 0 rather than reporting it).
        return SelfUpdate.compareSemver(binaryVersion, required) == .orderedAscending
            ? .belowFloor
            : .aboveFloor
    }

    /// Bare numeric version, 1-3 components, optional leading `v`. Matches what
    /// the coordinator accepts for `required_binary_version`.
    static func isComparableVersion(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^[vV]?[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil
    }

    func run() async -> DoctorReport {
        let url = Self.healthzURL(coordinatorURL: coordinatorURL)
        if offline {
            return report(url: url, healthz: nil, standing: .notChecked, note: "coordinator check skipped (--offline)")
        }
        guard let url else {
            return report(
                url: nil,
                healthz: nil,
                standing: .notChecked,
                note: coordinatorURL == nil
                    ? "no coordinator_url configured"
                    : "coordinator_url is not a usable https/wss endpoint"
            )
        }
        guard let healthz = await fetch(url) else {
            return report(url: url, healthz: nil, standing: .unreachable, note: "coordinator /healthz unreachable")
        }
        let standing = Self.standing(
            binaryVersion: binaryVersion,
            requiredBinaryVersion: healthz.requiredBinaryVersion
        )
        var note: String?
        switch standing {
        case .belowFloor:
            note = "this build is below the coordinator's required minimum; it will be closed with 4004 version_unsupported. Run 'macprovider-cli update'."
        case .indeterminate:
            note = "could not compare this binary version against the coordinator's floor"
        default:
            note = nil
        }
        return report(url: url, healthz: healthz, standing: standing, note: note)
    }

    private func report(
        url: URL?,
        healthz: DoctorHealthz?,
        standing: DoctorFloorStanding,
        note: String?
    ) -> DoctorReport {
        DoctorReport(
            binaryVersion: binaryVersion,
            configPath: configPath,
            coordinatorURL: coordinatorURL,
            providerID: providerID,
            healthzURL: url?.absoluteString,
            coordinatorVersion: healthz?.version,
            requiredBinaryVersion: healthz?.requiredBinaryVersion,
            recommendedBinaryVersion: healthz?.recommendedBinaryVersion,
            floorStanding: standing,
            note: note
        )
    }

    static func liveFetch(timeout: TimeInterval) -> @Sendable (URL) async -> DoctorHealthz? {
        { url in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = max(1, timeout)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = max(1, timeout)
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                return nil
            }
            return parseHealthz(data)
        }
    }

    static func parseHealthz(_ data: Data) -> DoctorHealthz? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return DoctorHealthz(
            version: string("version"),
            requiredBinaryVersion: string("required_binary_version"),
            recommendedBinaryVersion: string("recommended_binary_version")
        )
    }
}

enum DoctorReportPrinter {
    static func emitText(_ report: DoctorReport) {
        var lines: [String] = [
            "macprovider-cli doctor",
            "  binary_version:              \(report.binaryVersion)",
            "  config_path:                 \(report.configPath)",
            "  provider_id:                 \(report.providerID ?? "(unset)")",
            "  coordinator_url:             \(report.coordinatorURL ?? "(unset)")",
            "  coordinator_healthz:         \(report.healthzURL ?? "(not derivable)")",
            "  coordinator_version:         \(report.coordinatorVersion ?? "(unknown)")",
            "  required_binary_version:     \(report.requiredBinaryVersion ?? "(none published)")",
            "  recommended_binary_version:  \(report.recommendedBinaryVersion ?? "(none published)")",
            "  version_floor_standing:      \(report.floorStanding.rawValue)",
        ]
        if let note = report.note {
            lines.append("  note:                        \(note)")
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    static func emitJSON(_ report: DoctorReport) {
        var payload: [String: Any] = [
            "binary_version": report.binaryVersion,
            "config_path": report.configPath,
            "version_floor_standing": report.floorStanding.rawValue,
        ]
        payload["provider_id"] = report.providerID
        payload["coordinator_url"] = report.coordinatorURL
        payload["coordinator_healthz_url"] = report.healthzURL
        payload["coordinator_version"] = report.coordinatorVersion
        payload["required_binary_version"] = report.requiredBinaryVersion
        payload["recommended_binary_version"] = report.recommendedBinaryVersion
        payload["note"] = report.note
        let compacted = payload.compactMapValues { $0 }
        guard JSONSerialization.isValidJSONObject(compacted),
              var data = try? JSONSerialization.data(
                withJSONObject: compacted,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            FileHandle.standardOutput.write(Data("{\"binary_version\":\"\(report.binaryVersion)\"}\n".utf8))
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
