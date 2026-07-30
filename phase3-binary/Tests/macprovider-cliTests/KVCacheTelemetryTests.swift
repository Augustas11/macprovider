import Foundation
@testable import macprovider_cli
import XCTest

final class KVCacheTelemetryTests: XCTestCase {
    func testRequestCompletedPayloadIncludesReuseFields() throws {
        let completion = CompletionResult(
            content: "ok",
            finishReason: "stop",
            promptTokens: 10,
            cachedPromptTokens: 4,
            kvCacheBytesReused: 128,
            completionTokens: 2
        )

        let payload = try KVCacheTelemetry.requestCompletedPayload(
            providerID: "provider-a",
            requestID: "req-1",
            modelID: "model-a",
            stream: true,
            completion: completion
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(object["event"] as? String, "kv_cache_request_completed")
        XCTAssertEqual(object["provider_id"] as? String, "provider-a")
        XCTAssertEqual(object["request_id"] as? String, "req-1")
        XCTAssertEqual(object["model_id"] as? String, "model-a")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["prompt_tokens"] as? Int, 10)
        XCTAssertEqual(object["cached_prompt_tokens"] as? Int, 4)
        XCTAssertEqual(object["completion_tokens"] as? Int, 2)
        XCTAssertEqual(object["kv_cache_bytes_reused"] as? Int, 128)
        XCTAssertEqual(try XCTUnwrap(object["kv_cache_reuse_ratio"] as? Double), 0.4, accuracy: 0.000_001)
    }

    func testEmitRequestCompletedWritesNewlineDelimitedJSON() async throws {
        let completion = CompletionResult(
            content: "ok",
            finishReason: "stop",
            promptTokens: 8,
            cachedPromptTokens: 2,
            kvCacheBytesReused: 64,
            completionTokens: 1
        )
        let capture = KVCacheTelemetryCapture()

        await KVCacheTelemetry.withSink({ capture.append($0) }) {
            KVCacheTelemetry.emitRequestCompleted(
                providerID: nil,
                requestID: "req-2",
                modelID: "model-b",
                stream: false,
                completion: completion
            )
        }

        let record = try XCTUnwrap(capture.records.single)
        XCTAssertTrue(String(decoding: record, as: UTF8.self).hasSuffix("\n"))
        let trimmed = record.dropLast()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(trimmed)) as? [String: Any])
        XCTAssertEqual(object["provider_id"] as? String, "")
        XCTAssertEqual(object["kv_cache_reuse_ratio"] as? Double, 0.25)
    }
}

private final class KVCacheTelemetryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Data] = []

    var records: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func append(_ record: Data) {
        lock.lock()
        captured.append(record)
        lock.unlock()
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
