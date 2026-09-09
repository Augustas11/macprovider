import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class BYOMEvaluationTests: XCTestCase {
    func testEvaluateCommandRequiresJSONFlag() async throws {
        let command = try ModelsEvaluateCommand.parse(["ollama:Tiny-Ollama-1B-Q4", "--skip-ollama"])
        let capture = await captureBYOMEvaluationOutput {
            try await command.run()
        }

        XCTAssertTrue(capture.stdout.isEmpty)
        XCTAssertTrue(capture.stderr.contains("JSON-only"))
        XCTAssertEqual((capture.error as? ExitCode), ExitCode(2))
    }

    func testEvaluateCommandRunsHermeticLoopbackRuntimeWithoutMutation() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-loopback")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let runtime = try BYOMEvaluationLoopbackRuntime(
            tagsBody: """
            {"models":[{"name":"Tiny-Ollama-1B-Q4","details":{"family":"llama","quantization_level":"Q4_0"}}]}
            """,
            chatStatusCode: 200,
            chatBody: """
            {"id":"chatcmpl-local","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}
            """
        )

        let command = try ModelsEvaluateCommand.parse([
            "ollama:Tiny-Ollama-1B-Q4",
            "--json",
            "--local-discovery-namespace-path", namespace.path,
            "--mlx-cache-dir", cache.path,
            "--ollama-origin", runtime.origin,
        ])
        let capture = await captureBYOMEvaluationOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        XCTAssertEqual(object["schema"] as? String, "provider_byom_evaluation.v1")
        XCTAssertEqual(object["runtime_source"] as? String, "ollama_loopback")
        XCTAssertEqual(object["served_model_ref"] as? String, "ollama:Tiny-Ollama-1B-Q4")
        XCTAssertEqual(object["adapter_identity"] as? String, "openai_compatible_loopback")
        XCTAssertEqual(object["health_result"] as? String, "passed")
        XCTAssertEqual(object["request_count"] as? Int, 1)
        XCTAssertEqual(object["completion_tokens"] as? Int, 2)
        XCTAssertEqual(object["usage_reporting_source"] as? String, "runtime_reported")
        XCTAssertEqual(object["offer_preconditions_appear_satisfied"] as? Bool, true)
        let mutations = try XCTUnwrap(object["mutation_summary"] as? [String: Any])
        XCTAssertEqual(mutations["production_config_mutated"] as? Bool, false)
        XCTAssertEqual(mutations["coordinator_state_mutated"] as? Bool, false)
        XCTAssertEqual(mutations["production_model_switched"] as? Bool, false)
        XCTAssertEqual(mutations["runtime_started"] as? Bool, false)
        XCTAssertEqual(mutations["downloads_started"] as? Bool, false)
        let guidance = try XCTUnwrap(object["provider_guidance"] as? [String: Any])
        XCTAssertEqual(guidance["earning_path_class"] as? String, "local_inventory_only")
        let encoded = capture.stdout + capture.stderr
        XCTAssertFalse(encoded.contains("MacProvider BYOM local evaluation health probe"))
        XCTAssertFalse(encoded.contains("\"content\":\"ok\""))
        XCTAssertFalse(encoded.contains(runtime.origin))
        XCTAssertEqual(runtime.requestPaths, ["/api/tags", "/v1/chat/completions"])
    }

    // SPEC-046-R005/R006: an opaque `openai_compatible_loopback` candidate runs
    // through the same bounded chat-completions harness as the Ollama adapter.
    // The probe proves liveness only: the candidate stays local inventory, the
    // mutation summary stays all-false, and no prompt/completion text or origin
    // reaches stdout or stderr.
    func testEvaluateOpaqueOpenAICompatibleCandidateStaysNonEarning() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-opaque")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let runtime = try BYOMEvaluationLoopbackRuntime(
            tagsBody: #"{"models":[]}"#,
            modelsBody: #"{"object":"list","data":[{"id":"opaque-mini-1b","object":"model"}]}"#,
            chatStatusCode: 200,
            chatBody: """
            {"id":"chatcmpl-local","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}
            """
        )

        let command = try ModelsEvaluateCommand.parse([
            "openai_compatible:opaque-mini-1b",
            "--json",
            "--local-discovery-namespace-path", namespace.path,
            "--mlx-cache-dir", cache.path,
            "--skip-ollama",
            "--openai-compatible-origin", runtime.origin,
        ])
        let capture = await captureBYOMEvaluationOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        XCTAssertEqual(object["runtime_source"] as? String, "openai_compatible_loopback")
        XCTAssertEqual(object["served_model_ref"] as? String, "openai_compatible:opaque-mini-1b")
        XCTAssertEqual(object["adapter_identity"] as? String, "openai_compatible_loopback")
        XCTAssertEqual(object["health_result"] as? String, "passed")
        XCTAssertEqual(object["completion_tokens"] as? Int, 2)
        XCTAssertTrue(object["catalog_model_key"] is NSNull)
        // Liveness is not offerability: an opaque endpoint never satisfies the
        // offer preconditions, however healthy the probe was.
        XCTAssertEqual(object["offer_preconditions_appear_satisfied"] as? Bool, false)
        let mutations = try XCTUnwrap(object["mutation_summary"] as? [String: Any])
        for field in ["production_config_mutated", "coordinator_state_mutated", "production_model_switched", "runtime_started", "downloads_started"] {
            XCTAssertEqual(mutations[field] as? Bool, false, "\(field) must stay false")
        }
        let guidance = try XCTUnwrap(object["provider_guidance"] as? [String: Any])
        XCTAssertEqual(guidance["earning_path_class"] as? String, "local_inventory_only")

        let emitted = capture.stdout + capture.stderr
        XCTAssertFalse(emitted.contains("MacProvider BYOM local evaluation health probe"))
        XCTAssertFalse(emitted.contains("\"content\":\"ok\""))
        XCTAssertFalse(emitted.contains(runtime.origin))
        XCTAssertEqual(runtime.requestPaths, ["/v1/models", "/v1/chat/completions"])
    }

    func testEvaluateMLXCandidateBlocksWithoutCacheMutation() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-mlx")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try createBYOMMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        let before = try recursiveBYOMEvaluationPaths(cache)

        let document = await BYOMEvaluationRunner(
            target: "mlx-community/Tiny-1B-4bit",
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).evaluate()

        XCTAssertEqual(document.schema, "provider_byom_evaluation.v1")
        XCTAssertEqual(document.runtimeSource, "mlx_cache")
        XCTAssertEqual(document.healthResult, "blocked")
        XCTAssertEqual(document.requestCount, 0)
        XCTAssertEqual(document.mutationSummary.downloadsStarted, false)
        XCTAssertEqual(document.mutationSummary.productionModelSwitched, false)
        XCTAssertTrue(document.warnings.contains("requires_preparation"))
        let after = try recursiveBYOMEvaluationPaths(cache)
        XCTAssertEqual(before, after)
    }

    func testEvaluateRetainsRedactionWarningsWithoutBlockingSafeCandidate() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-redaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try BYOMEvaluationLoopbackRuntime(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4","details":{"family":"api_key=hidden","quantization_level":"/Users/private/hidden"}},{"name":"/Users/private/omitted"}]}"#,
            chatStatusCode: 200,
            chatBody: #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"completion_tokens":2}}"#
        )
        let command = try ModelsEvaluateCommand.parse([
            "ollama:Tiny-Ollama-1B-Q4", "--json",
            "--local-discovery-namespace-path", root.appendingPathComponent("ns").path,
            "--mlx-cache-dir", root.appendingPathComponent("hf").path,
            "--ollama-origin", runtime.origin,
        ])
        let capture = await captureBYOMEvaluationOutput { try await command.run() }
        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        XCTAssertEqual(object["health_result"] as? String, "passed")
        XCTAssertEqual(object["offer_preconditions_appear_satisfied"] as? Bool, true)
        let warnings = try XCTUnwrap(object["warnings"] as? [String])
        XCTAssertTrue(warnings.contains("capability_family_redacted"))
        XCTAssertTrue(warnings.contains("capability_quantization_redacted"))
        XCTAssertFalse(warnings.contains("model_reference_redacted"))
        XCTAssertFalse(warnings.contains("adapter_malformed_response"))
        XCTAssertFalse(warnings.contains("evaluation_required"))
        XCTAssertEqual(Set(warnings).count, warnings.count)
        let stderrCodes = capture.stderr.split(whereSeparator: \.isNewline).map { String($0).replacingOccurrences(of: "models evaluate warning: ", with: "") }
        XCTAssertEqual(stderrCodes, warnings.sorted())
        let guidance = try XCTUnwrap(object["provider_guidance"] as? [String: Any])
        XCTAssertEqual(guidance["earning_path_class"] as? String, "local_inventory_only")
        XCTAssertEqual(guidance["next_action"] as? String, "offer_dry_run")
        for raw in ["api_key", "hidden", "/Users/private", "omitted", runtime.origin] {
            XCTAssertFalse((capture.stdout + capture.stderr).contains(raw))
        }
        XCTAssertEqual(runtime.requestPaths, ["/api/tags", "/v1/chat/completions"])
    }

    func testEvaluateRuntimeTimeoutFailsClosed() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-timeout")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            postError: URLError(.timedOut)
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.healthResult, "timed_out")
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("adapter_timeout"))
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
        XCTAssertEqual(document.mutationSummary.coordinatorStateMutated, false)
    }

    func testEvaluateStalledRuntimePostHitsEvaluationDeadline() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-stalled-deadline")
        let productionConfig = try createBYOMEvaluationSentinel(root: root)
        let productionConfigBefore = try recursiveBYOMEvaluationFileSnapshot(productionConfig)
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            postDelayNanoseconds: 500_000_000
        )
        let limits = BYOMEvaluationLimits(
            timeoutSeconds: 0.02,
            maxRequestBytes: 16 * 1024,
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: 256 * 1024,
            maxOutputBytes: 64 * 1024,
            maxTokens: 8,
            requestCount: 1
        )

        let started = Date()
        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            limits: limits,
            httpClient: client
        ).evaluate()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.3)
        XCTAssertEqual(client.postCount, 1)
        XCTAssertEqual(client.requestLog, [
            "GET http://127.0.0.1:11434/api/tags",
            "POST http://127.0.0.1:11434/v1/chat/completions",
        ])
        XCTAssertEqual(document.healthResult, "timed_out")
        XCTAssertEqual(document.requestCount, 1)
        XCTAssertEqual(document.outputBytes, 0)
        XCTAssertNil(document.diagnosticHashes.responseBodySHA256)
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertEqual(document.mutationSummary, .none)
        XCTAssertTrue(document.warnings.contains("adapter_timeout"))
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
        XCTAssertEqual(document.providerGuidance.nextAction, "fix_local_blocker")
        XCTAssertEqual(document.providerGuidance.earningPathClass, "local_inventory_only")
        XCTAssertEqual(try recursiveBYOMEvaluationFileSnapshot(productionConfig), productionConfigBefore)
    }

    func testEvaluateOutputByteCapFailsClosedAndRedactsBody() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-output-cap")
        let productionConfig = try createBYOMEvaluationSentinel(root: root)
        let productionConfigBefore = try recursiveBYOMEvaluationFileSnapshot(productionConfig)
        let oversizedContent = String(repeating: "A", count: 96)
        let body = #"{"choices":[{"message":{"role":"assistant","content":""# + oversizedContent + #""},"finish_reason":"stop"}],"usage":{"completion_tokens":2}}"#
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(body.utf8))
        )
        let limits = BYOMEvaluationLimits(
            timeoutSeconds: 1.0,
            maxRequestBytes: 16 * 1024,
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: 256 * 1024,
            maxOutputBytes: 64,
            maxTokens: 8,
            requestCount: 1
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            limits: limits,
            httpClient: client
        ).evaluate()

        XCTAssertEqual(client.postCount, 1)
        XCTAssertEqual(client.requestLog, [
            "GET http://127.0.0.1:11434/api/tags",
            "POST http://127.0.0.1:11434/v1/chat/completions",
        ])
        XCTAssertEqual(document.healthResult, "failed")
        XCTAssertGreaterThan(document.outputBytes, limits.maxOutputBytes)
        XCTAssertNil(document.completionTokens)
        XCTAssertNil(document.tokensPerSecond)
        XCTAssertEqual(document.usageReportingSource, "not_evaluated")
        XCTAssertEqual(document.capabilityResults["chat_completions"]?.result, "not_tested")
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertEqual(document.mutationSummary, .none)
        XCTAssertNotNil(document.diagnosticHashes.responseBodySHA256)
        XCTAssertTrue(document.warnings.contains("adapter_response_truncated"))
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
        let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        XCTAssertFalse(encoded.contains(oversizedContent))
        XCTAssertFalse(encoded.contains("\"choices\""))
        XCTAssertEqual(try recursiveBYOMEvaluationFileSnapshot(productionConfig), productionConfigBefore)
    }

    func testProvisioningDoesNotChmodExistingParentDirectory() throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-provision-parent")
        let parent = root.appendingPathComponent("operator-supplied", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)

        _ = BYOMDiscoveryNamespaceStore().provisionNamespaceIfMissing(at: parent.appendingPathComponent("ns"))

        let perms = (try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms.map { $0 & 0o777 }, 0o755, "provisioning must not alter an existing parent directory's permissions")
    }

    func testProvisioningCreatesPrivateSaltAndIsIdempotent() throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-provision-idem")
        let ns = root.appendingPathComponent("nsdir", isDirectory: true).appendingPathComponent("ns")
        let store = BYOMDiscoveryNamespaceStore()

        let first = store.provisionNamespaceIfMissing(at: ns)
        XCTAssertEqual(first.bytes?.count, 32)
        XCTAssertTrue(first.warnings.isEmpty)
        let dirPerms = (try FileManager.default.attributesOfItem(atPath: ns.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        let filePerms = (try FileManager.default.attributesOfItem(atPath: ns.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirPerms.map { $0 & 0o077 }, 0)   // no group/other bits
        XCTAssertEqual(filePerms.map { $0 & 0o077 }, 0)

        // Idempotent: a second call reads the same salt, never rewriting it.
        let second = store.provisionNamespaceIfMissing(at: ns)
        XCTAssertEqual(second.bytes, first.bytes)
    }

    func testEvaluateMalformedRuntimeResponseFailsClosedAndHashesBody() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-malformed")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(#"{"choices":[]}"#.utf8))
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.healthResult, "failed")
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("adapter_malformed_response"))
        XCTAssertNotNil(document.diagnosticHashes.responseBodySHA256)
    }

    // #1246 / SPEC-046-R002: bounded JSON nesting and parser work on the
    // EVALUATION half of the shared safety layer. A chat-completions body that
    // stays under the 256KiB byte cap but is pathologically nested must fail
    // closed with adapter_malformed_response — no stack overflow, no fabricated
    // health result, and no raw body reflected into the evaluation document.
    func testEvaluationParserRejectsPathologicalJSONNestingWithoutCrashing() async throws {
        let openBrackets = Data(String(repeating: "[", count: 50_000).utf8)
        let openBraces = Data(String(repeating: "{", count: 50_000).utf8)
        for hostile in [openBrackets, openBraces] {
            XCTAssertLessThan(hostile.count, BYOMDiscoveryHTTPBounds.maxBodyBytes)
            XCTAssertThrowsError(try BYOMEvaluationJSON.parseChatCompletions(hostile, maxCompletionTokens: 8)) { error in
                guard case BYOMDiscoveryAdapterError.malformed = error else {
                    return XCTFail("expected malformed, got \(error)")
                }
            }
        }

        let depth = 20_000
        let nested = Data((
            #"{"choices":["# + String(repeating: "[", count: depth)
                + String(repeating: "]", count: depth) + "]}"
        ).utf8)
        XCTAssertLessThan(nested.count, BYOMDiscoveryHTTPBounds.maxBodyBytes)
        XCTAssertLessThan(nested.count, BYOMEvaluationLimits.standard.maxOutputBytes)
        XCTAssertThrowsError(try BYOMEvaluationJSON.parseChatCompletions(nested, maxCompletionTokens: 8)) { error in
            guard case BYOMDiscoveryAdapterError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }

        let root = try temporaryBYOMEvaluationDirectory("byom-eval-nesting")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: nested)
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(client.postCount, 1)
        XCTAssertEqual(document.healthResult, "failed")
        XCTAssertTrue(document.warnings.contains("adapter_malformed_response"))
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertEqual(document.mutationSummary, .none)
        XCTAssertNotNil(document.diagnosticHashes.responseBodySHA256)
        let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        XCTAssertFalse(encoded.contains("[[["))
        XCTAssertFalse(encoded.contains("\"choices\""))
    }

    func testEvaluateMalformedNonemptyChoicesFailClosed() async throws {
        let malformedBodies = [
            #"{"choices":[{}]}"#,
            #"{"choices":[{"message":{}}]}"#,
            #"{"choices":[{"message":{"role":"tool","content":"ok"}}]}"#,
            #"{"choices":[{"message":{"role":"assistant","content":""}}]}"#,
            #"{"choices":[{"message":{"role":"assistant","content":null}}]}"#,
        ]

        for body in malformedBodies {
            let root = try temporaryBYOMEvaluationDirectory("byom-eval-malformed-choice")
            let client = BYOMEvaluationStubHTTPClient(
                tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
                postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(body.utf8))
            )

            let document = await BYOMEvaluationRunner(
                target: "ollama:Tiny-Ollama-1B-Q4",
                environment: BYOMDiscoveryEnvironment(
                    namespaceURL: root.appendingPathComponent("ns"),
                    mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                    ollamaOrigin: "http://127.0.0.1:11434"
                ),
                httpClient: client
            ).evaluate()

            XCTAssertEqual(document.healthResult, "failed", body)
            XCTAssertFalse(document.offerPreconditionsAppearSatisfied, body)
            XCTAssertTrue(document.warnings.contains("adapter_malformed_response"), body)
            XCTAssertTrue(document.warnings.contains("evaluation_failed"), body)
            XCTAssertEqual(document.capabilityResults["chat_completions"]?.result, "not_tested", body)
        }
    }

    func testEvaluateRejectsMalformedOrOverLimitUsageTokens() async throws {
        let malformedBodies = [
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"completion_tokens":1e20}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"completion_tokens":9}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"completionTokens":"2"}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"output_tokens":-1}}"#,
        ]

        for body in malformedBodies {
            let root = try temporaryBYOMEvaluationDirectory("byom-eval-usage-bound")
            let client = BYOMEvaluationStubHTTPClient(
                tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
                postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(body.utf8))
            )

            let document = await BYOMEvaluationRunner(
                target: "ollama:Tiny-Ollama-1B-Q4",
                environment: BYOMDiscoveryEnvironment(
                    namespaceURL: root.appendingPathComponent("ns"),
                    mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                    ollamaOrigin: "http://127.0.0.1:11434"
                ),
                httpClient: client
            ).evaluate()

            XCTAssertEqual(document.healthResult, "failed", body)
            XCTAssertNil(document.completionTokens, body)
            XCTAssertNil(document.tokensPerSecond, body)
            XCTAssertEqual(document.usageReportingSource, "not_evaluated", body)
            XCTAssertTrue(document.warnings.contains("adapter_malformed_response"), body)
            XCTAssertTrue(document.warnings.contains("evaluation_failed"), body)
        }
    }

    func testEvaluateRejectsInvalidOriginBeforeRuntimePost() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-origin")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://localhost:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.healthResult, "blocked")
        XCTAssertEqual(client.postCount, 0)
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
    }

    func testEvaluateUnknownCandidateDoesNotReflectUnsafeTarget() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-unknown")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#
        )

        let document = await BYOMEvaluationRunner(
            target: "http://192.168.1.10:11434/private-model",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.candidateID, "unknown")
        XCTAssertEqual(document.servedModelRef, "unknown")
        XCTAssertEqual(document.runtimeSource, "unknown")
        XCTAssertEqual(client.postCount, 0)
        XCTAssertFalse(document.diagnosticHashes.promptSHA256.isEmpty)
        XCTAssertNil(document.diagnosticHashes.responseBodySHA256)
    }

    func testURLSessionEvaluationPostRejectsNonLoopbackURLBeforeDispatch() async throws {
        do {
            _ = try await BYOMURLSessionHTTPClient().post(
                URL(string: "http://192.168.1.10:11434/v1/chat/completions")!,
                jsonBody: Data(#"{"model":"x"}"#.utf8),
                maxHeaderBytes: 1024,
                maxBodyBytes: 1024
            )
            XCTFail("non-loopback evaluation URL must be rejected before dispatch")
        } catch BYOMDiscoveryAdapterError.rejectedNonLoopback {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await BYOMURLSessionHTTPClient().post(
                URL(string: "http://127.0.0.1:11434/v1/chat/completions?next=http://192.168.1.10")!,
                jsonBody: Data(#"{"model":"x"}"#.utf8),
                maxHeaderBytes: 1024,
                maxBodyBytes: 1024
            )
            XCTFail("query-bearing evaluation URL must be rejected before dispatch")
        } catch BYOMDiscoveryAdapterError.rejectedNonLoopback {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEvaluateRedirectResponseDoesNotFollowNonLoopbackTarget() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-redirect")
        let runtime = try BYOMEvaluationLoopbackRuntime(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            chatStatusCode: 302,
            chatHeaders: [("Location", "http://192.168.1.10:11434/v1/chat/completions")],
            chatBody: ""
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: runtime.origin
            )
        ).evaluate()

        XCTAssertEqual(document.healthResult, "failed")
        XCTAssertEqual(runtime.requestPaths, ["/api/tags", "/v1/chat/completions"])
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("adapter_rejected_non_loopback"))
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
    }

    private func temporaryBYOMEvaluationDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Private (0700) so a salt provisioned directly under it has a private
        // parent, mirroring the dedicated 0700 dir the production default uses.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func createBYOMMLXSnapshot(cacheRoot: URL, modelID: String) throws {
        let repo = cacheRoot
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(#"{"max_position_embeddings":2048}"#.utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0x7a, count: 128).write(to: repo.appendingPathComponent("model.safetensors"))
    }

    private func recursiveBYOMEvaluationPaths(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator {
            result.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return result.sorted()
    }

    private func createBYOMEvaluationSentinel(root: URL) throws -> URL {
        let productionConfig = root.appendingPathComponent("production-config", isDirectory: true)
        try FileManager.default.createDirectory(at: productionConfig, withIntermediateDirectories: true)
        try Data(#"{"serving_model":"catalog:stable","admission":"unchanged"}"#.utf8)
            .write(to: productionConfig.appendingPathComponent("serving.json"))
        return productionConfig
    }

    private func recursiveBYOMEvaluationFileSnapshot(_ root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    private func jsonObject(_ stdout: String) throws -> [String: Any] {
        let line = try XCTUnwrap(stdout.split(whereSeparator: \.isNewline).first { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

private final class BYOMEvaluationStubHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let tagsBody: String
    private let postResponse: BYOMHTTPResponse?
    private let postError: Error?
    private let postDelayNanoseconds: UInt64?
    private var posts = 0
    private var requests: [String] = []

    var postCount: Int {
        lock.withLock { posts }
    }

    var requestLog: [String] {
        lock.withLock { requests }
    }

    init(
        tagsBody: String,
        postResponse: BYOMHTTPResponse? = nil,
        postError: Error? = nil,
        postDelayNanoseconds: UInt64? = nil
    ) {
        self.tagsBody = tagsBody
        self.postResponse = postResponse
        self.postError = postError
        self.postDelayNanoseconds = postDelayNanoseconds
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock {
            requests.append("GET \(url.absoluteString)")
        }
        return BYOMHTTPResponse(statusCode: 200, headers: [("content-type", "application/json")], body: Data(tagsBody.utf8))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock {
            posts += 1
            requests.append("POST \(url.absoluteString)")
        }
        if let postError {
            throw postError
        }
        if let postDelayNanoseconds {
            try await Task.sleep(nanoseconds: postDelayNanoseconds)
        }
        return postResponse ?? BYOMHTTPResponse(statusCode: 200, headers: [], body: Data())
    }
}

private final class BYOMEvaluationLoopbackRuntime {
    let origin: String
    private let socketFD: Int32
    private let tagsBody: Data
    private let modelsBody: Data?
    private let chatStatusCode: Int
    private let chatHeaders: [(String, String)]
    private let chatBody: Data
    private let lock = NSLock()
    private var paths: [String] = []

    var requestPaths: [String] {
        lock.withLock { paths }
    }

    init(
        tagsBody: String,
        modelsBody: String? = nil,
        chatStatusCode: Int,
        chatHeaders: [(String, String)] = [],
        chatBody: String
    ) throws {
        self.tagsBody = Data(tagsBody.utf8)
        self.modelsBody = modelsBody.map { Data($0.utf8) }
        self.chatStatusCode = chatStatusCode
        self.chatHeaders = chatHeaders
        self.chatBody = Data(chatBody.utf8)

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        socketFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard Darwin.listen(fd, 2) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(fd, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        origin = "http://127.0.0.1:\(UInt16(bigEndian: bound.sin_port))"

        DispatchQueue.global(qos: .userInitiated).async { [weak self, fd] in
            for _ in 0..<2 {
                guard let self else { return }
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                self.handle(client)
            }
        }
    }

    deinit {
        Darwin.close(socketFD)
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        let request = String(decoding: buffer.prefix(count), as: UTF8.self)
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        record(path)
        if path == "/api/tags" {
            write(statusCode: 200, headers: [], body: tagsBody, to: client)
        } else if path == "/v1/models", let modelsBody {
            write(statusCode: 200, headers: [], body: modelsBody, to: client)
        } else {
            write(statusCode: chatStatusCode, headers: chatHeaders, body: chatBody, to: client)
        }
    }

    private func record(_ path: String) {
        lock.withLock {
            paths.append(path)
        }
    }

    private func write(statusCode: Int, headers: [(String, String)], body: Data, to client: Int32) {
        var responseHeaders = [
            "HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Found")",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        responseHeaders.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
        let head = responseHeaders.joined(separator: "\r\n") + "\r\n\r\n"
        _ = writeAll(Data(head.utf8), to: client)
        _ = writeAll(body, to: client)
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: sent), rawBuffer.count - sent)
                if result <= 0 {
                    return false
                }
                sent += result
            }
            return true
        }
    }
}

private struct BYOMEvaluationCapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureBYOMEvaluationOutput(_ body: () async throws -> Void) async -> BYOMEvaluationCapturedOutput {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let savedStdout = dup(STDOUT_FILENO)
    let savedStderr = dup(STDERR_FILENO)
    dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    let error: Error?
    do {
        try await body()
        error = nil
    } catch let caught {
        error = caught
    }

    fflush(stdout)
    fflush(stderr)
    dup2(savedStdout, STDOUT_FILENO)
    dup2(savedStderr, STDERR_FILENO)
    close(savedStdout)
    close(savedStderr)
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return BYOMEvaluationCapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
