import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// Issue #1695 shared fixtures: runtimes that must never sign a SPEC-015
/// receipt, driven through the real relay and HTTP receipt paths.
enum ReceiptEligibilityFixtures {
    static let ollamaServedRef = "ollama:gemma3:270m"
    static let fixtureModel = "relay-blind-fixture-model"

    struct LoopbackRuntime {
        let runtime: OpenAICompatibleLoopbackRuntime
        let blobURL: URL
        let digest: String
    }

    /// A real `OpenAICompatibleLoopbackRuntime` over a fake Ollama store and a stubbed
    /// loopback upstream, so its snapshot carries a genuine GGUF digest.
    static func makeOllamaLoopbackRuntime(
        testCase: XCTestCase,
        content: String = "ok"
    ) throws -> LoopbackRuntime {
        let blob = Data("GGUF".utf8) + Data(repeating: 0xab, count: 4096)
        let digest = Data(SHA256.hash(data: blob)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-eligibility-\(UUID().uuidString)")
        let blobURL = root.appendingPathComponent("blobs/sha256-\(digest)")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: blobURL)
        let manifestURL = root.appendingPathComponent("manifests/registry.ollama.ai/library/gemma3/270m")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = """
        {"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:\(String(repeating: "0", count: 64))","size":1},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\(digest)","size":\(blob.count)}]}
        """
        try Data(manifest.utf8).write(to: manifestURL)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let upstream = Data("""
        {"id":"chatcmpl-x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":2,"total_tokens":11}}
        """.utf8)
        let runtime = try OpenAICompatibleLoopbackRuntime(
            servedModelRef: ollamaServedRef,
            origin: "http://127.0.0.1:11434",
            httpClient: ReceiptEligibilityStubLoopbackClient(responseBody: upstream),
            digestResolver: BYOMArtifactDigestResolver(
                store: BYOMOllamaModelStore(root: root),
                cache: BYOMArtifactDigestCache(url: root.appendingPathComponent("cache/artifact-digests.json"))
            )
        )
        return LoopbackRuntime(runtime: runtime, blobURL: blobURL, digest: digest)
    }

    static func makeRelayBlindFixtureRuntime() -> RelayBlindFixtureRuntime {
        RelayBlindFixtureRuntime(model: fixtureModel, streamDelayMs: 0)
    }

    /// v0.4 settlement metadata that is otherwise fully receipt-eligible for
    /// the given request, so an omission can only come from the runtime gate.
    static func settlementMetadataWire(
        requestID: String,
        providerID: String,
        modelID: String,
        receiptKeyID: String,
        expectedModelHash: String
    ) -> [String: Any] {
        [
            "account_scope": "acct_sha256:" + String(repeating: "1", count: 64),
            "request_id": requestID,
            "attempt_n": 0,
            "provider_id": providerID,
            "provider_receipt_key_id": receiptKeyID,
            "model_id": modelID,
            "expected_catalog_model_hash": expectedModelHash,
            "catalog_id": "catalog-a",
            "catalog_body_digest": String(repeating: "2", count: 64),
            "route_snapshot_digest": String(repeating: "3", count: 64),
            "route_snapshot_policy_version": "spec022-prereq-v0",
            "route_snapshot_mode": "observe",
            "prompt_hash": String(repeating: "4", count: 64),
            "output_prefix_start_byte": 0,
            "pending_deadline_seconds": 120,
        ]
    }

    /// SPEC-015 §N.12 (#1690 M5): a well-formed `pool_runtime_authorization`
    /// bound to `settlementMetadataWire`'s attempt and route snapshot.
    static func poolRuntimeAuthorizationWire(
        runtimeSource: String,
        requestID: String,
        providerID: String,
        attemptN: Int = 0,
        routeSnapshotDigest: String = String(repeating: "3", count: 64)
    ) -> [String: Any] {
        [
            "pool_id": "pool-lab-1",
            "manifest_core_digest": String(repeating: "6", count: 64),
            "runtime_source": runtimeSource,
            "request_id": requestID,
            "attempt_n": attemptN,
            "provider_id": providerID,
            "route_snapshot_digest": routeSnapshotDigest,
        ]
    }

    static func receiptKeyID(_ pubkey: Data) -> String {
        "ed25519-sha256:" + SHA256.hash(data: pubkey).map { String(format: "%02x", $0) }.joined()
    }

    static func omittedReasons(_ records: [Data]) -> [String] {
        records.compactMap { record in
            let line = String(decoding: record, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == "receipt_omitted" else { return nil }
            return object["reason"] as? String
        }
    }
}

final class ReceiptEligibilityAuditRecorder: @unchecked Sendable {
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

final class ReceiptEligibilityStubLoopbackClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let responseBody: Data

    init(responseBody: Data) {
        self.responseBody = responseBody
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 200, headers: [], body: responseBody)
    }
}
