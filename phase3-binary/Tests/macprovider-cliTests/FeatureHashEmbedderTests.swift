import Foundation
import MacProviderCore
import NIOHTTP1
import XCTest
@testable import macprovider_cli

final class FeatureHashEmbedderTests: XCTestCase {
    func testHashIsDeterministicUnitAndSeparatesTopics() {
        let cat = FeatureHashEmbedder.embed("the cat sat on the mat")
        let hat = FeatureHashEmbedder.embed("the cat sat on the hat")
        let other = FeatureHashEmbedder.embed("quantum zirconium payroll")
        XCTAssertEqual(cat.count, FeatureHashEmbedder.dimension)
        XCTAssertEqual(cat, FeatureHashEmbedder.embed("the cat sat on the mat"))
        XCTAssertEqual(norm(cat), 1, accuracy: 1e-9)
        XCTAssertEqual(norm(hat), 1, accuracy: 1e-9)
        XCTAssertFalse(cat.contains { !$0.isFinite })
        XCTAssertGreaterThan(cosine(cat, hat), cosine(cat, other))
        let empty = FeatureHashEmbedder.embed("")
        XCTAssertEqual(empty, [Double](repeating: 0, count: FeatureHashEmbedder.dimension))
        XCTAssertEqual(FeatureHashEmbedder.embed("a"), empty)
        XCTAssertFalse(empty.contains { !$0.isFinite })
    }

    func testParseAcceptsAStringOrArrayAndEchoesAShortModel() throws {
        let one = try FeatureHashEmbedder.parse(Data("{\"input\":\"hello\"}".utf8))
        XCTAssertEqual(one.inputs, ["hello"])
        XCTAssertEqual(one.model, FeatureHashEmbedder.defaultModel)
        let many = try FeatureHashEmbedder.parse(JSONSerialization.data(withJSONObject: [
            "model": "demo",
            "input": ["alpha", "beta"],
        ]))
        XCTAssertEqual(many.inputs, ["alpha", "beta"])
        XCTAssertEqual(many.model, "demo")
        let blank = try FeatureHashEmbedder.parse(Data("{\"input\":\"\",\"model\":\"has\\nline\"}".utf8))
        XCTAssertEqual(blank.inputs, [""])
        XCTAssertEqual(blank.model, FeatureHashEmbedder.defaultModel)
        let response = FeatureHashEmbedder.response(for: many)
        XCTAssertEqual(response["object"] as? String, "list")
        XCTAssertEqual(response["model"] as? String, "demo")
        let rows = try XCTUnwrap(response["data"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["index"] as? Int }, [0, 1])
        XCTAssertEqual(rows.map { $0["object"] as? String }, ["embedding", "embedding"])
        XCTAssertEqual((rows[0]["embedding"] as? [Double])?.count, FeatureHashEmbedder.dimension)
        XCTAssertEqual((rows[1]["embedding"] as? [Double])?.count, FeatureHashEmbedder.dimension)
        let usage = try XCTUnwrap(response["usage"] as? [String: Int])
        XCTAssertEqual(usage["prompt_tokens"], usage["total_tokens"])
        XCTAssertGreaterThan(usage["prompt_tokens"] ?? 0, 0)
    }

    func testParseRejectsTheWrongShapeAndOversizeInput() throws {
        for body in ["[]", "null", "{\"input\":[]}", "{\"input\":[1]}", "{\"input\":true}", "{\"input\":null}",
                     "{\"input\":\"a\\u0000b\"}"] {
            XCTAssertThrowsError(try FeatureHashEmbedder.parse(Data(body.utf8))) { error in
                XCTAssertEqual(error as? FeatureHashFailure, .invalid, body)
            }
        }
        let tooMany = Array(repeating: "ab", count: FeatureHashEmbedder.maxInputs + 1)
        XCTAssertThrowsError(try FeatureHashEmbedder.parse(JSONSerialization.data(withJSONObject: ["input": tooMany]))) { error in
            XCTAssertEqual(error as? FeatureHashFailure, .limit)
        }
        let exact = String(repeating: "a", count: FeatureHashEmbedder.maxInputBytes)
        XCTAssertEqual(try FeatureHashEmbedder.parse(JSONSerialization.data(withJSONObject: ["input": exact])).inputs, [exact])
        let oversized = String(repeating: "b", count: FeatureHashEmbedder.maxInputBytes + 1)
        XCTAssertThrowsError(try FeatureHashEmbedder.parse(JSONSerialization.data(withJSONObject: ["input": oversized]))) { error in
            XCTAssertEqual(error as? FeatureHashFailure, .limit)
        }
        let full = Array(repeating: "ab", count: FeatureHashEmbedder.maxInputs)
        XCTAssertEqual(try FeatureHashEmbedder.parse(JSONSerialization.data(withJSONObject: ["input": full])).inputs.count,
                       FeatureHashEmbedder.maxInputs)
    }

    func testEmbeddingsAccessIsLoopbackLocalAppOnly() throws {
        let local = HTTPHeaders([("X-MacProvider-Origin", "local-app")])
        XCTAssertNoThrow(try RouterHandler.validateEmbeddingsAccess(headers: local, peerIsLoopback: true))
        let withPrivacy = HTTPHeaders([
            ("X-MacProvider-Origin", "local-app"),
            ("X-MacProvider-Privacy-Class", "private"),
        ])
        XCTAssertNoThrow(try RouterHandler.validateEmbeddingsAccess(headers: withPrivacy, peerIsLoopback: true))
        let refused = [
            HTTPHeaders(),
            HTTPHeaders([("X-MacProvider-Origin", "coordinator")]),
            HTTPHeaders([("X-MacProvider-Origin", "local-app"), ("X-MacProvider-Origin", "local-app")]),
            HTTPHeaders([("X-MacProvider-Origin", "local-app"), ("X-MacProvider-Settlement-Metadata", "invalid")]),
            local,
        ]
        for headers in refused.dropLast() {
            XCTAssertThrowsError(try RouterHandler.validateEmbeddingsAccess(headers: headers, peerIsLoopback: true)) { error in
                let api = error as? APIError
                XCTAssertEqual(api?.status, 403)
                XCTAssertEqual(api?.code, "embeddings_local_only")
                XCTAssertEqual(api?.message, "Embeddings are only available on this Mac.")
            }
        }
        XCTAssertThrowsError(try RouterHandler.validateEmbeddingsAccess(headers: local, peerIsLoopback: false)) { error in
            XCTAssertEqual((error as? APIError)?.code, "embeddings_local_only")
        }
    }

    private func cosine(_ left: [Double], _ right: [Double]) -> Double {
        let dot = zip(left, right).reduce(0.0) { $0 + $1.0 * $1.1 }
        return dot / (norm(left) * norm(right))
    }

    private func norm(_ vector: [Double]) -> Double {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}
