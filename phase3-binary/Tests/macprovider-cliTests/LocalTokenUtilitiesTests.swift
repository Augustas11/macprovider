import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class LocalTokenUtilitiesTests: XCTestCase {
    func testTokenizePreservesEmptyAndUnicodeText() throws {
        for text in ["", "🦀 café\n"] {
            let request = try parse(["model": "model", "text": text], .tokenize)
            XCTAssertEqual(request.text, text)
            XCTAssertEqual(try request.admissionRequest().model, "model")
        }
    }

    func testRejectsUnknownFieldsAndDuplicateKeys() throws {
        XCTAssertThrowsError(try parse(["model": "m", "text": "x", "add_special_tokens": true], .tokenize))
        XCTAssertThrowsError(try LocalTokenUtilityRequest.parse(
            data: Data(#"{"model":"m","text":"a","text":"b"}"#.utf8), operation: .tokenize))
    }

    func testRejectsInvalidAndOversizedTokenIDs() throws {
        for tokens: [Any] in [[true], [-1], [1.5], [Int64(Int32.max) + 1], ["1"], [NSNull()]] {
            XCTAssertThrowsError(try parse(["model": "m", "tokens": tokens], .detokenize))
        }
        XCTAssertThrowsError(try parse(["model": "m", "tokens": Array(repeating: 0, count: LocalTokenUtilityRequest.tokenLimit + 1)], .detokenize))
        XCTAssertEqual(try parse(["model": "m", "tokens": [0, 1, 100]], .detokenize).tokens, [0, 1, 100])
    }

    func testTemplateRejectsNonTextToolsAndUnboundedMessages() throws {
        for messages: Any in [
            [["role": "tool", "content": "x"]],
            [["role": "user", "content": "x", "extra": "x"]],
            [["role": "user", "content": [["type": "image_url"]]]],
            [],
            Array(repeating: ["role": "user", "content": "x"], count: 129)
        ] {
            XCTAssertThrowsError(try parse(["model": "m", "messages": messages], .applyTemplate))
        }
        XCTAssertEqual(try parse(["model": "m", "messages": [["role": "user", "content": "hi"]]], .applyTemplate).messages?.count, 1)
    }

    func testBodyBound() throws {
        XCTAssertThrowsError(try parse(["model": "m", "text": String(repeating: "x", count: LocalTokenUtilityRequest.bodyByteLimit)], .tokenize))
    }

    func testResultCarriesGenerationAndModelIdentity() throws {
        let result = LocalTokenUtilityResult(model: "loaded-model", modelHash: "hash", generation: 7, tokens: [1], text: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(object["model_hash"] as? String, "hash")
        XCTAssertEqual(object["generation"] as? Int, 7)
        XCTAssertEqual(object["tokens"] as? [Int], [1])
        XCTAssertNil(object["text"])
    }

    func testQueuedSessionKeepsOriginalGenerationAfterSwap() async throws {
        let gate = AsyncSemaphore(value: 0)
        var current = LocalTokenUtilitySession(model: "old", modelHash: "old-hash", generation: 1, gate: gate)
        let admitted = current
        let work = Task { try await admitted.perform { ([11], "old tokenizer") } }
        current = LocalTokenUtilitySession(model: "new", modelHash: "new-hash", generation: 2, gate: gate)
        await gate.resize(to: 1)
        let result = try await work.value
        XCTAssertEqual(result.model, "old")
        XCTAssertEqual(result.modelHash, "old-hash")
        XCTAssertEqual(result.generation, 1)
        XCTAssertEqual(result.tokens, [11])
        let next = try await current.perform { ([22], "new tokenizer") }
        XCTAssertEqual(next.model, "new")
        XCTAssertEqual(next.generation, 2)
        XCTAssertEqual(next.tokens, [22])
    }

    func testCancelledQueuedUtilityReleasesWithoutPermit() async throws {
        let gate = AsyncSemaphore(value: 0)
        let session = LocalTokenUtilitySession(model: "m", modelHash: nil, generation: 1, gate: gate)
        let started = expectation(description: "queued task started")
        let stopped = expectation(description: "cancelled without permit")
        let work = Task {
            started.fulfill()
            do {
                _ = try await session.perform {
                    XCTFail("Cancelled queued utility must not run tokenizer")
                    return (nil, nil)
                }
                XCTFail("Cancelled queued utility must throw")
            } catch is CancellationError {
                // Cancellation must release even though no permit is available.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            stopped.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        work.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        // A cancelled waiter must not steal the next shared inference permit.
        await gate.resize(to: 1)
        let result = try await session.perform { ([42], nil) }
        XCTAssertEqual(result.tokens, [42])
    }

    private func parse(_ body: [String: Any], _ operation: LocalTokenUtilityOperation) throws -> LocalTokenUtilityRequest {
        try LocalTokenUtilityRequest.parse(data: JSONSerialization.data(withJSONObject: body), operation: operation)
    }
}
