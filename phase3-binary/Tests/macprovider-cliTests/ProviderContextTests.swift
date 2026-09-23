import CryptoKit
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
        let provenance = try XCTUnwrap(loaded.maxContextProvenance)
        XCTAssertEqual(provenance.value, 200_000)
        XCTAssertEqual(provenance.benchmarkID, "spec-023-qwen-1")
        XCTAssertEqual(provenance.model, "mlx-community/Qwen3.6-27B-4bit")
        XCTAssertEqual(provenance.generatedAt, "2026-09-21T14:13:20Z")
        let text = try fixture.configText()
        XCTAssertTrue(text.contains(
            #"max_context_override_provenance: {source: "recommendation_apply", value: 200000, model: "mlx-community/Qwen3.6-27B-4bit", benchmark_id: "spec-023-qwen-1", generated_at: "2026-09-21T14:13:20Z"}"#
        ), text)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter { $0.hasSuffix(".json") },
            [],
            "no provenance file beside the config"
        )
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

    func testConfigWithoutProvenanceLoadsUnchangedAsOperatorConfig() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")

        let loaded = try fixture.load()

        XCTAssertEqual(loaded.maxContextOverride, 4_000)
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig)
    }

    // MARK: - Model switch (FR-20b)

    private static let qwen36IDs = ["qwen/qwen3.6-27b", "mlx-community/Qwen3.6-27B-4bit"]

    func testGeneratedContextIsRecomputedWhenTheServedModelChanges() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextSource, .recommendationApply)

        let toNewModel = ModelSwitchContext.decide(
            config: loaded, targetModelIDs: Self.qwen36IDs,
            recomputedContext: 200_000, supportedContext: 200_000
        )
        XCTAssertEqual(toNewModel, .generated(200_000))
        XCTAssertEqual(
            ModelsSwitchCommand.contextNotice(
                targetModelID: "qwen/qwen3.6-27b", servedContext: 200_000, servedSource: "recommendation_adoption", config: loaded
            ),
            "Context window: 200000 tokens, recomputed for qwen/qwen3.6-27b (the configured 32768 was generated for another model)."
        )

        let backToGeneratedModel = ModelSwitchContext.decide(
            config: loaded, targetModelIDs: ["MLX-Community/Qwen3-8B-4bit"],
            recomputedContext: 40_000, supportedContext: 40_000
        )
        XCTAssertEqual(backToGeneratedModel, .generated(32_768), "the model the value was generated for keeps the recorded value")
        XCTAssertNil(ModelsSwitchCommand.contextNotice(
            targetModelID: "mlx-community/Qwen3-8B-4bit", servedContext: 32_768, servedSource: "recommendation_adoption", config: loaded
        ))
    }

    func testOperatorContextIsKeptOnModelSwitchAndWarnsWhenUnderHalfOfTheNewModel() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        try fixture.applier.setOperatorOwnedValue(key: "max_context_override", value: "16000", now: now)
        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig)

        let underUsed = ModelSwitchContext.decide(
            config: loaded, targetModelIDs: Self.qwen36IDs,
            recomputedContext: 200_000, supportedContext: 200_000
        )
        guard case .operatorOwned(let warning) = underUsed else {
            return XCTFail("operator value must be preserved, got \(underUsed)")
        }
        let line = try XCTUnwrap(warning)
        XCTAssertFalse(line.contains("\n"), "one-line warning")
        XCTAssertTrue(line.contains("well below what this Mac and model support (200000 tokens)"), line)

        let fine = ModelSwitchContext.decide(
            config: loaded, targetModelIDs: Self.qwen36IDs,
            recomputedContext: 30_000, supportedContext: 30_000
        )
        XCTAssertEqual(fine, .operatorOwned(warning: nil))
    }

    func testStaleProvenanceValueIsTreatedAsOperatorOwnedOnModelSwitch() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 40_000), now: now)
        let edited = try String(contentsOf: fixture.configURL)
            .replacingOccurrences(of: "max_context_override: 40000", with: "max_context_override: 32768")
        try fixture.writeConfig(edited)
        let loaded = try fixture.load()
        XCTAssertTrue(try fixture.configText().contains("value: 40000"), "the record still claims the old value")
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig)
        XCTAssertNil(loaded.maxContextProvenance)

        let decision = ModelSwitchContext.decide(
            config: loaded, targetModelIDs: Self.qwen36IDs,
            recomputedContext: 200_000, supportedContext: 200_000
        )
        guard case .operatorOwned(let warning) = decision else {
            return XCTFail("a value that no longer matches its record is operator-owned, got \(decision)")
        }
        XCTAssertNotNil(warning)
    }

    // MARK: - Provenance binding and rollback (FR-20b)

    func testEditToAnotherKeyKeepsTheGeneratedContext() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)

        // Provenance is scoped to max_context_override: other first-party or
        // operator writes (log level, credential lines) do not transfer it.
        try fixture.writeConfig(try String(contentsOf: fixture.configURL) + "log_level: debug\nprovider_token: mp_live_example\n")

        XCTAssertEqual(try fixture.load().maxContextOverride, 32_768)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)
    }

    func testManualEditToTheGeneratedNumberStaysGenerated() throws {
        // Documented trade-off (SPEC-001 FR-20b): a hand edit that writes
        // exactly the generated number cannot be told from the generated
        // value, so it stays generated and a later switch recomputes it.
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        let rewritten = try String(contentsOf: fixture.configURL)
            .replacingOccurrences(of: "max_context_override: 32768", with: "max_context_override:   32768")

        try fixture.writeConfig(rewritten)

        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)
    }

    func testIncompleteOrMalformedProvenanceIsOperatorConfigAndNeverFailsTheLoad() throws {
        let fixture = try Fixture()
        let malformed = [
            #"{source: "recommendation_apply", value: 32768, generated_at: "2026-09-21T14:13:20Z"}"#,
            #"{source: "recommendation_apply", value: 32768, model: " "}"#,
            #"{source: "operator", value: 32768, model: "m"}"#,
            #"{source: "recommendation_apply", value: "32768", model: "m"}"#,
            #"{source: "recommendation_apply", value: 16000, model: "m"}"#,
            #"[recommendation_apply, 32768, m]"#,
            "recommendation_apply",
            "",
        ]
        for record in malformed {
            try fixture.writeConfig("model: m\nmax_context_override: 32768\nmax_context_override_provenance: \(record)\n")
            let loaded = try fixture.load()
            XCTAssertEqual(loaded.maxContextOverride, 32_768, record)
            XCTAssertEqual(loaded.maxContextSource, .operatorConfig, record)
            XCTAssertNil(loaded.maxContextProvenance, record)
        }

        try fixture.writeConfig("""
        model: m
        max_context_override: 32768
        max_context_override_provenance:
          source: recommendation_apply
          value: 32768
          model: m
        """)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply, "a hand-written block mapping reads the same")
    }

    func testBlockFormProvenanceIsReplacedWholeByTheNextWrite() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("""
        model: m
        max_context_override: 32768
        max_context_override_provenance:
          source: recommendation_apply
          value: 32768
          model: m
        log_level: debug

        """)

        try fixture.applier.setOperatorOwnedValue(key: "max_context_override", value: "16000", now: now)

        XCTAssertEqual(try fixture.configText(), "model: m\nmax_context_override: 16000\nlog_level: debug\n")
        XCTAssertEqual(try fixture.load().maxContextSource, .operatorConfig)
    }

    func testSymlinkedConfigCarriesProvenanceThroughApplyReloadAndSwitch() throws {
        let fixture = try Fixture()
        let realDirectory = fixture.directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let realConfig = realDirectory.appendingPathComponent("config.yaml")
        try Data("model: mlx-community/Qwen3-8B-4bit\n".utf8).write(to: realConfig)
        try FileManager.default.createSymbolicLink(at: fixture.configURL, withDestinationURL: realConfig)

        _ = try ConfigApplier(configPath: fixture.configURL)
            .apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.configURL.path),
            realConfig.path,
            "the link still points at the real config"
        )
        XCTAssertTrue(try String(contentsOf: realConfig).contains("max_context_override_provenance: "))
        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextSource, .recommendationApply)
        XCTAssertEqual(
            ModelSwitchContext.decide(
                config: loaded, targetModelIDs: Self.qwen36IDs,
                recomputedContext: 200_000, supportedContext: 200_000
            ),
            .generated(200_000)
        )
    }

    func testServeArtifactPathCanonicalizationKeepsGeneratedContextAndSwitchRecomputes() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        var rec = recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768)
        rec.modelArtifactPath = "/old/models/qwen3-8b"
        _ = try fixture.applier.apply(recommendation: rec, now: now)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)

        // serve's first-party model_artifact_path canonicalization rewrite.
        try ServeCommand.persistMigratedArtifactPath(
            configPath: fixture.configURL.path,
            from: "/old/models/qwen3-8b",
            to: "/durable/models/qwen3-8b"
        )
        XCTAssertTrue(try String(contentsOf: fixture.configURL).contains("model_artifact_path: /durable/models/qwen3-8b"))

        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextSource, .recommendationApply)
        XCTAssertEqual(
            ModelSwitchContext.decide(
                config: loaded, targetModelIDs: Self.qwen36IDs,
                recomputedContext: 200_000, supportedContext: 200_000
            ),
            .generated(200_000)
        )
    }

    func testRollbackAfterOperatorSetRestoresGeneratedValueAndProvenance() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\nprovider_token: keep-me\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        var workflow = fixture.workflow()
        _ = try await workflow.set(tokens: 16_000, preflight: false, apply: false)
        XCTAssertEqual(try fixture.load().maxContextSource, .operatorConfig)
        workflow.verify = { _ in Self.report(.agree) }

        let outcome = try await workflow.rollback()

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextOverride, 32_768)
        XCTAssertEqual(loaded.maxContextSource, .recommendationApply)
        XCTAssertEqual(
            ModelSwitchContext.decide(
                config: loaded, targetModelIDs: Self.qwen36IDs,
                recomputedContext: 200_000, supportedContext: 200_000
            ),
            .generated(200_000),
            "a restored generated value follows the served model again"
        )

        // Rolling back the rollback returns the operator value, operator-owned.
        _ = try await workflow.rollback()
        XCTAssertEqual(try fixture.load().maxContextOverride, 16_000)
        XCTAssertEqual(try fixture.load().maxContextSource, .operatorConfig)
    }

    func testRollbackToAnOperatorBackupClearsGeneratedProvenance() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "m", context: 32_768), now: now)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)
        var workflow = fixture.workflow()
        workflow.verify = { _ in Self.report(.agree) }

        _ = try await workflow.rollback()

        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextOverride, 4_000)
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig)
        XCTAssertFalse(try fixture.configText().contains("max_context_override_provenance"), "the backup had no record, so none is restored")
    }

    func testFailedAdoptionRestoreKeepsGeneratedProvenanceOfThePreviousApply() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        let before = try fixture.applier.recommendationOwnedFieldValues()
        XCTAssertNotNil(before[MaxContextProvenance.configKey], "the record is a recommendation-owned field")
        _ = try fixture.applier.apply(recommendation: recommendation(context: 200_000), now: now)

        // Value restore driven by the adoption journal.
        _ = try fixture.applier.restoreRecommendationOwnedFields(before, now: now)
        XCTAssertEqual(try fixture.load().maxContextOverride, 32_768)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)

        // Backup-driven restore of the same adoption.
        let second = try fixture.applier.apply(recommendation: recommendation(context: 200_000), now: now)
        _ = try fixture.applier.restoreRecommendationOwnedFields(from: second.backupPath, now: now)
        XCTAssertEqual(try fixture.load().maxContextOverride, 32_768)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)
    }

    func testAdoptionCrashRecoveryOfAnEqualValueApplyRestoresOperatorOwnership() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\nmax_context_override: 32768\n")
        XCTAssertEqual(try fixture.load().maxContextSource, .operatorConfig)
        var journal: RecommendationAdoptionJournalRecord?
        _ = try fixture.applier.apply(
            recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768),
            now: now,
            beforeMutation: { before, after, _, preSHA, postSHA in
                journal = RecommendationAdoptionJournalRecord(
                    transactionID: UUID().uuidString,
                    fromModelID: "mlx-community/Qwen3-8B-4bit",
                    targetModelID: "mlx-community/Qwen3-8B-4bit",
                    recommendationSHA256: String(repeating: "a", count: 64),
                    configPath: fixture.configURL.path,
                    preApplyConfigSHA256: preSHA,
                    postApplyConfigSHA256: postSHA,
                    redactedBackupPath: "redacted",
                    recommendationOwnedFieldsBefore: before,
                    recommendationOwnedFieldsAfter: after,
                    now: self.now
                )
            }
        )
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply, "same number, now generated")
        let record = try XCTUnwrap(journal).validated()
        XCTAssertNotNil(record.recommendationOwnedFieldsAfter[MaxContextProvenance.configKey])

        // Crash recovery before the runtime committed restores the "before"
        // fields under the config lock, exactly as recovery does.
        try fixture.applier.withExclusiveRecommendationMutation { mutation in
            let snapshot = try mutation.snapshot()
            XCTAssertEqual(snapshot.values, record.recommendationOwnedFieldsAfter)
            _ = try mutation.restore(record.recommendationOwnedFieldsBefore, now: now)
            XCTAssertEqual(try mutation.snapshot().values, record.recommendationOwnedFieldsBefore)
        }

        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextOverride, 32_768)
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig)
        XCTAssertFalse(try fixture.configText().contains("max_context_override_provenance"))
    }

    func testFailedContextSetWriteLeavesValueAndProvenanceIntact() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "m", context: 32_768), now: now)
        let configBefore = try fixture.configText()
        // The injected temp path cannot be created, so the config write throws.
        let failing = ConfigApplier(configPath: fixture.configURL, tempFileNamer: { destination, _ in
            destination.deletingLastPathComponent().appendingPathComponent("missing-directory/config.yaml.tmp")
        })

        XCTAssertThrowsError(try failing.setOperatorOwnedValue(key: "max_context_override", value: "16000", now: now))
        XCTAssertThrowsError(try failing.rollbackToNewestBackup(now: now))

        XCTAssertEqual(try fixture.configText(), configBefore)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)
    }

    func testSwitchFromSmallModelToQwen36On256GBMacRecomputesAFullContextNotFourK() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        let configData = Data(AutotuneRecommendTests.qwen36TwentySevenBConfigJSON.utf8)

        let recomputed = ModelSwitchContext.recomputedContext(
            memoryGB: 256,
            modelID: "mlx-community/Qwen3.6-27B-4bit",
            catalogMinRAMGB: 24,
            configJSONData: configData,
            configSHA256: SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined(),
            draftModel: nil,
            slots: 8
        )
        XCTAssertNotEqual(recomputed, AutotuneModelContextCap.minimumServeContext)
        XCTAssertEqual(recomputed, 200_000)

        let decision = ModelSwitchContext.decide(
            config: try fixture.load(), targetModelIDs: Self.qwen36IDs,
            recomputedContext: recomputed, supportedContext: 200_000
        )
        XCTAssertEqual(decision, .generated(200_000))
    }

    func testSwitchRecomputeWithADraftModelStaysUnderTheDraftCap() throws {
        let configData = Data(AutotuneRecommendTests.qwen36TwentySevenBConfigJSON.utf8)
        func recomputed(draftModel: String?) -> Int {
            ModelSwitchContext.recomputedContext(
                memoryGB: 256,
                modelID: "mlx-community/Qwen3.6-27B-4bit",
                catalogMinRAMGB: 24,
                configJSONData: configData,
                configSHA256: SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined(),
                draftModel: draftModel,
                slots: draftModel == nil ? 8 : 1
            )
        }
        XCTAssertEqual(recomputed(draftModel: nil), 200_000)
        XCTAssertEqual(recomputed(draftModel: "mlx-community/Qwen3-0.6B-4bit"), 120_000)
    }

    /// SPEC-023-R018 item 9: a switch keeps the operator's slot count and
    /// lowers the recomputed context until that many full-context KV caches
    /// fit memory. GLM-4.5-Air on a 256 GB Mac fits 5 slots at its declared
    /// 131,072 tokens; with 8 configured slots the context comes down.
    func testSwitchRecomputeLowersTheContextToFitTheConfiguredSlots() throws {
        let geometry = try XCTUnwrap(AutotuneRecommendTests.signedCandidateConfigGeometry["z-ai/glm-4.5-air"])
        let configData = Data(geometry.json.utf8)
        let configSHA256 = SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()
        func recomputed(slots: Int) -> Int {
            ModelSwitchContext.recomputedContext(
                memoryGB: 256,
                modelID: "mlx-community/GLM-4.5-Air-4bit",
                catalogMinRAMGB: 80,
                configJSONData: configData,
                configSHA256: configSHA256,
                draftModel: nil,
                slots: slots
            )
        }
        func fit(_ context: Int) throws -> Int {
            try XCTUnwrap(AutotuneModelContextCap.memoryFitBatchDepth(
                configData: configData,
                verifiedConfigSHA256: configSHA256,
                hardwareMemoryGB: 256,
                catalogMinRAMGB: 80,
                calibrationContextTokens: context
            ))
        }
        XCTAssertEqual(recomputed(slots: 1), 131_072)
        XCTAssertEqual(recomputed(slots: 5), 131_072, "five slots already fit at the declared maximum")
        let eight = recomputed(slots: 8)
        XCTAssertLessThan(eight, 131_072)
        XCTAssertGreaterThanOrEqual(try fit(eight), 8, "eight slots fit at the lowered context")
        XCTAssertLessThan(try fit(eight + 1), 8, "the lowered context is the largest that fits eight slots")
    }

    /// SPEC-023-R018 item 9 (e): when even the 4000-token floor does not fit
    /// the configured slots, the switch keeps the floor and lowers the slot
    /// count to what fits there, so it never serves an over-envelope pair.
    func testSwitchRecomputeLowersSlotsWhenEvenTheFloorContextDoesNotFit() throws {
        let geometry = try XCTUnwrap(AutotuneRecommendTests.signedCandidateConfigGeometry["z-ai/glm-4.5-air"])
        let configData = Data(geometry.json.utf8)
        let configSHA256 = SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()
        let floor = AutotuneModelContextCap.minimumServeContext
        let fitAtFloor = try XCTUnwrap(AutotuneModelContextCap.memoryFitBatchDepth(
            configData: configData, verifiedConfigSHA256: configSHA256,
            hardwareMemoryGB: 86, catalogMinRAMGB: 80, calibrationContextTokens: floor
        ))
        XCTAssertLessThan(fitAtFloor, 8, "fixture: eight slots do not fit even at the floor")

        XCTAssertNil(AutotuneModelContextCap.memoryBoundedContext(
            131_072, slots: 8, verifiedConfigJSONData: configData, verifiedConfigSHA256: configSHA256,
            hardwareMemoryGB: 86, catalogMinRAMGB: 80
        ), "the floor is not returned as if it fit")

        let knobs = ModelSwitchContext.recomputedServeKnobs(
            memoryGB: 86, modelID: "mlx-community/GLM-4.5-Air-4bit", catalogMinRAMGB: 80,
            configJSONData: configData, configSHA256: configSHA256, draftModel: nil, slots: 8
        )
        XCTAssertLessThanOrEqual(knobs.context, floor)
        XCTAssertEqual(knobs.slots, fitAtFloor)
        let fitAtServed = try XCTUnwrap(AutotuneModelContextCap.memoryFitBatchDepth(
            configData: configData, verifiedConfigSHA256: configSHA256,
            hardwareMemoryGB: 86, catalogMinRAMGB: 80, calibrationContextTokens: knobs.context
        ))
        XCTAssertGreaterThanOrEqual(fitAtServed, knobs.slots, "the served pair fits the envelope")

        let fitting = ModelSwitchContext.recomputedServeKnobs(
            memoryGB: 256, modelID: "mlx-community/GLM-4.5-Air-4bit", catalogMinRAMGB: 80,
            configJSONData: configData, configSHA256: configSHA256, draftModel: nil, slots: 8
        )
        XCTAssertEqual(fitting.slots, 8, "slots are kept whenever a context at or above the floor fits them")
    }

    func testServeSwitchSlotsFollowEachGeneratedTargetAndSkipOperatorValues() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        let targets: [(ids: [String], slots: Int)] = [(Self.qwen36IDs, 2)]

        let generated = ModelSwitchContext.serveSlotsByTarget(
            config: try fixture.load(),
            configuredModelIDs: ["mlx-community/Qwen3-8B-4bit", "qwen3-8b"], targets: targets, configuredSlots: 8
        )
        XCTAssertEqual(generated, [
            "qwen/qwen3.6-27b": 2,
            "mlx-community/qwen3.6-27b-4bit": 2,
            "mlx-community/qwen3-8b-4bit": 8,
            "qwen3-8b": 8,
        ])

        try fixture.applier.setOperatorOwnedValue(key: "max_context_override", value: "16000", now: now)
        XCTAssertEqual(ModelSwitchContext.serveSlotsByTarget(
            config: try fixture.load(),
            configuredModelIDs: ["mlx-community/Qwen3-8B-4bit"], targets: targets, configuredSlots: 8
        ), [:])
    }

    func testServeSwitchContextsCoverGeneratedTargetsAndSkipOperatorValues() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        let targets: [(ids: [String], recomputed: Int)] = [(Self.qwen36IDs, 200_000)]

        let generated = ModelSwitchContext.serveContextsByTarget(
            config: try fixture.load(),
            configuredModelIDs: ["mlx-community/Qwen3-8B-4bit", "qwen3-8b"], targets: targets
        )
        XCTAssertEqual(generated, [
            "qwen/qwen3.6-27b": 200_000,
            "mlx-community/qwen3.6-27b-4bit": 200_000,
            "mlx-community/qwen3-8b-4bit": 32_768,
            "qwen3-8b": 32_768,
        ])

        try fixture.applier.setOperatorOwnedValue(key: "max_context_override", value: "16000", now: now)
        let operatorOwned = ModelSwitchContext.serveContextsByTarget(
            config: try fixture.load(),
            configuredModelIDs: ["mlx-community/Qwen3-8B-4bit"], targets: targets
        )
        XCTAssertEqual(operatorOwned, [:], "an operator value is served unchanged for every model")
    }

    /// #1689 L2: only the model the provenance record names (and the ids of
    /// the same model) serve `recommendation_apply` after a switch.
    func testSwitchProvenanceModelIDsAreTheRecordedModelAndItsAliases() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/Qwen3-8B-4bit", context: 32_768), now: now)
        let targets: [(ids: [String], recomputed: Int)] = [
            (Self.qwen36IDs, 32_768),
            (["qwen3-8b", "mlx-community/Qwen3-8B-4bit"], 32_768),
        ]
        let ids = ModelSwitchContext.provenanceModelIDs(
            config: try fixture.load(),
            configuredModelIDs: ["mlx-community/Qwen3-8B-4bit", "qwen3-8b"],
            targets: targets
        )
        XCTAssertEqual(ids, ["mlx-community/qwen3-8b-4bit", "qwen3-8b"])

        try fixture.applier.setOperatorOwnedValue(key: "max_context_override", value: "16000", now: now)
        XCTAssertEqual(ModelSwitchContext.provenanceModelIDs(
            config: try fixture.load(),
            configuredModelIDs: ["mlx-community/Qwen3-8B-4bit"],
            targets: targets
        ), [], "an operator value has no provenance model")
    }

    func testModelsSwitchPrintsOneLineWarningForAnUnderUsedOperatorContext() throws {
        let fixture = try Fixture()
        let root = fixture.directory.appendingPathComponent("models", isDirectory: true)
        let artifact = try DurableModelArtifactStore(root: root).artifactURL(
            modelID: "mlx-community/Qwen3.6-27B-4bit",
            revision: "c000ac2c2057d94be3fa931000c31723aac53282",
            sha256: "518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931"
        )
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(AutotuneRecommendTests.qwen36TwentySevenBConfigJSON.utf8)
            .write(to: artifact.appendingPathComponent("config.json"))
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\nmodel_artifact_root: \(root.path)\nmax_context_override: 4000\n")
        let config = try fixture.load()

        let notice = try XCTUnwrap(ModelsSwitchCommand.contextNotice(
            targetModelID: "qwen/qwen3.6-27b", servedContext: 4_000, servedSource: "operator_config", config: config
        ))
        XCTAssertFalse(notice.contains("\n"), notice)
        XCTAssertTrue(notice.hasPrefix("Warning: this cap is well below what this Mac and model support"), notice)
        XCTAssertNil(ModelsSwitchCommand.contextNotice(
            targetModelID: "./local-checkpoint", servedContext: 4_000, servedSource: "operator_config", config: config
        ))
        XCTAssertNil(
            ModelsSwitchCommand.contextNotice(targetModelID: "qwen/qwen3.6-27b", servedContext: nil, servedSource: nil, config: config),
            "an older serve that does not report the applied context gets no notice rather than a guess"
        )
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
        workflow.restart = { _ in restarts.increment() }
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
        workflow.modelFacts = { _ in
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

    /// #1689: `set` resolves the draft term like every other writer; a blank
    /// draft_model (serve refuses it) or a config serve cannot load is refused
    /// instead of written without the draft cap.
    func testContextSetRefusesAConfigWhoseDraftModelServeCannotResolve() async throws {
        let fixture = try Fixture()
        for text in ["model: m\ndraft_model: \"  \"\n", "model: m\ndraft_model: d\nmax_concurrency_override: many\n"] {
            try fixture.writeConfig(text)
            let refused = try await fixture.workflow(physicalMemoryGB: 256).set(tokens: 150_000, preflight: false, apply: false)
            XCTAssertEqual(refused.exitCode, 1, refused.text)
            XCTAssertTrue(refused.text.contains("draft_model"), refused.text)
            XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), text)
            XCTAssertEqual(fixture.backups(), [])
        }
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
        workflow.restart = { _ in restarts.increment() }
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

    // MARK: - Transactional context mutations (#1689 R5)

    /// `--apply` restarts from config.yaml, so memory is checked for the slot
    /// count serve runs after the restart, never the running provider's.
    func testContextSetChecksTheSlotCountServeRunsAfterRestartNotTheLiveOne() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 16000\nmax_concurrency_override: 8\n")
        let before = try fixture.configText()
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        workflow.fetchStatus = { ["capacity": ["max_concurrency": 1, "max_context_tokens": 16_000]] }
        workflow.modelFacts = { _ in
            .init(declaredMax: 262_144, tokenizerMax: nil, kvBytesPerToken: 262_144, weightsBytes: 15 << 30)
        }

        let outcome = try await workflow.set(tokens: 120_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("8 slots"), outcome.text)
        XCTAssertTrue(outcome.text.contains("Refused"), outcome.text)
        XCTAssertEqual(try fixture.configText(), before)
        XCTAssertEqual(fixture.backups(), [])
    }

    /// A draft model added between the preflight and the write (the App or
    /// autotune) is caught under the config lock: the preflight runs again on
    /// the new file and refuses.
    func testContextSetRePreflightsWhenADraftModelIsAddedBeforeTheLock() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 16000\n")
        let concurrent = "model: m\ndraft_model: d\nmax_context_override: 16000\n"
        let calls = Counter()
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        workflow.modelFacts = { _ in
            if calls.value == 0 { try? fixture.writeConfig(concurrent) }
            calls.increment()
            return .init(declaredMax: 262_144, tokenizerMax: nil, kvBytesPerToken: 65_536, weightsBytes: 15 << 30)
        }

        let outcome = try await workflow.set(tokens: 150_000, preflight: false, apply: false)

        XCTAssertEqual(outcome.exitCode, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("120000-token limit"), outcome.text)
        XCTAssertEqual(calls.value, 2, "the preflight ran again on the changed file")
        XCTAssertEqual(try fixture.configText(), concurrent)
        XCTAssertEqual(fixture.backups(), [])
    }

    func testContextSetGivesUpWhenTheConfigKeepsChangingAndWritesNothing() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 16000\n")
        let calls = Counter()
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        workflow.modelFacts = { _ in
            calls.increment()
            try? fixture.writeConfig("model: m\nmax_context_override: 16000\nmax_concurrency_override: \(calls.value)\n")
            return .init(declaredMax: 262_144, tokenizerMax: nil, kvBytesPerToken: 65_536, weightsBytes: 15 << 30)
        }

        let outcome = try await workflow.set(tokens: 120_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("kept changing"), outcome.text)
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(try fixture.load().maxContextOverride, 16_000)
        XCTAssertEqual(fixture.backups(), [])
    }

    /// Rollback validates the restored values beside the fields it does not
    /// own: a context above the draft cap of a draft model added since the
    /// backup is refused, not written for serve to refuse.
    func testRollbackRestoringAContextAboveTheCurrentDraftCapIsRefused() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 200000\n")
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        _ = try await workflow.set(tokens: 16_000, preflight: false, apply: false)
        try fixture.writeConfig(try fixture.configText() + "draft_model: d\n")
        let before = try fixture.configText()
        let restarts = Counter()
        workflow.restart = { _ in restarts.increment() }

        let outcome = try await workflow.rollback()

        XCTAssertEqual(outcome.exitCode, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("120000-token limit"), outcome.text)
        XCTAssertEqual(try fixture.configText(), before)
        XCTAssertEqual(fixture.backups().count, 1, "no backup of a refused rollback")
        XCTAssertEqual(restarts.value, 0)
    }

    func testBlockFormProvenanceSurvivesContextRollback() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig(Self.blockFormGeneratedConfig)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)
        var workflow = fixture.workflow()
        workflow.verify = { _ in Self.report(.agree) }
        _ = try await workflow.set(tokens: 16_000, preflight: false, apply: false)

        let outcome = try await workflow.rollback()

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        XCTAssertEqual(try fixture.load().maxContextOverride, 32_768)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply, (try? fixture.configText()) ?? "")
    }

    func testBlockFormProvenanceSurvivesAdoptionCrashRecoveryRestore() throws {
        let fixture = try Fixture()
        try fixture.writeConfig(Self.blockFormGeneratedConfig)
        let before = try fixture.applier.recommendationOwnedFieldValues()
        _ = try fixture.applier.apply(recommendation: recommendation(model: "m", context: 200_000), now: now)

        try fixture.applier.withExclusiveRecommendationMutation { mutation in
            _ = try mutation.restore(before, now: now)
        }

        XCTAssertEqual(try fixture.load().maxContextOverride, 32_768)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply, (try? fixture.configText()) ?? "")
    }

    private static let blockFormGeneratedConfig = """
    model: m
    max_context_override: 32768
    max_context_override_provenance:
      source: recommendation_apply
      value: 32768
      model: m
    log_level: debug

    """

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

        XCTAssertTrue(lines.contains("other serve processes on this Mac: pids 202."), "101 listens on the queried port, so it is this provider: \(lines)")
        XCTAssertFalse(lines.contains("more than one provider process"), "serves on other ports and configs are not called extra: \(lines)")
        XCTAssertTrue(lines.contains("pids 101, 404"), lines)
        XCTAssertTrue(lines.contains("never stops processes"), lines)
    }

    // MARK: - Studio E2E findings (#1689 Loop A)

    /// F2: serve runs one slot when config.yaml sets no
    /// `max_concurrency_override`, so the memory check counts one.
    func testServeAndContextCommandsShareTheSlotResolution() {
        XCTAssertEqual(ProviderCapacity.servedSlotCount(maxConcurrencyOverride: nil), 1)
        XCTAssertEqual(ProviderCapacity.servedSlotCount(maxConcurrencyOverride: 6), 6)
    }

    func testContextSetCountsOneSlotWhenTheConfigSetsNoSlotOverride() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 16000\n")
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        workflow.fetchStatus = { ["capacity": ["max_concurrency": 8, "max_context_tokens": 16_000]] }
        workflow.modelFacts = { _ in
            .init(declaredMax: 262_144, tokenizerMax: nil, kvBytesPerToken: 262_144, weightsBytes: 15 << 30)
        }

        let outcome = try await workflow.set(tokens: 120_000, preflight: true, apply: false)

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains("for 1 slots"), outcome.text)
        XCTAssertTrue(outcome.text.contains("after a restart it uses 1 (serve's default without max_concurrency_override)"), outcome.text)
        XCTAssertFalse(outcome.text.contains("from config.yaml"), outcome.text)
    }

    func testExplainCountsOneSlotWithoutARunningProviderOrSlotOverride() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 16000\n")

        let text = await fixture.workflow(physicalMemoryGB: 256).explain()

        XCTAssertTrue(text.contains("Slots:        1"), text)
    }

    /// F3: `--apply` restarts the installed launchd job, so it is refused
    /// unless that job runs this config on this port.
    func testContextSetApplyIsRefusedForAConfigTheInstalledServiceDoesNotRun() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        let before = try fixture.configText()
        var workflow = fixture.workflow()
        let restarts = Counter()
        workflow.restart = { _ in restarts.increment() }
        workflow.installedService = { .found(.init(domain: "gui/501", configPath: "/Users/someone/.config/macprovider/config.yaml", port: 8_080)) }

        let outcome = try await workflow.set(tokens: 120_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 1, outcome.text)
        XCTAssertEqual(restarts.value, 0)
        XCTAssertEqual(try fixture.configText(), before, "nothing is written when --apply is refused")
        XCTAssertEqual(fixture.backups(), [])
        XCTAssertTrue(outcome.text.contains("the installed service gui/501/live.malibu.provider runs /Users/someone/.config/macprovider/config.yaml on port 8080; this config is \(fixture.configURL.path) on port 18080"), outcome.text)
        XCTAssertTrue(outcome.text.contains("provider verify"), outcome.text)
        XCTAssertTrue(outcome.text.contains("--port 18080"), outcome.text)

        workflow.installedService = { .found(.init(domain: "gui/501", configPath: fixture.configURL.path, port: 8_080)) }
        let otherPort = try await workflow.set(tokens: 120_000, preflight: false, apply: true)
        XCTAssertEqual(otherPort.exitCode, 1, otherPort.text)
        XCTAssertEqual(restarts.value, 0, "same config on another port is another provider")

        workflow.installedService = { .none }
        let noService = try await workflow.set(tokens: 120_000, preflight: false, apply: true)
        XCTAssertEqual(noService.exitCode, 1, noService.text)
        XCTAssertEqual(restarts.value, 0)
        XCTAssertTrue(noService.text.contains("none found"), noService.text)
    }

    func testContextSetApplyRestartsWhenTheInstalledServiceRunsThisConfigThroughASymlink() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        let link = fixture.directory.appendingPathComponent("linked.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.configURL)
        var workflow = fixture.workflow()
        let restarts = Counter()
        workflow.restart = { _ in restarts.increment() }
        workflow.verify = { _ in Self.report(.agree) }
        workflow.installedService = { .found(.init(domain: "gui/501", configPath: link.path, port: 18_080)) }

        let outcome = try await workflow.set(tokens: 120_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        XCTAssertEqual(restarts.value, 1)
    }

    func testRollbackRefusesToRestartAnotherServiceAndNoRestartOnlyRestores() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        var workflow = fixture.workflow()
        _ = try await workflow.set(tokens: 120_000, preflight: false, apply: false)
        let restarts = Counter()
        workflow.restart = { _ in restarts.increment() }
        workflow.installedService = { .found(.init(domain: "gui/501", configPath: "/elsewhere/config.yaml", port: 8_080)) }

        let refused = try await workflow.rollback()
        XCTAssertEqual(refused.exitCode, 1, refused.text)
        XCTAssertEqual(try fixture.load().maxContextOverride, 120_000, "a refused rollback restores nothing")
        XCTAssertTrue(refused.text.contains("--no-restart"), refused.text)

        let restored = try await workflow.rollback(restart: false)
        XCTAssertEqual(restored.exitCode, 0, restored.text)
        XCTAssertEqual(try fixture.load().maxContextOverride, 4_000)
        XCTAssertEqual(restarts.value, 0)
        XCTAssertTrue(restored.text.contains("malibu-cli provider verify"), restored.text)
        XCTAssertTrue(restored.text.contains("--port 18080"), restored.text)
    }

    func testInstalledServiceIsReadFromTheLaunchdPlist() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nport: 18090\n")
        func plist(_ arguments: [String], environment: [String: String] = [:]) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "Label": "live.malibu.provider",
                    "ProgramArguments": arguments,
                    "EnvironmentVariables": environment,
                ] as [String: Any],
                format: .xml,
                options: 0
            )
        }

        let fromArgument = ProviderContextWorkflow.installedService(
            plistData: try plist(["/Users/u/macprovider/macprovider-cli", "serve", "--config", fixture.configURL.path]),
            domain: "gui/501"
        )
        XCTAssertEqual(fromArgument, .init(domain: "gui/501", configPath: fixture.configURL.path, port: 18_090))

        let fromEnvironment = ProviderContextWorkflow.installedService(
            plistData: try plist(
                ["/Users/u/macprovider/macprovider-cli", "serve"],
                environment: ["MACPROVIDER_CONFIG": fixture.configURL.path, "MACPROVIDER_PORT": "18091"]
            ),
            domain: "system"
        )
        XCTAssertEqual(fromEnvironment, .init(domain: "system", configPath: fixture.configURL.path, port: 18_091))

        let portFlag = ProviderContextWorkflow.installedService(
            plistData: try plist(["/x/macprovider-cli", "serve", "--config", fixture.configURL.path, "--port", "18092"]),
            domain: "gui/501"
        )
        XCTAssertEqual(portFlag?.port, 18_092)

        XCTAssertNil(ProviderContextWorkflow.installedService(plistData: try plist(["/x/macprovider-cli", "update"]), domain: "gui/501"))
        XCTAssertNil(ProviderContextWorkflow.installedService(plistData: Data("not a plist".utf8), domain: "gui/501"))
    }

    /// Round-2 N3: the serve listening on the queried port is the provider
    /// being checked, never an "other" serve process.
    func testResourceCheckDoesNotCountTheQueriedServeAsAnotherProcess() {
        var workflow = (try? Fixture())!.workflow()
        workflow.processes = { [(pid: 101, argv: ["/usr/local/bin/macprovider-cli", "serve"])] }
        workflow.listenerPIDs = { [101] }

        let lines = workflow.resourceCheck().joined(separator: "\n")

        XCTAssertFalse(lines.contains("other serve processes"), lines)
        XCTAssertTrue(lines.contains("1 provider process(es), 1 listener(s) on port 18080"), lines)
    }

    // MARK: - Studio E2E round 2 (N1): the installed job's real launchd domain

    private struct LaunchdLayout {
        let root: URL
        var agents: URL { root.appendingPathComponent("LaunchAgents", isDirectory: true) }
        var daemons: URL { root.appendingPathComponent("LaunchDaemons", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProviderContextLaunchd-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("LaunchDaemons"), withIntermediateDirectories: true)
        }

        func install(in directory: URL, config: URL) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "Label": "live.malibu.provider",
                    "ProgramArguments": ["/Users/u/macprovider/macprovider-cli", "serve", "--config", config.path],
                ] as [String: Any],
                format: .xml,
                options: 0
            )
            try data.write(to: directory.appendingPathComponent("live.malibu.provider.plist"))
        }

        func detect(loaded: Set<String>) -> ProviderContextWorkflow.InstalledServiceLookup {
            ProviderContextWorkflow.detectInstalledService(
                uid: 501,
                launchAgentsDirectory: agents,
                launchDaemonsDirectory: daemons,
                isLoaded: { loaded.contains($0) }
            )
        }
    }

    func testGUIAgentWithAProtectedFileConfigIsDetectedInTheGUIDomain() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nport: 18080\ncredential_store: protected_file\n")
        let layout = try LaunchdLayout()
        try layout.install(in: layout.agents, config: fixture.configURL)

        let lookup = layout.detect(loaded: ["gui/501/live.malibu.provider"])

        XCTAssertEqual(lookup, .found(.init(domain: "gui/501", configPath: fixture.configURL.path, port: 18_080)))
    }

    func testSystemDaemonIsDetectedInTheSystemDomain() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nport: 18080\ncredential_store: protected_file\n")
        let layout = try LaunchdLayout()
        try layout.install(in: layout.daemons, config: fixture.configURL)

        XCTAssertEqual(
            layout.detect(loaded: []),
            .found(.init(domain: "system", configPath: fixture.configURL.path, port: 18_080))
        )
    }

    func testWhenBothJobsExistTheLoadedOneWinsAndOtherwiseItIsAmbiguous() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nport: 18080\n")
        let layout = try LaunchdLayout()
        try layout.install(in: layout.agents, config: fixture.configURL)
        try layout.install(in: layout.daemons, config: fixture.configURL)

        XCTAssertEqual(layout.detect(loaded: ["system/live.malibu.provider"]).service?.domain, "system")
        XCTAssertEqual(layout.detect(loaded: ["gui/501/live.malibu.provider"]).service?.domain, "gui/501")
        guard case let .ambiguous(both) = layout.detect(loaded: []) else {
            return XCTFail("neither loaded must be ambiguous")
        }
        XCTAssertEqual(both.map(\.domain), ["gui/501", "system"])
        guard case .ambiguous = layout.detect(loaded: ["gui/501/live.malibu.provider", "system/live.malibu.provider"]) else {
            return XCTFail("both loaded must be ambiguous")
        }
    }

    func testNoInstalledJobIsNoneFound() throws {
        let layout = try LaunchdLayout()
        XCTAssertEqual(layout.detect(loaded: ["gui/501/live.malibu.provider"]), .none)
    }

    func testAmbiguousInstalledJobsRefuseNamingBoth() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\n")
        var workflow = fixture.workflow()
        let restarts = Counter()
        workflow.restart = { _ in restarts.increment() }
        workflow.installedService = {
            .ambiguous([
                .init(domain: "gui/501", configPath: fixture.configURL.path, port: 18_080),
                .init(domain: "system", configPath: "/etc/macprovider/config.yaml", port: 8_080),
            ])
        }

        let outcome = try await workflow.set(tokens: 120_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 1, outcome.text)
        XCTAssertEqual(restarts.value, 0)
        XCTAssertTrue(outcome.text.contains("gui/501/live.malibu.provider"), outcome.text)
        XCTAssertTrue(outcome.text.contains("system/live.malibu.provider"), outcome.text)
    }

    func testApplyRestartsTheInstalledJobInTheDomainItWasFoundIn() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\nmax_context_override: 4000\ncredential_store: protected_file\n")
        var workflow = fixture.workflow()
        let restarted = Box<[String]>([])
        workflow.restart = { restarted.value.append($0.domain) }
        workflow.verify = { _ in Self.report(.agree) }
        workflow.installedService = { .found(.init(domain: "gui/501", configPath: fixture.configURL.path, port: 18_080)) }

        let outcome = try await workflow.set(tokens: 120_000, preflight: false, apply: true)

        XCTAssertEqual(outcome.exitCode, 0, outcome.text)
        XCTAssertEqual(restarted.value, ["gui/501"])
    }

    func testKickstartCommandUsesTheFoundDomainAndSudoOnlyForSystem() {
        let gui = CredentialRestartProver.kickstartCommand(domain: "gui/501")
        XCTAssertEqual(gui.executable, "/bin/launchctl")
        XCTAssertEqual(gui.arguments, ["kickstart", "-k", "gui/501/live.malibu.provider"])

        let system = CredentialRestartProver.kickstartCommand(domain: "system")
        XCTAssertEqual(system.executable, "/usr/bin/sudo")
        XCTAssertEqual(system.arguments, ["-n", "/bin/launchctl", "kickstart", "-k", "system/live.malibu.provider"])
    }

    func testExplainNamesTheDetectedInstalledServiceOrNoneFound() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        var workflow = fixture.workflow()

        let found = await workflow.explain()
        XCTAssertTrue(found.contains("Installed:    gui/501/live.malibu.provider (config \(fixture.configURL.path), port 18080)"), found)

        workflow.installedService = { .none }
        let none = await workflow.explain()
        XCTAssertTrue(none.contains("Installed:    none found (no readable live.malibu.provider serve job in gui/<uid> or system)"), none)

        workflow.installedService = {
            .ambiguous([
                .init(domain: "gui/501", configPath: "/a.yaml", port: 1),
                .init(domain: "system", configPath: "/b.yaml", port: 2),
            ])
        }
        let ambiguous = await workflow.explain()
        XCTAssertTrue(ambiguous.contains("Installed:    ambiguous: gui/501/live.malibu.provider (config /a.yaml, port 1) and system/live.malibu.provider (config /b.yaml, port 2)"), ambiguous)
    }

    func testRollbackNoRestartParses() throws {
        let rollback = try XCTUnwrap(try MacProviderCLI.parseAsRoot(["provider", "context", "rollback", "--no-restart"]) as? ProviderContextRollbackCommand)
        XCTAssertTrue(rollback.noRestart)
    }

    /// F6: a context above the served model's declared maximum is served as
    /// set, but every operator surface says so.
    func testExplainWarnsWhenTheEffectiveContextIsAboveTheModelsDeclaredMaximum() async throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        var workflow = fixture.workflow(physicalMemoryGB: 256)
        workflow.modelFacts = { _ in
            .init(declaredMax: 131_072, tokenizerMax: 131_072, kvBytesPerToken: 114_688, weightsBytes: 2 << 30)
        }

        let text = await workflow.explain()

        XCTAssertTrue(text.contains("Effective:    200000 tokens"), text)
        XCTAssertTrue(text.contains("Warning: the context window (200000 tokens) is above m's declared maximum of 131072 tokens"), text)
    }

    func testModelsSwitchWarnsWhenAnOperatorContextIsAboveTheTargetsDeclaredMaximum() throws {
        let fixture = try Fixture()
        let root = fixture.directory.appendingPathComponent("models", isDirectory: true)
        let artifact = try DurableModelArtifactStore(root: root).artifactURL(
            modelID: "mlx-community/Qwen3.6-27B-4bit",
            revision: "c000ac2c2057d94be3fa931000c31723aac53282",
            sha256: "518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931"
        )
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(AutotuneRecommendTests.qwen36TwentySevenBConfigJSON.utf8)
            .write(to: artifact.appendingPathComponent("config.json"))
        try fixture.writeConfig("model: mlx-community/Qwen3-8B-4bit\nmodel_artifact_root: \(root.path)\nmax_context_override: 300000\n")

        let notice = try XCTUnwrap(ModelsSwitchCommand.contextNotice(
            targetModelID: "qwen/qwen3.6-27b", servedContext: 300_000, servedSource: "operator_config", config: try fixture.load()
        ))

        XCTAssertTrue(notice.contains("above qwen/qwen3.6-27b's declared maximum of 262144 tokens"), notice)
        XCTAssertFalse(notice.contains("\n"), notice)
    }

    func testStatusWarnsAboutContextAboveTheModelLimitOrOverMemory() {
        var status: [String: Any] = [
            "model": "m",
            "capacity": ["max_context_tokens": 200_000, "max_concurrency": 8, "max_context_source": "operator_config"],
        ]
        let config = AppConfig.defaults(configPath: "/tmp/none.yaml")
        let facts = ProviderContextWorkflow.ModelFacts(declaredMax: 131_072, tokenizerMax: nil, kvBytesPerToken: 262_144, weightsBytes: 15 << 30)

        let warnings = ProviderContextWorkflow.statusContextWarnings(status: status, config: config, physicalMemoryGB: 256, facts: facts)

        XCTAssertTrue(warnings.contains { $0.contains("above m's declared maximum of 131072 tokens") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("8 slots × 200000 tokens") && $0.contains("does not fit") }, "\(warnings)")

        status["capacity"] = ["max_context_tokens": 16_000, "max_concurrency": 1, "max_context_source": "operator_config"]
        XCTAssertEqual(
            ProviderContextWorkflow.statusContextWarnings(status: status, config: config, physicalMemoryGB: 256, facts: facts),
            []
        )
    }

    func testStatusSaysWhenServeLoweredAGeneratedContextToFitItsSlots() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "m", context: 131_072), now: now)
        let status: [String: Any] = [
            "model": "m",
            "capacity": ["max_context_tokens": 90_000, "max_concurrency": 8, "max_context_source": "recommendation_apply"],
        ]

        let warnings = ProviderContextWorkflow.statusContextWarnings(
            status: status, config: try fixture.load(), physicalMemoryGB: 256, facts: .init()
        )

        XCTAssertTrue(warnings.contains { $0.contains("lowered from 131072 to 90000 tokens so 8 slots fit in memory") }, "\(warnings)")
    }

    func testAdvancedStatusPrintsContextWarnings() {
        let status: [String: Any] = ["model": "m", "capacity": ["max_context_tokens": 200_000]]
        let text = LocalStatusFormatter.format(status, advanced: true, contextWarnings: ["Warning: example context warning"])
        XCTAssertTrue(text.contains("Warning: example context warning"), text)
    }

    /// L3: a warm-switch recompute adopts nothing, so the label does not say it did.
    func testRecommendationAdoptionLabelDoesNotClaimAnAdoption() {
        let label = LocalStatusFormatter.maxContextSourceLabel("recommendation_adoption")
        XCTAssertFalse(label.contains("adopted"), label)
        XCTAssertTrue(label.contains("model switch"), label)
    }

    /// (g): at serve start a generated context gives way when the slot count
    /// serve runs (after --max-batch or the environment) would not fit.
    func testServeLowersAGeneratedContextThatDoesNotFitItsSlots() throws {
        let geometry = try XCTUnwrap(AutotuneRecommendTests.signedCandidateConfigGeometry["z-ai/glm-4.5-air"])
        let configData = Data(geometry.json.utf8)
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/GLM-4.5-Air-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/GLM-4.5-Air-4bit", context: 131_072), now: now)
        let generated = try fixture.load()

        func bounded(_ config: AppConfig, slots: Int) -> Int? {
            let bound = ModelSwitchContext.startupBoundedContext(
                config: config, slots: slots, memoryGB: 256, configJSONData: configData, catalogMinRAMGB: 80
            )
            XCTAssertEqual(bound.map(\.slots) ?? slots, slots, "slots are kept when a context above the floor fits them")
            return bound?.context
        }
        XCTAssertNil(bounded(generated, slots: 5), "five slots fit at the generated 131072")
        let lowered = try XCTUnwrap(bounded(generated, slots: 8))
        XCTAssertLessThan(lowered, 131_072)
        XCTAssertEqual(lowered, ModelSwitchContext.recomputedContext(
            memoryGB: 256, modelID: "mlx-community/GLM-4.5-Air-4bit", catalogMinRAMGB: 80,
            configJSONData: configData,
            configSHA256: SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined(),
            draftModel: nil, slots: 8
        ))

        let contexts = ModelSwitchContext.serveContextsByTarget(
            config: generated,
            configuredModelIDs: ["mlx-community/GLM-4.5-Air-4bit"],
            targets: [],
            configuredContext: lowered
        )
        XCTAssertEqual(contexts["mlx-community/glm-4.5-air-4bit"], lowered, "switching back serves the lowered value")

        try fixture.applier.setOperatorOwnedValue(key: "max_context_override", value: "131072", now: now)
        XCTAssertNil(bounded(try fixture.load(), slots: 8), "an operator value is never changed; status warns instead")
    }

    /// (e): at serve start, when even the 4000-token floor does not fit the
    /// slot count serve would run, the context goes to the floor and the slot
    /// count comes down to what fits there.
    func testServeLowersSlotsWhenEvenTheFloorContextDoesNotFit() throws {
        let geometry = try XCTUnwrap(AutotuneRecommendTests.signedCandidateConfigGeometry["z-ai/glm-4.5-air"])
        let configData = Data(geometry.json.utf8)
        let configSHA256 = SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()
        let fixture = try Fixture()
        try fixture.writeConfig("model: mlx-community/GLM-4.5-Air-4bit\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "mlx-community/GLM-4.5-Air-4bit", context: 131_072), now: now)

        let bound = try XCTUnwrap(ModelSwitchContext.startupBoundedContext(
            config: try fixture.load(), slots: 8, memoryGB: 86, configJSONData: configData, catalogMinRAMGB: 80
        ))
        XCTAssertEqual(bound.context, AutotuneModelContextCap.minimumServeContext)
        let fit = try XCTUnwrap(AutotuneModelContextCap.memoryFitBatchDepth(
            configData: configData, verifiedConfigSHA256: configSHA256,
            hardwareMemoryGB: 86, catalogMinRAMGB: 80, calibrationContextTokens: bound.context
        ))
        XCTAssertLessThan(bound.slots, 8)
        XCTAssertEqual(bound.slots, fit, "the lowered slot count is the most that fit at the floor")
    }

    func testStatusWarnsWhenServeLoweredTheSlotCount() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        _ = try fixture.applier.apply(recommendation: recommendation(model: "m", context: 131_072), now: now)
        let status: [String: Any] = [
            "model": "m",
            "capacity": ["max_context_tokens": 4_000, "max_concurrency": 2, "max_context_source": "recommendation_apply"],
        ]

        let warnings = ProviderContextWorkflow.statusContextWarnings(
            status: status, config: try fixture.load(), physicalMemoryGB: 86, facts: .init()
        )

        XCTAssertTrue(warnings.contains { $0.contains("Slots lowered from 8 to 2") }, "\(warnings)")
        let operatorBatch: [String: Any] = [
            "model": "m",
            "capacity": ["max_context_tokens": 131_072, "max_concurrency": 2, "max_context_source": "recommendation_apply"],
        ]
        XCTAssertFalse(ProviderContextWorkflow.statusContextWarnings(
            status: operatorBatch, config: try fixture.load(), physicalMemoryGB: 256, facts: .init()
        ).contains { $0.contains("Slots lowered") }, "a smaller --max-batch above the floor is not a lowering")
    }

    /// (c): the classic measured sweep writes an operator-owned pair, so it
    /// never carries `recommendation_apply` past the R018 item 9 joint bound.
    func testSweepApplyWritesNoGeneratedProvenance() throws {
        let fixture = try Fixture()
        try fixture.writeConfig("model: m\n")
        _ = try fixture.applier.apply(recommendation: recommendation(context: 131_072), now: now)
        XCTAssertEqual(try fixture.load().maxContextSource, .recommendationApply)

        _ = try fixture.applier.apply(recommendation: recommendation(context: 65_536), now: now, recordsProvenance: false)

        let loaded = try fixture.load()
        XCTAssertEqual(loaded.maxContextOverride, 65_536)
        XCTAssertEqual(loaded.maxContextSource, .operatorConfig)
        XCTAssertNil(loaded.maxContextProvenance)
        XCTAssertFalse(try fixture.configText().contains(MaxContextProvenance.configKey))
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

    private func recommendation(model: String = "mlx-community/Qwen3.6-27B-4bit", context: Int) -> RecommendationCore {
        RecommendationCore(
            model: model,
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

    func configText() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
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
            modelFacts: { _ in
                .init(declaredMax: 262_144, tokenizerMax: 262_144, kvBytesPerToken: 65_536, weightsBytes: 15 << 30)
            },
            processes: { [] },
            listenerPIDs: { [] },
            restart: { _ in },
            verify: { _ in ProviderVerifyReport(outcome: .agree, layers: [], proof: .init(), feedLagSeconds: nil, unverifiableFields: []) },
            installedService: { [configURL] in .found(.init(domain: "gui/501", configPath: configURL.path, port: 18_080)) },
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }
}
