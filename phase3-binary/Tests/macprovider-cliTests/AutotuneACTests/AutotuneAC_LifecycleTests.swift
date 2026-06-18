import Darwin
import ArgumentParser
import Foundation
import XCTest
@testable import macprovider_cli

final class AutotuneACLifecycleTests: XCTestCase {
    /// AC-10: Interrupt cleanup leaves the port free and future runs can open the DB; SPEC-013 lines 1485-1492.
    func testAC10CtrlCCleanup() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let port = try unusedPort()
        let interrupted = try fixture.command(["--port", "\(port)"])
        var deps = fixture.dependencies()
        deps.runStage1 = { _ in
            throw Stage1IteratorError.interrupted
        }

        let exit = try await fixture.assertExit { try await interrupted.run(dependencies: deps) }

        XCTAssertEqual(exit, ExitCode(130))
        XCTAssertTrue(isPortFree(port), "candidate port must be free after interrupt")
        let firstRun = try fixture.latestRunRow()
        XCTAssertEqual(firstRun.exitReason, "interrupted")
        XCTAssertNil(firstRun.endedAtUTC)

        let fresh = try fixture.command(["--port", "\(port)"])
        var freshDeps = fixture.dependencies()
        freshDeps.runStage1 = { request in
            let row = fixture.trial(runID: request.runID, stage: 1, model: request.candidates[0], fits: true, aggTPS: 8, ttft: 700)
            try request.db.insertTrial(row)
            return Stage1IteratorResult(selectedModel: request.candidates[0], trials: [row], exitReason: .ok)
        }

        try await fresh.run(dependencies: freshDeps)

        let rows = try fixture.runRows()
        XCTAssertEqual(rows.map(\.exitReason), ["interrupted", "ok"])
        XCTAssertTrue(isPortFree(port), "fresh run must not leave an orphan provider on the candidate port")
    }

    /// AC-13: Budget exhaustion during Stage 1 exits without a recommendation; SPEC-013 lines 1527-1535.
    func testAC13WallClockBudgetEnforcementMidStage1() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--json", "--max-duration", "60"])
        var deps = fixture.dependencies()
        deps.runStage1 = { _ in
            throw Stage1IteratorError.budgetExhaustedNoModelSelected
        }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.latestRunRow()
        XCTAssertEqual(row.exitReason, "budget_exhausted_no_model_selected")
        XCTAssertNil(row.recommendationJSON)
        let emitted = try fixture.emittedJSONFromStdout()
        XCTAssertTrue(emitted["recommendation"] is NSNull)
    }

    /// AC-13: Budget exhaustion during Stage 2 emits a partial recommendation; SPEC-013 lines 1527-1535.
    func testAC13WallClockBudgetEnforcementMidStage2() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--json", "--max-duration", "60"])
        var deps = fixture.dependencies()
        deps.runStage2 = { request in
            let partialRow = fixture.trial(
                runID: request.runID,
                stage: 2,
                model: request.selectedModel,
                fits: true,
                aggTPS: 10,
                ttft: 900,
                kvBits: 4,
                maxContext: request.targetContext,
                maxBatch: 1,
                kept: true
            )
            try request.db.insertTrial(partialRow)
            let partial = Stage2HillClimbResult(
                selectedModel: request.selectedModel,
                winningKnobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: request.targetContext),
                medianTPS: 10,
                p95TTFTMS: 900,
                replicates: request.stage2Replicates,
                cellTrials: [partialRow]
            )
            throw Stage2HillClimbError.budgetExhaustedWithPartialRecommendation(partial)
        }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.latestRunRow()
        XCTAssertEqual(row.exitReason, "budget_exhausted_with_partial_recommendation")
        XCTAssertNotNil(row.recipeHash)
        let json = try fixture.latestRecommendationJSON()
        XCTAssertEqual(json.recommendationModel, AutotuneCommand.defaultCandidates[0].modelID)
        XCTAssertEqual(json.recommendation?["partial"] as? Bool, true)
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

    private func isPortFree(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        if socketFD < 0 {
            return false
        }
        defer { close(socketFD) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var bindAddr = addr
        let result = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
