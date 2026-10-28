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
        XCTAssertEqual(header["schema"] as? String, "macprovider.native-mtp-request-shape-capture.v1")
        XCTAssertEqual(header["capture_requires_native_mtp_off"] as? Bool, true)
        XCTAssertNil(header["capture_role"])

        let shape = try XCTUnwrap(lines.last)
        XCTAssertEqual(shape["record_type"] as? String, "request_shape")
        XCTAssertEqual(shape["pre_capacity_selector_reason"] as? String, "mode_off")
        XCTAssertEqual(shape["effective_path"] as? String, "ordinary")
        for v2Key in ["observed_selector_reason", "observed_selector_eligible", "observed_effective_path",
                      "served_model_family", "parallel_tool_calls_state", "reasoning_effort_state",
                      "effective_reasoning_effort", "tool_choice_function_index", "tool_grammar_required"] {
            XCTAssertNil(shape[v2Key], v2Key)
        }
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
        let stopLengths = try XCTUnwrap(shape["stop_sequence_utf8_lengths"] as? [Any])
        XCTAssertEqual(stopLengths.compactMap { ($0 as? NSNumber)?.intValue }, [10])
        XCTAssertEqual(shape["requested_top_logprobs"] as? Int, 3)
        XCTAssertEqual((shape["logit_bias_geometry"] as? [String: Any])?["entry_count"] as? Int, 2)
        XCTAssertEqual((shape["response_schema_geometry"] as? [String: Any])?["property_count"] as? Int, 1)
        let toolGeometries = try XCTUnwrap(shape["tool_parameter_schema_geometries"] as? [[String: Any]])
        XCTAssertEqual(toolGeometries.count, 1)
        XCTAssertEqual(toolGeometries[0]["property_count"] as? Int, 1)
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

    // SPEC-049-R010: a privacy-class request leaves no shape record and no
    // counter change on disk; an ordinary request beside it still records.
    func testPrivacyRequestLeavesNoShapeRecordOrCounter() throws {
        let root = try privateTempDirectory()
        let captureDir = root.appendingPathComponent("capture", isDirectory: true)
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: NativeMTPRequestShapeCaptureConfig(directory: captureDir, maxRecords: 10, maxBytes: 64 * 1024),
            nativeMTPMode: .off,
            runningBuildIdentity: nil,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let base = try makeRequest(maxTokens: 64, includeSensitiveValues: true)
        for provenance in [KVIngestProvenance.privacy, .relay] {
            capture?.record(
                request: base.withIngestProvenance(provenance),
                snapshot: snapshot(),
                admission: ordinaryModeOffAdmission(),
                lease: nil,
                leaseAllowed: false,
                completion: completion(promptTokens: 37, completionTokens: 5),
                stream: false,
                now: Date(timeIntervalSince1970: 1_800_000_001)
            )
        }
        capture = nil

        let lines = try captureRecords(in: captureDir)
        XCTAssertEqual(lines.count, 2, "header plus the ordinary record only")
        XCTAssertEqual(lines.last?["record_type"] as? String, "request_shape")
        let status = try statusRecord(in: captureDir)
        XCTAssertEqual(status["attempts"] as? Int, 1)
        XCTAssertEqual(status["successful_records"] as? Int, 1)
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

    func testSchemaOptInKeepsV1DefaultAndOffOnly() throws {
        let directory = "/unused/private-capture"
        let defaultConfig = try XCTUnwrap(NativeMTPRequestShapeCaptureConfig.fromEnvironment([
            NativeMTPRequestShapeCaptureConfig.directoryEnvironmentKey: directory,
        ]))
        XCTAssertEqual(defaultConfig.schema, .v1)
        let v2Config = try XCTUnwrap(NativeMTPRequestShapeCaptureConfig.fromEnvironment([
            NativeMTPRequestShapeCaptureConfig.directoryEnvironmentKey: directory,
            NativeMTPRequestShapeCaptureConfig.schemaEnvironmentKey: "v2",
        ]))
        XCTAssertEqual(v2Config.schema, .v2)
        XCTAssertThrowsError(try NativeMTPRequestShapeCaptureConfig.fromEnvironment([
            NativeMTPRequestShapeCaptureConfig.directoryEnvironmentKey: directory,
            NativeMTPRequestShapeCaptureConfig.schemaEnvironmentKey: "v3",
        ])) { error in
            XCTAssertEqual(error as? NativeMTPRequestShapeCaptureError, .invalidSchema)
        }
        let root = try privateTempDirectory()
        XCTAssertThrowsError(try NativeMTPRequestShapeCapture(
            config: .init(directory: root.appendingPathComponent("v1"), maxRecords: 10, maxBytes: 64 * 1024),
            nativeMTPMode: .auto, runningBuildIdentity: nil
        )) { error in
            XCTAssertEqual(error as? NativeMTPRequestShapeCaptureError, .requiresNativeMTPOff)
        }
    }

    func testV2ObservesActualMixedPathsWithoutOrdinaryBaselineFields() throws {
        let root = try privateTempDirectory()
        let directory = root.appendingPathComponent("capture")
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: .init(directory: directory, maxRecords: 10, maxBytes: 64 * 1024, schema: .v2),
            nativeMTPMode: .auto, runningBuildIdentity: nil
        )
        let request = try makeRequest(maxTokens: 8)
        for (path, reason) in [(DecodePath.nativeMTP, NativeMTPSelectorReason.eligible), (.ordinary, .sampling)] {
            capture?.record(
                request: request, snapshot: snapshot(family: "glm5_next_mtp_v1"),
                admission: observedAdmission(path: path, reason: reason), lease: nil, leaseAllowed: false,
                completion: completion(promptTokens: 4, completionTokens: 2), stream: false
            )
        }
        capture = nil
        let records = try captureRecords(in: directory)
        XCTAssertEqual(records.count, 3)
        let header = records[0]
        XCTAssertEqual(header["schema"] as? String, "macprovider.native-mtp-request-shape-capture.v2")
        XCTAssertEqual(header["native_mtp_mode"] as? String, "auto")
        XCTAssertEqual(header["capture_role"] as? String, "request_shape_observation_only")
        XCTAssertEqual(header["capture_requires_native_mtp_off"] as? Bool, false)
        XCTAssertEqual(header["sample_method"] as? String, "opt_in_successful_persistable_completions_observation")
        XCTAssertEqual(records[1]["observed_effective_path"] as? String, "native_mtp")
        XCTAssertEqual(records[1]["observed_selector_reason"] as? String, "eligible")
        XCTAssertEqual(records[1]["observed_selector_eligible"] as? Bool, true)
        XCTAssertEqual(records[2]["observed_effective_path"] as? String, "ordinary")
        XCTAssertEqual(records[2]["observed_selector_reason"] as? String, "sampling")
        XCTAssertEqual(records[2]["observed_selector_eligible"] as? Bool, false)
        for row in records.dropFirst() {
            for forbidden in ["pre_capacity_selector_reason", "pre_capacity_eligible", "effective_path",
                              "ttft_seconds", "inter_token_gaps", "throughput_tps", "wall_seconds"] {
                XCTAssertNil(row[forbidden], forbidden)
            }
        }
        XCTAssertEqual(try statusRecord(in: directory)["skipped_ineligible"] as? Int, 0)
    }

    func testV2OffModeRetainsObservationRoleRatherThanV1OrdinaryEvidenceContract() throws {
        let directory = try privateTempDirectory().appendingPathComponent("capture")
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: .init(directory: directory, maxRecords: 10, maxBytes: 64 * 1024, schema: .v2),
            nativeMTPMode: .off, runningBuildIdentity: nil
        )
        capture?.record(
            request: try makeRequest(maxTokens: 8), snapshot: snapshot(), admission: ordinaryModeOffAdmission(),
            lease: nil, leaseAllowed: false, completion: completion(promptTokens: 4, completionTokens: 2), stream: false
        )
        capture = nil
        let records = try captureRecords(in: directory)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["native_mtp_mode"] as? String, "off")
        XCTAssertEqual(records[0]["capture_requires_native_mtp_off"] as? Bool, false)
        XCTAssertEqual(records[0]["capture_role"] as? String, "request_shape_observation_only")
        XCTAssertEqual(records[1]["observed_selector_reason"] as? String, "mode_off")
    }

    func testV2CapturesConsumedReasoningAndParallelControlsWithServedModelNormalization() throws {
        // The buyer model remains fixture-model; only the actual GLM served ID
        // should map none/minimal to low, as the production template does.
        let served = snapshot(modelID: "mlx-community/GLM-5.3-Flash", family: "glm5_next_mtp_v1")
        var controls: [[String: Any]] = [[:], ["reasoning_effort": NSNull()]]
        for value in ChatCompletionRequest.acceptedReasoningEfforts.sorted() {
            controls.append(["reasoning_effort": value])
        }
        for value in controls {
            let request = try makeRequest(maxTokens: 8, extra: value)
            let row = try writeV2Shape(request: request, servedSnapshot: served)
            let expectedState = value["reasoning_effort"] as? String
                ?? (value["reasoning_effort"] == nil ? "absent" : "null")
            XCTAssertEqual(row["reasoning_effort_state"] as? String, expectedState)
            if let expected = request.templateReasoningEffort(for: try XCTUnwrap(served.modelID)) {
                XCTAssertEqual(row["effective_reasoning_effort"] as? String, expected)
            } else {
                XCTAssertTrue(row["effective_reasoning_effort"] is NSNull)
            }
            XCTAssertEqual(row["served_model_family"] as? String, "glm5_next_mtp_v1")
            XCTAssertEqual(row["unknown_request_fields_present"] as? Bool, false)
        }
        for value in [nil, true, false] as [Bool?] {
            let extra: [String: Any] = value.map { ["parallel_tool_calls": $0] } ?? [:]
            let row = try writeV2Shape(request: makeRequest(maxTokens: 8, extra: extra), servedSnapshot: served)
            XCTAssertEqual(row["parallel_tool_calls_state"] as? String, value.map { $0 ? "true" : "false" } ?? "absent")
            XCTAssertEqual(row["unknown_top_level_keys_present"] as? Bool, false)
        }
        XCTAssertThrowsError(try makeRequest(maxTokens: 8, extra: ["parallel_tool_calls": NSNull()]))
        let unknown = try writeV2Shape(request: makeRequest(maxTokens: 8, extra: [
            "reasoning_effort": "high", "unknown_control": true,
        ]), servedSnapshot: served)
        XCTAssertEqual(unknown["unknown_request_fields_present"] as? Bool, true)
        let missingFamily = try writeV2Shape(request: makeRequest(maxTokens: 8), servedSnapshot: snapshot())
        XCTAssertEqual(missingFamily["served_model_family"] as? String, "unknown")
    }

    func testV2NamedChoiceRecordsOnlyUniqueFunctionIndexAndProductionGrammar() throws {
        let tools: [[String: Any]] = ["secret_first", "secret_second"].map { name in
            ["type": "function", "function": ["name": name, "parameters": ["type": "object"]]]
        }
        let served = snapshot(modelID: "mlx-community/GLM-5.3-Flash", family: "glm5_next_mtp_v1")
        let choice: [String: Any] = ["type": "function", "function": ["name": "secret_second"]]
        let named = try writeV2Shape(request: makeRequest(maxTokens: 8, extra: ["tools": tools, "tool_choice": choice]), servedSnapshot: served)
        XCTAssertEqual(named["tool_choice_function_index"] as? Int, 1)
        XCTAssertEqual(named["tool_grammar_required"] as? Bool, true)
        XCTAssertEqual(named["effective_reasoning_effort"] as? String, "low", "production tool default")
        let encoded = try String(decoding: JSONSerialization.data(withJSONObject: named), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret_first"))
        XCTAssertFalse(encoded.contains("secret_second"))
        for choice in ["auto", "none", "required"] {
            let row = try writeV2Shape(request: makeRequest(maxTokens: 8, extra: ["tools": tools, "tool_choice": choice]), servedSnapshot: served)
            XCTAssertTrue(row["tool_choice_function_index"] is NSNull)
            XCTAssertEqual(row["tool_grammar_required"] as? Bool, choice == "required")
        }
        let unresolved: [String: Any] = ["type": "function", "function": ["name": "undeclared"]]
        let row = try writeV2Shape(request: makeRequest(maxTokens: 8, extra: ["tools": tools, "tool_choice": unresolved]), servedSnapshot: served)
        XCTAssertEqual(row["tool_choice_kind"] as? String, "function")
        XCTAssertTrue(row["tool_choice_function_index"] is NSNull, "unresolved choice remains pending metadata")
        let other = try writeV2Shape(request: makeRequest(maxTokens: 8, extra: ["tool_choice": "unsupported_mode"]), servedSnapshot: served)
        XCTAssertEqual(other["tool_choice_kind"] as? String, "string_other")
        XCTAssertTrue(other["tool_choice_function_index"] is NSNull)
    }

    func testV2PreservesPrivacyExclusionAndRecordAndByteBounds() throws {
        let root = try privateTempDirectory()
        let directory = root.appendingPathComponent("capture")
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: .init(directory: directory, maxRecords: 1, maxBytes: 64 * 1024, schema: .v2),
            nativeMTPMode: .auto, runningBuildIdentity: nil
        )
        let request = try makeRequest(maxTokens: 8)
        for request in [request.withIngestProvenance(.privacy), request, request] {
            capture?.record(
                request: request, snapshot: snapshot(), admission: observedAdmission(path: .ordinary, reason: .tools),
                lease: nil, leaseAllowed: false, completion: completion(promptTokens: 4, completionTokens: 2), stream: false
            )
        }
        capture = nil
        XCTAssertEqual(try captureRecords(in: directory).count, 2)
        let status = try statusRecord(in: directory)
        XCTAssertEqual(status["attempts"] as? Int, 2)
        XCTAssertEqual(status["successful_records"] as? Int, 1)
        XCTAssertEqual(status["dropped_after_record_limit"] as? Int, 1)
        let byteDirectory = root.appendingPathComponent("byte-capture")
        capture = try NativeMTPRequestShapeCapture(
            config: .init(directory: byteDirectory, maxRecords: 10, maxBytes: 1024, schema: .v2),
            nativeMTPMode: .auto, runningBuildIdentity: nil
        )
        capture?.record(
            request: request, snapshot: snapshot(), admission: observedAdmission(path: .ordinary, reason: .tools),
            lease: nil, leaseAllowed: false, completion: completion(promptTokens: 4, completionTokens: 2), stream: false
        )
        capture = nil
        XCTAssertLessThanOrEqual(try Data(contentsOf: captureFile(in: byteDirectory)).count, 1024)
        XCTAssertEqual(try statusRecord(in: byteDirectory)["dropped_after_byte_limit"] as? Int, 1)
    }

    private func writeV2Shape(request: ChatCompletionRequest, servedSnapshot: RuntimeSnapshot) throws -> [String: Any] {
        let directory = try privateTempDirectory().appendingPathComponent("capture")
        var capture: NativeMTPRequestShapeCapture? = try NativeMTPRequestShapeCapture(
            config: .init(directory: directory, maxRecords: 10, maxBytes: 64 * 1024, schema: .v2),
            nativeMTPMode: .auto, runningBuildIdentity: nil
        )
        capture?.record(
            request: request, snapshot: servedSnapshot, admission: observedAdmission(path: .ordinary, reason: .tools),
            lease: nil, leaseAllowed: false, completion: completion(promptTokens: 4, completionTokens: 2), stream: false
        )
        capture = nil
        return try XCTUnwrap(captureRecords(in: directory).last)
    }

    private func observedAdmission(path: DecodePath, reason: NativeMTPSelectorReason) -> NativeMTPRuntimeAdmission {
        NativeMTPRuntimeAdmission.resolve(
            selection: DecodePathSelection(path: path, nativeMTPReason: reason),
            capability: captureCapability(family: "glm5_next_mtp_v1"), schedulerSupportsNativeMTP: true
        )
    }

    private func captureCapability(family: String) -> NativeMTPCapability {
        NativeMTPCapability(
            admitted: true, revoked: false, revocationStateAvailable: true,
            supportsCurrentProcessor: true, supportsCurrentStateCache: true,
            supportsStreaming: true, supportsNonStreaming: true, supportsStopSequences: false,
            hasQualifiedRowMappedTransactions: true, maximumProposalDepth: 1,
            maximumPromptTokens: 4096, maximumCompletionTokens: 4096, family: family
        )
    }

    private func privateTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func makeRequest(maxTokens: Int?, includeSensitiveValues: Bool = false, extra: [String: Any] = [:]) throws -> ChatCompletionRequest {
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
            object["logprobs"] = true
            object["top_logprobs"] = 3
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
        object.merge(extra) { _, value in value }
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

    private func snapshot(modelID: String = "fixture-model", family: String? = nil) -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: modelID,
            modelHash: String(repeating: "a", count: 64),
            weightsManifestSHA256: String(repeating: "b", count: 64),
            nativeMTPCapability: family.map { captureCapability(family: $0) }
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
