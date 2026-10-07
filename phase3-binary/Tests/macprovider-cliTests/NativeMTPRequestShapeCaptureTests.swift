import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class NativeMTPRequestShapeCaptureTests: XCTestCase {
    func testWritesSanitizedShapeAndStatusWithoutRawSecrets() throws {
        let root = try privateTempDirectory()
        let captureDir = root.appendingPathComponent("capture", isDirectory: true)
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: NativeMTPRequestShapeCaptureConfig(directory: captureDir, maxRecords: 10, maxBytes: 64 * 1024),
            nativeMTPMode: .off,
            runningBuildIdentity: nil,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let request = try makeRequest(maxTokens: nil, includeSensitiveValues: true)
            .withConversationKey("conv:secret-cache-key", cacheOnly: true)
            .withRequestID("secret-request-id")
        capture?.record(
            request: request,
            snapshot: snapshot(),
            admission: ordinaryModeOffAdmission(),
            lease: nil,
            leaseAllowed: true,
            completion: completion(promptTokens: 37, completionTokens: 5),
            stream: true,
            resolvedMaxCompletionTokens: 77,
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )
        capture = nil

        let lines = try captureRecords(in: captureDir)
        XCTAssertEqual(lines.count, 2)
        let header = try XCTUnwrap(lines.first)
        XCTAssertEqual(header["record_type"] as? String, "header")
        XCTAssertEqual(header["sample_method"] as? String, "opt_in_mtp_off_successful_ordinary_completions")
        XCTAssertEqual(header["build_identity_complete"] as? Bool, false)

        let shape = try XCTUnwrap(lines.last)
        XCTAssertEqual(shape["record_type"] as? String, "request_shape")
        XCTAssertEqual(shape["requested_max_completion_tokens"] is NSNull, true)
        XCTAssertEqual(shape["effective_max_output_tokens"] as? Int, 77)
        XCTAssertEqual(shape["conversation_key_present"] as? Bool, true)
        XCTAssertEqual(shape["conversation_key_cache_only"] as? Bool, true)
        XCTAssertEqual(shape["conversation_cache_lease"] as? String, "missing")
        XCTAssertEqual(shape["requested_top_k"] as? Int, 12)
        XCTAssertEqual(shape["requested_min_p"] as? Double, 0.05)
        XCTAssertEqual(shape["requested_presence_penalty"] as? Double, 0.25)
        XCTAssertEqual(shape["requested_frequency_penalty"] as? Double, -0.5)
        XCTAssertEqual(shape["requested_repetition_penalty"] as? Double, 1.1)
        XCTAssertEqual((shape["stop_sequence_utf8_length_buckets"] as? [String: Any])?["5_16"] as? Int, 1)
        XCTAssertEqual(shape["tool_count"] as? Int, 1)
        XCTAssertEqual(shape["tool_choice_kind"] as? String, "function")
        XCTAssertEqual(shape["tool_message_count"] as? Int, 1)
        XCTAssertEqual(shape["assistant_tool_call_count"] as? Int, 1)
        XCTAssertEqual((shape["logit_bias_geometry"] as? [String: Any])?["entry_count"] as? Int, 2)
        XCTAssertEqual((shape["response_schema_geometry"] as? [String: Any])?["property_count"] as? Int, 1)
        let anonymous = try XCTUnwrap(shape["anonymous_cache_group_sha256"] as? String)
        XCTAssertEqual(anonymous.count, 64)
        XCTAssertNil(shape["messages"])
        XCTAssertNil(shape["prompt"])
        XCTAssertNil(shape["conversation_key"])
        XCTAssertNil(shape["request_id"])

        let captureText = try String(contentsOf: try captureFile(in: captureDir), encoding: .utf8)
        XCTAssertFalse(captureText.contains("SECRET_PROMPT_DO_NOT_EXPORT"))
        XCTAssertFalse(captureText.contains("conv:secret-cache-key"))
        XCTAssertFalse(captureText.contains("secret-request-id"))

        let status = try statusRecord(in: captureDir)
        XCTAssertEqual(status["attempts"] as? Int, 1)
        XCTAssertEqual(status["successful_records"] as? Int, 1)
        XCTAssertEqual(status["dropped_missing_effective_budget"] as? Int, 0)
        XCTAssertEqual(status["exports_raw_prompt_text"] as? Bool, false)
        XCTAssertEqual(status["exports_recoverable_cache_groups"] as? Bool, false)
    }

    func testOmittedEffectiveBudgetDropsWithoutInferringFromCompletionLength() throws {
        let root = try privateTempDirectory()
        let captureDir = root.appendingPathComponent("capture", isDirectory: true)
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: NativeMTPRequestShapeCaptureConfig(directory: captureDir, maxRecords: 10, maxBytes: 64 * 1024),
            nativeMTPMode: .off,
            runningBuildIdentity: nil
        )
        capture?.record(
            request: try makeRequest(maxTokens: nil),
            snapshot: snapshot(),
            admission: ordinaryModeOffAdmission(),
            lease: nil,
            leaseAllowed: false,
            completion: completion(promptTokens: 9, completionTokens: 3),
            stream: false
        )
        capture = nil

        XCTAssertEqual(try captureRecords(in: captureDir).count, 1)
        let status = try statusRecord(in: captureDir)
        XCTAssertEqual(status["attempts"] as? Int, 1)
        XCTAssertEqual(status["successful_records"] as? Int, 0)
        XCTAssertEqual(status["dropped_missing_effective_budget"] as? Int, 1)
    }

    func testBoundsAndDroppedCountersAreWrittenToStatusSidecar() throws {
        let root = try privateTempDirectory()
        let captureDir = root.appendingPathComponent("capture", isDirectory: true)
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: NativeMTPRequestShapeCaptureConfig(directory: captureDir, maxRecords: 1, maxBytes: 64 * 1024),
            nativeMTPMode: .off,
            runningBuildIdentity: nil
        )
        let request = try makeRequest(maxTokens: 8)
        for _ in 0..<3 {
            capture?.record(
                request: request,
                snapshot: snapshot(),
                admission: ordinaryModeOffAdmission(),
                lease: nil,
                leaseAllowed: false,
                completion: completion(promptTokens: 4, completionTokens: 2),
                stream: false,
                resolvedMaxCompletionTokens: 8
            )
        }
        capture = nil

        XCTAssertEqual(try captureRecords(in: captureDir).filter { $0["record_type"] as? String == "request_shape" }.count, 1)
        let status = try statusRecord(in: captureDir)
        XCTAssertEqual(status["attempts"] as? Int, 3)
        XCTAssertEqual(status["successful_records"] as? Int, 1)
        XCTAssertEqual(status["dropped_after_record_limit"] as? Int, 2)
        XCTAssertEqual(status["jsonl_record_limit_reached"] as? Bool, true)
    }

    func testRejectsSymlinkAndSharedParentDirectories() throws {
        let root = try privateTempDirectory()
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let symlink = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: target.path)
        XCTAssertThrowsError(try NativeMTPRequestShapeCapture(
            config: NativeMTPRequestShapeCaptureConfig(directory: symlink, maxRecords: 1, maxBytes: 4096),
            nativeMTPMode: .off,
            runningBuildIdentity: nil
        ))

        let sharedParent = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedParent.path)
        let child = sharedParent.appendingPathComponent("capture", isDirectory: true)
        XCTAssertThrowsError(try NativeMTPRequestShapeCapture(
            config: NativeMTPRequestShapeCaptureConfig(directory: child, maxRecords: 1, maxBytes: 4096),
            nativeMTPMode: .off,
            runningBuildIdentity: nil
        ))

        let unsafeExistingLeaf = sharedParent.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeExistingLeaf, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unsafeExistingLeaf.path)
        XCTAssertThrowsError(try NativeMTPRequestShapeCapture(
            config: NativeMTPRequestShapeCaptureConfig(directory: unsafeExistingLeaf, maxRecords: 1, maxBytes: 4096),
            nativeMTPMode: .off,
            runningBuildIdentity: nil
        ))
    }

    private func privateTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func makeRequest(maxTokens: Int?, includeSensitiveValues: Bool = false) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": "fixture-model",
            "messages": [["role": "user", "content": includeSensitiveValues ? "SECRET_PROMPT_DO_NOT_EXPORT" : "hello"]],
            "stream": true,
            "temperature": 0.0,
            "top_p": 1.0,
        ]
        if let maxTokens { object["max_completion_tokens"] = maxTokens }
        if includeSensitiveValues {
            object["presence_penalty"] = 0.25
            object["frequency_penalty"] = -0.5
            object["top_k"] = 12
            object["min_p"] = 0.05
            object["repetition_penalty"] = 1.1
            object["stop"] = ["SECRETSTOP"]
            object["logit_bias"] = ["123": 5, "456": -2]
            object["tools"] = [[
                "type": "function",
                "function": [
                    "name": "secret_tool_name",
                    "parameters": ["type": "object", "properties": ["x": ["type": "string"]], "required": ["x"], "additionalProperties": false],
                ],
            ]]
            object["tool_choice"] = ["type": "function", "function": ["name": "secret_tool_name"]]
            object["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "result",
                    "strict": true,
                    "schema": ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false],
                ],
            ]
            object["messages"] = [
                ["role": "user", "content": "SECRET_PROMPT_DO_NOT_EXPORT"],
                ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_abcdefghijklmnop", "type": "function", "function": ["name": "secret_tool_name", "arguments": "{\"x\":\"y\"}"]]]],
                ["role": "tool", "tool_call_id": "call_abcdefghijklmnop", "content": "SECRET_TOOL_RESULT"],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try ChatCompletionRequest.parse(data: data)
    }

    private func ordinaryModeOffAdmission() -> NativeMTPRuntimeAdmission {
        NativeMTPRuntimeAdmission.resolve(
            selection: DecodePathSelection(path: .ordinary, nativeMTPReason: .modeOff),
            capability: nil,
            schedulerSupportsNativeMTP: false
        )
    }

    private func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "fixture-model",
            modelHash: String(repeating: "a", count: 64),
            weightsManifestSHA256: String(repeating: "b", count: 64)
        )
    }

    private func completion(promptTokens: Int, completionTokens: Int) -> CompletionResult {
        CompletionResult(
            content: "ok",
            finishReason: "stop",
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            settlementDisposition: .eligibleOwner
        )
    }

    private func captureFile(in directory: URL) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".jsonl") }
            .first)
    }

    private func statusFile(in directory: URL) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".status.json") }
            .first)
    }

    private func captureRecords(in directory: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: try captureFile(in: directory), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    private func statusRecord(in directory: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: try statusFile(in: directory))) as? [String: Any])
    }
}
