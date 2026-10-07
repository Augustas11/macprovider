#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPRequestShapeReplayCommandTests: XCTestCase {
    func testCaptureRejectsRawPromptAndRecoverableCacheKeys() throws {
        let rawPrompt = try writeCapture([
            shape("raw", extra: ["prompt": "buyer text"]),
        ])
        XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: rawPrompt)) { error in
            XCTAssertTrue("\(error)".contains("raw_or_recoverable_field"), "\(error)")
        }

        let rawCache = try writeCapture([
            shape("cache", extra: ["cache_group": "recoverable"]),
        ])
        XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: rawCache)) { error in
            XCTAssertTrue("\(error)".contains("raw_or_recoverable_field"), "\(error)")
        }
    }

    func testCacheShapeWithoutAnonymousGroupIsPendingNotPassable() throws {
        let url = try writeCapture([
            shape(
                "cache-miss",
                conversationKey: true,
                cacheOnly: true,
                lease: "miss"
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.pendingReason, "cache_shape_missing_anonymous_group:cache-miss")
    }

    func testCacheHitNeedsWarmupProofBeforeReplayCanPass() throws {
        let url = try writeCapture([
            shape(
                "cache-hit",
                conversationKey: true,
                cacheOnly: true,
                lease: "hit",
                cachedTokens: 128,
                extra: ["anonymous_cache_group_sha256": String(repeating: "a", count: 64)]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.pendingReason, "cache_hit_replay_requires_runtime_warmup_proof:cache-hit")
    }

    func testPlanPadsToMixedEightRowsAndCounterbalancesTenBlocks() throws {
        let url = try writeCapture([
            shape("eligible-a"),
            shape("eligible-b"),
            shape("sticky", conversationKey: true, lease: "miss", extra: [
                "anonymous_cache_group_sha256": String(repeating: "b", count: 64),
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertEqual(plan.blocks.count, 10)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.rows.count == 8 })
        XCTAssertEqual(plan.blocks.filter(\.nativeFirst).count, 5)
        XCTAssertEqual(plan.blocks[3].rows[0].requestID, "mixed-b3-r0-eligible-a")
        XCTAssertEqual(Set(plan.blocks[0].rows.map(\.requestID)).count, 8)
    }

    func testSanitizedExportDoesNotCarryRawOrRecoverableFields() throws {
        let url = try writeCapture([
            shape("safe", conversationKey: true, lease: "miss", extra: [
                "anonymous_cache_group_sha256": String(repeating: "c", count: 64),
                "unknown_top_level_keys_present": true,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let exported = try XCTUnwrap(capture.shapes.first?.sanitizedExport)
        XCTAssertNil(exported["prompt"])
        XCTAssertNil(exported["messages"])
        XCTAssertNil(exported["conversation_key"])
        XCTAssertNil(exported["cache_group"])
        XCTAssertEqual(exported["anonymous_cache_group_sha256"] as? String, String(repeating: "c", count: 64))
        XCTAssertEqual(capture.shapes.first?.features["unknown_top_level_keys_present"] as? Bool, true)
    }

    private func writeCapture(_ shapes: [[String: Any]]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-replay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("capture.jsonl")
        var lines = [try json(header())]
        for shape in shapes {
            lines.append(try json(shape))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func header() -> [String: Any] {
        [
            "schema": NativeMTPRequestShapeCapture.schema,
            "record_type": "header",
            "captured_at": "2026-10-07T00:00:00Z",
            "native_mtp_mode": "off",
            "capture_requires_native_mtp_off": true,
        ]
    }

    private func shape(
        _ id: String,
        conversationKey: Bool = false,
        cacheOnly: Bool = false,
        lease: String = "not_applicable",
        cachedTokens: Int = 0,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "schema": NativeMTPRequestShapeCapture.schema,
            "record_type": "request_shape",
            "sequence": 1,
            "shape_id": id,
            "captured_at": "2026-10-07T00:00:01Z",
            "served_model_hash_sha256": String(repeating: "d", count: 64),
            "served_weights_manifest_sha256": String(repeating: "e", count: 64),
            "native_mtp_tuple_sha256": String(repeating: "f", count: 64),
            "native_mtp_served_snapshot_id_sha256": String(repeating: "1", count: 64),
            "native_mtp_target_generation": 1,
            "stream": true,
            "stop_sequences": 0,
            "requested_temperature": 0.0,
            "requested_top_p": 1.0,
            "requested_n": 1,
            "requested_max_completion_tokens": 128,
            "resolved_max_completion_tokens": 128,
            "sampling_requested": false,
            "multiple_completions_requested": false,
            "top_k_present": false,
            "min_p_nonzero": false,
            "frequency_penalty_nonzero": false,
            "presence_penalty_nonzero": false,
            "repetition_penalty_nondefault": false,
            "logit_bias_present": false,
            "tools_present": false,
            "tool_choice_present": false,
            "tool_turn_state_present": false,
            "structured_output_requested": false,
            "response_format_kind": "text",
            "logprobs_requested": false,
            "top_logprobs_requested": false,
            "logit_controls_requested": false,
            "reasoning_or_template_model": false,
            "multimodal_requested": false,
            "unknown_request_fields_present": false,
            "unknown_top_level_keys_present": false,
            "unknown_stream_option_keys_present": false,
            "conversation_key_present": conversationKey,
            "conversation_key_cache_only": cacheOnly,
            "conversation_cache_lease": lease,
            "conversation_cache_cached_prompt_tokens": cachedTokens,
            "conversation_cache_retained_handoff": false,
            "prompt_tokens": 1536,
            "completion_tokens": 64,
            "generated_completion_tokens": 64,
            "max_completion_tokens_requested": 128,
            "pre_capacity_selector_reason": "mode_off",
            "pre_capacity_eligible": false,
            "effective_path": "ordinary",
        ]
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
