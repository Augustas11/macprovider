import Darwin
import Foundation
import SQLite3
import XCTest
@testable import macprovider_cli

final class Stage1IteratorTests: XCTestCase {
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

        XCTAssertEqual(try trialModels(at: dbURL), [])
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
            XCTAssertEqual(reason, "1b leaked stop token")
            XCTAssertEqual(trials, ["32b too slow", "14b too slow", "1b leaked stop token"])
            XCTAssertEqual(exitReason, .noFeasible)
            XCTAssertTrue(error.description.hasPrefix("no_feasible: 1b leaked stop token"))
        }

        XCTAssertEqual(try trialModels(at: dbURL), ["32b", "14b", "1b"])
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

    private func makeIterator(
        db: AutotuneDB,
        candidates: [String],
        prewarmer: StubPreWarmer,
        prober: StubStage1Prober
    ) -> Stage1Iterator {
        Stage1Iterator(
            candidateProviderRunner: { StubProviderRunner() },
            providerPreWarmer: prewarmer,
            autotuneDB: db,
            runID: "stage1-test-run",
            candidates: candidates,
            targetContext: 2_000,
            gateTTFTMS: 60_000,
            stage1Replicates: 1,
            port: 18_080,
            prober: prober,
            readyTimeoutSec: 1,
            now: { Date(timeIntervalSince1970: 1_781_740_800) }
        )
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
