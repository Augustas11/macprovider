import Darwin
import Foundation
import SQLite3
import XCTest
@testable import macprovider_cli

final class Stage1IteratorTests: XCTestCase {
    func testCandidateProviderCleanupFailureDoesNotReturnProbeValue() async throws {
        let runner = StubProviderRunner()
        runner.stopResult = .stuck(pid: 4242)

        do {
            _ = try await withCandidateProviderCleanup(runner, graceSeconds: 0) { 123 }
            XCTFail("stuck candidate teardown must fail closed")
        } catch let error as CandidateProviderTeardownError {
            XCTAssertEqual(error, .stuck(pid: 4242))
        }
    }

    func testStage1IteratorStopsOnFirstFeasible() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prewarmer = StubPreWarmer(results: [
            "model-a": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
            "model-b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
        ])
        let prober = StubStage1Prober(results: [
            "model-a": .infeasible(reason: "too slow", nErr: 1),
            "model-b": .feasible(medianTPS: 12.5, p95TTFTMS: 500),
            "model-c": .feasible(medianTPS: 99, p95TTFTMS: 100),
        ])

        let iterator = makeIterator(
            db: db,
            candidates: ["model-a", "model-b", "model-c"],
            prewarmer: prewarmer,
            prober: prober
        )

        let result = try await iterator.run()

        XCTAssertEqual(result.selectedModel, "model-b")
        XCTAssertEqual(result.trials.map(\.model), ["model-a", "model-b"])
        XCTAssertEqual(try trialModels(at: dbURL), ["model-a", "model-b"])
        XCTAssertEqual(prober.probedModels, ["model-a", "model-b"])
    }

    func testStage1IteratorAdvancesPastTransient() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prewarmer = StubPreWarmer(results: [
            "model-a": .failed(failureClass: .transient, reason: "network unreachable"),
            "model-b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
        ])
        let prober = StubStage1Prober(results: [
            "model-b": .feasible(medianTPS: 10, p95TTFTMS: 100),
        ])

        let result = try await makeIterator(
            db: db,
            candidates: ["model-a", "model-b"],
            prewarmer: prewarmer,
            prober: prober
        ).run()

        XCTAssertEqual(result.selectedModel, "model-b")
        XCTAssertEqual(try trialModels(at: dbURL), ["model-a", "model-b"])
        XCTAssertEqual(try notes(for: "model-a", at: dbURL), "pre-warm transient: network unreachable")
        XCTAssertEqual(prober.probedModels, ["model-b"])
    }

    func testStage1IteratorAbortsOnIntegrity() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prewarmer = StubPreWarmer(results: [
            "model-a": .failed(failureClass: .integrity, reason: "signature mismatch"),
            "model-b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
        ])
        let prober = StubStage1Prober(results: [
            "model-b": .feasible(medianTPS: 10, p95TTFTMS: 100),
        ])

        do {
            _ = try await makeIterator(
                db: db,
                candidates: ["model-a", "model-b"],
                prewarmer: prewarmer,
                prober: prober
            ).run()
            XCTFail("expected integrity abort")
        } catch let error as Stage1IteratorError {
            guard case .preWarmIntegrityFailure(let model, let reason, let exitReason) = error else {
                return XCTFail("expected preWarmIntegrityFailure, got \(error)")
            }
            XCTAssertEqual(model, "model-a")
            XCTAssertEqual(reason, "signature mismatch")
            XCTAssertEqual(exitReason, .preWarmIntegrityFailure)
        }

        // Round-1 audit F.1 (MAJOR) closure: integrity-abort path now
        // RECORDS the offending candidate's trial row before throwing,
        // per SPEC-013 §5.7 FR-G.1 ("every trial is recorded"). Candidate
        // 2 ("model-b") is still never reached (the abort throws after
        // candidate 1's row insertion).
        XCTAssertEqual(try trialModels(at: dbURL), ["model-a"])
        XCTAssertEqual(prewarmer.models, ["model-a"])
        XCTAssertEqual(prober.probedModels, [])
    }

    func testStage1IteratorAllInfeasibleSurfacesSmallestFirstReason() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prewarmer = StubPreWarmer(results: [
            "32b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
            "14b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
            "1b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
        ])
        let prober = StubStage1Prober(results: [
            "32b": .infeasible(reason: "32b too slow", nErr: 1),
            "14b": .infeasible(reason: "14b too slow", nErr: 1),
            "1b": .infeasible(reason: "1b leaked stop token", nErr: 1),
        ])

        do {
            // Default candidate list is largest-first per FR-C.1, so the
            // iterator's default `candidatesBySize` (nil → reversed) gives
            // ["1b", "14b", "32b"] — smallest-first. The surfaced reason
            // and the size-ordered trials list MUST reflect this.
            _ = try await makeIterator(
                db: db,
                candidates: ["32b", "14b", "1b"],
                prewarmer: prewarmer,
                prober: prober
            ).run()
            XCTFail("expected no feasible error")
        } catch let error as Stage1IteratorError {
            guard case .noFeasible(let reason, let trials, let exitReason) = error else {
                return XCTFail("expected noFeasible, got \(error)")
            }
            // Round-1 audit E.1 closure: surfaced reason now includes the
            // smallest candidate's name (FR-H.4 "even <smallest> failed"
            // semantics) and the `trials` list is in size order
            // (smallest-first) for the caller to print in order.
            XCTAssertEqual(reason, "1b: 1b leaked stop token")
            XCTAssertEqual(trials, ["1b leaked stop token", "14b too slow", "32b too slow"])
            XCTAssertEqual(exitReason, .noFeasible)
            XCTAssertTrue(error.description.hasPrefix("no_feasible: 1b: 1b leaked stop token"))
        }

        // All three rows recorded in tune_trials, in ITERATION order
        // (largest-first per the operator-supplied list).
        XCTAssertEqual(try trialModels(at: dbURL), ["32b", "14b", "1b"])
    }

    /// Round-1 audit E.1 (CRITICAL) regression lock: when the operator
    /// passes a SMALLEST-FIRST list via `--candidate-models 1b,32b` AND
    /// both fail, FR-H.4 still requires the SMALLEST candidate's reason
    /// to surface first — independent of iteration order. The prior
    /// `failureReasons.last` code would have surfaced 32b's reason
    /// (LARGEST), silently violating FR-A.4 / FR-H.4 under an AC-17-shaped
    /// override.
    func testStage1IteratorAllInfeasibleWithOperatorOverrideSurfacesSmallestBySize() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prewarmer = StubPreWarmer(results: [
            "1b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
            "32b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
        ])
        let prober = StubStage1Prober(results: [
            "1b": .infeasible(reason: "1b leaked stop token", nErr: 1),
            "32b": .infeasible(reason: "32b OOM during probe", nErr: 1),
        ])

        do {
            // Operator override: iteration order is 1b, 32b (the AC-17
            // shape). Size order (smallest-first) is also [1b, 32b].
            // Both fail.
            _ = try await Stage1Iterator(
                candidateProviderRunner: { StubProviderRunner() },
                providerPreWarmer: prewarmer,
                autotuneDB: db,
                runID: "test-run",
                candidates: ["1b", "32b"],
                candidatesBySize: ["1b", "32b"],
                targetContext: 2_000,
                gateTTFTMS: 60_000,
                stage1Replicates: 1,
                port: 18_080,
                prober: prober
            ).run()
            XCTFail("expected no feasible error")
        } catch let error as Stage1IteratorError {
            guard case .noFeasible(let reason, let trials, _) = error else {
                return XCTFail("expected noFeasible, got \(error)")
            }
            // The CRITICAL contract: 1b's reason (smallest) leads, NOT
            // 32b's. Under the prior `failureReasons.last` code, this
            // would have asserted "32b OOM during probe" — the silent
            // FR-H.4 violation.
            XCTAssertEqual(reason, "1b: 1b leaked stop token")
            XCTAssertEqual(trials, ["1b leaked stop token", "32b OOM during probe"])
        }

        // Iteration order preserved in tune_trials.
        XCTAssertEqual(try trialModels(at: dbURL), ["1b", "32b"])
    }

    func testStage1IteratorHonorsOperatorOrderForACSeventeen() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prewarmer = StubPreWarmer(results: [
            "1b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
            "32b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
        ])
        let prober = StubStage1Prober(results: [
            "1b": .feasible(medianTPS: 50, p95TTFTMS: 100),
            "32b": .feasible(medianTPS: 5, p95TTFTMS: 100),
        ])

        let result = try await makeIterator(
            db: db,
            candidates: ["1b", "32b"],
            prewarmer: prewarmer,
            prober: prober
        ).run()

        XCTAssertEqual(result.selectedModel, "1b")
        XCTAssertEqual(prewarmer.models, ["1b"])
        XCTAssertEqual(prober.probedModels, ["1b"])
        XCTAssertEqual(try trialModels(at: dbURL), ["1b"])
    }

    func testStage1ProberDetectsStopTokenLeak() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try sseProviderScript(responseText: "hello <|im_end|>", delayBeforeFirstToken: 0).path,
            logDirectory: try temporaryDirectory(name: "stage1-stop-token-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .infeasible(let reason, let nErr) = result else {
            return XCTFail("expected infeasible, got \(result)")
        }
        XCTAssertTrue(reason.contains("stop-token leak"), reason)
        XCTAssertEqual(nErr, 1)
    }

    // MARK: - v1.7.7 Track A3 — prewarm before TTFT measurement

    /// Prewarm swallows the first POST to the subprocess so measured TTFT
    /// reflects warm-service latency, not model-load + prefill cold-start.
    /// This mock returns HTTP 500 to its FIRST /v1/chat/completions request
    /// and 200 SSE thereafter. Pre-v1.7.7 the real probe hit the 500 and
    /// returned `.infeasible`. Post-v1.7.7 the prewarm eats the 500 via
    /// `try?` and the real probe runs against the warm state.
    func testStage1ProberPrewarmAbsorbsFirstColdStartFailure() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try firstRequestFailsSSEScript().path,
            logDirectory: try temporaryDirectory(name: "stage1-prewarm-absorb-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .feasible(let medianTPS, _) = result else {
            return XCTFail("expected feasible after prewarm absorbed cold-start failure, got \(result)")
        }
        XCTAssertGreaterThan(medianTPS, 0)
    }

    /// If the subprocess dies BETWEEN prewarm and real probe, the prober
    /// must classify the run infeasible with a prewarm-scoped reason string
    /// instead of pretending prewarm never happened.
    func testStage1ProberDetectsProcessExitBetweenPrewarmAndProbe() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try firstRequestExitsSubprocessScript().path,
            logDirectory: try temporaryDirectory(name: "stage1-prewarm-exit-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .infeasible(let reason, _) = result else {
            return XCTFail("expected infeasible on subprocess exit during prewarm, got \(result)")
        }
        XCTAssertTrue(reason.contains("prewarm") || reason.contains("exit"), reason)
    }

    // MARK: - v1.7.8 Track A4 — token-count + generation-only elapsed

    /// Pre-v1.7.8 code counted whitespace-separated words and divided by
    /// TOTAL elapsed (including TTFT). This test uses a mock that emits
    /// 10 single-token deltas fast (each ~1ms apart) after a deliberately
    /// long 0.4s TTFT. Post-v1.7.8 TPS = 10 / (~10ms) = 1000+ tok/s.
    /// Pre-v1.7.8 TPS would have been ~25 tok/s (10 words / 0.4s) —
    /// well under the asserted 40 tok/s floor.
    ///
    /// Real-world win: pre-v1.7.8, M-Base measured 3-4 TPS on 30B MoE
    /// candidates that actually stream 25-40 tok/s in warm generation.
    /// The measurement bug drove every candidate under the catalog's
    /// `min_sustained_tps` gate and caused install drop-out.
    func testStage1ProberTPSCountsDeltasAndDividesByGenerationTime() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try slowTTFTFastDeltasScript(ttftSeconds: 0.4, deltaCount: 10).path,
            logDirectory: try temporaryDirectory(name: "stage1-tps-math-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 10, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .feasible(let medianTPS, let p95TTFTMS) = result else {
            return XCTFail("expected feasible, got \(result)")
        }
        // Generation elapsed for 10 fast-emitted deltas is ~10ms
        // (Python for-loop + socket sendall). Expected TPS ≈ 10 /
        // 0.010 = 1000. Even under CI jitter → 100ms elapsed → TPS =
        // 100. Assert > 40 to rule out the pre-v1.7.8 total-elapsed
        // math which would produce ~25 TPS (10 deltas / 0.4s).
        XCTAssertGreaterThan(medianTPS, 40,
            "post-v1.7.8 TPS must exclude TTFT from elapsed; got \(medianTPS)")
        // TTFT measurement itself should reflect the ~400ms wait
        // (v1.7.5 contract, unaffected by A4).
        XCTAssertGreaterThan(p95TTFTMS, 200)
    }

    func testStage1ProberDetectsTTFTGateMiss() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try sseProviderScript(responseText: "hello world", delayBeforeFirstToken: 0.2).path,
            logDirectory: try temporaryDirectory(name: "stage1-ttft-gate-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 10,
            replicates: 1
        )

        guard case .infeasible(let reason, let nErr) = result else {
            return XCTFail("expected infeasible, got \(result)")
        }
        XCTAssertTrue(reason.contains("exceeded gate 10ms"), reason)
        XCTAssertEqual(nErr, 1)
    }

    func testStage1ProberInvalidTTFTWithPositiveGateReturnsInfeasibleWithoutTrapping() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try emptyCompletionSSEScript().path,
            logDirectory: try temporaryDirectory(name: "stage1-invalid-ttft-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 10,
            replicates: 1
        )

        guard case .infeasible(let reason, let nErr) = result else {
            return XCTFail("expected infeasible, got \(result)")
        }
        XCTAssertTrue(reason.contains("invalid throughput 0"), reason)
        XCTAssertEqual(nErr, 1)
    }

    // MARK: - Round-1 audit fix tests

    /// Round-1 D.1 closure: HTTP non-2xx responses MUST classify as
    /// infeasible. The prior SSE parser handled this correctly but
    /// without a regression-lock test.
    func testStage1ProberClassifiesHTTPNon2xxAsInfeasible() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try non2xxProviderScript(statusCode: 503, statusMessage: "Service Unavailable").path,
            logDirectory: try temporaryDirectory(name: "stage1-non2xx-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .infeasible(let reason, let nErr) = result else {
            return XCTFail("expected infeasible, got \(result)")
        }
        XCTAssertTrue(reason.contains("HTTP 503"), reason)
        XCTAssertEqual(nErr, 1)
    }

    /// Round-1 D.1 closure: completions-style `choices[0].text` SSE
    /// payloads MUST be accepted as content (alongside the chat-style
    /// `choices[0].delta.content`).
    func testStage1ProberAcceptsCompletionsStyleTextSSE() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try completionsTextSSEProviderScript(responseText: "completions-style content").path,
            logDirectory: try temporaryDirectory(name: "stage1-completions-text-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 1).probe(
            model: "model-a",
            port: port,
            runner: runner,
            targetContext: 64,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .feasible(let medianTPS, _) = result else {
            return XCTFail("expected feasible, got \(result)")
        }
        XCTAssertGreaterThan(medianTPS, 0)
    }

    // MARK: - Reasoning-model throughput fix

    /// Reasoning models (gpt-oss-20b / Harmony) suppress their analysis
    /// channel from `delta.content`, so the probe sees ZERO content
    /// deltas AND — crucially — the provider reports `completion_tokens`
    /// = 0 (visible-final only) for a probe that elicits no final answer.
    /// The honest decode count lives in the additive vendor field
    /// `macprovider_generated_completion_tokens`. This end-to-end test
    /// drives the prober against a server that emits only empty-content
    /// deltas + a usage chunk with `completion_tokens: 0` and the
    /// generated-tokens field, and asserts the candidate is feasible with
    /// positive throughput — NOT the 0 tok/s "invalid throughput"
    /// infeasible verdict that pre-fix code (and a completion_tokens-only
    /// fix) produced.
    func testStage1ProberReasoningOnlyStreamUsesGeneratedTokens() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try reasoningOnlyUsageScript(generatedTokens: 40).path,
            logDirectory: try temporaryDirectory(name: "stage1-reasoning-only-logs")
        )

        let result = try await Stage1Prober(readyTimeoutSec: 10, stopGraceSeconds: 1).probe(
            model: "gpt-oss-20b",
            port: port,
            runner: runner,
            targetContext: 4_000,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .feasible(let medianTPS, _) = result else {
            return XCTFail("reasoning-only stream must be feasible, got \(result)")
        }
        XCTAssertGreaterThan(medianTPS, 0,
            "macprovider_generated_completion_tokens must yield positive throughput for reasoning models even when completion_tokens is 0")
        // 40 decoded tokens / 2000ms provider decode window = 20 tok/s. The
        // measured median must track the PROVIDER-reported decode rate, not
        // a client-timed artifact.
        XCTAssertEqual(medianTPS, 20.0, accuracy: 0.5,
            "throughput must equal the provider-reported decode rate (40 tokens / 2000ms = 20 tok/s)")
    }

    /// Unit: reasoning-only finalization. No content deltas
    /// (`firstTokenAt == nil`) but a decode-token count → throughput
    /// derived from it over the full request window, TTFT finite.
    func testFinalizeProbeMetricsReasoningOnlyStream() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(2.0)
        // Branch 3: a decoded-token count but no provider timing and no
        // visible token → divide by the full request window (conservative).
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 0,
            usageDecodedTokens: 50,
            usageGenerationMS: nil,
            firstTokenAt: nil,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 25.0, accuracy: 0.0001,
            "50 tokens / 2s full window = 25 tok/s")
        XCTAssertEqual(metrics.ttftMS, 2_000, accuracy: 0.0001,
            "no content token observed → TTFT falls back to full elapsed")
        XCTAssertTrue(metrics.ttftMS.isFinite)
    }

    /// Unit: provider-timed path (branch 1). When the usage chunk carries
    /// BOTH a decoded-token count and `macprovider_generation_ms`,
    /// throughput = tokens / (generationMS / 1000) — the authoritative,
    /// all-channel decode rate, independent of client-observed timing.
    func testFinalizeProbeMetricsProviderTimedIsAuthoritative() {
        let started = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = started.addingTimeInterval(0.2)
        let ended = started.addingTimeInterval(1.2)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 10,
            usageDecodedTokens: 12,
            usageGenerationMS: 1_000,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 12.0, accuracy: 0.0001,
            "12 decoded tokens / 1s provider decode window = 12 tok/s")
        XCTAssertEqual(metrics.ttftMS, 200, accuracy: 0.0001)
    }

    /// Unit: the MIXED reasoning+final case that fixes the HIGH. A stream
    /// with 5s of silent reasoning then 1s of visible final output reports
    /// 110 total decoded tokens over a 6000ms provider decode window. The
    /// client-observed content window (`ended - firstTokenAt` = 1s) would
    /// wrongly yield 110 tok/s; the provider-timed path must yield
    /// ≈18.3 tok/s.
    func testFinalizeProbeMetricsMixedReasoningAndFinal() {
        let started = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = started.addingTimeInterval(5.0)
        let ended = started.addingTimeInterval(6.0)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 20,
            usageDecodedTokens: 110,
            usageGenerationMS: 6_000,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 110.0 / 6.0, accuracy: 0.01,
            "110 tokens / 6s provider decode window ≈ 18.3 tok/s, NOT 110")
        XCTAssertLessThan(metrics.throughputTPS, 20,
            "must NOT report the content-window rate (110 tok/s)")
        XCTAssertEqual(metrics.ttftMS, 5_000, accuracy: 0.0001)
    }

    /// Unit (code round-3 MEDIUM): a `usageGenerationMS` larger than the
    /// observed request wall-time is malformed — the decode window is a
    /// subset of the request. An overflowed `Int64.max` must NOT be trusted
    /// (it would yield a garbage ~0 TPS "feasible" replicate); the provider
    /// branch (1b) is skipped and finalization falls through to the
    /// conservative client-timed window (1c here, since a visible token was
    /// seen).
    func testFinalizeProbeMetricsRejectsGenerationMSExceedingRequestWindow() {
        let started = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = started.addingTimeInterval(0.2)
        let ended = started.addingTimeInterval(1.2)

        // Int64.max ms → absurdly larger than the 1.2s request → ignored.
        let overflow = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 10,
            usageDecodedTokens: 40,
            usageGenerationMS: Int(Int64.max),
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        // Falls to 1c: decoded count (40) over the warm-generation window (1s).
        XCTAssertEqual(overflow.throughputTPS, 40.0, accuracy: 0.0001,
            "generation_ms > request window must be ignored, not trusted")

        // A merely-too-large value (5s reported for a 1.2s request) is also
        // rejected.
        let tooLarge = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 10,
            usageDecodedTokens: 40,
            usageGenerationMS: 5_000,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        XCTAssertEqual(tooLarge.throughputTPS, 40.0, accuracy: 0.0001)
    }

    /// Unit: a `usageGenerationMS` within the observed request window (plus
    /// tolerance) IS trusted as the provider decode window.
    func testFinalizeProbeMetricsAcceptsGenerationMSWithinRequestWindow() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(2.0)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 0,
            usageDecodedTokens: 40,
            usageGenerationMS: 1_800,
            firstTokenAt: nil,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 40.0 / 1.8, accuracy: 0.01,
            "1800ms decode window inside the 2s request is authoritative")
    }

    /// Unit (code round-4 MEDIUM): a legacy stream with observed content but
    /// a fallback token count of 0 (e.g. a whitespace-only delta whose word
    /// split is empty) must NOT be infeasible — content was observed, so at
    /// least one token counts. Preserves the prior `max(1, wordCount)` /
    /// `max(1, deltaCount)` behavior.
    func testFinalizeProbeMetricsContentObservedButZeroFallbackCountsAsOne() {
        let started = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = started.addingTimeInterval(0.2)
        let ended = started.addingTimeInterval(1.2)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 0,
            usageDecodedTokens: nil,
            usageGenerationMS: nil,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 1.0, accuracy: 0.0001,
            "content observed → at least 1 token / 1s window = 1 tok/s, not infeasible")
        XCTAssertTrue(metrics.throughputTPS.isFinite)
        XCTAssertEqual(metrics.ttftMS, 200, accuracy: 0.0001)
    }

    /// Unit: content stream without a usage chunk (older serve builds).
    /// Falls back (branch 2) to the content-delta count over the
    /// generation window.
    func testFinalizeProbeMetricsContentStreamWithoutUsage() {
        let started = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = started.addingTimeInterval(0.2)
        let ended = started.addingTimeInterval(1.2)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 10,
            usageDecodedTokens: nil,
            usageGenerationMS: nil,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 10.0, accuracy: 0.0001,
            "10 deltas / 1s generation window = 10 tok/s")
        XCTAssertEqual(metrics.ttftMS, 200, accuracy: 0.0001)
    }

    /// Unit: a decoded-token count present but `usageGenerationMS` == 0
    /// (degenerate provider timing) must NOT divide by zero — the provider
    /// branch (1b) requires ms >= 1. Round-2 code MEDIUM-2 branch order: the
    /// authoritative decoded count (12) is preferred over the content-delta
    /// fallback (10), divided by the warm-generation window (1c).
    func testFinalizeProbeMetricsZeroGenerationMSFallsThrough() {
        let started = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = started.addingTimeInterval(0.2)
        let ended = started.addingTimeInterval(1.2)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 10,
            usageDecodedTokens: 12,
            usageGenerationMS: 0,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 12.0, accuracy: 0.0001,
            "generationMS<1 → skip provider path; decoded count over the 1s warm window = 12 tok/s")
        XCTAssertTrue(metrics.throughputTPS.isFinite)
    }

    /// Unit: truly empty generation (no content deltas AND no usage) →
    /// throughput 0 with an infinite TTFT sentinel, preserving the
    /// pre-existing infeasible verdict.
    func testFinalizeProbeMetricsTrulyEmptyIsZero() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(1.0)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 0,
            usageDecodedTokens: nil,
            usageGenerationMS: nil,
            firstTokenAt: nil,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 0)
        XCTAssertEqual(metrics.ttftMS, .infinity)
    }

    /// Unit: an explicit decoded-token count of 0 also means nothing was
    /// generated → throughput 0.
    func testFinalizeProbeMetricsExplicitZeroUsageIsZero() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(1.0)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 0,
            usageDecodedTokens: 0,
            usageGenerationMS: nil,
            firstTokenAt: nil,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 0)
        XCTAssertEqual(metrics.ttftMS, .infinity)
    }

    /// Unit: the usage-chunk parser. Prefers the additive
    /// `macprovider_generated_completion_tokens` (total decode count
    /// incl. suppressed reasoning) over `completion_tokens`; falls back to
    /// `completion_tokens` when the generated field is absent (older serve
    /// builds); returns nil for ordinary content chunks, `[DONE]`, and
    /// malformed payloads.
    func testUsageDecodedTokensParsing() {
        // Generated field present + completion_tokens 0 (the reasoning-only
        // case): the generated field wins.
        let reasoningChunk = #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":0,"macprovider_generated_completion_tokens":57,"total_tokens":100}}"#
        XCTAssertEqual(Stage1Prober.usageDecodedTokens(from: reasoningChunk), 57,
            "generated-tokens field must win over completion_tokens")

        // Generated field present alongside a non-zero completion_tokens:
        // still prefer the (larger) generated total (both within the
        // max_tokens cap).
        let bothChunk = #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12,"macprovider_generated_completion_tokens":60,"total_tokens":112}}"#
        XCTAssertEqual(Stage1Prober.usageDecodedTokens(from: bothChunk), 60)

        // Older serve build without the generated field → fall back to
        // completion_tokens.
        let legacyChunk = #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":42,"total_tokens":142}}"#
        XCTAssertEqual(Stage1Prober.usageDecodedTokens(from: legacyChunk), 42)

        let contentChunk = #"{"choices":[{"delta":{"content":"hi"}}]}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: contentChunk))

        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: "[DONE]"))
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: "not-valid-json"))

        let usageNoTokens = #"{"choices":[],"usage":{"prompt_tokens":100}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: usageNoTokens))
    }

    /// Unit: hardened usage-chunk parser rejects malformed/hostile values.
    /// Each must return nil so finalization falls back rather than trusting
    /// an inflated or nonsensical count.
    func testUsageDecodedTokensParserHardening() {
        // Boolean masquerading as a number (JSON `true` bridges to NSNumber).
        let boolChunk = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":true}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: boolChunk),
            "boolean token count must be rejected")

        // Fractional (non-integral) value.
        let fractionalChunk = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":12.5}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: fractionalChunk),
            "fractional token count must be rejected")

        // Negative value.
        let negativeChunk = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":-3}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: negativeChunk),
            "negative token count must be rejected")

        // Int.max — an overflow/garbage sentinel far above the cap.
        let intMaxChunk = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":9223372036854775807}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: intMaxChunk),
            "Int.max token count must be rejected")

        // Greater than the probe's max_tokens cap (512): an honest provider
        // cannot decode more completion tokens than the cap.
        let oversizedChunk = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":513}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: oversizedChunk),
            "value > maxTokens must be rejected")
        // Exactly the cap is valid.
        let atCapChunk = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":512}}"#
        XCTAssertEqual(Stage1Prober.usageDecodedTokens(from: atCapChunk), 512)

        XCTAssertEqual(Stage1Prober.maxTokens(for: 4_000), 512)
        XCTAssertEqual(Stage1Prober.maxTokens(for: 2_000), 272)
        XCTAssertEqual(Stage1Prober.maxTokens(for: 128), 1)

        // A content chunk that ALSO carries usage (non-empty choices) must
        // NOT be treated as the terminal usage chunk.
        let contentWithUsage = #"{"choices":[{"delta":{"content":"hi"}}],"usage":{"macprovider_generated_completion_tokens":50}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: contentWithUsage),
            "non-empty choices must not be treated as terminal usage chunk")

        // The valid reasoning chunk still parses.
        let validChunk = #"{"choices":[],"usage":{"completion_tokens":0,"macprovider_generated_completion_tokens":57}}"#
        XCTAssertEqual(Stage1Prober.usageDecodedTokens(from: validChunk), 57)
    }

    /// Unit: `usageGenerationMS` parser — terminal-shape checks plus a
    /// non-boolean, finite, integral, nonnegative whole-millisecond value.
    func testUsageGenerationMSParsing() {
        let validChunk = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":40,"macprovider_generation_ms":2000}}"#
        XCTAssertEqual(Stage1Prober.usageGenerationMS(from: validChunk), 2000)

        // Round-2 security HIGH: the provider emits whole-ms Int64. A
        // fractional value is malformed and must be rejected (a lenient Double
        // accepting `0.001` inflated throughput by ~10^6).
        let fractionalChunk = #"{"choices":[],"usage":{"macprovider_generation_ms":1234.5}}"#
        XCTAssertNil(Stage1Prober.usageGenerationMS(from: fractionalChunk),
            "fractional generation_ms must be rejected")

        // Sub-millisecond fraction (the exact HIGH exploit value) rejected.
        let subMsChunk = #"{"choices":[],"usage":{"macprovider_generation_ms":0.001}}"#
        XCTAssertNil(Stage1Prober.usageGenerationMS(from: subMsChunk),
            "0.001ms must be rejected, not accepted as a 10^6x TPS multiplier")

        // An integral value encoded as a JSON float (e.g. 2000.0) is still a
        // whole number of ms and is accepted.
        let integralFloatChunk = #"{"choices":[],"usage":{"macprovider_generation_ms":2000.0}}"#
        XCTAssertEqual(Stage1Prober.usageGenerationMS(from: integralFloatChunk), 2000)

        // Zero is a valid, finite, integral, nonnegative value (the caller's
        // finalization treats ms < 1 as "no usable timing").
        let zeroChunk = #"{"choices":[],"usage":{"macprovider_generation_ms":0}}"#
        XCTAssertEqual(Stage1Prober.usageGenerationMS(from: zeroChunk), 0)

        // Boolean rejected.
        let boolChunk = #"{"choices":[],"usage":{"macprovider_generation_ms":true}}"#
        XCTAssertNil(Stage1Prober.usageGenerationMS(from: boolChunk))

        // Negative rejected.
        let negativeChunk = #"{"choices":[],"usage":{"macprovider_generation_ms":-5}}"#
        XCTAssertNil(Stage1Prober.usageGenerationMS(from: negativeChunk))

        // Non-empty choices rejected.
        let contentWithUsage = #"{"choices":[{"delta":{"content":"hi"}}],"usage":{"macprovider_generation_ms":2000}}"#
        XCTAssertNil(Stage1Prober.usageGenerationMS(from: contentWithUsage))

        // Absent field → nil.
        let noField = #"{"choices":[],"usage":{"macprovider_generated_completion_tokens":40}}"#
        XCTAssertNil(Stage1Prober.usageGenerationMS(from: noField))

        XCTAssertNil(Stage1Prober.usageGenerationMS(from: "[DONE]"))
        XCTAssertNil(Stage1Prober.usageGenerationMS(from: "not-valid-json"))
    }

    /// Round-2 security HIGH: a valid integer ms drives the provider-timed
    /// branch, and the denominator is floored at 1 ms (0.001s) so throughput
    /// stays bounded even at the minimum reportable window. The pre-fix lenient
    /// Double path let `0.001` ms give `64 / (0.001/1000)` = 64,000,000 TPS;
    /// the floored integer path caps ms=1 at `64 / 0.001s` = 64,000 TPS.
    func testFinalizeProbeMetricsProviderTimedUsesOneMillisecondFloor() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(2.0)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 0,
            usageDecodedTokens: 64,
            usageGenerationMS: 1,
            firstTokenAt: nil,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 64.0 / 0.001, accuracy: 0.0001,
            "ms=1 floors the denominator at 0.001s → 64,000 TPS, not an unbounded value")
        XCTAssertTrue(metrics.throughputTPS.isFinite)
    }

    /// Round-2 code MEDIUM-2 (Fix D): an authoritative decoded-count of 0 means
    /// the provider decoded nothing — infeasible — even when a stray content
    /// delta was observed and a first-token time exists. The count is
    /// authoritative over the content fallback.
    func testFinalizeProbeMetricsAuthoritativeZeroBeatsContentFallback() {
        let started = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = started.addingTimeInterval(0.2)
        let ended = started.addingTimeInterval(1.2)
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: 1,
            usageDecodedTokens: 0,
            usageGenerationMS: nil,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        XCTAssertEqual(metrics.throughputTPS, 0,
            "authoritative decoded-count 0 → infeasible regardless of observed content")
        XCTAssertEqual(metrics.ttftMS, .infinity)
    }

    /// Round-2 code MEDIUM-1 (Fix C): when the namespaced generated field is
    /// PRESENT but invalid, the parser returns nil and must NOT silently fall
    /// back to `completion_tokens`.
    func testUsageDecodedTokensPresentButInvalidDoesNotFallBack() {
        // Generated > maxTokens cap (513 > 512) with a valid completion_tokens 32:
        // present-but-invalid → nil, NOT 32.
        let overCapChunk = #"{"choices":[],"usage":{"completion_tokens":32,"macprovider_generated_completion_tokens":513}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: overCapChunk),
            "present-but-over-cap generated field must yield nil, not fall back to completion_tokens")

        // Generated boolean with a valid completion_tokens 20 → nil.
        let boolChunk = #"{"choices":[],"usage":{"completion_tokens":20,"macprovider_generated_completion_tokens":true}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: boolChunk),
            "present-but-boolean generated field must yield nil, not fall back to completion_tokens")

        // Generated JSON null (present as NSNull) with valid completion_tokens → nil.
        let nullChunk = #"{"choices":[],"usage":{"completion_tokens":20,"macprovider_generated_completion_tokens":null}}"#
        XCTAssertNil(Stage1Prober.usageDecodedTokens(from: nullChunk),
            "present-but-null generated field must yield nil, not fall back to completion_tokens")

        // Sanity: when the generated field is genuinely ABSENT, completion_tokens
        // is still used (unchanged fallback behavior).
        let absentChunk = #"{"choices":[],"usage":{"completion_tokens":20}}"#
        XCTAssertEqual(Stage1Prober.usageDecodedTokens(from: absentChunk), 20,
            "absent generated field → fall back to completion_tokens")
    }

    /// Round-1 K.1 closure: persistence-field assertion. The iterator
    /// MUST write Stage 1 rows with `stage = 1`, `replicates_n = stage1Replicates`,
    /// `max_context_cap = targetContext`, `kv_bits = NULL`,
    /// `max_batch = NULL`, AND `kept = 0` (Stage 1 leaves `kept` to
    /// Step 9's recommendation surface per FR-G.1 schema comment;
    /// closes round-1 audit H.1 too).
    func testStage1IteratorPersistsFullStage1FieldSet() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prewarmer = StubPreWarmer(results: [
            "1b": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
        ])
        let prober = StubStage1Prober(results: [
            "1b": .feasible(medianTPS: 10, p95TTFTMS: 100),
        ])

        _ = try await makeIterator(
            db: db,
            candidates: ["1b"],
            prewarmer: prewarmer,
            prober: prober,
            stage1Replicates: 3,
            targetContext: 4_000
        ).run()

        let row = try assertSingleTrialRow(at: dbURL)
        XCTAssertEqual(row.stage, 1, "Stage 1 rows MUST set stage = 1 (AC-16 contract)")
        XCTAssertEqual(row.runID, "stage1-test-run")
        XCTAssertEqual(row.replicatesN, 3)
        XCTAssertEqual(row.maxContextCap, 4_000)
        XCTAssertNil(row.kvBits, "Stage 1 leaves kv_bits to Stage 2 cells")
        XCTAssertNil(row.maxBatch, "Stage 1 leaves max_batch to Stage 2 cells")
        // Round-1 H.1 closure: SPEC-013 §5.7 FR-G.1's tune_trials.kept
        // schema comment reserves kept for Stage 2; the chosen model is
        // surfaced via Stage1IteratorResult.selectedModel, not via kept.
        XCTAssertFalse(row.kept, "Stage 1 rows MUST have kept = false per FR-G.1 schema comment")
        XCTAssertTrue(row.fits)
        XCTAssertEqual(row.nErr, 0)
    }

    private func makeIterator(
        db: AutotuneDB,
        candidates: [String],
        candidatesBySize: [String]? = nil,
        prewarmer: StubPreWarmer,
        prober: StubStage1Prober,
        stage1Replicates: Int = 1,
        targetContext: Int = 2_000
    ) -> Stage1Iterator {
        Stage1Iterator(
            candidateProviderRunner: { StubProviderRunner() },
            providerPreWarmer: prewarmer,
            autotuneDB: db,
            runID: "stage1-test-run",
            candidates: candidates,
            candidatesBySize: candidatesBySize,
            targetContext: targetContext,
            gateTTFTMS: 60_000,
            stage1Replicates: stage1Replicates,
            port: 18_080,
            prober: prober,
            readyTimeoutSec: 1,
            now: { Date(timeIntervalSince1970: 1_781_740_800) }
        )
    }

    /// Round-1 D.1 fixture: HTTP server that returns a non-2xx status
    /// for every chat completions request (after responding 200 to
    /// /v1/models so waitForReady completes).
    private func non2xxProviderScript(statusCode: Int, statusMessage: String) throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-non2xx-provider")
        let scriptURL = directory.appendingPathComponent("non2xx-provider")
        let script = """
        #!/usr/bin/env python3
        import socket, sys

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 non2xx provider ready", flush=True)

        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            body = '{"error":"non-2xx test fixture"}'
            client.sendall((
                f"HTTP/1.1 \(statusCode) \(statusMessage)\\r\\n"
                "Content-Type: application/json\\r\\n"
                f"Content-Length: {len(body)}\\r\\n"
                "Connection: close\\r\\n"
                "\\r\\n"
                f"{body}"
            ).encode())
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Round-1 D.1 fixture: SSE stream that uses `choices[0].text`
    /// (completions API style) instead of `choices[0].delta.content`
    /// (chat API style). Both shapes must be accepted by the parser.
    private func completionsTextSSEProviderScript(responseText: String) throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-completions-text-provider")
        let scriptURL = directory.appendingPathComponent("completions-text-provider")
        let escapedText = responseText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let script = """
        #!/usr/bin/env python3
        import json, socket, sys

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 completions-text provider ready", flush=True)

        response_text = '\(escapedText)'

        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            if "POST /v1/chat/completions " in request:
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: text/event-stream\\r\\n"
                    "Cache-Control: no-cache\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                ).encode())
                # Send a comment line (SSE heartbeat) — parser must skip.
                client.sendall(b": keep-alive\\n\\n")
                # Send a malformed `data:` JSON line — parser must skip
                # gracefully without crashing.
                client.sendall(b"data: not-valid-json\\n\\n")
                # The "text" shape used by the completions API.
                chunk = json.dumps({"choices":[{"text":response_text}]})
                client.sendall(f"data: {chunk}\\n\\n".encode())
                client.sendall(b"data: [DONE]\\n\\n")
                client.close()
                continue
            body = "not found"
            client.sendall((
                "HTTP/1.1 404 Not Found\\r\\n"
                f"Content-Length: {len(body)}\\r\\n"
                "Connection: close\\r\\n"
                "\\r\\n"
                f"{body}"
            ).encode())
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Round-1 K.1 helper: read a single trial row's full field set from
    /// the DB for persistence-field assertion.
    private func assertSingleTrialRow(at url: URL) throws -> AutotuneTrialRow {
        let handle = try openSQLite(at: url)
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT ts_utc, run_id, stage, model, target_context,
               measured_prompt_tokens, max_tokens, agg_throughput_tps,
               ttft_p95_ms, fits, n_err, kept, notes,
               kv_bits, max_context_cap, max_batch, replicates_n
        FROM tune_trials
        ORDER BY id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw NSError(domain: "Stage1IteratorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "prepare failed"])
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "Stage1IteratorTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "expected one row"])
        }

        func intOrNil(_ column: Int32) -> Int? {
            if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
            return Int(sqlite3_column_int64(statement, column))
        }
        func doubleOrNil(_ column: Int32) -> Double? {
            if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
            return sqlite3_column_double(statement, column)
        }
        func stringOrNil(_ column: Int32) -> String? {
            if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
            guard let cString = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: cString)
        }

        return AutotuneTrialRow(
            tsUTC: stringOrNil(0) ?? "",
            runID: stringOrNil(1) ?? "",
            stage: intOrNil(2) ?? 0,
            model: stringOrNil(3) ?? "",
            targetContext: intOrNil(4) ?? 0,
            measuredPromptTokens: intOrNil(5),
            maxTokens: intOrNil(6) ?? 0,
            aggThroughputTPS: doubleOrNil(7),
            ttftP95MS: doubleOrNil(8),
            fits: (intOrNil(9) ?? 0) == 1,
            nErr: intOrNil(10) ?? 0,
            kept: (intOrNil(11) ?? 0) == 1,
            notes: stringOrNil(12),
            kvBits: intOrNil(13),
            maxContextCap: intOrNil(14),
            maxBatch: intOrNil(15),
            replicatesN: intOrNil(16)
        )
    }

    /// v1.7.8 Track A4 test helper: emits `deltaCount` SSE deltas fast after
    /// a deliberate `ttftSeconds` delay. Used to verify that the prober
    /// measures generation-only elapsed and counts deltas (not words).
    private func slowTTFTFastDeltasScript(ttftSeconds: Double, deltaCount: Int) throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-slow-ttft-provider")
        let scriptURL = directory.appendingPathComponent("slow-ttft-provider")
        let script = """
        #!/usr/bin/env python3
        import json, socket, sys, time

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 slow-ttft provider ready", flush=True)

        ttft = \(ttftSeconds)
        delta_count = \(deltaCount)
        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            if "POST /v1/chat/completions " in request:
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: text/event-stream\\r\\n"
                    "Cache-Control: no-cache\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                ).encode())
                time.sleep(ttft)
                for i in range(delta_count):
                    chunk = json.dumps({"choices":[{"delta":{"content":"tok"}}]})
                    client.sendall(f"data: {chunk}\\n\\n".encode())
                client.sendall(b"data: [DONE]\\n\\n")
                client.close()
                continue
            body = "not found"
            client.sendall((
                "HTTP/1.1 404 Not Found\\r\\n"
                f"Content-Length: {len(body)}\\r\\n"
                "Connection: close\\r\\n"
                "\\r\\n"
                f"{body}"
            ).encode())
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// v1.7.7 Track A3 test helper: first POST returns HTTP 500 (simulates
    /// cold-start failure like model-load OOM retry), subsequent POSTs
    /// return valid SSE. Prewarm should absorb the 500; the real probe
    /// should measure warm-service latency.
    private func firstRequestFailsSSEScript() throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-first-fails-provider")
        let scriptURL = directory.appendingPathComponent("first-fails-provider")
        let script = """
        #!/usr/bin/env python3
        import json, socket, sys

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 first-fails provider ready", flush=True)

        post_count = 0
        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            if "POST /v1/chat/completions " in request:
                post_count += 1
                if post_count == 1:
                    body = "cold start"
                    client.sendall((
                        "HTTP/1.1 500 Internal Server Error\\r\\n"
                        f"Content-Length: {len(body)}\\r\\n"
                        "Connection: close\\r\\n"
                        "\\r\\n"
                        f"{body}"
                    ).encode())
                    client.close()
                    continue
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: text/event-stream\\r\\n"
                    "Cache-Control: no-cache\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                ).encode())
                chunk = json.dumps({"choices":[{"delta":{"content":"hello"}}]})
                client.sendall(f"data: {chunk}\\n\\n".encode())
                client.sendall(b"data: [DONE]\\n\\n")
                client.close()
                continue
            body = "not found"
            client.sendall((
                "HTTP/1.1 404 Not Found\\r\\n"
                f"Content-Length: {len(body)}\\r\\n"
                "Connection: close\\r\\n"
                "\\r\\n"
                f"{body}"
            ).encode())
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// v1.7.7 Track A3 test helper: subprocess exits(1) after handling the
    /// first POST, so the real probe attempt cannot connect. Prewarm
    /// completes successfully but the post-prewarm waitForReady(0.05)
    /// detects `.processExited` and returns infeasible.
    private func firstRequestExitsSubprocessScript() throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-first-exits-provider")
        let scriptURL = directory.appendingPathComponent("first-exits-provider")
        let script = """
        #!/usr/bin/env python3
        import json, socket, sys

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 first-exits provider ready", flush=True)

        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            if "POST /v1/chat/completions " in request:
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: text/event-stream\\r\\n"
                    "Cache-Control: no-cache\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                ).encode())
                chunk = json.dumps({"choices":[{"delta":{"content":"prewarm-ok"}}]})
                client.sendall(f"data: {chunk}\\n\\n".encode())
                client.sendall(b"data: [DONE]\\n\\n")
                client.close()
                sys.exit(1)
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func sseProviderScript(responseText: String, delayBeforeFirstToken: Double) throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-sse-provider")
        let scriptURL = directory.appendingPathComponent("sse-provider")
        let escapedText = responseText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let script = """
        #!/usr/bin/env python3
        import json, socket, sys, time

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 sse provider ready", flush=True)

        response_text = '\(escapedText)'
        delay = \(delayBeforeFirstToken)

        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            if "POST /v1/chat/completions " in request:
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: text/event-stream\\r\\n"
                    "Cache-Control: no-cache\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                ).encode())
                time.sleep(delay)
                chunk = json.dumps({"choices":[{"delta":{"content":response_text}}]})
                client.sendall(f"data: {chunk}\\n\\n".encode())
                client.sendall(b"data: [DONE]\\n\\n")
                client.close()
                continue
            body = "not found"
            client.sendall((
                "HTTP/1.1 404 Not Found\\r\\n"
                f"Content-Length: {len(body)}\\r\\n"
                "Connection: close\\r\\n"
                "\\r\\n"
                f"{body}"
            ).encode())
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Emits a reasoning-model stream faithful to the real provider:
    /// empty-content deltas (the visible analysis channel gpt-oss
    /// suppresses) followed by the terminal usage chunk with
    /// `completion_tokens: 0` (visible-final only, as the real provider
    /// reports when a probe elicits no final answer) AND the additive
    /// `macprovider_generated_completion_tokens` carrying the honest total
    /// decode count. The prober must derive throughput from the generated
    /// field, not the (zero) content deltas or the (zero) completion_tokens.
    private func reasoningOnlyUsageScript(generatedTokens: Int) throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-reasoning-only-provider")
        let scriptURL = directory.appendingPathComponent("reasoning-only-provider")
        let script = """
        #!/usr/bin/env python3
        import json, socket, sys, time

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 reasoning-only provider ready", flush=True)

        generated_tokens = \(generatedTokens)
        generation_ms = generated_tokens * 50

        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            if "POST /v1/chat/completions " in request:
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: text/event-stream\\r\\n"
                    "Cache-Control: no-cache\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                ).encode())
                # Reasoning models emit empty-content deltas (the parser
                # skips them) while generating suppressed analysis tokens.
                for _ in range(3):
                    chunk = json.dumps({"choices":[{"delta":{"content":""}}]})
                    client.sendall(f"data: {chunk}\\n\\n".encode())
                # Spend real wall-time equal to the decode window we report,
                # so the observed request duration contains it (the probe
                # rejects a generation_ms larger than the request window).
                time.sleep(generation_ms / 1000.0)
                # Terminal usage chunk: completion_tokens is the visible-
                # final count (0 for a reasoning-only probe); the honest
                # total decode count is the macprovider vendor field.
                usage_chunk = json.dumps({
                    "choices": [],
                    "usage": {
                        "prompt_tokens": 51,
                        "completion_tokens": 0,
                        "macprovider_generated_completion_tokens": generated_tokens,
                        # Provider-measured warm-decode wall-time. 50ms/token
                        # → generated_tokens / (ms/1000) = 20 tok/s for the
                        # 40-token fixture, the authoritative decode rate the
                        # probe must report.
                        "macprovider_generation_ms": generation_ms,
                        "total_tokens": 51,
                    },
                })
                client.sendall(f"data: {usage_chunk}\\n\\n".encode())
                client.sendall(b"data: [DONE]\\n\\n")
                client.close()
                continue
            body = "not found"
            client.sendall((
                "HTTP/1.1 404 Not Found\\r\\n"
                f"Content-Length: {len(body)}\\r\\n"
                "Connection: close\\r\\n"
                "\\r\\n"
                f"{body}"
            ).encode())
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func emptyCompletionSSEScript() throws -> URL {
        let directory = try temporaryDirectory(name: "stage1-empty-sse-provider")
        let scriptURL = directory.appendingPathComponent("empty-sse-provider")
        let script = """
        #!/usr/bin/env python3
        import socket, sys

        args = sys.argv[1:]
        if "serve" not in args or "--no-join" not in args:
            sys.stderr.write("expected serve --no-join\\n")
            sys.exit(2)
        port = int(args[args.index("--port") + 1])

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        print("stage1 empty sse provider ready", flush=True)

        while True:
            client, _ = server.accept()
            request = client.recv(65536).decode("utf-8", "ignore")
            if "GET /v1/models " in request:
                body = '{"object":"list","data":[{"id":"stub","object":"model"}]}'
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: application/json\\r\\n"
                    f"Content-Length: {len(body)}\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    f"{body}"
                ).encode())
                client.close()
                continue
            if "POST /v1/chat/completions " in request:
                client.sendall((
                    "HTTP/1.1 200 OK\\r\\n"
                    "Content-Type: text/event-stream\\r\\n"
                    "Cache-Control: no-cache\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                ).encode())
                client.sendall(b"data: [DONE]\\n\\n")
                client.close()
                continue
            body = "not found"
            client.sendall((
                "HTTP/1.1 404 Not Found\\r\\n"
                f"Content-Length: {len(body)}\\r\\n"
                "Connection: close\\r\\n"
                "\\r\\n"
                f"{body}"
            ).encode())
            client.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func temporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func temporaryDBURL() throws -> URL {
        try temporaryDirectory(name: "stage1-db").appendingPathComponent("autotune.sqlite")
    }

    private func unusedPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var bindAddr = addr
        let bindResult = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        XCTAssertEqual(nameResult, 0)
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func trialModels(at url: URL) throws -> [String] {
        try stringColumn("SELECT model FROM tune_trials ORDER BY id", at: url)
    }

    private func notes(for model: String, at url: URL) throws -> String? {
        let rows = try stringColumn("SELECT notes FROM tune_trials WHERE model = '\(model)' ORDER BY id", at: url)
        return rows.first
    }

    private func stringColumn(_ sql: String, at url: URL) throws -> [String] {
        let handle = try openSQLite(at: url)
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw sqliteError(handle, fallback: "prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                values.append(String(cString: cString))
            }
        }
        return values
    }

    private func openSQLite(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            throw NSError(domain: "Stage1IteratorTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not open sqlite fixture",
            ])
        }
        return handle
    }

    private func sqliteError(_ handle: OpaquePointer, fallback: String) -> NSError {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? fallback
        return NSError(domain: "Stage1IteratorTests", code: Int(sqlite3_errcode(handle)), userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}

private final class StubProviderRunner: Stage1ProviderRunning {
    var stopResult: StopResult = .stopped

    func start(
        model: String,
        port: Int,
        kvBits: Int?,
        maxContext: Int?,
        maxBatch: Int?
    ) throws {}

    func waitForReady(timeout: TimeInterval) async throws -> ReadyStatus {
        .ready
    }

    func stop(graceSeconds: Double) -> StopResult {
        stopResult
    }
}

private final class StubPreWarmer: Stage1PreWarming {
    private let results: [String: PreWarmResult]
    private(set) var models: [String] = []

    init(results: [String: PreWarmResult]) {
        self.results = results
    }

    func prewarmAndProbe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        readyTimeoutSec: TimeInterval
    ) async throws -> PreWarmResult {
        models.append(model)
        return results[model] ?? .failed(failureClass: .transient, reason: "missing stub prewarm result")
    }
}

private final class StubStage1Prober: Stage1Probing {
    private let results: [String: Stage1ProbeResult]
    private(set) var probedModels: [String] = []

    init(results: [String: Stage1ProbeResult]) {
        self.results = results
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage1ProbeResult {
        probedModels.append(model)
        return results[model] ?? .infeasible(reason: "missing stub probe result", nErr: 1)
    }
}
