import ArgumentParser
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelCatalogReadTests: XCTestCase {
    func testNestedWorkNeverRenewsExpiredRequestAndCancellationReachesExistingBudget() throws {
        var now: UInt64 = 1_000_000_000
        let read = ModelCatalogReadBudget(mode: .quick, clock: { now })
        let first = try read.transactionBudget()
        now += 9_000_000_000
        let last = try read.transactionBudget()
        try first.check(); try last.check()
        now += 1_000_000_000
        XCTAssertThrowsError(try first.check())
        XCTAssertThrowsError(try last.check())
        XCTAssertThrowsError(try read.transactionBudget())
        let cancelled = ModelCatalogReadBudget(mode: .verify)
        let helper = try cancelled.transactionBudget()
        cancelled.cancel()
        XCTAssertThrowsError(try helper.check())
    }

    func testHashProgressCannotRenewAbsoluteDeadlineOrExpiredPhase() throws {
        var now: UInt64 = 0
        let read = ModelCatalogReadBudget(mode: .verify, clock: { now })
        try read.beginHashing()
        for _ in 0..<35 { now += 50_000_000_000; try read.reportBytes(1) }
        try read.beginFinalization()
        now += 10_000_000_000
        XCTAssertThrowsError(try read.check(), "final phase remains bounded after useful hashing")
        let absolute = ModelCatalogReadBudget(mode: .verify, clock: { now })
        try absolute.beginHashing()
        for _ in 0..<35 { now += 50_000_000_000; try absolute.reportBytes(1) }
        now += 50_000_000_000
        XCTAssertThrowsError(try absolute.reportBytes(1), "measured progress cannot renew30minutes")
    }

    func testHeartbeatAndZeroBytesCannotHideStalledHash() throws {
        var now: UInt64 = 0
        let read = ModelCatalogReadBudget(mode: .verify, clock: { now })
        try read.beginHashing()
        for _ in 0..<11 { now += 5_000_000_000; try read.reportBytes(0); try read.check() }
        XCTAssertEqual(read.bytesCompleted, 0)
        now += 5_000_000_000
        XCTAssertThrowsError(try read.check())
        XCTAssertThrowsError(try read.reportBytes(1), "late bytes cannot resurrect expired read")
    }

    func testParsedOwnedReadOptionsAndMalformedCombinations() throws {
        let id = "a3838c05-ed4e-46b5-8052-af1f94bf68ae"
        let base = ["models", "catalog-economics", "--json", "--local-activation", "--app-read-request", id,
                    "--app-read-mode", "quick", "--read-lock-fd", "199", "--read-lifetime-fd", "200"]
        let parsed = try XCTUnwrap(MacProviderCLI.parseAsRoot(base) as? ModelsCatalogEconomicsCommand)
        try parsed.readOptions.validate(mode: [.quick, .verify], target: parsed.verifyLocalModel)
        XCTAssertEqual(parsed.readOptions.appReadRequest, id)
        XCTAssertNil(parsed.ctlSocketPath)
        for suffix in [["--expected-context-sha256", String(repeating: "a", count: 64)],
                       ["--verify-local-model", "mlx-community/Test-Model-4bit"]] {
            let invalid = try XCTUnwrap(MacProviderCLI.parseAsRoot(base + suffix) as? ModelsCatalogEconomicsCommand)
            XCTAssertThrowsError(try invalid.readOptions.validate(mode: [.quick, .verify], target: invalid.verifyLocalModel))
        }
        var invalid = parsed.readOptions
        invalid.readLockFD = 198
        XCTAssertThrowsError(try invalid.validate(mode: [.quick]))
        invalid = parsed.readOptions; invalid.appReadRequest = id.uppercased()
        XCTAssertThrowsError(try invalid.validate(mode: [.quick]))
        invalid = parsed.readOptions; invalid.appReadMode = .result
        XCTAssertThrowsError(try invalid.validate(mode: [.quick, .verify]))
    }

    func testClosedProgressEventsNeverAppendAfterTerminal() throws {
        let output = CapturedOutput()
        let budget = ModelCatalogReadBudget(mode: .verify)
        let events = ModelCatalogReadEvents(requestID: "a3838c05-ed4e-46b5-8052-af1f94bf68ae",
            target: "mlx-community/Test-Model-4bit", key: "test-model", budget: budget, write: output.write)
        try events.start()
        events.fail(.authorityChanged)
        events.fail(.verificationIncomplete)
        let records = try output.records()
        XCTAssertEqual(records.count, 2)
        let keys: Set<String> = ["schema", "request_id", "event_sequence", "target_model_id", "model_key",
                                 "kind", "bytes_completed", "error_code", "projection"]
        for (index, record) in records.enumerated() {
            XCTAssertEqual(Set(record.keys), keys)
            XCTAssertEqual(record["event_sequence"] as? Int, index + 1)
            XCTAssertEqual(record["bytes_completed"] as? Int, 0)
            XCTAssertTrue(record["projection"] is NSNull)
        }
        XCTAssertTrue(records[0]["error_code"] is NSNull)
        XCTAssertEqual(records[1]["error_code"] as? String, "authority_changed")
    }

    func testParsedForbiddenOverridesFailBeforeConfigInputsOrRootSetup() async throws {
        let arguments = ["models", "catalog-economics", "--json", "--local-activation", "--app-read-request",
                         "a3838c05-ed4e-46b5-8052-af1f94bf68ae", "--app-read-mode", "quick",
                         "--read-lock-fd", "199", "--read-lifetime-fd", "200"]
        var context = ModelCommandExecutionContext.production
        context.inputs = { XCTFail("invalid app argv reached signed inputs"); return AutotuneStaticInputs() }
        context.projectionEnvironment = [:]
        for extra in [["--ctl-socket-path", "/untrusted/socket"], ["--model", "wrong/model"],
                      ["--supported-models", "wrong/model"], ["--provider-id", "untrusted"],
                      ["--coordinator-url", "https://untrusted.invalid"], ["--mlx-cache-dir", "/untrusted/cache"],
                      ["--local-discovery-namespace-path", "/untrusted/namespace"],
                      ["--ollama-origin", "http://127.0.0.1:11434"], ["--skip-ollama"],
                      ["--openai-compatible-origin", "http://127.0.0.1:11434"],
                      ["--skip-openai-compatible"], ["--skip-coordinator-status"]] {
            let command = try XCTUnwrap(MacProviderCLI.parseAsRoot(arguments + extra) as? ModelsCatalogEconomicsCommand)
            do { try await command.run(context: context); XCTFail("accepted forbidden override \(extra.first!)") }
            catch ModelCatalogReadError.contextChanged { }
            catch { XCTFail("wrong early rejection for \(extra.first!): \(error)") }
        }
    }

    func testRealCanonicalHashCanProgressBeyondTenSecondsWithIndependentHeartbeats() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data(repeating: 9, count: 10 * 1_048_576).write(to: root.appendingPathComponent("weights.safetensors"))
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        let budget = ModelCatalogReadBudget(mode: .verify)
        let output = CapturedOutput()
        let events = ModelCatalogReadEvents(requestID: UUID().uuidString.lowercased(), target: "fixture/model",
            key: "fixture", budget: budget, write: output.write)
        try events.start(); try budget.beginHashing()
        let began = DispatchTime.now().uptimeNanoseconds
        let observed = try ModelArtifactVerifier.inspectCanonicalArtifact(
            observation: ModelCatalogVerifiedArtifactObservation(directory: root, check: budget.check), budget: budget,
            measuredBytes: { delta in if delta >= 1_048_576 { Thread.sleep(forTimeInterval: 2.1) } })
        try budget.beginFinalization()
        XCTAssertEqual(observed.sha256, expected)
        XCTAssertEqual(budget.bytesCompleted, 10 * 1_048_576 + 2)
        XCTAssertGreaterThan(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000, 20)
        // This test proves actual hash/heartbeat duration. Final app projection
        // acceptance is the distinct parsed command/argv integration fixture.
        events.fail(.verificationIncomplete)
        let records = try output.records()
        XCTAssertGreaterThanOrEqual(records.filter { $0["kind"] as? String == "progress" }.count, 4)
        for gap in output.gaps() { XCTAssertLessThanOrEqual(gap, 5) }
        let values = records.compactMap { ($0["bytes_completed"] as? NSNumber)?.uint64Value }
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(values.last, 10 * 1_048_576 + 2)
    }

    func testCC06ProjectionBelowCeilingStillRejectsOversizedCompletedEnvelope() throws {
        let ceiling = ModelCatalogReadOutput.rawLineLimit - ModelCatalogReadOutput.preflightReserve
        let emptyWarning = projection(warnings: [""])
        let baseSize = try ModelCatalogReadOutput.encoder().encode(emptyWarning).count
        let document = projection(warnings: [String(repeating: "x", count: ceiling - baseSize)])
        XCTAssertEqual(try ModelCatalogReadOutput.encoder().encode(document).count, ceiling)
        XCTAssertThrowsError(try ModelCatalogReadOutput.preflight(document, requestID: requestID,
            targetModelID: "fixture/model", modelKey: "fixture", budget: ModelCatalogReadBudget(mode: .verify))) {
            XCTAssertEqual($0 as? ModelCatalogReadError, .readLimitExceeded)
        }
    }

    func testCC07ExactCompletedEnvelopeBoundariesAndMaximumRecoveryCardinality() throws {
        let ceiling = ModelCatalogReadOutput.rawLineLimit - ModelCatalogReadOutput.preflightReserve
        let base = projection()
        let baseline = try ModelCatalogReadOutput.preflight(base, requestID: requestID,
            targetModelID: "", modelKey: "", budget: ModelCatalogReadBudget(mode: .verify))
        let padding = ceiling - baseline.completedLineBytes
        XCTAssertGreaterThan(padding, 1)
        let exact = try ModelCatalogReadOutput.preflight(base, requestID: requestID,
            targetModelID: String(repeating: "x", count: padding), modelKey: "",
            budget: ModelCatalogReadBudget(mode: .verify))
        XCTAssertEqual(exact.completedLineBytes, ceiling)
        XCTAssertNoThrow(try ModelCatalogReadOutput.preflight(base, requestID: requestID,
            targetModelID: String(repeating: "x", count: padding - 1), modelKey: "",
            budget: ModelCatalogReadBudget(mode: .verify)))
        XCTAssertThrowsError(try ModelCatalogReadOutput.preflight(base, requestID: requestID,
            targetModelID: String(repeating: "x", count: padding + 1), modelKey: "",
            budget: ModelCatalogReadBudget(mode: .verify)))

        let rawBaseline = try ModelCatalogReadEvents.encodedLine(requestID: requestID, eventSequence: 2,
            targetModelID: "", modelKey: "", kind: "completed", bytesCompleted: 0,
            errorCode: nil, projection: base)
        let rawPadding = ModelCatalogReadOutput.rawLineLimit - rawBaseline.count
        for delta in [-1, 0] {
            let output = CapturedOutput(), eventBudget = ModelCatalogReadBudget(mode: .verify)
            let events = ModelCatalogReadEvents(requestID: requestID,
                target: String(repeating: "r", count: rawPadding + delta), key: "",
                budget: eventBudget, write: output.write)
            try events.start(); try events.complete(base)
            XCTAssertEqual(try XCTUnwrap(output.lineSizes().last), ModelCatalogReadOutput.rawLineLimit + delta)
        }
        let oversizedOutput = CapturedOutput(), oversizedBudget = ModelCatalogReadBudget(mode: .verify)
        let oversizedEvents = ModelCatalogReadEvents(requestID: requestID,
            target: String(repeating: "r", count: rawPadding + 1), key: "",
            budget: oversizedBudget, write: oversizedOutput.write)
        try oversizedEvents.start()
        XCTAssertThrowsError(try oversizedEvents.complete(base))
        XCTAssertEqual(try oversizedOutput.records().map { $0["kind"] as? String }, ["accepted"])

        let recoveries = (0..<1_024).map { offset in
            ModelCatalogEconomicsWire.Recovery(targetModelID: "fixture/model/\(offset)", modelKey: "fixture-\(offset)",
                action: .init(available: true, requiresConfirmation: true, transactionKind: "cleanup_staging",
                    transactionID: String(format: "00000000-0000-4000-8000-%012d", offset),
                    actionTimeoutSeconds: 1_800, estimatedBytes: nil, unavailableReason: nil,
                    operationGeneration: String(format: "10000000-0000-4000-8000-%012d", offset)))
        }
        let highCardinality = projection(recoveries: recoveries)
        let high = try ModelCatalogReadOutput.preflight(highCardinality, requestID: requestID,
            targetModelID: "fixture/model", modelKey: "fixture", budget: ModelCatalogReadBudget(mode: .verify))
        XCTAssertLessThanOrEqual(high.completedLineBytes, ceiling)
    }

    func testCC09FinalGrowthFailsBeforeWriteAndPostWriteExpiryCannotAddTerminal() throws {
        let base = projection()
        let envelope = try ModelCatalogReadOutput.preflight(base, requestID: requestID,
            targetModelID: "fixture/model", modelKey: "fixture", budget: ModelCatalogReadBudget(mode: .verify))
        let output = CapturedOutput()
        let events = ModelCatalogReadEvents(requestID: requestID, target: "fixture/model", key: "fixture",
            budget: ModelCatalogReadBudget(mode: .verify), write: output.write)
        try events.start()
        XCTAssertThrowsError(try events.complete(projection(warnings: [String(repeating: "g", count: 4_096)]),
                                                 maximumLineBytes: envelope.maximumFinalLineBytes))
        XCTAssertEqual(try output.records().map { $0["kind"] as? String }, ["accepted"])

        var now: UInt64 = 0
        let expiringBudget = ModelCatalogReadBudget(mode: .quick, clock: { now })
        let expiringOutput = CapturedOutput()
        let expiringEvents = ModelCatalogReadEvents(requestID: requestID, target: "fixture/model", key: "fixture",
            budget: expiringBudget, write: { data in
                expiringOutput.write(data)
                if data.range(of: Data(#""kind":"completed""#.utf8)) != nil { now += 11_000_000_000 }
            })
        try expiringEvents.start()
        XCTAssertThrowsError(try expiringEvents.complete(base)) {
            XCTAssertEqual($0 as? ModelCatalogReadError, .verificationIncomplete)
        }
        expiringEvents.fail(.readLimitExceeded)
        XCTAssertEqual(try expiringOutput.records().map { $0["kind"] as? String }, ["accepted", "completed"])
    }

    private let requestID = "a3838c05-ed4e-46b5-8052-af1f94bf68ae"

    private func projection(warnings: [String] = [], recoveries: [ModelCatalogEconomicsWire.Recovery] = [])
        -> ModelCatalogEconomicsWire {
        ModelCatalogEconomicsWire(generatedAt: "2026-09-10T00:00:00Z", projectionSequence: 0,
            source: .init(cliVersion: "fixture", cliBuildCommit: "fixture", processLaunchID: requestID,
                processStartedAt: "2026-09-10T00:00:00Z", projectionProtocolVersion: "2",
                rateCardSource: "fixture", rateCardDigest: nil, rateCardSignatureDigest: nil,
                demandFeedDigest: nil, candidateFeedDigest: nil, rateCardMaxAgeSeconds: 1,
                transactionContextSHA256: String(repeating: "a", count: 64)),
            rows: [], warnings: warnings, recoveries: recoveries)
    }

    private final class CapturedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        private var timestamps: [UInt64] = []
        func write(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            lines.append(data); timestamps.append(DispatchTime.now().uptimeNanoseconds)
        }
        func records() throws -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        }
        func gaps() -> [Double] {
            lock.lock(); defer { lock.unlock() }
            return zip(timestamps.dropFirst(), timestamps).map { Double($0.0 - $0.1) / 1_000_000_000 }
        }
        func lineSizes() -> [Int] {
            lock.lock(); defer { lock.unlock() }; return lines.map(\.count)
        }
    }
}
