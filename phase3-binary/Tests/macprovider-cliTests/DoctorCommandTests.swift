import Foundation
import Darwin
import ArgumentParser
import XCTest
import MacProviderCore
@testable import macprovider_cli

/// Issue #767 item 3 — `macprovider-cli doctor`. Offline-first: everything but
/// the floor comparison is answerable with no network at all.
final class DoctorCommandTests: XCTestCase {
    private func runner(
        binaryVersion: String = "1.8.65",
        coordinatorURL: String? = "wss://coordinator.malibu.tech/ws/provider",
        offline: Bool = false,
        fetch: @escaping @Sendable (URL) async -> DoctorHealthz?
    ) -> DoctorRunner {
        DoctorRunner(
            binaryVersion: binaryVersion,
            coordinatorURL: coordinatorURL,
            providerID: "mac",
            configPath: "/tmp/macprovider-doctor-test.yaml",
            offline: offline,
            fetch: fetch
        )
    }

    private static let unreachable: @Sendable (URL) async -> DoctorHealthz? = { _ in nil }

    private static let reportNow = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - endpoint derivation

    func testHealthzURLDerivation() {
        XCTAssertEqual(
            DoctorRunner.healthzURL(coordinatorURL: "wss://coordinator.malibu.tech/ws/provider")?.absoluteString,
            "https://coordinator.malibu.tech/healthz"
        )
        XCTAssertEqual(
            DoctorRunner.healthzURL(coordinatorURL: "ws://127.0.0.1:8444/ws/provider")?.absoluteString,
            "http://127.0.0.1:8444/healthz"
        )
        // Plaintext is loopback-only, credentials are refused, and a garbage or
        // absent URL yields nil rather than a guessed endpoint.
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: "ws://coordinator.malibu.tech/ws/provider"))
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: "wss://user:pass@coordinator.malibu.tech/ws/provider"))
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: "not a url"))
        XCTAssertNil(DoctorRunner.healthzURL(coordinatorURL: nil))
    }

    // MARK: - floor standing

    func testStandingAgainstPublishedFloor() {
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.32", requiredBinaryVersion: "1.8.33"), .belowFloor)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.33", requiredBinaryVersion: "1.8.33"), .aboveFloor)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: "1.8.33"), .aboveFloor)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: nil), .noFloorConfigured)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: "  "), .noFloorConfigured)
        // Never claim "you're fine" from a comparison that did not happen.
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65-dev", requiredBinaryVersion: "1.8.33"), .indeterminate)
        XCTAssertEqual(DoctorRunner.standing(binaryVersion: "1.8.65", requiredBinaryVersion: "latest"), .indeterminate)
    }

    // MARK: - offline-first behavior

    func testOfflineSkipsTheCoordinatorEntirely() async {
        let probed = LockedBox(false)
        let report = await runner(offline: true, fetch: { _ in
            probed.set(true)
            return nil
        }).run()
        XCTAssertFalse(probed.get(), "--offline must not touch the network")
        XCTAssertEqual(report.floorStanding, .notChecked)
        XCTAssertEqual(report.binaryVersion, "1.8.65")
        XCTAssertEqual(report.coordinatorURL, "wss://coordinator.malibu.tech/ws/provider")
        XCTAssertNil(report.requiredBinaryVersion)
    }

    func testUnreachableCoordinatorDegradesGracefully() async {
        let report = await runner(fetch: Self.unreachable).run()
        XCTAssertEqual(report.floorStanding, .unreachable)
        // Local facts are still reported — that is the point of offline-first.
        XCTAssertEqual(report.binaryVersion, "1.8.65")
        XCTAssertEqual(report.healthzURL, "https://coordinator.malibu.tech/healthz")
    }

    func testMissingCoordinatorURLIsNotChecked() async {
        let report = await runner(coordinatorURL: nil, fetch: Self.unreachable).run()
        XCTAssertEqual(report.floorStanding, .notChecked)
        XCTAssertNil(report.healthzURL)
    }

    func testBelowFloorIsReportedWithTheRequiredTarget() async {
        let report = await runner(binaryVersion: "1.8.32", fetch: { _ in
            DoctorHealthz(
                version: "v1.4.0",
                requiredBinaryVersion: "1.8.33",
                recommendedBinaryVersion: "1.8.65"
            )
        }).run()
        XCTAssertEqual(report.floorStanding, .belowFloor)
        XCTAssertEqual(report.requiredBinaryVersion, "1.8.33")
        XCTAssertEqual(report.recommendedBinaryVersion, "1.8.65")
        XCTAssertEqual(report.coordinatorVersion, "v1.4.0")
        XCTAssertTrue(try! XCTUnwrap(report.note).contains("4004"))
    }

    func testAboveFloorIsClean() async {
        let report = await runner(fetch: { _ in
            DoctorHealthz(version: "v1.4.0", requiredBinaryVersion: "1.8.33", recommendedBinaryVersion: "1.8.65")
        }).run()
        XCTAssertEqual(report.floorStanding, .aboveFloor)
        XCTAssertNil(report.note)
    }

    func testNoFloorPublished() async {
        let report = await runner(fetch: { _ in
            DoctorHealthz(version: "v1.4.0", requiredBinaryVersion: nil, recommendedBinaryVersion: "1.8.65")
        }).run()
        XCTAssertEqual(report.floorStanding, .noFloorConfigured)
    }

    // MARK: - healthz parsing

    func testParseHealthz() throws {
        let body = Data("""
        {"status":"ok","version":"v1.4.0","recommended_binary_version":"1.8.65","required_binary_version":"1.8.33"}
        """.utf8)
        let parsed = try XCTUnwrap(DoctorRunner.parseHealthz(body))
        XCTAssertEqual(parsed.version, "v1.4.0")
        XCTAssertEqual(parsed.requiredBinaryVersion, "1.8.33")
        XCTAssertEqual(parsed.recommendedBinaryVersion, "1.8.65")

        // The coordinator omits required_binary_version when no floor is set.
        let noFloor = try XCTUnwrap(DoctorRunner.parseHealthz(Data("""
        {"status":"ok","version":"v1.4.0","recommended_binary_version":"1.8.65"}
        """.utf8)))
        XCTAssertNil(noFloor.requiredBinaryVersion)

        XCTAssertNil(DoctorRunner.parseHealthz(Data("not json".utf8)))
    }

    // MARK: - SPEC-035 doctor report

    func testDoctorReportJSONCommandRemainsParseable() throws {
        let command = try XCTUnwrap(MacProviderCLI.parseAsRoot([
            "doctor", "report", "--json", "--offline", "--timeout-seconds", "0.25",
        ]) as? DoctorCommand)
        XCTAssertEqual(command.mode, "report")
        XCTAssertTrue(command.json)
        XCTAssertTrue(command.offline)
        XCTAssertEqual(command.timeoutSeconds, 0.25, accuracy: 0.001)
    }

    func testDoctorReportEmitsOnlyServeUnresponsiveWhenStatusUnavailable() async {
        let report = await diagnosticsRunner(status: nil).run(now: Self.reportNow)
        XCTAssertEqual(report.exitCode, DoctorDiagnosticsReportExit.providerAttention.rawValue)
        XCTAssertEqual(report.outcome, "provider_attention")
        XCTAssertEqual(report.statusObservation.state, .unavailable)
        XCTAssertEqual(report.findings.map(\.signatureID), ["serve_unresponsive"])
        XCTAssertEqual(report.findings.map(\.source), ["doctor_report"])
    }

    func testDoctorReportSuppressesFindingsWhenStatusIsFresh() async {
        let report = await diagnosticsRunner(status: freshStatus(networkState: "buyer_serving")).run(now: Self.reportNow)
        XCTAssertEqual(report.exitCode, DoctorDiagnosticsReportExit.healthy.rawValue)
        XCTAssertEqual(report.outcome, "healthy")
        XCTAssertEqual(report.statusObservation.state, .fresh)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testDoctorReportDoesNotTrustNetworkStateWithoutAuthorityCapability() async {
        let report = await diagnosticsRunner(
            status: freshStatus(networkState: "buyer_serving", capabilities: ["status_observation_v1"])
        ).run(now: Self.reportNow)
        XCTAssertEqual(report.exitCode, DoctorDiagnosticsReportExit.unknown.rawValue)
        XCTAssertEqual(report.outcome, "unknown")
        XCTAssertEqual(report.statusObservation.state, .fresh)
        XCTAssertNil(report.statusObservation.networkState)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testDoctorReportAllowlistsNetworkStateBeforeEmission() async throws {
        let report = await diagnosticsRunner(status: freshStatus(
            networkState: "buyer_serving /Users/alice provider_id=mp-secret 192.168.1.20\u{0007}"
        )).run(now: Self.reportNow)
        XCTAssertEqual(report.statusObservation.state, .fresh)
        XCTAssertNil(report.statusObservation.networkState)
        XCTAssertEqual(report.exitCode, DoctorDiagnosticsReportExit.unknown.rawValue)
        let stdout = captureStdout {
            DoctorDiagnosticsReportPrinter.emitJSON(report)
        }
        XCTAssertFalse(stdout.contains("/Users/alice"))
        XCTAssertFalse(stdout.contains("provider_id"))
        XCTAssertFalse(stdout.contains("192.168.1.20"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        let doctor = try XCTUnwrap(object["doctor"] as? [String: Any])
        let status = try XCTUnwrap(doctor["status_observation"] as? [String: Any])
        XCTAssertTrue(status["network_state"] is NSNull)
    }

    func testDoctorReportDoesNotOverrideFreshStatusOwnedNetworkState() async {
        let report = await diagnosticsRunner(status: freshStatus(networkState: "not_buyer_serving")).run(now: Self.reportNow)
        XCTAssertEqual(report.exitCode, DoctorDiagnosticsReportExit.unknown.rawValue)
        XCTAssertEqual(report.outcome, "unknown")
        XCTAssertEqual(report.statusObservation.state, .fresh)
        XCTAssertEqual(report.statusObservation.networkState, "not_buyer_serving")
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testDoctorReportContributesServeUnresponsiveForStaleOrIncompatibleStatus() async {
        let stale = await diagnosticsRunner(status: freshStatus(
            networkState: "buyer_serving",
            observedAt: Self.reportNow.addingTimeInterval(-6),
            validForMS: 5_000
        )).run(now: Self.reportNow)
        XCTAssertEqual(stale.statusObservation.state, .stale)
        XCTAssertEqual(stale.findings.map(\.signatureID), ["serve_unresponsive"])

        let incompatible = await diagnosticsRunner(status: [
            "local_status_contract": [
                "version": 1,
                "minimum_reader_version": 99,
                "capabilities": ["status_observation_v1"],
            ],
            "network_state": "buyer_serving",
        ]).run(now: Self.reportNow)
        XCTAssertEqual(incompatible.statusObservation.state, .contractIncompatible)
        XCTAssertEqual(incompatible.findings.map(\.signatureID), ["serve_unresponsive"])
    }

    func testDoctorReportAttachesBelowFloorAsServeUnresponsiveEvidenceOnly() async {
        let report = await diagnosticsRunner(
            binaryVersion: "1.8.32",
            status: nil,
            healthz: DoctorHealthz(version: "v1.4.0", requiredBinaryVersion: "1.8.33", recommendedBinaryVersion: "1.8.65")
        ).run(now: Self.reportNow)
        XCTAssertEqual(report.versionFloorStanding, .belowFloor)
        XCTAssertEqual(report.exitCode, DoctorDiagnosticsReportExit.providerAttention.rawValue)
        XCTAssertEqual(report.findings.map(\.signatureID), ["serve_unresponsive"])
        XCTAssertTrue(try! XCTUnwrap(report.findings.first?.evidence).contains("version_floor_standing=below_floor"))
    }

    func testDoctorReportJSONIsBackCompatAndDoesNotExposeConfigPathOrProviderID() async throws {
        var config = AppConfig.defaults(configPath: "/Users/alice/.config/macprovider/config.yaml")
        config.providerID = "provider-full-id-must-not-leak"
        let report = await diagnosticsRunner(config: config, status: nil).run(now: Self.reportNow)
        let stdout = captureStdout {
            DoctorDiagnosticsReportPrinter.emitJSON(report)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, DoctorDiagnosticsReportRunner.schema)
        XCTAssertEqual(object["schema_version"] as? Int, 2)
        XCTAssertEqual(object["minimum_reader_version"] as? Int, 1)
        let findings = try XCTUnwrap(object["diagnostic_findings"] as? [[String: Any]])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?["signature_id"] as? String, "serve_unresponsive")
        XCTAssertFalse(stdout.contains("config_path"))
        XCTAssertFalse(stdout.contains(config.configPath))
        XCTAssertFalse(stdout.contains("provider-full-id-must-not-leak"))
        XCTAssertFalse(stdout.contains("provider_id"))
    }

    func testDoctorReportConfigLoadFailureEmitsRedactedJSON() async throws {
        let badPath = "/Users/alice/.config/macprovider/missing-config.yaml"
        let command = try XCTUnwrap(DoctorCommand.parse([
            "report", "--json", "--config", badPath,
        ]))
        let capture = await captureStdoutAsync {
            try await command.run()
        }
        XCTAssertEqual(capture.error as? ExitCode, ExitCode(Int32(DoctorDiagnosticsReportExit.unknown.rawValue)))
        XCTAssertFalse(capture.stdout.contains(badPath))
        XCTAssertFalse(capture.stdout.contains("config_path"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(capture.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, DoctorDiagnosticsReportRunner.schema)
        XCTAssertEqual(object["minimum_reader_version"] as? Int, 1)
        let doctor = try XCTUnwrap(object["doctor"] as? [String: Any])
        XCTAssertEqual(doctor["outcome"] as? String, "unknown")
        let status = try XCTUnwrap(doctor["status_observation"] as? [String: Any])
        XCTAssertEqual(status["reason"] as? String, "config_load_failed")
        let findings = try XCTUnwrap(object["diagnostic_findings"] as? [[String: Any]])
        XCTAssertTrue(findings.isEmpty)
    }

    func testDoctorReportRedactsLogsByConstruction() {
        let nonSecret = DoctorReportRedactor.redactedForTest(
            "provider process unhealthy at /Users/alice/macprovider-cli host=myhost.local ip=192.168.1.20\u{0007}",
            usernameCandidates: ["alice"],
            hostnameCandidates: ["myhost.local", "myhost"]
        )
        XCTAssertFalse(nonSecret.contains("/Users/alice"))
        XCTAssertFalse(nonSecret.contains("alice"))
        XCTAssertFalse(nonSecret.contains("myhost"))
        XCTAssertFalse(nonSecret.contains("192.168.1.20"))
        XCTAssertFalse(nonSecret.unicodeScalars.contains { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) })
        XCTAssertTrue(nonSecret.contains("[path]"))
        XCTAssertTrue(nonSecret.contains("[host]"))
        XCTAssertTrue(nonSecret.contains("[ip]"))

        XCTAssertEqual(
            DoctorReportRedactor.redactedForTest(
                "Authorization: Bearer abcdefghijklmnop provider_token=secret",
                usernameCandidates: []
            ),
            "[redacted]"
        )
        XCTAssertEqual(
            DoctorReportRedactor.redactedForTest(
                "secret=abc credential=def x-secret-key=ghi",
                usernameCandidates: []
            ),
            "[redacted]"
        )
        XCTAssertEqual(
            DoctorReportRedactor.redactedForTest(
                "status provider_id=mp-full-provider-id",
                usernameCandidates: []
            ),
            "[redacted]"
        )
    }

    func testDoctorReportAutoupdateConfigPrecedence() {
        XCTAssertEqual(
            DoctorLocalEvidenceCollector.effectiveAutoUpdateEnabled(
                autoUpdateEnabled: false,
                legacyAutoupdateEnabled: true
            ).enabled,
            false
        )
        XCTAssertEqual(
            DoctorLocalEvidenceCollector.effectiveAutoUpdateEnabled(
                autoUpdateEnabled: nil,
                legacyAutoupdateEnabled: false
            ).source,
            "autoupdate.enabled"
        )
        XCTAssertTrue(DoctorLocalEvidenceCollector.effectiveAutoUpdateEnabled(
            autoUpdateEnabled: nil,
            legacyAutoupdateEnabled: nil
        ).enabled)
    }

    func testDoctorReportTimeoutIsPassedToServeStatusProbe() async {
        let seen = LockedBox<TimeInterval?>(nil)
        _ = await diagnosticsRunner(
            timeoutSeconds: 0.25,
            statusFetch: { _, timeout in
                seen.set(timeout)
                return nil
            }
        ).run(now: Self.reportNow)
        XCTAssertEqual(try XCTUnwrap(seen.get()), 0.25, accuracy: 0.001)
    }

    func testDoctorReportDoesNotEmitRawPlistLabels() async throws {
        let report = await diagnosticsRunner(
            status: nil,
            localEvidence: {
                DoctorLocalEvidence(
                    autoUpdateEnabled: true,
                    autoUpdateSource: "default_enabled",
                    pendingUpdatePhase: nil,
                    pendingMarkerDeadline: nil,
                    launchd: DoctorLaunchdEvidence(
                        providerPlist: DoctorPlistEvidence(
                            present: true,
                            labelMatchesExpected: false,
                            programConfigured: false
                        ),
                        legacyProviderPlist: DoctorPlistEvidence(
                            present: false,
                            labelMatchesExpected: nil,
                            programConfigured: false
                        ),
                        providerLaunchctl: DoctorLaunchctlEvidence(available: false, pid: nil, reason: "service_not_found")
                    ),
                    stat: [],
                    logs: DoctorLogEvidence(provider: [], watchdog: [])
                )
            }
        ).run(now: Self.reportNow)
        let stdout = captureStdout {
            DoctorDiagnosticsReportPrinter.emitJSON(report)
        }
        XCTAssertFalse(stdout.contains("label\""))
        XCTAssertFalse(stdout.contains("/Users/alice"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        let doctor = try XCTUnwrap(object["doctor"] as? [String: Any])
        let launchd = try XCTUnwrap(doctor["launchd"] as? [String: Any])
        let plist = try XCTUnwrap(launchd["provider_plist"] as? [String: Any])
        XCTAssertEqual(plist["label_matches_expected"] as? Bool, false)
    }

    func testDoctorReportReadOnlyCollectorCreatesNoFilesOrLocks() async throws {
        let home = try temporaryDirectory(name: "doctor-report-readonly")
        defer { try? FileManager.default.removeItem(at: home) }
        let autoupdateRoot = home.appendingPathComponent(".local/share/macprovider/autoupdate", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/macprovider", isDirectory: true)
        try FileManager.default.createDirectory(at: autoupdateRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try makePendingMarker().write(to: autoupdateRoot.appendingPathComponent("pending.json"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>live.malibu.provider</string>
        <key>ProgramArguments</key><array><string>/Users/alice/macprovider-cli</string><string>serve</string></array>
        </dict></plist>
        """.utf8).write(to: launchAgents.appendingPathComponent("live.malibu.provider.plist"))
        try Data("provider process unhealthy: launchd service live.malibu.provider has no validated PID at /Users/alice/macprovider-cli\n".utf8)
            .write(to: logs.appendingPathComponent("macprovider.err.log"))
        var config = AppConfig.defaults(configPath: home.appendingPathComponent(".config/macprovider/config.yaml").path)
        config.autoUpdateEnabled = false
        let collector = DoctorLocalEvidenceCollector(
            homeDirectory: home,
            launchctl: { _ in DoctorLaunchctlEvidence(available: false, pid: nil, reason: "service_not_found") }
        )
        let collectorConfig = config
        let before = try treeSnapshot(home)
        let report = await diagnosticsRunner(
            config: config,
            status: nil,
            localEvidence: { collector.collect(config: collectorConfig) }
        ).run(now: Self.reportNow)
        let after = try treeSnapshot(home)
        XCTAssertEqual(report.localEvidence.pendingUpdatePhase, CompatibilitySetTransactionState.activatingTarget.rawValue)
        XCTAssertEqual(report.localEvidence.autoUpdateEnabled, false)
        XCTAssertTrue(report.localEvidence.logs.provider.contains { $0.contains("[path]") })
        XCTAssertFalse(report.localEvidence.logs.provider.joined(separator: "\n").contains("/Users/alice"))
        XCTAssertEqual(before, after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: autoupdateRoot.appendingPathComponent("update.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/macprovider/install.lock").path))
    }

    private func diagnosticsRunner(
        binaryVersion: String = "1.8.65",
        config: AppConfig = AppConfig.defaults(),
        timeoutSeconds: TimeInterval = 1,
        status: [String: Any]? = nil,
        healthz: DoctorHealthz? = nil,
        localEvidence: @escaping @Sendable () -> DoctorLocalEvidence = { DoctorCommandTests.emptyEvidence },
        statusFetch: (@Sendable (Int, TimeInterval) async -> [String: Any]?)? = nil
    ) -> DoctorDiagnosticsReportRunner {
        var runnerConfig = config
        if runnerConfig.coordinatorURL == nil {
            runnerConfig.coordinatorURL = "wss://coordinator.malibu.tech/ws/provider"
        }
        let statusBox = LockedBox(status)
        let healthzBox = LockedBox(healthz)
        return DoctorDiagnosticsReportRunner(
            binaryVersion: binaryVersion,
            config: runnerConfig,
            offline: false,
            timeoutSeconds: timeoutSeconds,
            statusFetch: statusFetch ?? { _, _ in statusBox.get() },
            healthzFetch: { _ in healthzBox.get() },
            localEvidence: localEvidence
        )
    }

    private static var emptyEvidence: DoctorLocalEvidence {
        DoctorLocalEvidence(
            autoUpdateEnabled: true,
            autoUpdateSource: "default_enabled",
            pendingUpdatePhase: nil,
            pendingMarkerDeadline: nil,
            launchd: DoctorLaunchdEvidence(
                providerPlist: DoctorPlistEvidence(present: false, labelMatchesExpected: nil, programConfigured: false),
                legacyProviderPlist: DoctorPlistEvidence(present: false, labelMatchesExpected: nil, programConfigured: false),
                providerLaunchctl: DoctorLaunchctlEvidence(available: false, pid: nil, reason: "service_not_found")
            ),
            stat: [],
            logs: DoctorLogEvidence(provider: [], watchdog: [])
        )
    }

    private func freshStatus(
        networkState: String,
        observedAt: Date = reportNow,
        validForMS: Int = 5_000,
        capabilities: [String] = ["buyer_serving_authority_v1", "status_observation_v1"]
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "local_status_contract": [
                "version": 1,
                "minimum_reader_version": 1,
                "capabilities": capabilities,
            ],
            "observation": [
                "id": "obs-1",
                "observed_at": formatter.string(from: observedAt),
                "valid_for_ms": validForMS,
            ],
            "network_state": networkState,
        ]
    }

    private func temporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePendingMarker() throws -> Data {
        let marker = AutoUpdatePendingMarker(
            updateID: "00000000-0000-4000-8000-000000000000",
            targetVersion: "1.8.66",
            targetPath: "/tmp/macprovider-cli",
            backupPath: "/tmp/macprovider-cli.backup",
            size: 1,
            mode: 0o755,
            sha256: String(repeating: "a", count: 64),
            markerDeadline: "2026-09-01T00:00:00Z",
            transactionState: .activatingTarget
        )
        return try JSONEncoder().encode(marker)
    }

    private func treeSnapshot(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var snapshot: [String: String] = [:]
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true {
                snapshot[relative] = "dir"
            } else if values.isRegularFile == true {
                snapshot[relative] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            }
        }
        return snapshot
    }

    private func captureStdout(_ body: () -> Void) -> String {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        body()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func captureStdoutAsync(_ body: () async throws -> Void) async -> (stdout: String, error: Error?) {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var caught: Error?
        do {
            try await body()
        } catch {
            caught = error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(decoding: data, as: UTF8.self), caught)
    }
}
