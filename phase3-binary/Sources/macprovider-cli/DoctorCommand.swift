import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

/// Issue #767 — offline-first provider diagnostics.
///
///     malibu-cli doctor [--config PATH] [--json] [--offline]
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

    @Argument(help: "Optional report mode. Use `report --json` for the SPEC-035 diagnostics report.")
    var mode: String?

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Flag(help: "Emit a single JSON object instead of human-readable lines.")
    var json = false

    @Flag(help: "Skip the coordinator reachability + version-floor check entirely.")
    var offline = false

    @Option(help: "Seconds to wait for the coordinator /healthz probe, or report localhost /v1/status probe.")
    var timeoutSeconds: Double = 3

    func run() async throws {
        if let mode {
            guard mode == "report" else {
                throw ValidationError("unknown doctor mode '\(mode)'")
            }
            try await runDiagnosticsReport()
            return
        }

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

    private func runDiagnosticsReport() async throws {
        guard json else {
            throw ValidationError("doctor report currently supports --json only")
        }
        let resolved: AppConfig
        do {
            resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        } catch {
            let report = DoctorDiagnosticsReportRunner.configLoadFailureReport(
                binaryVersion: CoordinatorClient.binaryVersion,
                localEvidence: .empty
            )
            DoctorDiagnosticsReportPrinter.emitJSON(report)
            throw ExitCode(Int32(report.exitCode))
        }
        let runner = DoctorDiagnosticsReportRunner(
            binaryVersion: CoordinatorClient.binaryVersion,
            config: resolved,
            offline: offline,
            timeoutSeconds: timeoutSeconds,
            statusFetch: { port, timeout in
                await DoctorDiagnosticsReportRunner.liveStatusFetch(port: port, timeout: timeout)
            },
            healthzFetch: DoctorRunner.liveFetch(timeout: timeoutSeconds),
            localEvidence: {
                DoctorLocalEvidenceCollector(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
                    .collect(config: resolved)
            }
        )
        let report = await runner.run()
        DoctorDiagnosticsReportPrinter.emitJSON(report)
        if report.exitCode != 0 {
            throw ExitCode(Int32(report.exitCode))
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
            note = "this build is below the coordinator's required minimum; it will be closed with 4004 version_unsupported. Run 'malibu-cli update'."
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
            "malibu-cli doctor",
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

enum DoctorDiagnosticsReportExit: Int, Sendable {
    /// JSON report emitted; fresh `/v1/status` says the provider is buyer-serving.
    case healthy = 0
    /// JSON report emitted; doctor contributed `serve_unresponsive` or version-floor evidence.
    case providerAttention = 1
    /// JSON report emitted, but fresh status owns the state or offline data is inconclusive.
    case unknown = 2
}

struct DoctorDiagnosticsReport: Equatable, Sendable {
    let createdAt: Date
    let binaryVersion: String
    let outcome: String
    let exitCode: Int
    let statusObservation: DoctorStatusObservation
    let versionFloorStanding: DoctorFloorStanding
    let localEvidence: DoctorLocalEvidence
    let findings: [DoctorDiagnosticFinding]
}

struct DoctorDiagnosticFinding: Equatable, Sendable {
    let signatureID: String
    let source: String
    let message: String
    let evidence: String?
    let observedAt: Date
}

struct DoctorStatusObservation: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case unavailable
        case stale
        case contractIncompatible = "contract_incompatible"
        case fresh
    }

    let state: State
    let networkState: String?
    let reason: String?
    let observedAt: Date?
    let validForMS: Int?
}

struct DoctorLocalEvidence: Equatable, Sendable {
    let autoUpdateEnabled: Bool
    let autoUpdateSource: String
    let pendingUpdatePhase: String?
    let pendingMarkerDeadline: String?
    let launchd: DoctorLaunchdEvidence
    let stat: [DoctorStatEvidence]
    let logs: DoctorLogEvidence
}

struct DoctorLaunchdEvidence: Equatable, Sendable {
    let providerPlist: DoctorPlistEvidence
    let legacyProviderPlist: DoctorPlistEvidence
    let providerLaunchctl: DoctorLaunchctlEvidence
}

struct DoctorPlistEvidence: Equatable, Sendable {
    let present: Bool
    let labelMatchesExpected: Bool?
    let programConfigured: Bool
}

struct DoctorLaunchctlEvidence: Equatable, Sendable {
    let available: Bool?
    let pid: Int?
    let reason: String?
}

struct DoctorStatEvidence: Equatable, Sendable {
    let name: String
    let present: Bool
    let ownerCurrentUser: Bool?
    let mode: String?
    let aclExtended: Bool?
}

struct DoctorLogEvidence: Equatable, Sendable {
    let provider: [String]
    let watchdog: [String]
}

extension DoctorLocalEvidence {
    static let empty = DoctorLocalEvidence(
        autoUpdateEnabled: true,
        autoUpdateSource: "unknown",
        pendingUpdatePhase: nil,
        pendingMarkerDeadline: nil,
        launchd: DoctorLaunchdEvidence(
            providerPlist: DoctorPlistEvidence(present: false, labelMatchesExpected: nil, programConfigured: false),
            legacyProviderPlist: DoctorPlistEvidence(present: false, labelMatchesExpected: nil, programConfigured: false),
            providerLaunchctl: DoctorLaunchctlEvidence(available: nil, pid: nil, reason: "config_load_failed")
        ),
        stat: [],
        logs: DoctorLogEvidence(provider: [], watchdog: [])
    )
}

struct DoctorDiagnosticsReportRunner: Sendable {
    static let schema = "malibu.provider-diagnostics.v2"
    static let schemaVersion = 2
    static let minimumReaderVersion = 1
    static let supportedLocalStatusReaderVersion = 1
    static let localStatusObservationCapability = "status_observation_v1"
    static let buyerServingAuthorityCapability = "buyer_serving_authority_v1"
    static let networkStateAllowlist: Set<String> = [
        "buyer_serving",
        "not_buyer_serving",
        "buyer_serving_unknown",
        "network_offline",
        "coordinator_unavailable",
        "safe_offline_fallback",
    ]

    let binaryVersion: String
    let config: AppConfig
    let offline: Bool
    let timeoutSeconds: TimeInterval
    let statusFetch: @Sendable (Int, TimeInterval) async -> [String: Any]?
    let healthzFetch: @Sendable (URL) async -> DoctorHealthz?
    let localEvidence: @Sendable () -> DoctorLocalEvidence

    func run(now: Date = Date()) async -> DoctorDiagnosticsReport {
        let timeout = max(0.05, timeoutSeconds.isFinite ? timeoutSeconds : 1)
        let status = Self.statusObservation(
            await statusFetch(config.port, timeout),
            now: now
        )
        let healthz = await healthz(now: now)
        let standing = DoctorRunner.standing(
            binaryVersion: binaryVersion,
            requiredBinaryVersion: healthz?.requiredBinaryVersion
        )
        let evidence = localEvidence()
        let findings = Self.findings(
            status: status,
            floorStanding: standing,
            localEvidence: evidence,
            now: now
        )
        let exit: DoctorDiagnosticsReportExit
        let outcome: String
        if !findings.isEmpty || standing == .belowFloor {
            exit = .providerAttention
            outcome = "provider_attention"
        } else if status.state == .fresh, status.networkState == "buyer_serving" {
            exit = .healthy
            outcome = "healthy"
        } else {
            exit = .unknown
            outcome = "unknown"
        }
        return DoctorDiagnosticsReport(
            createdAt: now,
            binaryVersion: binaryVersion,
            outcome: outcome,
            exitCode: exit.rawValue,
            statusObservation: status,
            versionFloorStanding: standing,
            localEvidence: evidence,
            findings: findings
        )
    }

    private func healthz(now _: Date) async -> DoctorHealthz? {
        guard !offline,
              let url = DoctorRunner.healthzURL(coordinatorURL: config.coordinatorURL) else {
            return nil
        }
        return await healthzFetch(url)
    }

    static func statusObservation(_ object: [String: Any]?, now: Date = Date()) -> DoctorStatusObservation {
        guard let object else {
            return DoctorStatusObservation(
                state: .unavailable,
                networkState: nil,
                reason: "status_fetch_unavailable",
                observedAt: nil,
                validForMS: nil
            )
        }
        let contract = object["local_status_contract"] as? [String: Any] ?? [:]
        let observation = object["observation"] as? [String: Any] ?? [:]
        let capabilities = Set((contract["capabilities"] as? [Any] ?? []).compactMap(Self.stringValue))
        let networkState = capabilities.contains(buyerServingAuthorityCapability)
            ? safeNetworkState(object["network_state"])
            : nil
        guard let version = intValue(contract["version"]),
              let minimumReaderVersion = intValue(contract["minimum_reader_version"]),
              version >= 1,
              minimumReaderVersion <= supportedLocalStatusReaderVersion,
              capabilities.contains(localStatusObservationCapability) else {
            return DoctorStatusObservation(
                state: .contractIncompatible,
                networkState: networkState,
                reason: "local_status_contract_incompatible",
                observedAt: nil,
                validForMS: nil
            )
        }
        let observedAt = stringValue(observation["observed_at"]).flatMap(parseISO8601)
        let validForMS = intValue(observation["valid_for_ms"])
        guard let id = stringValue(observation["id"]),
              !id.isEmpty,
              let observedAt,
              let validForMS,
              (1...60_000).contains(validForMS) else {
            return DoctorStatusObservation(
                state: .stale,
                networkState: networkState,
                reason: "status_observation_invalid",
                observedAt: observedAt,
                validForMS: validForMS
            )
        }
        let fresh = observedAt <= now.addingTimeInterval(1)
            && observedAt.addingTimeInterval(Double(validForMS) / 1_000) >= now
        return DoctorStatusObservation(
            state: fresh ? .fresh : .stale,
            networkState: networkState,
            reason: fresh ? nil : "status_observation_stale",
            observedAt: observedAt,
            validForMS: validForMS
        )
    }

    static func findings(
        status: DoctorStatusObservation,
        floorStanding: DoctorFloorStanding,
        localEvidence: DoctorLocalEvidence,
        now: Date
    ) -> [DoctorDiagnosticFinding] {
        guard status.state != .fresh else { return [] }
        return [
            DoctorDiagnosticFinding(
                signatureID: "serve_unresponsive",
                source: "doctor_report",
                message: "Provider serve status is unavailable to the doctor report.",
                evidence: evidenceString(status: status, floorStanding: floorStanding, localEvidence: localEvidence),
                observedAt: now
            )
        ]
    }

    private static func evidenceString(
        status: DoctorStatusObservation,
        floorStanding: DoctorFloorStanding,
        localEvidence: DoctorLocalEvidence
    ) -> String {
        var parts = [
            "status_observation=\(status.state.rawValue)",
            "version_floor_standing=\(floorStanding.rawValue)",
            "auto_update_enabled=\(localEvidence.autoUpdateEnabled)",
            "auto_update_source=\(localEvidence.autoUpdateSource)",
            "launchd.provider_plist.present=\(localEvidence.launchd.providerPlist.present)",
            "launchd.provider.loaded=\(localEvidence.launchd.providerLaunchctl.available.map(String.init) ?? "unknown")",
        ]
        if let reason = status.reason {
            parts.append("status_reason=\(reason)")
        }
        if let networkState = status.networkState {
            parts.append("network_state=\(networkState)")
        }
        if let phase = localEvidence.pendingUpdatePhase {
            parts.append("pending_update.phase=\(phase)")
        }
        if let pid = localEvidence.launchd.providerLaunchctl.pid {
            parts.append("launchd.provider.pid=\(pid)")
        }
        if let reason = localEvidence.launchd.providerLaunchctl.reason {
            parts.append("launchd.provider.reason=\(reason)")
        }
        if localEvidence.logs.provider.contains(where: Self.containsStaleLaunchAgentNeedle) {
            parts.append("provider_log.stale_launch_agent=true")
        }
        if localEvidence.logs.watchdog.contains(where: Self.containsAutoupdateACLNeedle) {
            parts.append("watchdog_log.autoupdate_acl_rejected=true")
        }
        return parts.joined(separator: "; ")
    }

    private static func containsStaleLaunchAgentNeedle(_ line: String) -> Bool {
        line.lowercased().contains(
            "provider process unhealthy: launchd service live.malibu.provider has no validated pid at"
        )
    }

    static func configLoadFailureReport(
        binaryVersion: String,
        localEvidence: DoctorLocalEvidence,
        now: Date = Date()
    ) -> DoctorDiagnosticsReport {
        DoctorDiagnosticsReport(
            createdAt: now,
            binaryVersion: binaryVersion,
            outcome: "unknown",
            exitCode: DoctorDiagnosticsReportExit.unknown.rawValue,
            statusObservation: DoctorStatusObservation(
                state: .unavailable,
                networkState: nil,
                reason: "config_load_failed",
                observedAt: nil,
                validForMS: nil
            ),
            versionFloorStanding: .notChecked,
            localEvidence: localEvidence,
            findings: []
        )
    }

    private static func containsAutoupdateACLNeedle(_ line: String) -> Bool {
        line.lowercased().contains("autoupdate recovery_error=acl_write_rejected:")
    }

    static func liveStatusFetch(port: Int, timeout: TimeInterval) async -> [String: Any]? {
        try? await LocalStatusClient.fetch(port: port, timeoutSeconds: timeout)
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func safeNetworkState(_ value: Any?) -> String? {
        guard let state = stringValue(value),
              networkStateAllowlist.contains(state) else {
            return nil
        }
        return state
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct DoctorLocalEvidenceCollector: @unchecked Sendable {
    let homeDirectory: URL
    let launchctl: @Sendable (String) -> DoctorLaunchctlEvidence

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchctl: @escaping @Sendable (String) -> DoctorLaunchctlEvidence = { label in
            DoctorLocalEvidenceCollector.launchctlEvidence(label: label)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.launchctl = launchctl
    }

    func collect(config: AppConfig) -> DoctorLocalEvidence {
        collect(autoUpdateEnabled: config.autoUpdateEnabled, legacyAutoupdateEnabled: config.autoupdateEnabled)
    }

    func collect(
        autoUpdateEnabled: Bool? = nil,
        legacyAutoupdateEnabled: Bool? = nil
    ) -> DoctorLocalEvidence {
        let autoupdate = Self.effectiveAutoUpdateEnabled(
            autoUpdateEnabled: autoUpdateEnabled,
            legacyAutoupdateEnabled: legacyAutoupdateEnabled
        )
        let pending = readPendingMarker()
        return DoctorLocalEvidence(
            autoUpdateEnabled: autoupdate.enabled,
            autoUpdateSource: autoupdate.source,
            pendingUpdatePhase: pending?.transactionState?.rawValue,
            pendingMarkerDeadline: pending?.markerDeadline,
            launchd: DoctorLaunchdEvidence(
                providerPlist: plistEvidence(providerPlistURL, expectedLabel: "live.malibu.provider"),
                legacyProviderPlist: plistEvidence(legacyProviderPlistURL, expectedLabel: "live.streamvc.macprovider"),
                providerLaunchctl: launchctl("live.malibu.provider")
            ),
            stat: [
                statEvidence(name: "home", url: homeDirectory),
                statEvidence(name: "autoupdate_root", url: autoupdateRoot),
                statEvidence(name: "provider_plist", url: providerPlistURL),
                statEvidence(name: "legacy_provider_plist", url: legacyProviderPlistURL),
            ],
            logs: DoctorLogEvidence(
                provider: Self.readRedactedTail(providerStderrLogURL) + Self.readRedactedTail(providerStdoutLogURL),
                watchdog: Self.readRedactedTail(watchdogLogURL)
            )
        )
    }

    private var autoupdateRoot: URL {
        homeDirectory.appendingPathComponent(".local/share/macprovider/autoupdate", isDirectory: true)
    }

    private var pendingURL: URL {
        autoupdateRoot.appendingPathComponent("pending.json")
    }

    private var providerPlistURL: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/live.malibu.provider.plist")
    }

    private var legacyProviderPlistURL: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
    }

    private var providerStdoutLogURL: URL {
        homeDirectory.appendingPathComponent("Library/Logs/macprovider/macprovider.out.log")
    }

    private var providerStderrLogURL: URL {
        homeDirectory.appendingPathComponent("Library/Logs/macprovider/macprovider.err.log")
    }

    private var watchdogLogURL: URL {
        homeDirectory.appendingPathComponent("Library/Logs/macprovider/watchdog.log")
    }

    private func readPendingMarker() -> AutoUpdatePendingMarker? {
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        return try? JSONDecoder().decode(AutoUpdatePendingMarker.self, from: data)
    }

    private func plistEvidence(_ url: URL, expectedLabel: String) -> DoctorPlistEvidence {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return DoctorPlistEvidence(present: false, labelMatchesExpected: nil, programConfigured: false)
        }
        let args = plist["ProgramArguments"] as? [String]
        let labelMatchesExpected = plist["Label"] as? String == expectedLabel
        return DoctorPlistEvidence(
            present: true,
            labelMatchesExpected: labelMatchesExpected,
            programConfigured: labelMatchesExpected && args?.first?.isEmpty == false
        )
    }

    private func statEvidence(name: String, url: URL) -> DoctorStatEvidence {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return DoctorStatEvidence(name: name, present: false, ownerCurrentUser: nil, mode: nil, aclExtended: nil)
        }
        return DoctorStatEvidence(
            name: name,
            present: true,
            ownerCurrentUser: info.st_uid == getuid(),
            mode: String(format: "%04o", info.st_mode & mode_t(0o7777)),
            aclExtended: Self.hasExtendedACL(url)
        )
    }

    static func effectiveAutoUpdateEnabled(
        autoUpdateEnabled: Bool?,
        legacyAutoupdateEnabled: Bool?
    ) -> (enabled: Bool, source: String) {
        if let autoUpdateEnabled {
            return (autoUpdateEnabled, "auto_update_enabled")
        }
        if let legacyAutoupdateEnabled {
            return (legacyAutoupdateEnabled, "autoupdate.enabled")
        }
        return (true, "default_enabled")
    }

    static func launchctlEvidence(label: String) -> DoctorLaunchctlEvidence {
        do {
            let target = "gui/\(getuid())/\(label)"
            let result = try SelfUpdate.runLaunchctlCommand(arguments: ["print", target], allowFailure: true, timeout: 1)
            if result.terminationStatus == 113,
               result.output.contains("Could not find service") {
                return DoctorLaunchctlEvidence(available: false, pid: nil, reason: "service_not_found")
            }
            guard result.terminationStatus == 0 else {
                return DoctorLaunchctlEvidence(available: nil, pid: nil, reason: "launchctl_exit_\(result.terminationStatus)")
            }
            return DoctorLaunchctlEvidence(
                available: !result.output.lowercased().contains("disabled = true"),
                pid: pid(fromLaunchctlPrint: result.output),
                reason: nil
            )
        } catch {
            return DoctorLaunchctlEvidence(available: nil, pid: nil, reason: "launchctl_unavailable")
        }
    }

    static func readRedactedTail(_ url: URL, maximumBytes: Int = 256 * 1024, maximumLines: Int = 400) -> [String] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              Int(info.st_nlink) == 1,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              hasNoExtendedACL(descriptor),
              info.st_size >= 0 else {
            return []
        }
        let start = max(off_t(0), info.st_size - off_t(maximumBytes))
        guard lseek(descriptor, start, SEEK_SET) >= 0 else { return [] }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bytes.count < maximumBytes {
            let count = read(descriptor, &buffer, min(buffer.count, maximumBytes - bytes.count))
            guard count >= 0 else { return [] }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard var text = String(data: bytes, encoding: .utf8) else { return [] }
        if start > 0, let firstNewline = text.firstIndex(where: \.isNewline) {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .suffix(maximumLines)
            .map { String(DoctorReportRedactor.redacted($0).prefix(8 * 1024)) }
    }

    private static func hasExtendedACL(_ url: URL) -> Bool? {
        errno = 0
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == 0 {
                return false
            }
            return nil
        }
        _ = acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT || errno == ENOTSUP
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return false
    }

    private static func pid(fromLaunchctlPrint output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("pid =") else { continue }
            return Int(trimmed.dropFirst("pid =".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

enum DoctorDiagnosticsReportPrinter {
    static func emitJSON(_ report: DoctorDiagnosticsReport) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "schema": DoctorDiagnosticsReportRunner.schema,
            "schema_version": DoctorDiagnosticsReportRunner.schemaVersion,
            "minimum_reader_version": DoctorDiagnosticsReportRunner.minimumReaderVersion,
            "created_at": formatter.string(from: report.createdAt),
            "binary_version": report.binaryVersion,
            "doctor": [
                "outcome": report.outcome,
                "exit_code": report.exitCode,
                "status_observation": statusObject(report.statusObservation, formatter: formatter),
                "version_floor_standing": report.versionFloorStanding.rawValue,
                "auto_update_enabled": report.localEvidence.autoUpdateEnabled,
                "auto_update_source": report.localEvidence.autoUpdateSource,
                "pending_update_phase": json(report.localEvidence.pendingUpdatePhase),
                "launchd": launchdObject(report.localEvidence.launchd),
                "stat": report.localEvidence.stat.map(statObject),
            ],
            "diagnostic_findings": report.findings.map { findingObject($0, formatter: formatter) },
            "logs": [
                "provider": report.localEvidence.logs.provider,
                "watchdog": report.localEvidence.logs.watchdog,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            let fallback = "{\"minimum_reader_version\":\(DoctorDiagnosticsReportRunner.minimumReaderVersion),"
                + "\"schema\":\"\(DoctorDiagnosticsReportRunner.schema)\","
                + "\"schema_version\":\(DoctorDiagnosticsReportRunner.schemaVersion)}\n"
            FileHandle.standardOutput.write(Data(fallback.utf8))
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func statusObject(_ status: DoctorStatusObservation, formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "state": status.state.rawValue,
            "network_state": json(status.networkState),
            "reason": json(status.reason),
            "observed_at": json(status.observedAt.map(formatter.string(from:))),
            "valid_for_ms": json(status.validForMS),
        ]
    }

    private static func launchdObject(_ launchd: DoctorLaunchdEvidence) -> [String: Any] {
        [
            "provider_plist": plistObject(launchd.providerPlist),
            "legacy_provider_plist": plistObject(launchd.legacyProviderPlist),
            "provider": [
                "available": json(launchd.providerLaunchctl.available),
                "pid": json(launchd.providerLaunchctl.pid),
                "reason": json(launchd.providerLaunchctl.reason),
            ],
        ]
    }

    private static func plistObject(_ plist: DoctorPlistEvidence) -> [String: Any] {
        [
            "present": plist.present,
            "label_matches_expected": json(plist.labelMatchesExpected),
            "program_configured": plist.programConfigured,
        ]
    }

    private static func statObject(_ stat: DoctorStatEvidence) -> [String: Any] {
        [
            "name": stat.name,
            "present": stat.present,
            "owner_current_user": json(stat.ownerCurrentUser),
            "mode": json(stat.mode),
            "acl_extended": json(stat.aclExtended),
        ]
    }

    private static func findingObject(_ finding: DoctorDiagnosticFinding, formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "signature_id": finding.signatureID,
            "source": finding.source,
            "message": DoctorReportRedactor.redacted(finding.message),
            "evidence": finding.evidence.map(DoctorReportRedactor.redacted) ?? NSNull(),
            "observed_at": formatter.string(from: finding.observedAt),
        ]
    }

    private static func json<T>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        return value
    }
}

enum DoctorReportRedactor {
    static func redacted(_ line: String) -> String {
        let sanitized = scrubNonSecretIdentifiers(line)
        if containsSecret(line) || containsSecret(sanitized) {
            return "[redacted]"
        }
        return sanitized
    }

    static func redactedForTest(
        _ line: String,
        usernameCandidates: [String],
        hostnameCandidates: [String?] = []
    ) -> String {
        let sanitized = scrubNonSecretIdentifiers(
            line,
            usernameCandidates: usernameCandidates,
            hostnameCandidates: hostnameCandidates
        )
        if containsSecret(line) || containsSecret(sanitized) {
            return "[redacted]"
        }
        return sanitized
    }

    private static func containsSecret(_ line: String) -> Bool {
        let lower = line.lowercased()
        let normalizedIdentifierText = lower.filter { $0.isLetter || $0.isNumber }
        return lower.contains("provider_token")
            || lower.contains("provider_id")
            || lower.contains("identity_signature")
            || lower.contains("authorization:")
            || lower.contains("token_sha256")
            || lower.contains("token_hash")
            || lower.contains("private_key")
            || lower.contains("api_key")
            || lower.contains("client_secret")
            || lower.contains("secret")
            || lower.contains("credential")
            || lower.contains("password")
            || lower.contains("set-cookie")
            || lower.contains("signed_payload")
            || lower.contains("payload_to_sign")
            || normalizedIdentifierText.contains("providertoken")
            || normalizedIdentifierText.contains("providerid")
            || normalizedIdentifierText.contains("identitysignature")
            || normalizedIdentifierText.contains("privatekey")
            || normalizedIdentifierText.contains("apikey")
            || normalizedIdentifierText.contains("clientsecret")
            || normalizedIdentifierText.contains("secretkey")
            || normalizedIdentifierText.contains("credential")
            || normalizedIdentifierText.contains("password")
            || normalizedIdentifierText.contains("setcookie")
            || normalizedIdentifierText.contains("signedpayload")
            || normalizedIdentifierText.contains("payloadtosign")
            || normalizedIdentifierText.contains("tokensha256")
            || normalizedIdentifierText.contains("tokenhash")
            || (lower.contains("-----begin") && lower.contains("private key-----"))
            || matchesSecretPattern(line)
    }

    private static func matchesSecretPattern(_ line: String) -> Bool {
        let patterns = [
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-=]{12,}"#,
            #"(?i)(^|[^A-Za-z0-9_-])["']?authorization["']?\s*[:=]\s*["']?\S+"#,
            #"(?i)\b(provider|identity|auth|access|refresh|session)[_-]?token\b\s*[:=]\s*\S+"#,
            #"(?i)\b(api[_-]?key|client[_-]?secret|secret|secret[_-]?key|x[_-]?secret[_-]?key|credential|password|cookie)\b\s*[:=]\s*\S+"#,
            #"(?i)https?://\S+\?\S+"#,
        ]
        return patterns.contains { pattern in
            line.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func scrubNonSecretIdentifiers(_ line: String) -> String {
        scrubNonSecretIdentifiers(
            line,
            usernameCandidates: [
                NSUserName(),
                FileManager.default.homeDirectoryForCurrentUser.lastPathComponent,
            ],
            hostnameCandidates: currentHostnameCandidates()
        )
    }

    private static func currentHostnameCandidates() -> [String?] {
        var candidates: [String?] = [
            ProcessInfo.processInfo.hostName,
            ProcessInfo.processInfo.hostName.components(separatedBy: ".").first,
        ]
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        if gethostname(&buffer, buffer.count) == 0 {
            let hostname = String(cString: buffer)
            candidates.append(hostname)
            candidates.append(hostname.components(separatedBy: ".").first)
        }
        return candidates
    }

    private static func scrubNonSecretIdentifiers(
        _ line: String,
        usernameCandidates rawUsernameCandidates: [String],
        hostnameCandidates rawHostnameCandidates: [String?]
    ) -> String {
        var output = String(line.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !(value <= 0x1F || (0x7F...0x9F).contains(value))
        })
        for username in orderedIdentifierCandidates(rawUsernameCandidates) {
            output = output.replacingOccurrences(of: username, with: "[user]")
        }
        for hostname in orderedIdentifierCandidates(rawHostnameCandidates.compactMap { $0 }) {
            output = output.replacingOccurrences(of: hostname, with: "[host]")
        }
        let replacements: [(String, String)] = [
            (#"(?i)\b(user(?:name)?|login|account)=([^\s,;]+)"#, "$1=[user]"),
            (#"(?i)\b(host(?:name)?|computer[_-]?name|machine|nodename)=([^\s,;]+)"#, "$1=[host]"),
            (#"\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)*\.local\b"#, "[host]"),
            (#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b"#, "[ip]"),
        ]
        for (pattern, template) in replacements {
            output = output.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return scrubAbsolutePaths(scrubIPAddresses(output))
    }

    private static func orderedIdentifierCandidates(_ candidates: [String]) -> [String] {
        Array(Set(candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }))
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs < rhs
            }
    }

    private static func scrubAbsolutePaths(_ line: String) -> String {
        let line = line.replacingOccurrences(of: #"\/"#, with: "/")
        var output = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line.lowercasedRange(from: index, hasPrefix: "file:///") {
                let pathStart = line.index(index, offsetBy: "file://".count)
                output += "file://[path]"
                index = line.indexAfterAbsolutePath(startingAt: pathStart)
                continue
            }
            let character = line[index]
            if character == "/", isPathBoundary(before: index, in: line) {
                output += "[path]"
                index = line.indexAfterAbsolutePath(startingAt: index)
            } else {
                output.append(character)
                index = line.index(after: index)
            }
        }
        return output
    }

    private static func scrubIPAddresses(_ line: String) -> String {
        var output = ""
        var token = ""

        func flushToken() {
            guard !token.isEmpty else { return }
            output += redactedIPToken(token) ?? token
            token = ""
        }

        for character in line {
            if isIPTokenCharacter(character) {
                token.append(character)
            } else {
                flushToken()
                output.append(character)
            }
        }
        flushToken()
        return output
    }

    private static func isIPTokenCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "."
            || character == ":"
            || character == "%"
            || character == "["
            || character == "]"
    }

    private static func redactedIPToken(_ token: String) -> String? {
        guard token.contains(".") || token.contains(":") else { return nil }
        let split = splitTrailingPunctuation(from: token)
        let candidate = split.candidate
        if candidate.hasPrefix("["),
           let closeBracket = candidate.firstIndex(of: "]") {
            let addressStart = candidate.index(after: candidate.startIndex)
            let address = String(candidate[addressStart..<closeBracket])
            let suffix = candidate[candidate.index(after: closeBracket)...]
            guard suffix.isEmpty || isPortSuffix(suffix), isIPAddress(address) else { return nil }
            return "[ip]" + split.trailing
        }
        if isIPAddress(candidate) {
            return "[ip]" + split.trailing
        }
        if let colon = candidate.lastIndex(of: ":") {
            let suffix = candidate[colon...]
            let prefix = String(candidate[..<colon])
            if isPortSuffix(suffix), isIPAddress(prefix) {
                return "[ip]" + split.trailing
            }
        }
        return nil
    }

    private static func splitTrailingPunctuation(from token: String) -> (candidate: String, trailing: String) {
        var candidate = token
        var trailing = ""
        while let last = candidate.last, last == "." || last == "," || last == ";" {
            trailing.insert(last, at: trailing.startIndex)
            candidate.removeLast()
        }
        return (candidate, trailing)
    }

    private static func isPortSuffix(_ suffix: Substring) -> Bool {
        guard suffix.first == ":" else { return false }
        let digits = suffix.dropFirst()
        return (1...5).contains(digits.count) && digits.allSatisfy(\.isNumber)
    }

    private static func isIPAddress(_ rawAddress: String) -> Bool {
        let address = rawAddress.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? rawAddress
        guard !address.isEmpty else { return false }
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private static func isPathBoundary(before index: String.Index, in line: String) -> Bool {
        guard index > line.startIndex else { return true }
        let previous = line[line.index(before: index)]
        if previous == ":" {
            let next = line.index(after: index)
            return next == line.endIndex || line[next] != "/"
        }
        return previous.isWhitespace || #""'(<[{="#.contains(previous)
    }
}

private extension String {
    func lowercasedRange(from index: String.Index, hasPrefix prefix: String) -> Bool {
        let end = self.index(index, offsetBy: prefix.count, limitedBy: endIndex) ?? endIndex
        guard distance(from: index, to: end) == prefix.count else { return false }
        return self[index..<end].lowercased() == prefix
    }

    func indexAfterAbsolutePath(startingAt start: String.Index) -> String.Index {
        var index = self.index(after: start)
        while index < endIndex {
            let character = self[index]
            if #""'`<>|;,"#.contains(character) {
                break
            }
            if character.isWhitespace {
                let next = self.index(after: index)
                if next == endIndex || tokenAfterWhitespaceStartsKeyValue(at: next) {
                    break
                }
            }
            index = self.index(after: index)
        }
        return index
    }

    private func tokenAfterWhitespaceStartsKeyValue(at start: String.Index) -> Bool {
        var index = start
        guard index < endIndex, self[index].isLetter || self[index] == "_" else {
            return false
        }
        index = self.index(after: index)
        while index < endIndex {
            let character = self[index]
            if character == "=" || character == ":" {
                return true
            }
            if character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." {
                index = self.index(after: index)
            } else {
                return false
            }
        }
        return false
    }
}
