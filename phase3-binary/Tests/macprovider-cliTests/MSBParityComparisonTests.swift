import XCTest
import ArgumentParser
@testable import macprovider_cli

final class MSBParityComparisonTests: XCTestCase {
    func testOptionalMLXCacheLimitParsing() throws {
        XCTAssertNil(try MSBThroughputCommand.parse([]).mlxCacheLimitMB)
        XCTAssertEqual(try MSBThroughputCommand.parse(["--mlx-cache-limit-mb", "256"]).mlxCacheLimitMB, 256)
        XCTAssertThrowsError(try MSBThroughputCommand.parse([
            "--mlx-cache-limit-mb", "999999999999999999999999999999"
        ]))
    }

    func testInvalidMLXCacheLimitsFailBeforeModelLoading() async throws {
        for value in [-1, ModelRuntime.maximumMLXCacheLimitMB + 1, Int.max] {
            let command = try MSBThroughputCommand.parse([
                "--model", "/nonexistent-msb-cache-limit-fixture",
                "--mlx-cache-limit-mb=\(value)"
            ])
            do {
                try await command.run()
                XCTFail("invalid cache limit was accepted")
            } catch {
                XCTAssertTrue(error is ValidationError, "expected cache validation before loading: \(error)")
                XCTAssertTrue(String(describing: error).contains("--mlx-cache-limit-mb"))
            }
        }
    }

    func testQualificationDefaultsToProductionUncompiledDecode() throws {
        XCTAssertFalse(try MSBThroughputCommand.parse([]).compile)
        XCTAssertFalse(try MSBThroughputCommand.parse(["--no-compile"]).compile)
        XCTAssertTrue(try MSBThroughputCommand.parse(["--compile"]).compile)
    }

    func testArchivedParityWithoutPerRowProofRemainsReadable() throws {
        let json = #"{"comparedTokens":32,"oneRowMatch":true,"batchedRowMatches":[true,true],"serialTokenSHA256":"a","batchedTokenSHA256":"a","pass":true}"#
        let report = try JSONDecoder().decode(MSBParityEvidence.self, from: Data(json.utf8))
        XCTAssertNil(report.rows)
    }

    func testPerRowProofPreservesActualLengthsAndHashes() throws {
        let row = MSBParityRowEvidence(
            serialTokenCount: 32, standaloneTokenCount: 31, batchedTokenCount: 32,
            serialTokenSHA256: "serial", standaloneTokenSHA256: "standalone", batchedTokenSHA256: "batch"
        )
        let report = MSBParityEvidence(
            comparedTokens: 32, oneRowMatch: false, standaloneRowMatches: [false],
            batchedRowMatches: [true], firstDivergenceIndex: 31,
            serialTokenSHA256: "serial", batchedTokenSHA256: "standalone", rows: [row], pass: false
        )
        let decoded = try JSONDecoder().decode(MSBParityEvidence.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.rows?.first?.standaloneTokenCount, 31)
    }

    func testRequestedWindowMustBePositive() {
        for count in [Int.min, -1, 0] {
            let result = msbTemp0ParityMatch(serial: [1], batched: [1], comparedTokens: count)
            XCTAssertFalse(result.match)
            XCTAssertEqual(result.firstDivergence, 0)
        }
    }

    func testEmptyOrTruncatedSequencesCannotProveTheRequestedWindow() {
        let fixtures: [([Int], [Int], Int)] = [
            ([], [], 0), ([], [1, 2, 3], 0), ([1, 2, 3], [], 0),
            ([1], [1, 2, 3], 1), ([1, 2, 3], [1], 1),
            ([1, 2], [1, 2], 2), ([1, 2], [1, 2, 3, 4], 2),
        ]
        for (serial, batched, missingIndex) in fixtures {
            let result = msbTemp0ParityMatch(serial: serial, batched: batched, comparedTokens: 3)
            XCTAssertFalse(result.match)
            XCTAssertEqual(result.firstDivergence, missingIndex)
        }
    }

    func testLongerSequencesCompareOnlyTheCompleteRequestedPrefix() {
        for (serial, batched) in [([1, 2], [1, 2, 3]), ([1, 2, 4], [1, 2]), ([1, 2, 4], [1, 2, 9])] {
            let result = msbTemp0ParityMatch(serial: serial, batched: batched, comparedTokens: 2)
            XCTAssertTrue(result.match)
            XCTAssertNil(result.firstDivergence)
        }
    }

    func testMismatchPrecedesAnyLaterMissingToken() {
        for (serial, batched) in [([1, 9], [1, 2, 3]), ([1, 2, 3], [1, 9]), ([1, 9, 3], [1, 2, 3])] {
            let result = msbTemp0ParityMatch(serial: serial, batched: batched, comparedTokens: 3)
            XCTAssertFalse(result.match)
            XCTAssertEqual(result.firstDivergence, 1)
        }
    }
}
