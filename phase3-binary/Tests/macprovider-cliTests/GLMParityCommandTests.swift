import XCTest
@testable import macprovider_cli

#if DEBUG || MACPROVIDER_LAB_HARNESS

final class GLMParityCommandTests: XCTestCase {
    /// Security r1: `glm-parity` is a lab harness. It is registered only
    /// through `labSubcommands()` and its source compiles only under
    /// DEBUG / MACPROVIDER_LAB_HARNESS, so a plain release binary has neither
    /// the command nor its registration.
    func testParityCommandIsLabOnly() throws {
        let names = MacProviderCLI.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertEqual(names.filter { $0 == "glm-parity" }.count, 1)
        XCTAssertFalse(GLMParityCommand.configuration.shouldDisplay)

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/macprovider-cli")
        let cli = try String(contentsOf: sources.appendingPathComponent("MacProviderCLI.swift"), encoding: .utf8)
        let labGate = try XCTUnwrap(cli.range(of: "private static func labSubcommands()"))
        let labBody = cli[labGate.lowerBound...]
        let labEnd = try XCTUnwrap(labBody.range(of: "#else"))
        XCTAssertEqual(cli.components(separatedBy: "GLMParityCommand.self").count - 1, 1)
        XCTAssertTrue(labBody[..<labEnd.lowerBound].contains("#if DEBUG || MACPROVIDER_LAB_HARNESS"))
        XCTAssertTrue(labBody[..<labEnd.lowerBound].contains("GLMParityCommand.self"))

        let command = try String(contentsOf: sources.appendingPathComponent("GLMParityCommand.swift"), encoding: .utf8)
        let gate = try XCTUnwrap(command.range(of: "#if DEBUG || MACPROVIDER_LAB_HARNESS"))
        let declaration = try XCTUnwrap(command.range(of: "struct GLMParityCommand"))
        XCTAssertLessThan(gate.lowerBound, declaration.lowerBound)
        XCTAssertTrue(command.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
    }

    func testComparisonReportsFirstDivergenceTop1AndLogitError() {
        let comparison = GLMParityComparison(
            oracleGreedy: [5, 6, 7, 8],
            oracleTopIdx: [[5, 1], [6, 2], [7, 3]],
            oracleTopLogit: [[10, 9], [8, 7], [6, 5]],
            tokens: [5, 6, 9, 8],
            argmaxTokens: [5, 6, 9, 8],
            gatheredLogits: [[10, 9], [8.25, 7], [5.5, 5.75]]
        )
        XCTAssertEqual(comparison.comparedTokens, 4)
        XCTAssertEqual(comparison.firstDivergence, 2)
        XCTAssertEqual(comparison.matchingTokens, 3)
        XCTAssertEqual(comparison.top1Compared, 3)
        XCTAssertEqual(comparison.top1Agreement, 2)
        XCTAssertEqual(comparison.maxAbsLogitDiffPerStep, [0, 0.25, 0.75])
        XCTAssertEqual(comparison.maxAbsLogitDiff, 0.75)
    }

    func testExactRunHasNoDivergenceAndComparesOnlyDecodedTokens() {
        let comparison = GLMParityComparison(
            oracleGreedy: [1, 2, 3],
            oracleTopIdx: [[1]],
            oracleTopLogit: [[4]],
            tokens: [1, 2],
            argmaxTokens: [1, 2],
            gatheredLogits: [[4]]
        )
        XCTAssertNil(comparison.firstDivergence)
        XCTAssertEqual(comparison.comparedTokens, 2)
        XCTAssertEqual(comparison.matchingTokens, 2)
        XCTAssertEqual(comparison.top1Agreement, 1)
        XCTAssertEqual(comparison.maxAbsLogitDiff, 0)
    }

    func testTopFiveDetectsUnseenCandidateDespiteMatchingArgmax() {
        let comparison = GLMParityComparison(
            oracleGreedy: [1], oracleTopIdx: [Array(1...16)],
            oracleTopLogit: [(0..<16).map { Float(16 - $0) }],
            tokens: [1], argmaxTokens: [1],
            gatheredLogits: [(0..<16).map { Float(16 - $0) }],
            candidateTopFive: [[1, 2, 3, 4, 99]]
        )
        XCTAssertEqual(comparison.top1Agreement, 1)
        XCTAssertEqual(comparison.maxAbsLogitDiff, 0)
        XCTAssertEqual(comparison.top5Compared, 1)
        XCTAssertEqual(comparison.top5Agreement, 0)
        XCTAssertEqual(comparison.top5MismatchSteps, [0])
        XCTAssertEqual(comparison.candidateTopFive, [[1, 2, 3, 4, 99]])
        XCTAssertEqual(comparison.oracleTopTwoGaps, [1])
    }

    func testTopFiveComparesSetsWithoutRequiringSameRankOrder() {
        let comparison = GLMParityComparison(
            oracleGreedy: [1], oracleTopIdx: [[1, 2, 3, 4, 5]],
            oracleTopLogit: [[5, 4, 3, 2, 1]],
            tokens: [1], argmaxTokens: [1], gatheredLogits: [[5, 4, 3, 2, 1]],
            candidateTopFive: [[1, 5, 4, 3, 2]]
        )
        XCTAssertEqual(comparison.top5Compared, 1)
        XCTAssertEqual(comparison.top5Agreement, 1)
        XCTAssertTrue(comparison.top5MismatchSteps.isEmpty)
    }

    func testOracleDecodesConverterJSONAndRejectsBadShapes() throws {
        func oracle(_ body: String) throws -> GLMParityOracle {
            try JSONDecoder().decode(GLMParityOracle.self, from: Data(body.utf8))
        }
        let valid = try oracle(#"""
        {"schema":"glm-parity-oracle-v1","source":"oracle_1024.npz","source_sha256":"ab",
         "prompt":[1,2],"greedy":[3,4],"top_idx":[[3,9]],"top_logit":[[1.5,0.25]]}
        """#)
        XCTAssertNoThrow(try valid.validate())
        XCTAssertEqual(valid.topLogit, [[1.5, 0.25]])

        for bad in [
            #"{"schema":"other","source":"s","source_sha256":"x","prompt":[1],"greedy":[1],"top_idx":[],"top_logit":[]}"#,
            #"{"schema":"glm-parity-oracle-v1","source":"s","source_sha256":"x","prompt":[],"greedy":[1],"top_idx":[],"top_logit":[]}"#,
            #"{"schema":"glm-parity-oracle-v1","source":"s","source_sha256":"x","prompt":[1],"greedy":[1],"top_idx":[[1,2]],"top_logit":[[1]]}"#,
            #"{"schema":"glm-parity-oracle-v1","source":"s","source_sha256":"x","prompt":[1],"greedy":[1],"top_idx":[[1],[1]],"top_logit":[[1],[1]]}"#,
            #"{"schema":"glm-parity-oracle-v1","source":"s","source_sha256":"x","prompt":[-1],"greedy":[1],"top_idx":[],"top_logit":[]}"#,
        ] {
            XCTAssertThrowsError(try oracle(bad).validate(), bad)
        }
    }
}
#endif
