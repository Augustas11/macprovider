import XCTest
@testable import MacProviderCore

final class ComputeScoreProtocolTests: XCTestCase {
    private func request(_ overrides: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
        var raw: [String: Any] = [
            "type": "compute_score_request_v1",
            "version": 1,
            "score_id": "score-1",
            "provider_id": "provider-a",
            "assigned_id": "assigned-a",
            "model_id": "model-a",
            "weights_manifest_sha256": String(repeating: "c", count: 64),
            "body": #"{"model":"model-a","messages":[{"role":"user","content":"hi"}]}"#,
            "output_text": "hello",
            "reasoning_text": "",
            "issued_at": "2026-10-13T00:00:00.123456Z",
            "expires_at": "2026-10-13T00:01:00Z",
        ]
        for key in removing { raw.removeValue(forKey: key) }
        for (key, value) in overrides { raw[key] = value }
        return raw
    }

    func testDecodesValidRequest() throws {
        let decoded = try ComputeScoreProtocol.decodeRequest(request())
        XCTAssertEqual(decoded.scoreID, "score-1")
        XCTAssertEqual(decoded.modelID, "model-a")
        XCTAssertEqual(decoded.scoredText, "hello")
        XCTAssertLessThan(decoded.issuedAt, decoded.expiresAt)
    }

    func testReasoningIsWrappedInThinkDelimiters() throws {
        let decoded = try ComputeScoreProtocol.decodeRequest(request(["reasoning_text": "plan"]))
        XCTAssertEqual(decoded.scoredText, "<think>\nplan\n</think>\n\nhello")
        let absent = try ComputeScoreProtocol.decodeRequest(request(removing: ["reasoning_text"]))
        XCTAssertEqual(absent.scoredText, "hello")
    }

    func testRejectsUnknownFieldsAndMalformedIdentity() {
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["usage": 1])))
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["version": 2])))
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["weights_manifest_sha256": "ABC"])))
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["score_id": "has space"])))
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["expires_at": "2026-10-12T00:00:00Z"])))
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["output_text": ""])))
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(removing: ["body"])))
    }

    func testOverBoundInputIsTooLongNotInvalid() {
        let big = String(repeating: "x", count: ComputeScoreProtocol.maxOutputBytes + 1)
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["output_text": big]))) { error in
            XCTAssertEqual(error as? ComputeScoreProtocol.DecodeError, .tooLong("output"))
        }
        let body = String(repeating: "y", count: ComputeScoreProtocol.maxBodyBytes + 1)
        XCTAssertThrowsError(try ComputeScoreProtocol.decodeRequest(request(["body": body]))) { error in
            XCTAssertEqual(error as? ComputeScoreProtocol.DecodeError, .tooLong("body"))
        }
        XCTAssertNotNil(ComputeScoreProtocol.echoRequest(request(["output_text": big])))
    }

    func testAggregateAndResultClamping() throws {
        let agg = ComputeScoreProtocol.aggregate(logprobs: [-0.5, -1.5, 0], top1: [true, false, true])
        XCTAssertEqual(agg.scored, 3)
        XCTAssertEqual(agg.matches, 2)
        XCTAssertEqual(agg.sum, -2.0, accuracy: 1e-12)

        let decoded = try ComputeScoreProtocol.decodeRequest(request())
        let ok = ComputeScoreProtocol.Result(request: decoded, status: .ok, promptTokens: 4, scoredTokens: 3, top1Matches: 9, sumLogprob: 2)
        XCTAssertEqual(ok.top1Matches, 3)
        XCTAssertEqual(ok.sumLogprob, 0)
        let wire = ok.wireObject
        XCTAssertEqual(wire["type"] as? String, "compute_score_result_v1")
        XCTAssertEqual(Set(wire.keys), [
            "type", "version", "score_id", "provider_id", "assigned_id", "model_id",
            "weights_manifest_sha256", "status", "prompt_tokens", "scored_tokens",
            "top1_matches", "sum_logprob",
        ])

        let unavailable = ComputeScoreProtocol.Result(request: decoded, status: .unavailable, scoredTokens: 5, top1Matches: 5, sumLogprob: -1)
        XCTAssertEqual(unavailable.scoredTokens, 0)
        XCTAssertEqual(unavailable.top1Matches, 0)
        XCTAssertEqual(unavailable.sumLogprob, 0)
        let nonFinite = ComputeScoreProtocol.Result(request: decoded, status: .ok, scoredTokens: 2, sumLogprob: -.infinity)
        XCTAssertEqual(nonFinite.sumLogprob, -200)
        let impossible = ComputeScoreProtocol.aggregate(logprobs: [-.infinity, .nan, -500], top1: [false, false, false])
        XCTAssertEqual(impossible.sum, -300, accuracy: 1e-12)
    }
}
