import ArgumentParser
import XCTest
@testable import macprovider_cli

final class AutotuneCommandTests: XCTestCase {
    /// #742 AC-3: paid --recommend never inherits a 60 s TTFT default;
    /// classic Stage 1/2 keeps SPEC-013's 60s default when the flag is omitted.
    func testGateTTFTMSPathDependentDefaultAndExplicitZero() throws {
        let omitted = try AutotuneCommand.parse(["--dry-run"])
        XCTAssertNil(omitted.gateTTFTMS)

        let recommend = try AutotuneCommand.parse(["--recommend", "--dry-run"])
        XCTAssertNil(recommend.gateTTFTMS)

        let explicit = try AutotuneCommand.parse(["--gate-ttft-ms", "3500", "--dry-run"])
        XCTAssertEqual(explicit.gateTTFTMS, 3500)

        let disabled = try AutotuneCommand.parse(["--gate-ttft-ms", "0", "--dry-run"])
        XCTAssertEqual(disabled.gateTTFTMS, 0)

        XCTAssertThrowsError(try AutotuneCommand.parse(["--gate-ttft-ms", "-1", "--dry-run"]))
    }

    func testDefaultCandidatePlanIsLargestFirst() throws {
        let command = try AutotuneCommand.parse(["--dry-run"])
        let plan = try command.candidatePlan()

        XCTAssertEqual(plan.source, .defaultList)
        XCTAssertEqual(plan.candidates, [
            "mlx-community/Qwen2.5-32B-Instruct-4bit",
            "mlx-community/Qwen2.5-14B-Instruct-4bit",
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
        ])
    }

    func testExplicitCandidateOrderBeatsSizeFlags() throws {
        let command = try AutotuneCommand.parse([
            "--candidate-models", "one,two",
            "--max-model-size", "7B",
            "--min-model-size", "3B",
            "--dry-run",
        ])
        let plan = try command.candidatePlan()

        XCTAssertEqual(plan.source, .explicit)
        XCTAssertEqual(plan.candidates, ["one", "two"])
        XCTAssertEqual(plan.warning, "warning: --candidate-models supplied; ignoring --max-model-size/--min-model-size")
    }

    func testMaxModelSizeTrimsDefaultList() throws {
        let command = try AutotuneCommand.parse(["--max-model-size", "8B", "--dry-run"])
        let plan = try command.candidatePlan()

        XCTAssertEqual(plan.candidates.first, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertFalse(plan.candidates.contains("mlx-community/Qwen2.5-32B-Instruct-4bit"))
        XCTAssertFalse(plan.candidates.contains("mlx-community/Qwen2.5-14B-Instruct-4bit"))
    }

    func testMaxContextAxisRejectsBelowTargetCell() throws {
        XCTAssertThrowsError(
            try AutotuneCommand.parse([
                "--target-context", "4000",
                "--max-context-axis", "2000,4000",
                "--dry-run",
            ])
        )
    }

    func testKvBitsAxisAcceptsUnsetFourEight() throws {
        let values = try AutotuneCommand.parseKvBitsAxis("unset,4,8")

        XCTAssertEqual(values.count, 3)
        XCTAssertNil(values[0])
        XCTAssertEqual(values[1], 4)
        XCTAssertEqual(values[2], 8)
    }

    // MARK: - Round-1 audit fix tests

    /// Round-1 A.4 closure: empty cell in a non-empty axis MUST throw at
    /// flag-parse time, not be silently dropped. The prior `parseCSV`
    /// filter let `--max-context-axis 4000,,8000` parse as [4000, 8000].
    func testMaxContextAxisRejectsEmptyCell() throws {
        XCTAssertThrowsError(
            try AutotuneCommand.parse([
                "--target-context", "4000",
                "--max-context-axis", "4000,,8000",
                "--dry-run",
            ])
        )
    }

    /// FR-B.1: max-context-axis cells MUST be sorted ascending after parse.
    func testMaxContextAxisSortsAscending() throws {
        let values = try AutotuneCommand.parseMaxContextAxis("8000,4000,16000", targetContext: 4000)
        XCTAssertEqual(values, [4000, 8000, 16000])
    }

    /// FR-B.1: duplicate cells MUST be rejected.
    func testMaxContextAxisRejectsDuplicates() throws {
        XCTAssertThrowsError(
            try AutotuneCommand.parseMaxContextAxis("4000,8000,4000", targetContext: 4000)
        )
    }

    /// FR-B.1: empty default maps to [--target-context].
    func testMaxContextAxisEmptyDefaultMapsToTargetContext() throws {
        let values = try AutotuneCommand.parseMaxContextAxis("", targetContext: 4000)
        XCTAssertEqual(values, [4000])
    }

    /// Round-1 B.5 closure: --candidate-models with an empty cell MUST throw.
    /// Same parseCSV-drops-empty bug class as A.4.
    func testCandidateModelsRejectsEmptyCell() throws {
        XCTAssertThrowsError(
            try AutotuneCommand.parse([
                "--candidate-models", "one,,two",
                "--dry-run",
            ])
        )
    }

    /// AC-17 prep: explicit operator-supplied order with a SMALLER candidate
    /// first MUST survive to candidatePlan() verbatim. An implementation
    /// that pre-sorts by parameter count would fail this test even though
    /// the runtime AC-17 (Step 7) is what catches the full violation.
    func testExplicitCandidateOrderPreservesSmallFirst() throws {
        let command = try AutotuneCommand.parse([
            "--candidate-models",
            "mlx-community/Llama-3.2-1B-Instruct-4bit,mlx-community/Qwen2.5-32B-Instruct-4bit",
            "--dry-run",
        ])
        let plan = try command.candidatePlan()

        XCTAssertEqual(plan.source, .explicit)
        XCTAssertEqual(plan.candidates, [
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
            "mlx-community/Qwen2.5-32B-Instruct-4bit",
        ])
    }

    /// Round-1 C.2 closure: dry-run stdout MUST include the candidate
    /// plan in order. Tested via the testable `dryRunLines` helper
    /// rather than capturing stdout.
    func testDryRunLinesContainCandidatePlanInOrder() throws {
        let command = try AutotuneCommand.parse(["--dry-run"])
        let plan = try command.candidatePlan()
        let lines = command.dryRunLines(plan)

        let firstCandidateLine = lines.first(where: { $0.contains("Qwen2.5-32B") })
        let lastCandidateLine = lines.first(where: { $0.contains("Llama-3.2-1B") })
        XCTAssertNotNil(firstCandidateLine)
        XCTAssertNotNil(lastCandidateLine)
        // Each candidate is a numbered line "  N. <id>"; verify order
        // matches the FR-C.1 default list largest-first.
        XCTAssertTrue(lines.contains("  1. mlx-community/Qwen2.5-32B-Instruct-4bit"))
        XCTAssertTrue(lines.contains("  5. mlx-community/Llama-3.2-1B-Instruct-4bit"))
    }

    /// --restart-foreground is declared in Step 1 (it acts in Step 5).
    /// Test parses successfully and exposes the flag for later steps.
    func testRestartForegroundFlagParses() throws {
        let command = try AutotuneCommand.parse(["--restart-foreground", "--dry-run"])
        XCTAssertTrue(command.restartForeground)
    }

    func testDonorModeApplyWarningMatchesSpec() {
        let warning = AutotuneCommand.donorModeApplyWarning(for: "model-a")

        XCTAssertEqual(
            warning,
            "DONOR MODE: model-a does not meet rate-card or hardware requirements on this Mac."
        )
        XCTAssertFalse(warning.contains("/hr"))
    }

    func testRecommendFlagsParse() throws {
        let command = try AutotuneCommand.parse([
            "--recommend",
            "--freshness-check",
            "--submit-hardware-evidence",
            "--require-hardware-evidence",
            "--donor-mode",
        ])

        XCTAssertTrue(command.recommend)
        XCTAssertTrue(command.freshnessCheck)
        XCTAssertTrue(command.submitHardwareEvidence)
        XCTAssertTrue(command.requireHardwareEvidence)
        XCTAssertTrue(command.donorMode)
    }

    func testRecoverHardwareAdmissionFlagParsesAndRejectsConflictingModes() throws {
        let command = try AutotuneCommand.parse([
            "--recommend",
            "--recover-hardware-admission",
        ])
        XCTAssertTrue(command.recoverHardwareAdmission)

        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recover-hardware-admission",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend",
            "--recover-hardware-admission",
            "--freshness-check",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend",
            "--recover-hardware-admission",
            "--no-submit-hardware-evidence",
        ]))
    }

    func testRecommendPrefetchRequiresExplicitCandidateAndRejectsMutationModes() throws {
        let command = try AutotuneCommand.parse([
            "--recommend",
            "--prefetch",
            "--candidate-models", "namespace/existing-model",
            "--prefetch-receipt", "/tmp/prefetch-receipt.json",
            "--no-submit-hardware-evidence",
        ])

        XCTAssertTrue(command.recommend)
        XCTAssertTrue(command.prefetch)
        XCTAssertEqual(command.candidateModels, "namespace/existing-model")
        XCTAssertEqual(command.prefetchReceipt, "/tmp/prefetch-receipt.json")
        XCTAssertFalse(command.submitHardwareEvidence)

        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--prefetch", "--candidate-models", "namespace/model", "--prefetch-receipt", "/tmp/receipt",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--prefetch"]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--prefetch", "--apply", "--candidate-models", "namespace/model",
            "--prefetch-receipt", "/tmp/receipt",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--prefetch", "--freshness-check", "--candidate-models", "namespace/model",
            "--prefetch-receipt", "/tmp/receipt",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--prefetch", "--donor-mode", "--candidate-models", "namespace/model",
            "--prefetch-receipt", "/tmp/receipt",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--prefetch", "--candidate-models", "namespace/model",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--apply", "--prefetch-receipt", "/tmp/receipt",
        ]))
    }

    func testRecommendPrefetchTrustWarningsIncludeRateCardBlockingWarnings() throws {
        let demand = AutotuneStaticSelection(
            value: try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)),
            selectedBytes: Data(),
            warnings: [.demandRankFallbackUsed],
            usedFallback: false
        )
        let catalog = AutotuneStaticSelection(
            value: try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)),
            selectedBytes: Data(),
            warnings: [.candidateCatalogFallbackUsed],
            usedFallback: false
        )
        let rateCard = AutotuneStaticSelection(
            value: try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)),
            selectedBytes: Data(),
            warnings: [.rateCardIntegrityFailure],
            usedFallback: true
        )

        let warnings = AutotuneCommand.recommendationPrefetchTrustWarnings(
            demand: demand,
            catalog: catalog,
            rateCard: rateCard
        )

        XCTAssertTrue(warnings.contains(.rateCardIntegrityFailure))
        XCTAssertTrue(AutotuneRecommendEngine.paidTrustBlocks(warnings))
    }

    func testRecommendUsesSpec023FourKProbeContext() throws {
        let command = try AutotuneCommand.parse(["--recommend"])

        XCTAssertEqual(command.targetContext, 2_000)
        XCTAssertEqual(AutotuneCommand.spec023RecommendationProbeContext, 4_000)
    }

    func testFreshnessCheckRequiresRecommend() {
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--freshness-check",
        ]))
    }

    func testTrustBlockedFreshnessMapsToDedicatedExitCodeAndSortedDiagnostic() throws {
        let failure = try XCTUnwrap(AutotuneCommand.recommendationFreshnessFailure(
            for: .trustBlocked(
                nil,
                [.demandRankUpdateRequired, .candidateCatalogUpdateRequired]
            )
        ))

        XCTAssertEqual(failure.exitCode, ExitCode(12))
        XCTAssertEqual(
            failure.diagnostic,
            "catalog_trust_blocked: candidate_catalog_update_required, demand_rank_update_required\n"
        )
    }

    func testRequiredHardwareEvidenceRequiresRecommend() {
        XCTAssertThrowsError(try AutotuneCommand.parse(["--require-hardware-evidence"]))
    }

    func testRequiredHardwareEvidenceRejectsSubmissionOptOut() {
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend",
            "--require-hardware-evidence",
            "--no-submit-hardware-evidence",
        ]))
    }

    func testCalibratedRecommendationCommitRejectsPreCommitInterruptWithoutMutation() async throws {
        let flag = AutotuneInterruptFlag()
        flag.set()
        var operations: [String] = []
        var interruptMessages = 0

        do {
            _ = try await AutotuneCommand.commitCalibratedRecommendationMutation(
                interruptFlag: flag,
                writeInterrupted: { interruptMessages += 1 },
                writeRecommendationState: { operations.append("state") },
                submitHardwareEvidence: { operations.append("evidence") },
                applyConfig: {
                    operations.append("config")
                    return Self.appliedConfig()
                },
                emitAppliedSummary: { _ in operations.append("summary") }
            )
            XCTFail("expected pre-commit interrupt to throw")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, ExitCode(130))
        }

        XCTAssertEqual(interruptMessages, 1)
        XCTAssertEqual(operations, [])
    }

    func testCalibratedRecommendationCommitRejectsPreCommitDeadlineWithoutMutation() async throws {
        var operations: [String] = []
        var deadlineMessages = 0

        do {
            _ = try await AutotuneCommand.commitCalibratedRecommendationMutation(
                interruptFlag: AutotuneInterruptFlag(),
                writeInterrupted: { operations.append("interrupted") },
                hasDeadlineExpired: { true },
                writeDeadlineExceeded: { deadlineMessages += 1 },
                writeRecommendationState: { operations.append("state") },
                submitHardwareEvidence: { operations.append("evidence") },
                applyConfig: {
                    operations.append("config")
                    return Self.appliedConfig()
                },
                emitAppliedSummary: { _ in operations.append("summary") }
            )
            XCTFail("expected pre-commit deadline to throw")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, ExitCode(1))
        }

        XCTAssertEqual(deadlineMessages, 1)
        XCTAssertEqual(operations, [])
    }

    func testCalibratedRecommendationCommitFinishesWhenInterruptedAfterStateWrite() async throws {
        let flag = AutotuneInterruptFlag()
        var operations: [String] = []

        let applied = try await AutotuneCommand.commitCalibratedRecommendationMutation(
            interruptFlag: flag,
            writeInterrupted: { operations.append("interrupted") },
            writeRecommendationState: {
                operations.append("state")
                flag.set()
            },
            submitHardwareEvidence: { operations.append("evidence") },
            applyConfig: {
                operations.append("config")
                return Self.appliedConfig()
            },
            emitAppliedSummary: { applied in operations.append("summary:\(applied.summary)") }
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(operations, ["state", "evidence", "config", "summary:applied test summary"])
    }

    func testCalibratedRecommendationCommitFinishesWhenInterruptedBeforeConfigWrite() async throws {
        let flag = AutotuneInterruptFlag()
        var operations: [String] = []

        let applied = try await AutotuneCommand.commitCalibratedRecommendationMutation(
            interruptFlag: flag,
            writeInterrupted: { operations.append("interrupted") },
            writeRecommendationState: { operations.append("state") },
            submitHardwareEvidence: {
                operations.append("evidence")
                flag.set()
            },
            applyConfig: {
                operations.append("config")
                return Self.appliedConfig()
            },
            emitAppliedSummary: { applied in operations.append("summary:\(applied.summary)") }
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(operations, ["state", "evidence", "config", "summary:applied test summary"])
    }

    func testCalibratedRecommendationCommitFinishesSummaryWhenInterruptedDuringConfigWrite() async throws {
        let flag = AutotuneInterruptFlag()
        var operations: [String] = []

        let applied = try await AutotuneCommand.commitCalibratedRecommendationMutation(
            interruptFlag: flag,
            writeInterrupted: { operations.append("interrupted") },
            writeRecommendationState: { operations.append("state") },
            submitHardwareEvidence: { operations.append("evidence") },
            applyConfig: {
                operations.append("config")
                flag.set()
                return Self.appliedConfig()
            },
            emitAppliedSummary: { applied in operations.append("summary:\(applied.summary)") }
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(operations, ["state", "evidence", "config", "summary:applied test summary"])
    }

    private static func appliedConfig() -> ConfigApplier.AppliedConfig {
        ConfigApplier.AppliedConfig(
            backupPath: URL(fileURLWithPath: "/tmp/config.yaml.bak"),
            summary: "applied test summary"
        )
    }
}
