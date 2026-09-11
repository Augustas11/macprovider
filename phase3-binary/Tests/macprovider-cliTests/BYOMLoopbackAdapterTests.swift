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

        XCTAssertEqual(hashed.readinessState, "ready")   // offerability needs a seeded namespace; covered in the state test

        let mlx = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "lmstudio:mlx-only-model" })
        XCTAssertEqual(mlx.identityState, "runtime_reported")
        let absent = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "lmstudio:not-on-disk" })
        XCTAssertEqual(absent.identityState, "runtime_reported")
        // Neither carried state: not proven serviceable, so not offerable.
        for c in [mlx, absent] {
            XCTAssertEqual(c.readinessState, "requires_preparation")
            XCTAssertTrue(c.warningCodes.contains("requires_preparation"))
        }

        // Seen on hardware: LM Studio's default embedding model is listed with
        // type "embedding"; it cannot serve chat and must not be a candidate.
        XCTAssertNil(document.candidates.first { $0.servedModelRef == "lmstudio:text-embedding-nomic-embed-text-v1.5" })
        XCTAssertEqual(document.candidates.filter { $0.runtimeSource == "lmstudio_loopback" }.count, 3)

        for candidate in document.candidates where candidate.runtimeSource == "lmstudio_loopback" {
            XCTAssertNotEqual(candidate.identityState, "opaque_endpoint")
            XCTAssertNotEqual(candidate.runtimeSource, "openai_compatible_loopback")
        }
    }

    /// Audit MEDIUM: a downloaded but unloaded LM Studio model must not be
    /// `ready`/`offerable`. Only the documented `loaded` state is serviceable;
    /// `not-loaded`, an unrecognized value, and an absent field all stay
    /// local-only until evaluate proves a completion.
    func testLMStudioOnlyALoadedModelIsReadyAndOfferable() async throws {
        let root = try temporaryDirectory("byom-lms-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try seededNamespace(in: root)
        let client = RoutingBYOMHTTPClient(routes: ["/api/v0/models": json(#"""
        {"data":[
          {"id":"is-loaded","type":"llm","compatibility_type":"gguf","state":"loaded"},
          {"id":"is-not-loaded","type":"llm","compatibility_type":"gguf","state":"not-loaded"},
          {"id":"is-weird","type":"llm","compatibility_type":"gguf","state":"defragmenting"},
          {"id":"has-no-state","type":"llm","compatibility_type":"gguf"}
        ]}
        """#)])
        let document = await BYOMDiscoveryRunner(environment: environment(root: root, namespace: namespace, lmstudio: "http://127.0.0.1:1234"), httpClient: client).discover()
        func c(_ id: String) throws -> BYOMDiscoveryWire.Candidate { try XCTUnwrap(document.candidates.first { $0.servedModelRef == "lmstudio:\(id)" }) }
        XCTAssertEqual(try c("is-loaded").readinessState, "ready")
        XCTAssertEqual(try c("is-loaded").admissionState, "offerable")
        for id in ["is-not-loaded", "is-weird", "has-no-state"] {
            XCTAssertEqual(try c(id).readinessState, "requires_preparation", id)
            XCTAssertEqual(try c(id).admissionState, "local_only", id)
        }
        // A non-string state is malformed, not silently ready.
        let bad = await BYOMDiscoveryRunner(environment: environment(root: root, lmstudio: "http://127.0.0.1:1234"), httpClient: RoutingBYOMHTTPClient(routes: ["/api/v0/models": json(#"{"data":[{"id":"x","type":"llm","state":true}]}"#)])).discover()
        XCTAssertEqual(bad.adapters.first { $0.runtimeSource == "lmstudio_loopback" }?.status, "malformed")
    }

    func testLMStudioFallsBackToV1ModelsOn404AndNothingFromItIsReady() async throws {
        let root = try temporaryDirectory("byom-lms-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RoutingBYOMHTTPClient(routes: [
            "/api/v0/models": BYOMHTTPResponse(statusCode: 404, headers: [], body: Data()),
            "/v1/models": json(#"{"data":[{"id":"legacy-model"}]}"#),
        ])
        let document = await BYOMDiscoveryRunner(environment: environment(root: root, lmstudio: "http://127.0.0.1:1234"), httpClient: client).discover()
        XCTAssertEqual(client.requestLog, ["GET http://127.0.0.1:1234/api/v0/models", "GET http://127.0.0.1:1234/v1/models"])
        let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "lmstudio_loopback" })
        XCTAssertEqual(adapter.status, "ok")
        let candidate = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "lmstudio:legacy-model" })
        XCTAssertEqual(candidate.readinessState, "requires_preparation")
        XCTAssertEqual(candidate.admissionState, "local_only")
        // Any other non-200 on the native endpoint is still 'unavailable', not a fallback.
        let down = await BYOMDiscoveryRunner(environment: environment(root: root, lmstudio: "http://127.0.0.1:1234"), httpClient: RoutingBYOMHTTPClient(routes: ["/api/v0/models": BYOMHTTPResponse(statusCode: 503, headers: [], body: Data())])).discover()
        XCTAssertEqual(down.adapters.first { $0.runtimeSource == "lmstudio_loopback" }?.status, "unavailable")
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

    /// PR #1480 audit (HIGH): the served path is PROOF. A same-stem file under
    /// the operator root must NOT be hashed on behalf of a different file the
    /// runtime is actually serving. And a filesystem path must never reach
    /// the wire in any of these outcomes.
    func testLlamaCppSameStemFileUnderRootIsNotHashedForAFileServedElsewhere() async throws {
        let root = try temporaryDirectory("byom-llamacpp-samestem")
        defer { try? FileManager.default.removeItem(at: root) }
        let operatorRoot = root.appendingPathComponent("allowed", isDirectory: true)
        let decoy = operatorRoot.appendingPathComponent("tiny-q4.gguf")
        try write(ggufBytes, to: decoy)
        let servedElsewhere = "/Users/someone/private-models/tiny-q4.gguf"
        let routes = [
            "/props": json(#"{"default_generation_settings":{"n_ctx":8192},"total_slots":1,"model_path":"\#(servedElsewhere)"}"#),
            "/v1/models": json(#"{"data":[{"id":"\#(servedElsewhere)"}]}"#),
        ]
        let env = environment(root: root, llamacpp: "http://127.0.0.1:8080", llamacppModelRoot: operatorRoot)

        // Even a digest already cached for the decoy must not be read back.
        _ = try? env.artifactDigests.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: decoy.path)
        let document = await BYOMDiscoveryRunner(environment: env, httpClient: RoutingBYOMHTTPClient(routes: routes)).discover()
        let candidate = try XCTUnwrap(document.candidates.first { $0.runtimeSource == "llamacpp_loopback" })
        XCTAssertEqual(candidate.servedModelRef, "llamacpp:tiny-q4")
        XCTAssertEqual(candidate.identityState, "runtime_reported", "a same-stem decoy under the root was hashed for a file served elsewhere")
        XCTAssertEqual(candidate.contextWindowTokens, 8192)
        let encoded = try ModelSwitchingWireCodec.encode(document)
        XCTAssertFalse(encoded.contains(servedElsewhere)); XCTAssertFalse(encoded.contains("/Users/"))
        XCTAssertFalse(encoded.contains(operatorRoot.path))

        // Evaluate/offer-time binding refuses the same way.
        XCTAssertThrowsError(try env.artifactDigests.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: servedElsewhere)) {
            XCTAssertEqual($0 as? BYOMArtifactDigestError, .unresolvedBlob)
        }
    }

    func testLlamaCppIsHashedOnlyWhenTheServedPathIsTheRootResolvedFile() async throws {
        let root = try temporaryDirectory("byom-llamacpp-bound")
        defer { try? FileManager.default.removeItem(at: root) }
        let operatorRoot = root.appendingPathComponent("allowed", isDirectory: true)
        let served = operatorRoot.appendingPathComponent("tiny-q4.gguf")
        try write(ggufBytes, to: served)
        let servedPath = served.resolvingSymlinksInPath().standardizedFileURL.path
        let routes = [
            "/props": json(#"{"default_generation_settings":{"n_ctx":4096},"total_slots":1,"model_path":"\#(servedPath)"}"#),
            "/v1/models": json(#"{"data":[{"id":"\#(servedPath)"}]}"#),
        ]
        let env = environment(root: root, llamacpp: "http://127.0.0.1:8080", llamacppModelRoot: operatorRoot)
        let evidence = try env.artifactDigests.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: servedPath)
        XCTAssertEqual(evidence.locatorDigest, "tiny-q4.gguf")

        let document = await BYOMDiscoveryRunner(environment: env, httpClient: RoutingBYOMHTTPClient(routes: routes)).discover()
        let candidate = try XCTUnwrap(document.candidates.first { $0.runtimeSource == "llamacpp_loopback" })
        XCTAssertEqual(candidate.identityState, "artifact_hash_available")
        XCTAssertNotEqual(candidate.identityState, "opaque_endpoint")
        let encoded = try ModelSwitchingWireCodec.encode(document)
        XCTAssertFalse(encoded.contains(servedPath), "served path leaked to the wire")

        // The binding is re-checked against what the runtime serves NOW: a
        // different served path fails closed even though the file is unchanged.
        XCTAssertThrowsError(try env.artifactDigests.validateCurrent(evidence, runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: "/somewhere/else/tiny-q4.gguf")) {
            XCTAssertEqual($0 as? BYOMArtifactDigestError, .fileIdentityChanged)
        }
        XCTAssertNoThrow(try env.artifactDigests.validateCurrent(evidence, runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: servedPath))
    }

    func testLlamaCppWithoutAServedPathOrWithAStemMismatchHasNoArtifactLeg() async throws {
        let root = try temporaryDirectory("byom-llamacpp-noproof")
        defer { try? FileManager.default.removeItem(at: root) }
        let operatorRoot = root.appendingPathComponent("allowed", isDirectory: true)
        let file = operatorRoot.appendingPathComponent("tiny-q4.gguf")
        try write(ggufBytes, to: file)
        let env = environment(root: root, llamacpp: "http://127.0.0.1:8080", llamacppModelRoot: operatorRoot)
        let store = BYOMLlamaCppModelStore(root: operatorRoot)
        // No served path, a relative one, or one whose stem disagrees with the served id: no proof, no identity.
        XCTAssertNil(store.resolveArtifact(servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: nil))
        XCTAssertNil(store.resolveArtifact(servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: "models/tiny-q4.gguf"))
        XCTAssertNil(store.resolveArtifact(servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: operatorRoot.appendingPathComponent("other.gguf").path))
        // A /props without model_path (older llama-server) still fingerprints, but yields runtime_reported.
        let document = await BYOMDiscoveryRunner(environment: env, httpClient: RoutingBYOMHTTPClient(routes: [
            "/props": json(#"{"default_generation_settings":{"n_ctx":2048}}"#),
            "/v1/models": json(#"{"data":[{"id":"tiny-q4"}]}"#),
        ])).discover()
        XCTAssertEqual(document.candidates.first { $0.runtimeSource == "llamacpp_loopback" }?.identityState, "runtime_reported")
    }

    func testLlamaCppStoreRejectsSymlinkEscapeAndNilRoot() throws {
        let root = try temporaryDirectory("byom-llamacpp-escape")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside/real.gguf")
        try write(ggufBytes, to: outside)
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("real.gguf"), withDestinationURL: outside)

        let servedLink = allowed.appendingPathComponent("real.gguf").path
        XCTAssertNil(BYOMLlamaCppModelStore(root: allowed).resolveArtifact(servedModelRef: "llamacpp:real", runtimeArtifactPath: servedLink), "symlink escaped the operator root")
        XCTAssertNil(BYOMLlamaCppModelStore(root: nil).resolveArtifact(servedModelRef: "llamacpp:real", runtimeArtifactPath: outside.path), "nil root resolved a file")
        XCTAssertEqual(BYOMLlamaCppModelStore.stem(fromRuntimeModelID: "/x/y/Model-Q4_K_M.GGUF"), "Model-Q4_K_M")
        XCTAssertEqual(BYOMLlamaCppModelStore.stem(fromRuntimeModelID: "my-alias"), "my-alias")
    }

    func testLlamaCppPinnedFileResolvesOnlyThatFileAndOverridesTheRoot() throws {
        let root = try temporaryDirectory("byom-llamacpp-pinned")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let pinned = root.appendingPathComponent("elsewhere/tiny-q4.gguf")
        let decoy = allowed.appendingPathComponent("tiny-q4.gguf")
        try write(ggufBytes, to: pinned)
        try write(ggufBytes + Data([0x01]), to: decoy)

        let pinnedPath = pinned.resolvingSymlinksInPath().standardizedFileURL.path
        let decoyPath = decoy.resolvingSymlinksInPath().standardizedFileURL.path
        // (c): the pinned file resolves only when the runtime serves exactly it.
        let both = BYOMLlamaCppModelStore(root: allowed, pinnedFile: pinned)
        let hit = try XCTUnwrap(both.resolveArtifact(servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: pinnedPath))
        XCTAssertEqual(hit.fileURL.path, pinnedPath)
        XCTAssertEqual(hit.locator, pinnedPath)
        // Same stem, different served file (the root's decoy): the pin does not apply, and the root is not consulted. No identity.
        XCTAssertNil(both.resolveArtifact(servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: decoyPath), "pinned mode hashed a same-stem file the operator did not pin")
        // The runtime serving a DIFFERENT stem than the operator pinned gets no identity, not a wrong one.
        XCTAssertNil(both.resolveArtifact(servedModelRef: "llamacpp:other-model", runtimeArtifactPath: pinnedPath))
        // A pinned path that is not a regular GGUF resolves nothing.
        XCTAssertNil(BYOMLlamaCppModelStore(root: nil, pinnedFile: root.appendingPathComponent("missing.gguf")).resolveArtifact(servedModelRef: "llamacpp:missing", runtimeArtifactPath: root.appendingPathComponent("missing.gguf").path))
        // No root is needed in (c).
        XCTAssertNotNil(BYOMLlamaCppModelStore(root: nil, pinnedFile: pinned).resolveArtifact(servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: pinnedPath))
    }

    func testLlamaCppPinnedFileDrivesArtifactHashAvailableThroughDiscovery() async throws {
        let root = try temporaryDirectory("byom-llamacpp-pinned-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = root.appendingPathComponent("models/tiny-q4.gguf")
        try write(ggufBytes, to: pinned)
        let env = BYOMDiscoveryEnvironment(
            namespaceURL: root.appendingPathComponent("ns"),
            mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
            ollamaOrigin: nil,
            llamacppOrigin: "http://127.0.0.1:8080",
            ollamaModelsRoot: root.appendingPathComponent("ollama", isDirectory: true),
            lmstudioModelsRoot: root.appendingPathComponent("lms", isDirectory: true),
            llamacppModelRoot: nil,
            llamacppModelPath: pinned,
            artifactDigestCacheURL: root.appendingPathComponent("digests.json")
        )
        let pinnedPath = pinned.resolvingSymlinksInPath().standardizedFileURL.path
        _ = try env.artifactDigests.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: pinnedPath)
        let document = await BYOMDiscoveryRunner(environment: env, httpClient: RoutingBYOMHTTPClient(routes: [
            "/props": json(#"{"default_generation_settings":{"n_ctx":4096},"model_path":"\#(pinnedPath)"}"#),
            "/v1/models": json(#"{"data":[{"id":"\#(pinnedPath)"}]}"#),
        ])).discover()
        let candidate = try XCTUnwrap(document.candidates.first { $0.runtimeSource == "llamacpp_loopback" })
        XCTAssertEqual(candidate.identityState, "artifact_hash_available")
        XCTAssertFalse(try ModelSwitchingWireCodec.encode(document).contains(pinnedPath), "pinned path leaked to the wire")
    }

    // MARK: - llama.cpp selector precedence (audit MEDIUM)

    func testLlamaCppSelectorIsDecidedOnceFromOneSource() throws {
        typealias S = BYOMLlamaCppArtifactSelector
        let env = ["MACPROVIDER_LLAMACPP_MODEL_ROOT": "/env/root", "MACPROVIDER_LLAMACPP_MODEL_PATH": "/env/pin.gguf"]

        // An explicit CLI root ignores BOTH environment selectors: the inherited pin cannot defeat it.
        let cliRoot = try S.resolve(cliRoot: "/cli/root", cliPath: nil, environment: env)
        XCTAssertEqual(cliRoot.root?.path, "/cli/root"); XCTAssertNil(cliRoot.pinnedFile)
        let cliPath = try S.resolve(cliRoot: nil, cliPath: "/cli/pin.gguf", environment: env)
        XCTAssertNil(cliPath.root); XCTAssertEqual(cliPath.pinnedFile?.path, "/cli/pin.gguf")

        // Two selectors from the same source are an error, not a precedence rule.
        XCTAssertThrowsError(try S.resolve(cliRoot: "/a", cliPath: "/b.gguf", environment: [:])) {
            XCTAssertEqual($0 as? S.SelectionError, .conflictingCLISelectors)
        }
        XCTAssertThrowsError(try S.resolve(cliRoot: nil, cliPath: nil, environment: env)) {
            XCTAssertEqual($0 as? S.SelectionError, .conflictingEnvironmentSelectors)
        }

        // Environment is honoured only when the CLI says nothing; blank strings count as nothing.
        XCTAssertEqual(try S.resolve(cliRoot: "  ", cliPath: nil, environment: ["MACPROVIDER_LLAMACPP_MODEL_ROOT": "/env/root"]).root?.path, "/env/root")
        XCTAssertEqual(try S.resolve(cliRoot: nil, cliPath: nil, environment: [:]), .none)
    }

    func testLlamaCppEnvironmentPinCannotDefeatAnExplicitCLIRootEndToEnd() throws {
        let root = try temporaryDirectory("byom-llamacpp-precedence")
        defer { try? FileManager.default.removeItem(at: root) }
        let approved = root.appendingPathComponent("approved", isDirectory: true)
        let approvedFile = approved.appendingPathComponent("tiny-q4.gguf")
        let rogue = root.appendingPathComponent("rogue/tiny-q4.gguf")
        try write(ggufBytes, to: approvedFile); try write(ggufBytes, to: rogue)
        let env = BYOMDiscoveryEnvironment.production(
            namespacePath: root.appendingPathComponent("ns").path,
            mlxCacheDir: root.appendingPathComponent("hf").path,
            ollamaOrigin: nil,
            llamacppOrigin: "http://127.0.0.1:8080",
            llamacppSelector: try BYOMLlamaCppArtifactSelector.resolve(cliRoot: approved.path, cliPath: nil, environment: ["MACPROVIDER_LLAMACPP_MODEL_PATH": rogue.path]),
            homeDirectory: root
        )
        XCTAssertNil(env.llamacppModelPath, "the inherited pin leaked into the environment despite an explicit CLI root")
        XCTAssertEqual(env.llamacppModelRoot?.path, approved.path)
        // The rogue file, served by the runtime, is outside the approved root: no identity.
        XCTAssertThrowsError(try env.artifactDigests.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: rogue.resolvingSymlinksInPath().path))
        // The approved file, served by the runtime, hashes.
        XCTAssertNoThrow(try env.artifactDigests.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:tiny-q4", runtimeArtifactPath: approvedFile.resolvingSymlinksInPath().path))
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
            httpClient: RoutingBYOMHTTPClient(routes: ["/api/v0/models": json(#"{"data":[{"id":"tiny-1b-q4_k_m","compatibility_type":"gguf","state":"loaded"}]}"#)])
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
