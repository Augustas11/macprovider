import Foundation
import SQLite3
import XCTest
@testable import macprovider_cli

final class Stage2HillClimbTests: XCTestCase {
    func testStage2UsesTheContextBoundedHarmonyProbeBudget() {
        XCTAssertEqual(Stage2Prober.maxTokens(for: 4_000), 512)
        XCTAssertEqual(Stage2Prober.maxTokens(for: 2_000), 272)
    }

    func testStage2HillClimbPicksFirstFeasibleAsBaseline() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil],
            maxBatchAxis: [1],
            maxContextAxis: [2_000]
        ).run()

        XCTAssertEqual(result.selectedModel, "selected-model")
        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.medianTPS, 10)
        XCTAssertEqual(result.p95TTFTMS, 900)
        XCTAssertEqual(result.replicates, 1)
        XCTAssertEqual(result.cellTrials.count, 1)
        XCTAssertTrue(result.cellTrials[0].kept)
        XCTAssertEqual(try persistedTrialRows(at: dbURL).count, 1)
    }

    func testStage2HillClimbAppliesIsNewBestThroughputPrimary() async throws {
        let db = try AutotuneDB(path: try temporaryDBURL().path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 700, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 12, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000]
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.medianTPS, 12)
        // Round-1 audit D.1 (MAJOR) closure: only the FINAL winner row
        // carries `kept = true`. Cell A (kv_bits=nil) was the running
        // best at iteration time but cell B (kv_bits=4) won on
        // throughput; only B's row keeps kept=true.
        XCTAssertEqual(result.cellTrials.map(\.kept), [false, true])
    }

    func testStage2HillClimbAppliesIsNewBestTTFTTiebreak() async throws {
        let db = try AutotuneDB(path: try temporaryDBURL().path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 1_000, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 10.1, p95TTFTMS: 800, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000]
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.p95TTFTMS, 800)
        // D.1 closure: only the final TTFT-tiebreak winner has kept=true.
        XCTAssertEqual(result.cellTrials.map(\.kept), [false, true])
    }

    func testStage2HillClimbRejectsCellWhenAnyReplicateInfeasible() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .infeasible(reason: "TTFT 61000ms exceeded gate 60000ms", nErr: 1, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 9, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000],
            stage2Replicates: 3
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.cellTrials.count, 2)
        XCTAssertFalse(result.cellTrials[0].fits)
        XCTAssertNil(result.cellTrials[0].aggThroughputTPS)
        XCTAssertNil(result.cellTrials[0].ttftP95MS)
        XCTAssertEqual(result.cellTrials[0].replicatesN, 3)
        XCTAssertEqual(try persistedTrialRows(at: dbURL)[0].aggThroughputTPS, nil)
    }

    func testStage2HillClimbAllCellsInfeasibleThrowsNoFeasibleCell() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .infeasible(reason: "HTTP 503", nErr: 1, measuredPromptTokens: nil),
            .infeasible(reason: "provider exited", nErr: 1, measuredPromptTokens: nil),
        ])

        do {
            _ = try await makeHillClimb(
                db: db,
                prober: prober,
                kvBitsAxis: [nil, 4],
                maxBatchAxis: [1],
                maxContextAxis: [2_000]
            ).run()
            XCTFail("expected no feasible cell")
        } catch let error as Stage2HillClimbError {
            guard case .noFeasibleCell(let reason) = error else {
                return XCTFail("expected noFeasibleCell, got \(error)")
            }
            XCTAssertTrue(reason.contains("HTTP 503"), reason)
            XCTAssertTrue(reason.contains("provider exited"), reason)
            XCTAssertTrue(error.description.contains("Stage 2 found no feasible knob cell"))
        }

        XCTAssertEqual(try persistedTrialRows(at: dbURL).count, 2)
    }

    func testStage2HillClimbPersistsAllCellTrialsWithStageTwo() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 900, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 11, p95TTFTMS: 850, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 9, p95TTFTMS: 700, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 10.5, p95TTFTMS: 950, measuredPromptTokens: 1_600),
        ])

        _ = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1, 2],
            maxContextAxis: [2_000],
            stage2Replicates: 2
        ).run()

        let rows = try persistedTrialRows(at: dbURL)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.stage), [2, 2, 2, 2])
        XCTAssertEqual(rows.map(\.kvBits), [nil, nil, 4, 4])
        XCTAssertEqual(rows.map(\.maxBatch), [1, 2, 1, 2])
        XCTAssertEqual(rows.map(\.maxContextCap), [2_000, 2_000, 2_000, 2_000])
        XCTAssertEqual(rows.map(\.replicatesN), [2, 2, 2, 2])
        XCTAssertEqual(prober.probedKnobs, [
            WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000),
            WinningKnobs(kvBits: nil, maxBatch: 2, maxContext: 2_000),
            WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000),
            WinningKnobs(kvBits: 4, maxBatch: 2, maxContext: 2_000),
        ])
        // Round-1 audit D.1 (MAJOR) closure: exactly ONE Stage 2 row
        // in a run carries `kept = true` — the FINAL winning cell.
        // TPS values [10, 11, 9, 10.5] mean cell 2 (kv_bits=nil,
        // max_batch=2) wins by isNewBest at row 1 and is never
        // displaced (9 and 10.5 don't beat 11).
        XCTAssertEqual(rows.map(\.kept), [false, true, false, false])
        XCTAssertEqual(rows.filter(\.kept).count, 1,
                       "exactly one Stage 2 row per run MUST have kept = true")
    }

    func testStage2HillClimbHonorsTPSTieEpsilon() async throws {
        let db = try AutotuneDB(path: try temporaryDBURL().path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 800, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 10.05, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000],
            tpsTieEpsilon: 0.02
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.medianTPS, 10)
        XCTAssertEqual(result.cellTrials.map(\.kept), [true, false])
    }

    // MARK: - Round-1 audit J.1 closure: direct isNewBest edge-branch tests

    /// Round-1 J.1 closure: when `bestTPS == 0` (the unmeasurable-prior
    /// edge), `isNewBest` should accept any positive TPS as the new
    /// best per the prototype's `if best_tps <= 0: return tps > 0`.
    func testIsNewBestAcceptsPositiveTPSWhenBestTPSIsZero() {
        XCTAssertTrue(Stage2HillClimb.isNewBest(
            tps: 0.1, ttft: nil, bestTPS: 0, bestTTFT: nil
        ))
        XCTAssertTrue(Stage2HillClimb.isNewBest(
            tps: 5.0, ttft: 1_000, bestTPS: 0, bestTTFT: 500
        ))
    }

    /// Round-1 J.1 closure: when `bestTPS == 0` AND new TPS is also 0
    /// (or negative), `isNewBest` MUST return false. Asymmetric edge —
    /// without this, the zero-vs-zero case would incorrectly return
    /// true via the relGap path (0 / 0 division would crash).
    func testIsNewBestRejectsZeroTPSWhenBestTPSIsZero() {
        XCTAssertFalse(Stage2HillClimb.isNewBest(
            tps: 0, ttft: nil, bestTPS: 0, bestTTFT: nil
        ))
        XCTAssertFalse(Stage2HillClimb.isNewBest(
            tps: -1.0, ttft: nil, bestTPS: 0, bestTTFT: nil
        ))
    }

    /// Round-1 J.1 closure: in the tie band, when `bestTTFT == nil`
    /// (e.g. best had unmeasurable TTFT) and new ttft IS measurable,
    /// new wins per the prototype's `ttft is not None and (best_ttft
    /// is None or ...)`.
    func testIsNewBestWinsTieBandWhenBestTTFTIsNil() {
        // tps 10 vs 10.05 = 0.5% gap, within 2% epsilon.
        XCTAssertTrue(Stage2HillClimb.isNewBest(
            tps: 10.05, ttft: 800, bestTPS: 10, bestTTFT: nil
        ))
    }

    /// Round-1 J.1 closure: in the tie band, when BOTH TTFTs are nil,
    /// neither wins (best holds — the first feasible incumbent wins
    /// true ties).
    func testIsNewBestHoldsWhenBothTTFTsAreNilInTieBand() {
        XCTAssertFalse(Stage2HillClimb.isNewBest(
            tps: 10.05, ttft: nil, bestTPS: 10, bestTTFT: nil
        ))
    }

    /// Round-1 J.1 closure: in the tie band, when only new TTFT is
    /// nil (best has measurable TTFT), best holds.
    func testIsNewBestHoldsWhenNewTTFTIsNilInTieBand() {
        XCTAssertFalse(Stage2HillClimb.isNewBest(
            tps: 10.05, ttft: nil, bestTPS: 10, bestTTFT: 800
        ))
    }

    // MARK: - Stage 2 feasibility guard + fallback (real prober)

    /// Fix 2: a stream that generates NOTHING (empty SSE) yields
    /// `(.infinity, 0)` from finalizeProbeMetrics. With `gateTTFTMS == 0` the
    /// TTFT ceiling is disabled, so the pre-fix code appended a `(0, ∞)`
    /// replicate and returned `.feasible(medianTPS: 0, p95TTFTMS: ∞)`. The
    /// guard must reject the non-positive throughput / non-finite TTFT and
    /// mark the cell infeasible — INDEPENDENT of `gateTTFTMS`.
    func testStage2ProberEmptyStreamWithZeroGateIsInfeasible() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try stage2EmptyStreamScript().path,
            logDirectory: try temporaryDirectory(name: "stage2-empty-logs")
        )

        let result = try await Stage2Prober(readyTimeoutSec: 10, stopGraceSeconds: 1).probe(
            model: "gpt-oss-20b",
            port: port,
            runner: runner,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000),
            targetContext: 64,
            gateTTFTMS: 0,
            replicates: 1
        )

        guard case .infeasible = result else {
            return XCTFail("empty stream with gateTTFTMS==0 must be infeasible, got \(result)")
        }
    }

    /// Fix 5: older serve builds emit multi-word content deltas but NO usage
    /// chunk. Stage 2 must measure throughput from the WORD count of the
    /// visible text (its historical fallback numerator), not the delta count.
    /// The script emits 2 deltas of 15 words each (30 words, 2 deltas) then
    /// holds the stream ~0.3s before closing, so the generation window is
    /// well-defined: a word-count numerator yields ~100 tok/s while a
    /// delta-count numerator would yield only ~6 tok/s.
    func testStage2ProberOlderServerMeasuresFromWordCount() async throws {
        let port = try unusedPort()
        let runner = try CandidateProviderRunner(
            providerBinaryPath: try stage2WordCountFallbackScript().path,
            logDirectory: try temporaryDirectory(name: "stage2-wordcount-logs")
        )

        let result = try await Stage2Prober(readyTimeoutSec: 10, stopGraceSeconds: 1).probe(
            model: "legacy-model",
            port: port,
            runner: runner,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000),
            targetContext: 64,
            gateTTFTMS: 60_000,
            replicates: 1
        )

        guard case .feasible(let medianTPS, _, _) = result else {
            return XCTFail("older-server multi-word stream must be feasible, got \(result)")
        }
        // 30 words / ~0.3s ≈ 100 tok/s. A delta-count numerator (2 deltas)
        // could reach at most ~6-7 tok/s over the same window. Assert well
        // above that ceiling so only the word-count numerator can pass.
        XCTAssertGreaterThan(medianTPS, 30,
            "throughput must be derived from the word count, not the delta count; got \(medianTPS)")
    }

    /// Round-2 security MEDIUM (Fix B): the aggregate median that feeds a
    /// `.feasible` cell must be overflow-safe. Two enormous-but-finite
    /// per-replicate throughputs averaged as `(a + b) / 2` overflow to
    /// `.infinity`; averaged as `a / 2 + b / 2` they stay finite. A finite
    /// median then passes the `medianTPS.isFinite && medianTPS > 0` guard,
    /// while an `.infinity` would have been rejected — either way the cell is
    /// never marked `.feasible(medianTPS: .infinity)`.
    func testStage2AggregateMedianIsOverflowSafe() {
        let enormous = Double.greatestFiniteMagnitude
        // Naive averaging overflows; confirm the harness's premise.
        XCTAssertEqual((enormous + enormous) / 2, .infinity,
            "premise: naive (a + b) / 2 overflows for two greatestFiniteMagnitude values")

        let median = Stage2Prober.median([enormous, enormous])
        XCTAssertTrue(median.isFinite,
            "overflow-safe median must stay finite for two enormous-but-finite replicates")
        XCTAssertEqual(median, enormous, accuracy: enormous * 1e-12)
        XCTAssertNotEqual(median, .infinity,
            "median must never be .infinity — that would yield .feasible(medianTPS: .infinity)")
    }

    private func stage2EmptyStreamScript() throws -> URL {
        let directory = try temporaryDirectory(name: "stage2-empty-provider")
        let scriptURL = directory.appendingPathComponent("empty-provider")
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
        print("stage2 empty provider ready", flush=True)

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

    private func stage2WordCountFallbackScript() throws -> URL {
        let directory = try temporaryDirectory(name: "stage2-wordcount-provider")
        let scriptURL = directory.appendingPathComponent("wordcount-provider")
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
        print("stage2 wordcount provider ready", flush=True)

        # 15 words per delta, 2 deltas → 30 words / 2 deltas. NO usage chunk
        # (older serve build), so finalization must use the word count.
        words = " ".join(f"w{i}" for i in range(15))

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
                for _ in range(2):
                    chunk = json.dumps({"choices":[{"delta":{"content":words + " "}}]})
                    client.sendall(f"data: {chunk}\\n\\n".encode())
                # Hold the stream open so the generation window is well-defined
                # (~0.3s) before the terminal [DONE]. No usage chunk emitted.
                time.sleep(0.3)
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

        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        XCTAssertEqual(nameResult, 0)
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    private func makeHillClimb(
        db: AutotuneDB,
        prober: StubStage2Prober,
        kvBitsAxis: [Int?],
        maxBatchAxis: [Int],
        maxContextAxis: [Int],
        stage2Replicates: Int = 1,
        tpsTieEpsilon: Double = 0.02
    ) -> Stage2HillClimb {
        Stage2HillClimb(
            candidateProviderRunner: { StubStage2ProviderRunner() },
            prober: prober,
            autotuneDB: db,
            selectedModel: "selected-model",
            kvBitsAxis: kvBitsAxis,
            maxBatchAxis: maxBatchAxis,
            maxContextAxis: maxContextAxis,
            targetContext: 2_000,
            gateTTFTMS: 60_000,
            stage2Replicates: stage2Replicates,
            tpsTieEpsilon: tpsTieEpsilon,
            port: 18_080,
            runID: "stage2-test-run",
            now: { Date(timeIntervalSince1970: 1_781_740_800) }
        )
    }

    private func temporaryDBURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage2-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("autotune.sqlite")
    }

    private func persistedTrialRows(at url: URL) throws -> [AutotuneTrialRow] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            throw NSError(domain: "Stage2HillClimbTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not open sqlite fixture",
            ])
        }
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
            throw sqliteError(handle, fallback: "prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [AutotuneTrialRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
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

            rows.append(AutotuneTrialRow(
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
            ))
        }
        return rows
    }

    private func sqliteError(_ handle: OpaquePointer, fallback: String) -> NSError {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? fallback
        return NSError(domain: "Stage2HillClimbTests", code: Int(sqlite3_errcode(handle)), userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}

private final class StubStage2ProviderRunner: Stage1ProviderRunning {
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
        .stopped
    }
}

private final class StubStage2Prober: Stage2Probing {
    private var results: [Stage2ProbeResult]
    private(set) var probedKnobs: [WinningKnobs] = []

    init(results: [Stage2ProbeResult]) {
        self.results = results
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        knobs: WinningKnobs,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage2ProbeResult {
        probedKnobs.append(knobs)
        if results.isEmpty {
            return .infeasible(reason: "missing stub probe result", nErr: 1, measuredPromptTokens: nil)
        }
        return results.removeFirst()
    }
}
