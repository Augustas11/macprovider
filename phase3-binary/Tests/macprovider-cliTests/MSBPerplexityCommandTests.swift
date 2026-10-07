import XCTest
@testable import macprovider_cli

final class MSBPerplexityCommandTests: XCTestCase {
    func testTokenPolicyWithoutBOSLeavesCorpusAndChunksUnchanged() {
        let base = [10, 11, 12, 13, 14, 15, 16, 17, 18]
        let corpus = MSBPerplexityTokenPolicy.corpusTokens(baseTokens: base, bosToken: nil)
        let chunks = MSBPerplexityTokenPolicy.evaluatedChunks(
            corpusTokens: corpus,
            ctx: 4,
            chunks: 2,
            bosToken: nil
        )

        XCTAssertEqual(corpus, base)
        XCTAssertEqual(chunks, [
            [10, 11, 12, 13],
            [14, 15, 16, 17],
        ])
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.scoredTargetTokens(chunks: chunks, firstScoredOffset: 2),
            [13, 17]
        )
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.tokenizationMode(bosToken: nil),
            "native_encode_addSpecialTokens_false_no_manual_bos_no_auto_eos"
        )
    }

    func testTokenPolicyWithBOSPrependsOnceAndReplacesChunkStarts() {
        let corpus = MSBPerplexityTokenPolicy.corpusTokens(baseTokens: [1, 2, 3, 4, 5, 6, 7, 8], bosToken: 0)
        let chunks = MSBPerplexityTokenPolicy.evaluatedChunks(
            corpusTokens: corpus,
            ctx: 4,
            chunks: 2,
            bosToken: 0
        )

        XCTAssertEqual(corpus, [0, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(chunks, [
            [0, 1, 2, 3],
            [0, 5, 6, 7],
        ])
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.scoredTargetTokens(chunks: chunks, firstScoredOffset: 2),
            [3, 7]
        )
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.tokenizationMode(bosToken: 0),
            "native_encode_addSpecialTokens_false_manual_bos_no_auto_eos"
        )
    }

    func testTokenPolicyChunkBoundsAndBOSValidation() {
        XCTAssertTrue(MSBPerplexityTokenPolicy.validBOSToken(nil))
        XCTAssertTrue(MSBPerplexityTokenPolicy.validBOSToken(0))
        XCTAssertTrue(MSBPerplexityTokenPolicy.validBOSToken(Int(Int32.max)))
        XCTAssertFalse(MSBPerplexityTokenPolicy.validBOSToken(-1))
        XCTAssertFalse(MSBPerplexityTokenPolicy.validBOSToken(Int(Int32.max) + 1))

        let chunks = MSBPerplexityTokenPolicy.evaluatedChunks(
            corpusTokens: [1, 2, 3, 4, 5, 6, 7],
            ctx: 3,
            chunks: 2,
            bosToken: 99
        )
        XCTAssertEqual(chunks, [
            [99, 2, 3],
            [99, 5, 6],
        ])
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.scoredTargetTokens(chunks: chunks, firstScoredOffset: 1),
            [3, 6]
        )
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.evaluatedChunks(corpusTokens: [1, 2, 3], ctx: 0, chunks: 1, bosToken: nil),
            []
        )
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.evaluatedChunks(corpusTokens: [1, 2, 3], ctx: 3, chunks: 0, bosToken: nil),
            []
        )
        XCTAssertEqual(
            MSBPerplexityTokenPolicy.evaluatedChunks(corpusTokens: [1, 2, 3, 4], ctx: 3, chunks: 4, bosToken: nil),
            [[1, 2, 3]]
        )
    }

    func testReportDecodesHistoricalArtifactsMissingOptionalPolicyFields() throws {
        let report = MSBPerplexityReport(
            schemaVersion: 1,
            modelID: "model",
            mlxSwiftLMPin: "pin",
            textFile: "wiki.test.raw",
            textTokens: 8,
            ctx: 4,
            chunks: 2,
            scoredTokens: 2,
            perplexity: 10,
            meanNLL: 2.3,
            elapsedSeconds: 1,
            peakPhysFootprintMB: nil,
            timestamp: "2026-10-07T00:00:00Z",
            tokenizationMode: MSBPerplexityTokenPolicy.tokenizationMode(bosToken: 0),
            bosToken: 0,
            firstScoredOffset: 2,
            corpusTokenSHA256: msbPromptTokenSHA256([0, 1, 2, 3]),
            evaluatedChunkTokenSHA256: msbPromptTokenSHA256([0, 1, 2, 3]),
            scoredTargetTokenSHA256: msbPromptTokenSHA256([3])
        )
        let data = try Self.removingOptionalPolicyFields(from: JSONEncoder().encode(report))
        let decoded = try JSONDecoder().decode(MSBPerplexityReport.self, from: data)

        XCTAssertNil(decoded.tokenizationMode)
        XCTAssertNil(decoded.bosToken)
        XCTAssertNil(decoded.firstScoredOffset)
        XCTAssertNil(decoded.corpusTokenSHA256)
        XCTAssertNil(decoded.evaluatedChunkTokenSHA256)
        XCTAssertNil(decoded.scoredTargetTokenSHA256)
    }

    private static func removingOptionalPolicyFields(from data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in [
            "tokenizationMode",
            "bosToken",
            "firstScoredOffset",
            "corpusTokenSHA256",
            "evaluatedChunkTokenSHA256",
            "scoredTargetTokenSHA256",
        ] {
            object.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
