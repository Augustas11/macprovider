import Foundation
import XCTest
@testable import macprovider_cli

/// #1478: `lmstudio_loopback` and `llamacpp_loopback` are thin copies of the
/// Ollama adapter over the #1246 harness, with a CLI-side GGUF artifact leg.
/// These tests cover the scope items the issue names — non-loopback rejected
/// before dispatch, skip ⇒ no adapter row, hashed vs opaque identity, dry-run
/// claims no settlement — plus the two properties that make the artifact leg
/// evidence rather than a claim: the runtime never chooses the hashed file,
/// and a filesystem path never reaches the wire.
final class BYOMLoopbackAdapterTests: XCTestCase {
    private let ggufBytes = Data("GGUF".utf8) + Data(repeating: 0x5c, count: 8192)

    // MARK: - Non-loopback rejected before dispatch (SPEC-046-R002)

    func testLMStudioRejectsNonLoopbackOriginBeforeDispatch() async throws {
        let root = try temporaryDirectory("byom-lms-reject")
        defer { try? FileManager.default.removeItem(at: root) }
        for origin in ["http://0.0.0.0:1234", "http://192.168.1.10:1234", "http://localhost:1234", "https://127.0.0.1:1234"] {
            let client = RoutingBYOMHTTPClient()
            let document = await BYOMDiscoveryRunner(
                environment: environment(root: root, lmstudio: origin),
                httpClient: client
            ).discover()
            XCTAssertEqual(client.requestLog, [], "dispatched a request for \(origin)")
            let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "lmstudio_loopback" })
            XCTAssertEqual(adapter.status, "rejected")
            XCTAssertEqual(adapter.warningCodes, ["adapter_rejected_non_loopback"])
            XCTAssertTrue(document.candidates.isEmpty)
            XCTAssertFalse(try ModelSwitchingWireCodec.encode(document).contains(origin), "rejection leaked \(origin)")
        }
    }

    func testLlamaCppRejectsNonLoopbackOriginBeforeDispatch() async throws {
        let root = try temporaryDirectory("byom-llamacpp-reject")
        defer { try? FileManager.default.removeItem(at: root) }
        for origin in ["http://0.0.0.0:8080", "http://10.0.0.5:8080", "http://localhost:8080", "https://127.0.0.1:8080"] {
            let client = RoutingBYOMHTTPClient()
            let document = await BYOMDiscoveryRunner(
                environment: environment(root: root, llamacpp: origin),
                httpClient: client
            ).discover()
            XCTAssertEqual(client.requestLog, [], "dispatched a request for \(origin)")
            let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "llamacpp_loopback" })
            XCTAssertEqual(adapter.status, "rejected")
            XCTAssertTrue(document.candidates.isEmpty)
        }
    }

    // MARK: - Skip ⇒ no adapter row, zero requests

    func testSkippedAdaptersLeaveNoRowAndDispatchNothing() async throws {
        let root = try temporaryDirectory("byom-skip")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RoutingBYOMHTTPClient()
        let document = await BYOMDiscoveryRunner(
            environment: environment(root: root, lmstudio: nil, llamacpp: nil),
            httpClient: client
        ).discover()
        XCTAssertEqual(client.requestLog, [])
        XCTAssertFalse(document.adapters.contains { $0.runtimeSource == "lmstudio_loopback" })
        XCTAssertFalse(document.adapters.contains { $0.runtimeSource == "llamacpp_loopback" })
    }

    // MARK: - LM Studio: hashed vs runtime_reported, never opaque

    func testLMStudioIdentityIsHashedOnlyForAResolvableGGUFAndNeverOpaque() async throws {
        let root = try temporaryDirectory("byom-lms-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("lmstudio-models", isDirectory: true)
        try write(ggufBytes, to: models.appendingPathComponent("lmstudio-community/Tiny-1B-GGUF/tiny-1b-q4_k_m.gguf"))
        let env = environment(root: root, lmstudio: "http://127.0.0.1:1234", lmstudioModelsRoot: models)

        // evaluate/offer computes the digest; discovery only reads it back.
        let seeded = try env.artifactDigests.computeEvidence(runtimeSource: "lmstudio_loopback", servedModelRef: "lmstudio:tiny-1b-q4_k_m")
        XCTAssertEqual(seeded.locatorDigest, "lmstudio-community/Tiny-1B-GGUF/tiny-1b-q4_k_m.gguf")

        let client = RoutingBYOMHTTPClient(routes: [
            "/api/v0/models": json(#"""
            {"data":[
              {"id":"tiny-1b-q4_k_m","type":"llm","publisher":"lmstudio-community","arch":"llama","compatibility_type":"gguf","quantization":"Q4_K_M","state":"loaded","max_context_length":4096},
              {"id":"mlx-only-model","type":"llm","compatibility_type":"mlx"},
              {"id":"not-on-disk","type":"llm","compatibility_type":"gguf"},
              {"id":"text-embedding-nomic-embed-text-v1.5","type":"embedding","compatibility_type":"gguf"}
            ]}
            """#),
        ])
        let document = await BYOMDiscoveryRunner(environment: env, httpClient: client).discover()
        XCTAssertEqual(client.requestLog, ["GET http://127.0.0.1:1234/api/v0/models"])

        let hashed = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "lmstudio:tiny-1b-q4_k_m" })
        XCTAssertEqual(hashed.runtimeSource, "lmstudio_loopback")
        XCTAssertEqual(hashed.identityState, "artifact_hash_available")
        XCTAssertEqual(hashed.contextWindowTokens, 4096)
        XCTAssertEqual(hashed.capabilities.quantization, "Q4_K_M")
        XCTAssertEqual(hashed.capabilities.family, "llama")

        let mlx = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "lmstudio:mlx-only-model" })
        XCTAssertEqual(mlx.identityState, "runtime_reported")
        let absent = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "lmstudio:not-on-disk" })
        XCTAssertEqual(absent.identityState, "runtime_reported")

        // Seen on hardware: LM Studio's default embedding model is listed with
        // type "embedding"; it cannot serve chat and must not be a candidate.
        XCTAssertNil(document.candidates.first { $0.servedModelRef == "lmstudio:text-embedding-nomic-embed-text-v1.5" })
        XCTAssertEqual(document.candidates.filter { $0.runtimeSource == "lmstudio_loopback" }.count, 3)

        for candidate in document.candidates where candidate.runtimeSource == "lmstudio_loopback" {
            XCTAssertNotEqual(candidate.identityState, "opaque_endpoint")
            XCTAssertNotEqual(candidate.runtimeSource, "openai_compatible_loopback")
        }
    }

    func testLMStudioStoreFailsClosedWhenSeveralFilesAnswerTheID() throws {
        let root = try temporaryDirectory("byom-lms-ambiguous")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("m", isDirectory: true)
        try write(ggufBytes, to: models.appendingPathComponent("pub/Tiny-GGUF/tiny-q4.gguf"))
        try write(ggufBytes, to: models.appendingPathComponent("pub/Tiny-GGUF/tiny-q8.gguf"))
        let store = BYOMLMStudioModelStore(root: models)
        // The repo name answers both quantizations: ambiguous, no identity.
        XCTAssertNil(store.resolveArtifact(servedModelRef: "lmstudio:tiny"))
        XCTAssertNil(store.resolveArtifact(servedModelRef: "lmstudio:Tiny-GGUF"))
        // A file stem answers exactly one.
        XCTAssertEqual(store.resolveArtifact(servedModelRef: "lmstudio:tiny-q8")?.locator, "pub/Tiny-GGUF/tiny-q8.gguf")
    }

    // MARK: - llama.cpp: fingerprint, stem-not-path, operator root

    func testLlamaCppRequiresThePropsFingerprintBeforeTrustingInventory() async throws {
        let root = try temporaryDirectory("byom-llamacpp-fingerprint")
        defer { try? FileManager.default.removeItem(at: root) }
        // A server on :8080 that answers /v1/models but is NOT llama-server —
        // exactly what macprovider's own serve looks like on a provider Mac.
        for props in [
            BYOMHTTPResponse(statusCode: 404, headers: [], body: Data("not found".utf8)),
            json(#"{"provider_id":"mp-abc","model":"llama-3.2-3b"}"#),
        ] {
            let client = RoutingBYOMHTTPClient(routes: [
                "/props": props,
                "/v1/models": json(#"{"data":[{"id":"/Users/someone/models/served-by-macprovider.gguf"}]}"#),
            ])
            let document = await BYOMDiscoveryRunner(
                environment: environment(root: root, llamacpp: "http://127.0.0.1:8080"),
                httpClient: client
            ).discover()
            let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "llamacpp_loopback" })
            XCTAssertEqual(adapter.status, "unavailable")
            XCTAssertTrue(document.candidates.isEmpty, "a non-llama.cpp server produced a candidate")
            XCTAssertEqual(client.requestLog, ["GET http://127.0.0.1:8080/props"], "inventory was fetched before the fingerprint passed")
        }
    }

    func testLlamaCppPathIDBecomesAStemAndResolvesOnlyUnderTheOperatorRoot() async throws {
        let root = try temporaryDirectory("byom-llamacpp-stem")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretDir = "/Users/someone/private-models"
        let routes = [
            "/props": json(#"{"default_generation_settings":{"n_ctx":8192},"total_slots":1,"model_path":"\#(secretDir)/tiny-q4.gguf"}"#),
            "/v1/models": json(#"{"data":[{"id":"\#(secretDir)/tiny-q4.gguf"}]}"#),
        ]

        // No operator root: the runtime's path is not adopted; runtime_reported.
        var document = await BYOMDiscoveryRunner(
            environment: environment(root: root, llamacpp: "http://127.0.0.1:8080", llamacppModelRoot: nil),
            httpClient: RoutingBYOMHTTPClient(routes: routes)
        ).discover()
        var candidate = try XCTUnwrap(document.candidates.first { $0.runtimeSource == "llamacpp_loopback" })
        XCTAssertEqual(candidate.servedModelRef, "llamacpp:tiny-q4")
        XCTAssertEqual(candidate.identityState, "runtime_reported")
        XCTAssertEqual(candidate.contextWindowTokens, 8192)
        var encoded = try ModelSwitchingWireCodec.encode(document)
        XCTAssertFalse(encoded.contains(secretDir), "runtime path leaked to the wire")
        XCTAssertFalse(encoded.contains("/Users/"), "a filesystem path leaked to the wire")

        // Operator root containing the file: the stem resolves there, the CLI
        // hashes it, and discovery reports the digest as available.
        let operatorRoot = root.appendingPathComponent("allowed", isDirectory: true)
        try write(ggufBytes, to: operatorRoot.appendingPathComponent("tiny-q4.gguf"))
        let env = environment(root: root, llamacpp: "http://127.0.0.1:8080", llamacppModelRoot: operatorRoot)
        let evidence = try env.artifactDigests.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4")
        XCTAssertEqual(evidence.locatorDigest, "tiny-q4.gguf")
        document = await BYOMDiscoveryRunner(environment: env, httpClient: RoutingBYOMHTTPClient(routes: routes)).discover()
        candidate = try XCTUnwrap(document.candidates.first { $0.runtimeSource == "llamacpp_loopback" })
        XCTAssertEqual(candidate.identityState, "artifact_hash_available")
        XCTAssertNotEqual(candidate.identityState, "opaque_endpoint")
        encoded = try ModelSwitchingWireCodec.encode(document)
        XCTAssertFalse(encoded.contains(secretDir))
    }

    func testLlamaCppStoreRejectsSymlinkEscapeAndNilRoot() throws {
        let root = try temporaryDirectory("byom-llamacpp-escape")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside/real.gguf")
        try write(ggufBytes, to: outside)
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("real.gguf"), withDestinationURL: outside)

        XCTAssertNil(BYOMLlamaCppModelStore(root: allowed).resolveArtifact(servedModelRef: "llamacpp:real"), "symlink escaped the operator root")
        XCTAssertNil(BYOMLlamaCppModelStore(root: nil).resolveArtifact(servedModelRef: "llamacpp:real"), "nil root resolved a file")
        XCTAssertEqual(BYOMLlamaCppModelStore.stem(fromRuntimeModelID: "/x/y/Model-Q4_K_M.GGUF"), "Model-Q4_K_M")
        XCTAssertEqual(BYOMLlamaCppModelStore.stem(fromRuntimeModelID: "my-alias"), "my-alias")
    }

    // MARK: - Failure classes map to closed warning codes

    func testMalformedInventoryEmitsWarningNotCandidate() async throws {
        let root = try temporaryDirectory("byom-malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let lms = await BYOMDiscoveryRunner(
            environment: environment(root: root, lmstudio: "http://127.0.0.1:1234"),
            httpClient: RoutingBYOMHTTPClient(routes: ["/api/v0/models": json(#"{"data":[{"no_id":true}]}"#)])
        ).discover()
        XCTAssertEqual(lms.adapters.first { $0.runtimeSource == "lmstudio_loopback" }?.status, "malformed")
        XCTAssertTrue(lms.candidates.isEmpty)

        let llama = await BYOMDiscoveryRunner(
            environment: environment(root: root, llamacpp: "http://127.0.0.1:8080"),
            httpClient: RoutingBYOMHTTPClient(routes: [
                "/props": json(#"{"default_generation_settings":{}}"#),
                "/v1/models": json(#"not json"#),
            ])
        ).discover()
        XCTAssertEqual(llama.adapters.first { $0.runtimeSource == "llamacpp_loopback" }?.status, "malformed")
        XCTAssertTrue(llama.candidates.isEmpty)
    }

    // MARK: - Offer dry-run claims no settlement (out of scope until #1453 slice 7)

    func testOfferDryRunClaimsNoSettlementForEitherAdapter() async throws {
        let root = try temporaryDirectory("byom-dryrun")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try seededNamespace(in: root)

        let lms = await BYOMOfferDryRunRunner(
            target: "lmstudio:tiny-1b-q4_k_m",
            environment: environment(root: root, namespace: namespace, lmstudio: "http://127.0.0.1:1234"),
            httpClient: RoutingBYOMHTTPClient(routes: ["/api/v0/models": json(#"{"data":[{"id":"tiny-1b-q4_k_m","compatibility_type":"gguf"}]}"#)])
        ).dryRun()
        XCTAssertEqual(lms.servedModelRef, "lmstudio:tiny-1b-q4_k_m")
        // A hashed GGUF candidate is first-class and MAY be offered (unlike the
        // opaque adapter, which submit refuses). What it must never do is
        // claim earning: no catalog match here, so no trusted binding, so the
        // likely state is offer-level and the guidance names no earning path.
        XCTAssertNil(lms.catalogModelKey)
        XCTAssertNotEqual(lms.likelyAdmissionState, "settlement_capable")
        XCTAssertNotEqual(lms.likelyAdmissionState, "catalog_priced")
        XCTAssertEqual(lms.providerGuidance.earningPathClass, "no_earning_path_in_v0_1")

        let llama = await BYOMOfferDryRunRunner(
            target: "llamacpp:tiny-q4",
            environment: environment(root: root, namespace: namespace, llamacpp: "http://127.0.0.1:8080"),
            httpClient: RoutingBYOMHTTPClient(routes: [
                "/props": json(#"{"default_generation_settings":{"n_ctx":4096}}"#),
                "/v1/models": json(#"{"data":[{"id":"/m/tiny-q4.gguf"}]}"#),
            ])
        ).dryRun()
        XCTAssertEqual(llama.servedModelRef, "llamacpp:tiny-q4")
        XCTAssertNil(llama.catalogModelKey)
        XCTAssertNotEqual(llama.likelyAdmissionState, "settlement_capable")
        XCTAssertNotEqual(llama.likelyAdmissionState, "catalog_priced")
        XCTAssertEqual(llama.providerGuidance.earningPathClass, "no_earning_path_in_v0_1")
    }

    // MARK: - Helpers

    private func environment(
        root: URL,
        namespace: URL? = nil,
        lmstudio: String? = nil,
        llamacpp: String? = nil,
        lmstudioModelsRoot: URL? = nil,
        llamacppModelRoot: URL? = nil
    ) -> BYOMDiscoveryEnvironment {
        BYOMDiscoveryEnvironment(
            namespaceURL: namespace ?? root.appendingPathComponent("ns"),
            mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
            ollamaOrigin: nil,
            lmstudioOrigin: lmstudio,
            llamacppOrigin: llamacpp,
            ollamaModelsRoot: root.appendingPathComponent("ollama", isDirectory: true),
            lmstudioModelsRoot: lmstudioModelsRoot ?? root.appendingPathComponent("lmstudio-empty", isDirectory: true),
            llamacppModelRoot: llamacppModelRoot,
            artifactDigestCacheURL: root.appendingPathComponent("digests.json")
        )
    }

    private func json(_ body: String) -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 200, headers: [("content-type", "application/json")], body: Data(body.utf8))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func seededNamespace(in root: URL) throws -> URL {
        let dir = root.appendingPathComponent("byom", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let namespace = dir.appendingPathComponent("local_discovery_namespace")
        try Data(repeating: 0x42, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namespace.path)
        return namespace
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Hermetic client that answers by URL path suffix and records every request,
/// so a test can assert both what was dispatched and in what order (the
/// llama.cpp adapter must fingerprint before it fetches inventory).
private final class RoutingBYOMHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let routes: [String: BYOMHTTPResponse]

    var requestLog: [String] { lock.withLock { log } }

    init(routes: [String: BYOMHTTPResponse] = [:]) {
        self.routes = routes
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock { log.append("GET \(url.absoluteString)") }
        if let hit = routes.first(where: { url.path.hasSuffix($0.key) })?.value {
            return hit
        }
        return BYOMHTTPResponse(statusCode: 404, headers: [], body: Data())
    }
}
