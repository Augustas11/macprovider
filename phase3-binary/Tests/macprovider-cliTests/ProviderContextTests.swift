import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// #1689 part 3: context provenance, operator context commands, and the
/// guarded restart/verify/rollback path.
final class ProviderContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Provenance of generated knobs

    func testApplyRecordsGeneratedContextAndLoaderReportsRecommendationApply() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: old-model\nmax_context_override: 4000\n")

        _ = try fixture.applier.apply(recommendation: recommendation(context: 200_000), now: now, benchmarkID: "spec-023-qwen-1")

        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextOverride, 200_000)
        XCTAssertEqual(loaded.maxContextSource, .recommendationApply)
        let sidecar = try XCTUnwrap(KnobProvenance.load(configPath: fixture.configURL.path) {
            try String(contentsOfFile: $0, encoding: .utf8)
        })
        XCTAssertEqual(sidecar.maxContextOverride?.value, 200_000)
        XCTAssertEqual(sidecar.maxContextOverride?.benchmarkID, "spec-023-qwen-1")
        XCTAssertEqual(sidecar.maxContextOverride?.model, "mlx-community/Qwen3.6-27B-4bit")
        XCTAssertEqual(sidecar.maxContextOverride?.generatedAt, "2026-09-21T14:13:20Z")
    }

    func testHandEditedContextAfterApplyIsOperatorOwned() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: old-model\n")
        _ = try fixture.applier.apply(recommendation: recommendation(context: 200_000), now: now)

        let edited = try String(contentsOf: fixture.configURL)
            .replacingOccurrences(of: "max_context_override: 200000", with: "max_context_override: 150000")
        try fixture.writeConfig(edited)

        XCTAssertEqual(try fixture.load().maxContextSource, .operatorConfig)
    }

    func testConfigWithoutSidecarLoadsUnchangedAsOperatorConfig() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")

        let loaded = try fixture.load()

        XCTAssertEqual(loaded.maxContextOverride, 4_000)
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig)
    }

    // MARK: - context set / rollback

    func testContextSetWritesOperatorOwnedValueWithBackup() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nprovider_token: keep-me\n")
        _ = try fixture.applier.apply(recommendation: recommendation(context: 200_000), now: now)

        let outcome = try await fixture.workflow().set(tokens: 200_000, preflight: false, apply: false)

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextOverride, 200_000)
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig, "an operator set wins even at the generated value")
        XCTAssertTrue(try String(contentsOf: fixture.configURL).contains("provider_token: keep-me"))
        XCTAssertEqual(fixture.backups().count, 2, "apply and set each back up the previous config")
        XCTAssertTrue(outcome.text.contains("Restart the provider"), outcome.text)
    }

    func testContextSetApplyRestartsThenVerifiesExpectedContext() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        var workflow = fixture.workflow()
        let restarts = Counter()
        let expected = Box<ProviderVerifier.ExpectedContext?>(nil)
        workflow.restart = { restarts.increment() }
        workflow.verify = { context in
            expected.value = context
            return Self.report(.agree)
        }

        let outcome = try await workflow.set(tokens: 120_000, preflight: true, apply: true)

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(expected.value, .init(tokens: 120_000, source: nil))
        XCTAssertEqual(try fixture.load().maxContextOverride, 120_000)
        XCTAssertTrue(outcome.text.contains("Verified:"), outcome.text)
    }

    func testFailedVerifyAfterApplyOffersRollback() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        var workflow = fixture.workflow()
        workflow.verify = { _ in Self.report(.localNotReady) }

        let outcome = try await workflow.set(tokens: 120_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertTrue(outcome.text.contains("malibu-cli provider context rollback"), outcome.text)
    }

    func testPreflightRefusesWhenKVCacheExceedsMemoryAndWritesNothing() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        let before = try String(contentsOf: fixture.configURL)
        var workflow = fixture.workflow(physicalMemoryGB: 32)
        workflow.modelFacts = {
            .init(declaredMax: 262_144, tokenizerMax: nil, kvBytesPerToken: 262_144, weightsBytes: 16 << 30)
        }

        let outcome = try await workflow.set(tokens: 200_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.text.contains("Refused"), outcome.text)
        XCTAssertEqual(try String(contentsOf: fixture.configURL), before)
        XCTAssertTrue(fixture.backups().isEmpty)
    }

    func testContextSetAboveTheDraftCapIsRefusedBeforeAnyWrite() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\ndraft_model: d\nmax_context_override: 16000\n")
        let before = try String(contentsOf: fixture.configURL, encoding: .utf8)

        let refused = try await fixture.workflow(physicalMemoryGB: 256).set(tokens: 150_000, preflight: false, apply: true)

        XCTAssertEqual(refused.exitCode, 1, refused.text)
        XCTAssertTrue(refused.text.contains("120000-token limit"), refused.text)
        XCTAssertTrue(refused.text.contains("draft model"), refused.text)
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), before)
        XCTAssertEqual(fixture.backups(), [])

        let accepted = try await fixture.workflow(physicalMemoryGB: 256).set(tokens: 120_000, preflight: false, apply: false)
        XCTAssertEqual(accepted.exitCode, 0, accepted.text)
        var loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextOverride, 120_000)
        XCTAssertNoThrow(try ServeCommand.runSpecDecodeCapacityPreflight(&loaded, physicalMemoryGB: 256))
    }

    func testExplainWithADraftModelShowsTheDraftCapAndSuggestsIt() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\ndraft_model: d\nmax_context_override: 16000\n")

        let text = await fixture.workflow(physicalMemoryGB: 256).explain()

        XCTAssertTrue(text.contains("Draft cap:    120000 tokens"), text)
        XCTAssertTrue(text.contains("malibu-cli provider context set 120000 --preflight"), text)
    }

    func testPreflightOnlyWritesNothing() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        let before = try String(contentsOf: fixture.configURL)

        let outcome = try await fixture.workflow().set(tokens: 120_000, preflight: true, apply: false)

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        XCTAssertEqual(try String(contentsOf: fixture.configURL), before)
        XCTAssertTrue(outcome.text.contains("Nothing was written"), outcome.text)
    }

    func testSetRejectsOutOfBoundsAndAboveModelLimit() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        let workflow = fixture.workflow()

        let tooSmall = try await workflow.set(tokens: 1_000, preflight: true, apply: false)
        XCTAssertEqual(tooSmall.exitCode, 1)
        let aboveModel = try await workflow.set(tokens: 300_000, preflight: true, apply: false)
        XCTAssertEqual(aboveModel.exitCode, 1)
        XCTAssertTrue(aboveModel.text.contains("262144"), aboveModel.text)
    }

    func testRollbackRestoresNewestBackupAndSavesCurrentFirst() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\nprovider_token: keep-me\n")
        var workflow = fixture.workflow()
        _ = try await workflow.set(tokens: 120_000, preflight: false, apply: false)
        let expected = Box<ProviderVerifier.ExpectedContext?>(nil)
        let restarts = Counter()
        workflow.restart = { restarts.increment() }
        workflow.verify = { context in
            expected.value = context
            return Self.report(.agree)
        }

        let outcome = try await workflow.rollback()

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        XCTAssertEqual(try fixture.load().maxContextOverride, 4_000)
        XCTAssertTrue(try String(contentsOf: fixture.configURL).contains("provider_token: keep-me"))
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(expected.value, .init(tokens: 4_000, source: nil))
        XCTAssertEqual(fixture.backups().count, 2, "rollback saves the replaced config so it can be undone")
    }

    func testRollbackToABackupWithoutAnOverrideVerifiesTheResolvedDefault() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        _ = try await workflow.set(tokens: 120_000, preflight: false, apply: false)
        let expected = Box<ProviderVerifier.ExpectedContext?>(nil)
        workflow.verify = { context in
            expected.value = context
            return Self.report(.agree)
        }

        _ = try await workflow.rollback()

        XCTAssertNil(try fixture.load().maxContextOverride)
        XCTAssertEqual(
            expected.value,
            .init(tokens: ProviderCapacity.defaultContextTokens(forPhysicalMemoryGB: 256), source: .ramTierDefault),
            "verify must require the default serve resolves, not skip the context check"
        )

        // With a draft model the default is clamped, and verify requires it.
        try fixture.writeConfig("model: m\ndraft_model: d\n")
        _ = try await workflow.set(tokens: 16_000, preflight: false, apply: false)
        _ = try await workflow.rollback()
        XCTAssertEqual(expected.value, .init(tokens: 120_000, source: .draftClamp))
    }

    func testRollbackOfRollbackFollowsBackupOrderWhenTheClockMovesBackwards() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        var workflow = fixture.workflow()
        workflow.verify = { _ in Self.report(.agree) }
        workflow.now = { Date(timeIntervalSince1970: 1_790_000_100) }
        _ = try await workflow.set(tokens: 120_000, preflight: false, apply: false)

        workflow.now = { Date(timeIntervalSince1970: 1_790_000_000) }
        _ = try await workflow.rollback()
        XCTAssertEqual(try fixture.load().maxContextOverride, 4_000)

        workflow.now = { Date(timeIntervalSince1970: 1_789_999_900) }
        _ = try await workflow.rollback()
        XCTAssertEqual(try fixture.load().maxContextOverride, 120_000, "rolling back the rollback restores the value it replaced")

        _ = try await workflow.rollback()
        XCTAssertEqual(try fixture.load().maxContextOverride, 4_000)
    }

    func testContextSetAndRollbackRejectAnOutOfRangeTimeoutBeforeAnyWrite() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        _ = try fixture.applier.setOperatorOwnedValue(key: "max_context_override", value: "8000", now: now)
        let before = try String(contentsOf: fixture.configURL)
        let backupsBefore = fixture.backups()

        for timeout in ["-1", "3601"] {
            XCTAssertThrowsError(try MacProviderCLI.parseAsRoot([
                "provider", "context", "set", "120000", "--apply", "--timeout=\(timeout)", "--config", fixture.configURL.path,
            ]), "set --timeout \(timeout)")
            XCTAssertThrowsError(try MacProviderCLI.parseAsRoot([
                "provider", "context", "rollback", "--timeout=\(timeout)", "--config", fixture.configURL.path,
            ]), "rollback --timeout \(timeout)")
        }
        XCTAssertNoThrow(try MacProviderCLI.parseAsRoot(["provider", "context", "set", "120000", "--timeout", "0"]))
        XCTAssertNoThrow(try MacProviderCLI.parseAsRoot(["provider", "context", "rollback", "--timeout", "3600"]))

        XCTAssertEqual(try String(contentsOf: fixture.configURL), before)
        XCTAssertEqual(fixture.backups(), backupsBefore)
    }

    // MARK: - explain and resource check

    func testExplainShowsSourceBoundsSlotsMemoryAndAdvertisedValue() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        _ = try fixture.applier.apply(recommendation: recommendation(context: 4_000), now: now)
        var workflow = fixture.workflow()
        workflow.fetchStatus = {
            [
                "model": "mlx-community/Qwen3.6-27B-4bit",
                "capacity": [
                    "max_context_tokens": 4_000,
                    "max_concurrency": 8,
                    "max_context_source": "recommendation_apply",
                ],
                "coordinator": ["connected": true],
            ]
        }

        let text = await workflow.explain()

        XCTAssertTrue(text.contains("Effective:    4000 tokens (source: config.yaml max_context_override written by an autotune recommendation)"), text)
        XCTAssertTrue(text.contains("RAM default:  200000 tokens"), text)
        XCTAssertTrue(text.contains("Model limit:  262144 tokens"), text)
        XCTAssertTrue(text.contains("Slots:        8"), text)
        XCTAssertTrue(text.contains("KV memory:"), text)
        XCTAssertTrue(text.contains("Advertised:   4000 tokens to the network (connected)"), text)
        XCTAssertTrue(text.contains("well below"), text)
        XCTAssertTrue(text.contains("malibu-cli provider context set 200000 --preflight"), text)
    }

    func testExplainReportsTheConfigFileAndLabelsAShellOverrideAsAnOverlay() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        _ = try fixture.applier.apply(recommendation: recommendation(context: 200_000), now: now)
        var workflow = fixture.workflow()
        workflow.environment = ["MACPROVIDER_MAX_CONTEXT_OVERRIDE": "9000"]

        let text = await workflow.explain()

        XCTAssertTrue(text.contains("Effective:    200000 tokens (source: config.yaml max_context_override written by an autotune recommendation)"), text)
        XCTAssertTrue(text.contains("Config file:  max_context_override 200000, written by an autotune recommendation for mlx-community/Qwen3.6-27B-4bit"), text)
        XCTAssertTrue(text.contains("This shell:   sets MACPROVIDER_MAX_CONTEXT_OVERRIDE=9000; the launchd service does not inherit it"), text)
        XCTAssertFalse(text.contains("Config file:  max_context_override 9000"), text)
    }

    func testRollbackExpectationIgnoresTheShellEnvironment() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        workflow.environment = ["MACPROVIDER_MAX_CONTEXT_OVERRIDE": "9000"]
        _ = try await workflow.set(tokens: 120_000, preflight: false, apply: false)
        let expected = Box<ProviderVerifier.ExpectedContext?>(nil)
        workflow.verify = { context in
            expected.value = context
            return Self.report(.agree)
        }

        _ = try await workflow.rollback()
        XCTAssertEqual(expected.value, .init(tokens: 4_000, source: nil), "launchd resolves the restored file value, not this shell's override")

        try fixture.writeConfig("model: m\n")
        _ = try await workflow.set(tokens: 16_000, preflight: false, apply: false)
        _ = try await workflow.rollback()
        XCTAssertEqual(expected.value, .init(tokens: 200_000, source: .ramTierDefault))
    }

    func testResourceCheckNamesCompetingProcessesAndListenersButNeverStopsThem() {
        var workflow = (try? Fixture())!.workflow()
        workflow.processes = {
            [
                (pid: 101, argv: ["/usr/local/bin/macprovider-cli", "serve"]),
                (pid: 202, argv: ["/opt/macprovider-cli", "serve", "--port", "8080"]),
                (pid: 303, argv: ["/usr/bin/python3", "server.py"]),
            ]
        }
        workflow.listenerPIDs = { [101, 404] }

        let lines = workflow.resourceCheck().joined(separator: "\n")

        XCTAssertTrue(lines.contains("pids 101, 202"), lines)
        XCTAssertTrue(lines.contains("pids 101, 404"), lines)
        XCTAssertTrue(lines.contains("never stops processes"), lines)
    }

    func testContextCommandsParseUnderProviderGroup() throws {
        let set = try XCTUnwrap(try MacProviderCLI.parseAsRoot(["provider", "context", "set", "200000", "--preflight", "--apply"]) as? ProviderContextSetCommand)
        XCTAssertEqual(set.tokens, 200_000)
        XCTAssertTrue(set.preflight)
        XCTAssertTrue(set.apply)
        XCTAssertTrue(try MacProviderCLI.parseAsRoot(["provider", "context", "explain"]) is ProviderContextExplainCommand)
        XCTAssertTrue(try MacProviderCLI.parseAsRoot(["provider", "context", "rollback"]) is ProviderContextRollbackCommand)
    }

    // MARK: - Fixtures

    private func recommendation(context: Int) -> RecommendationCore {
        RecommendationCore(
            model: "mlx-community/Qwen3.6-27B-4bit",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 8, maxContext: context),
            tpsMedian: 30,
            ttftP95MS: 0,
            replicates: 0
        )
    }

    private static func report(_ outcome: ProviderVerifyReport.Outcome) -> ProviderVerifyReport {
        let pass = outcome == .agree
        return ProviderVerifyReport(
            outcome: outcome,
            layers: [
                .init(layer: .local, state: pass ? .pass : .fail, reason: pass ? "ready" : "model not loaded"),
                .init(layer: .network, state: pass ? .pass : .pending, reason: "connected"),
                .init(layer: .publicFeed, state: pass ? .pass : .pending, reason: "lists model"),
            ],
            proof: .init(providerID: "mp-1", model: "m", artifactSHA256: "abc", maxContextTokens: 120_000, slots: 8, catalogReleaseID: "r", feedGeneratedAt: "t"),
            feedLagSeconds: 1,
            unverifiableFields: ProviderVerifier.unverifiableFields
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct Fixture {
    let directory: URL
    let configURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.yaml")
    }

    var applier: ConfigApplier { ConfigApplier(configPath: configURL) }

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    func load() throws -> AppConfig {
        try ConfigLoader.load(cli: CLIOverrides(configPath: configURL.path), environment: [:])
    }

    func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("config.yaml.bak-") }
    }

    func workflow(physicalMemoryGB: Int = 256) -> ProviderContextWorkflow {
        ProviderContextWorkflow(
            configPath: configURL.path,
            port: 18_080,
            physicalMemoryGB: physicalMemoryGB,
            fetchStatus: { nil },
            modelFacts: {
                .init(declaredMax: 262_144, tokenizerMax: 262_144, kvBytesPerToken: 65_536, weightsBytes: 15 << 30)
            },
            processes: { [] },
            listenerPIDs: { [] },
            restart: {},
            verify: { _ in ProviderVerifyReport(outcome: .agree, layers: [], proof: .init(), feedLagSeconds: nil, unverifiableFields: []) },
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }
}
