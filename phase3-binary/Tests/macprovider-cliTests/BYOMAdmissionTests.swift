import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class BYOMAdmissionTests: XCTestCase {
    override func tearDown() {
        BYOMAdmissionMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testOfferCommandRequiresExplicitYesForCoordinatorMutation() async throws {
        let command = try ModelsOfferCommand.parse([
            "ollama:tiny-offer-1b-q4",
            "--json",
            "--skip-ollama",
            "--skip-lmstudio",
            "--coordinator-url", "wss://coordinator.example/ws/provider",
            "--provider-id", "provider-byom-a",
        ])
        let capture = await captureBYOMAdmissionOutput {
            try await command.run()
        }

        XCTAssertFalse(command.yes)
        XCTAssertEqual((capture.error as? ExitCode), ExitCode(2))
    }

    func testOfferSubmissionPackageBindsAdmissionIdentityAndCandidate() throws {
        let identity = Curve25519.Signing.PrivateKey()
        let candidate = byomAdmissionCandidate(
            candidateID: stableBYOMAdmissionCandidateID("a"),
            servedModelRef: "ollama:qwen3-8b",
            catalogModelKey: "qwen3-8b"
        )

        let package = try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: candidate,
            admissionIdentity: identity,
            evaluationDigestSHA256: String(repeating: "b", count: 64),
            requestedDisclosureClass: "non_earning_provider_asserted",
            now: Date(timeIntervalSince1970: 1_800_000_000),
            nonce: "nonce_test",
            idempotencyKey: "request_test",
            cliVersion: "test"
        )

        XCTAssertEqual(package.request.schema, "model_admission_offer_submit.v1")
        XCTAssertEqual(package.request.signatureDomain, "macprovider.model_admission.offer.v1")
        XCTAssertEqual(package.request.providerID, "provider-byom-a")
        XCTAssertEqual(package.request.candidateID, stableBYOMAdmissionCandidateID("a"))
        XCTAssertEqual(package.request.catalogModelKey, "qwen3-8b")
        XCTAssertEqual(package.request.signatureAlgorithm, "ed25519")
        XCTAssertFalse(String(decoding: package.encodedRequest, as: UTF8.self).contains("endpoint"))
        XCTAssertFalse(String(decoding: package.encodedRequest, as: UTF8.self).contains("payout"))

        let canonical = try RFC8785JCS.canonicalString(package.request.canonicalValue())
        let signature = try XCTUnwrap(Data(base64Encoded: package.request.providerSignature))
        XCTAssertTrue(identity.publicKey.isValidSignature(signature, for: Data(canonical.utf8)))
    }

    func testOfferSubmissionRunnerPostsPackageAndPreservesNonEarningStatus() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-submit")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try createBYOMAdmissionMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let identity = Curve25519.Signing.PrivateKey()
        let credentialStore = BYOMAdmissionCredentialStore(token: "provider-token-test")
        let identityStore = BYOMAdmissionIdentityStore(identity: identity)
        let session = makeBYOMAdmissionSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer provider-token-test")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(byomAdmissionRequestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["schema"] as? String, "model_admission_offer_submit.v1")
            XCTAssertEqual(object["signature_domain"] as? String, "macprovider.model_admission.offer.v1")
            XCTAssertEqual(object["provider_id"] as? String, "provider-byom-a")
            XCTAssertEqual(object["served_model_ref"] as? String, "mlx-community/Tiny-1B-4bit")
            XCTAssertEqual(object["runtime_source"] as? String, "mlx_cache")
            XCTAssertEqual(object["signature_algorithm"] as? String, "ed25519")
            XCTAssertNotNil(object["provider_signature"] as? String)
            XCTAssertNotNil(object["signing_key_digest"] as? String)
            let candidateID = try XCTUnwrap(object["candidate_id"] as? String)
            return BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"offer_submitted","admission_state_source":"coordinator","allowed_next_states":["offer_rejected","sandbox_probe_only","network_visible_unpriced","network_admitted_unsettled","catalog_priced","withdrawn","revoked"],"candidate_id":"\(candidateID)","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"wait_for_coordinator","state_label_key":"byom.admission.offer_submitted","state_meaning_key":"byom.admission.not_earning","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"mlx-community/Tiny-1B-4bit","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let runtime = BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            credentialStore: credentialStore,
            identityStore: identityStore,
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionDiscoveryHTTPClient()
        )

        let status = try await runtime.submitOffer(
            providerID: "provider-byom-a",
            target: "mlx-community/Tiny-1B-4bit",
            evaluationDigestSHA256: String(repeating: "b", count: 64),
            requestedDisclosureClass: "non_earning_provider_asserted"
        )

        XCTAssertEqual(status.schema, "model_admission_status.v1")
        XCTAssertEqual(status.admissionState, "offer_submitted")
        XCTAssertEqual(status.providerGuidance.nextAction, "wait_for_coordinator")
        XCTAssertEqual(status.allowedNextStates.first, "offer_rejected")
    }

    /// SPEC-010-R007(a) at the production boundary: `models offer` for an
    /// Ollama-served candidate posts `artifact_hashes` RECOMPUTED over the
    /// blob's complete bytes (never the manifest's layer digest, which here
    /// lies), signed into the package; and a candidate discovery reported as
    /// artifact-backed whose blob cannot be hashed never submits.
    func testOfferSubmissionPostsRecomputedGGUFArtifactHashesForOllamaCandidates() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-gguf")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let blob = Data("GGUF".utf8) + Data(repeating: 0x6b, count: 8192)
        let digest = Data(SHA256.hash(data: blob)).map { String(format: "%02x", $0) }.joined()
        let lyingLocator = String(repeating: "e", count: 64)
        let ollamaRoot = root.appendingPathComponent("ollama", isDirectory: true)
        let blobURL = ollamaRoot.appendingPathComponent("blobs/sha256-\(lyingLocator)")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: blobURL)
        let manifestURL = ollamaRoot.appendingPathComponent("manifests/registry.ollama.ai/library/tiny-offer-1b/q4")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {"schemaVersion":2,"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\(lyingLocator)","size":\(blob.count)}]}
        """.utf8).write(to: manifestURL)
        let environment = BYOMDiscoveryEnvironment(
            namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: "http://127.0.0.1:11434",
            ollamaModelsRoot: ollamaRoot, artifactDigestCacheURL: root.appendingPathComponent("artifact-digests.json")
        )
        let identity = Curve25519.Signing.PrivateKey()
        let posted = BYOMAdmissionPostedHashes()
        let session = makeBYOMAdmissionSession { request in
            let body = try XCTUnwrap(byomAdmissionRequestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["runtime_source"] as? String, "ollama_loopback")
            XCTAssertEqual(object["served_model_ref"] as? String, "ollama:tiny-offer-1b:q4")
            posted.record(object["artifact_hashes"] as? [String: String] ?? [:])
            let candidateID = try XCTUnwrap(object["candidate_id"] as? String)
            return BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"offer_submitted","admission_state_source":"coordinator","allowed_next_states":["offer_rejected"],"candidate_id":"\(candidateID)","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"wait_for_coordinator","state_label_key":"byom.admission.offer_submitted","state_meaning_key":"byom.admission.not_earning","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:tiny-offer-1b:q4","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let runtime = BYOMModelAdmissionRuntime(
            environment: environment,
            credentialStore: BYOMAdmissionCredentialStore(token: "provider-token-test"),
            identityStore: BYOMAdmissionIdentityStore(identity: identity),
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionOllamaTagsHTTPClient(models: ["tiny-offer-1b:q4"])
        )
        let status = try await runtime.submitOffer(
            providerID: "provider-byom-a",
            target: "ollama:tiny-offer-1b:q4",
            evaluationDigestSHA256: String(repeating: "b", count: 64),
            requestedDisclosureClass: "non_earning_provider_asserted"
        )
        XCTAssertEqual(status.admissionState, "offer_submitted")
        XCTAssertEqual(posted.hashes, [ModelArtifactIdentity.ggufFileV1: digest], "the posted digest is computed over the bytes, not the manifest locator")
        XCTAssertNotEqual(posted.hashes[ModelArtifactIdentity.ggufFileV1], lyingLocator)

        // The blob is now known. Replacing it with non-GGUF bytes of the SAME
        // size changes its identity, so the fresh discovery inside the next
        // offer no longer reports it as artifact-backed and the offer goes out
        // IDENTITY-LESS (v0.1 shape) — a real submission, but never a GGUF
        // digest for bytes that are not GGUF. (An offer for a candidate that
        // discovery still reports as artifact-backed fails closed instead:
        // BYOMArtifactDigestTests.)
        XCTAssertEqual(environment.artifactDigests.knownDigest(forOllamaModel: "tiny-offer-1b:q4"), digest)
        try (Data("XXXX".utf8) + Data(repeating: 0x6b, count: 8192)).write(to: blobURL)
        posted.record([:])
        let sameSizeRuntime = BYOMModelAdmissionRuntime(
            environment: environment,
            credentialStore: BYOMAdmissionCredentialStore(token: "provider-token-test"),
            identityStore: BYOMAdmissionIdentityStore(identity: identity),
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionOllamaTagsHTTPClient(models: ["tiny-offer-1b:q4"])
        )
        let identityless = try await sameSizeRuntime.submitOffer(
            providerID: "provider-byom-a",
            target: "ollama:tiny-offer-1b:q4",
            evaluationDigestSHA256: String(repeating: "b", count: 64),
            requestedDisclosureClass: "non_earning_provider_asserted"
        )
        XCTAssertEqual(identityless.admissionState, "offer_submitted", "the identity-less offer is a real submission")
        XCTAssertEqual(posted.hashes, [:], "no GGUF digest is ever posted for bytes that are not GGUF")
        XCTAssertNil(environment.artifactDigests.knownDigest(forOllamaModel: "tiny-offer-1b:q4"), "nothing is recorded for the non-GGUF bytes")
    }

    func testAdmissionStatusClientReadsCandidateStatus() async throws {
        let session = makeBYOMAdmissionSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.query, "candidate_id=\(stableBYOMAdmissionCandidateID("c"))")
            return BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"not_offered","admission_state_source":"coordinator","allowed_next_states":["offer_submitted"],"candidate_id":"\(stableBYOMAdmissionCandidateID("c"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":null,"generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"local_inventory_only","next_action":"submit_offer","state_label_key":"byom.admission.not_offered","state_meaning_key":"byom.admission.not_offered","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)
        let status = try await client.status(candidateID: stableBYOMAdmissionCandidateID("c"), bearerToken: "token")

        XCTAssertEqual(status.admissionState, "not_offered")
        XCTAssertEqual(status.providerGuidance.nextAction, "submit_offer")
        XCTAssertEqual(status.allowedNextStates, ["offer_submitted"])
    }

    func testAdmissionRuntimeStatusPreservesLocalIdentityForNotOfferedCandidate() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-status")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try createBYOMAdmissionMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        let credentialStore = BYOMAdmissionCredentialStore(token: "provider-token-test")
        let identityStore = BYOMAdmissionIdentityStore(identity: Curve25519.Signing.PrivateKey())
        let session = makeBYOMAdmissionSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            let candidateID = try XCTUnwrap(queryItems?.first(where: { $0.name == "candidate_id" })?.value)
            return BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"not_offered","admission_state_source":"coordinator","allowed_next_states":["offer_submitted"],"candidate_id":"\(candidateID)","catalog_model_key":null,"cli_version":"test","coordinator_event_id":null,"generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"local_inventory_only","next_action":"submit_offer","state_label_key":"byom.admission.not_offered","state_meaning_key":"byom.admission.not_offered","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let runtime = BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            credentialStore: credentialStore,
            identityStore: identityStore,
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionDiscoveryHTTPClient()
        )

        let status = try await runtime.status(providerID: "provider-byom-a", target: "mlx-community/Tiny-1B-4bit")

        XCTAssertTrue(status.candidateID.hasPrefix("byom_"))
        XCTAssertEqual(status.candidateID.count, 57)
        XCTAssertEqual(status.servedModelRef, "mlx-community/Tiny-1B-4bit")
        XCTAssertEqual(status.admissionState, "not_offered")
        XCTAssertEqual(status.admissionStateSource, "coordinator")
    }

    func testWithdrawCommandRequiresExplicitYesForCoordinatorMutation() async throws {
        let command = try ModelsAdmissionWithdrawCommand.parse([
            "ollama:tiny-offer-1b-q4",
            "--json",
            "--skip-ollama",
            "--skip-lmstudio",
            "--coordinator-url", "wss://coordinator.example/ws/provider",
            "--provider-id", "provider-byom-a",
        ])
        let capture = await captureBYOMAdmissionOutput {
            try await command.run()
        }

        XCTAssertFalse(command.yes)
        XCTAssertEqual((capture.error as? ExitCode), ExitCode(2))
    }

    func testWithdrawalPackageBindsAdmissionIdentityAndNullableCatalogKey() throws {
        let identity = Curve25519.Signing.PrivateKey()
        let candidate = byomAdmissionCandidate(
            candidateID: stableBYOMAdmissionCandidateID("o"),
            servedModelRef: "ollama:qwen3-8b"
        )

        let package = try BYOMWithdrawalBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: candidate,
            admissionIdentity: identity,
            reasonCode: "provider_requested",
            now: Date(timeIntervalSince1970: 1_800_000_000),
            nonce: "withdraw_nonce_test",
            idempotencyKey: "withdraw_request_test",
            cliVersion: "test"
        )

        XCTAssertEqual(package.request.schema, "model_admission_withdraw_request.v1")
        XCTAssertEqual(package.request.signatureDomain, "macprovider.model_admission.withdraw.v1")
        XCTAssertEqual(package.request.providerID, "provider-byom-a")
        XCTAssertNil(package.request.catalogModelKey)
        XCTAssertEqual(package.request.reasonCode, "provider_requested")
        XCTAssertFalse(String(decoding: package.encodedRequest, as: UTF8.self).contains("previous_admission_state"))
        XCTAssertFalse(String(decoding: package.encodedRequest, as: UTF8.self).contains("endpoint"))
        XCTAssertFalse(String(decoding: package.encodedRequest, as: UTF8.self).contains("payout"))

        let canonical = try RFC8785JCS.canonicalString(package.request.canonicalValue())
        let signature = try XCTUnwrap(Data(base64Encoded: package.request.providerSignature))
        XCTAssertTrue(identity.publicKey.isValidSignature(signature, for: Data(canonical.utf8)))
    }

    func testAdmissionRuntimeWithdrawPostsPackageAndPreservesNonEarningStatus() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-withdraw")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try createBYOMAdmissionMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let identity = Curve25519.Signing.PrivateKey()
        let credentialStore = BYOMAdmissionCredentialStore(token: "provider-token-test")
        let identityStore = BYOMAdmissionIdentityStore(identity: identity)
        let session = makeBYOMAdmissionSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer provider-token-test")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/provider/model-admission/withdrawals")
            let body = try XCTUnwrap(byomAdmissionRequestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["schema"] as? String, "model_admission_withdraw_request.v1")
            XCTAssertEqual(object["signature_domain"] as? String, "macprovider.model_admission.withdraw.v1")
            XCTAssertEqual(object["provider_id"] as? String, "provider-byom-a")
            XCTAssertEqual(object["served_model_ref"] as? String, "mlx-community/Tiny-1B-4bit")
            XCTAssertEqual(object["reason_code"] as? String, "wrong_model")
            XCTAssertNil(object["catalog_model_key"] as? String)
            XCTAssertNil(object["previous_admission_state"])
            XCTAssertNotNil(object["provider_signature"] as? String)
            let candidateID = try XCTUnwrap(object["candidate_id"] as? String)
            let idempotencyKey = try XCTUnwrap(object["idempotency_key"] as? String)
            return BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"accepted_at":"2027-01-15T08:00:01Z","candidate_id":"\(candidateID)","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"withdraw_event_test","generated_at":"2027-01-15T08:00:01Z","idempotency_key":"\(idempotencyKey)","previous_admission_state":"offer_submitted","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"submit_offer","state_label_key":"byom.admission.withdrawn","state_meaning_key":"byom.admission.not_earning","transition_reason_code":"wrong_model"},"provider_id":"provider-byom-a","reason_code":"wrong_model","resulting_admission_state":"withdrawn","schema":"model_admission_withdraw.v1","served_model_ref":"mlx-community/Tiny-1B-4bit","warnings":[]}
                """
            )
        }
        let runtime = BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            credentialStore: credentialStore,
            identityStore: identityStore,
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionDiscoveryHTTPClient()
        )

        let withdrawal = try await runtime.withdraw(
            providerID: "provider-byom-a",
            target: "mlx-community/Tiny-1B-4bit",
            reasonCode: "wrong_model"
        )

        XCTAssertEqual(withdrawal.schema, "model_admission_withdraw.v1")
        XCTAssertEqual(withdrawal.resultingAdmissionState, "withdrawn")
        XCTAssertEqual(withdrawal.providerGuidance.nextAction, "submit_offer")
        XCTAssertEqual(withdrawal.providerGuidance.earningPathClass, "no_earning_path_in_v0_1")
    }

    // The withdrawal response must be bound to the full submitted tuple, not just
    // provider+candidate: a substituted served_model_ref (or catalog key /
    // idempotency key / reason) in an otherwise-valid envelope must be rejected.
    func testAdmissionRuntimeWithdrawRejectsSubstitutedResponseTuple() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-withdraw-substitute")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try createBYOMAdmissionMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let identity = Curve25519.Signing.PrivateKey()
        let credentialStore = BYOMAdmissionCredentialStore(token: "provider-token-test")
        let identityStore = BYOMAdmissionIdentityStore(identity: identity)
        let session = makeBYOMAdmissionSession { request in
            let body = try XCTUnwrap(byomAdmissionRequestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let candidateID = try XCTUnwrap(object["candidate_id"] as? String)
            let idempotencyKey = try XCTUnwrap(object["idempotency_key"] as? String)
            // served_model_ref substituted vs the submitted "mlx-community/Tiny-1B-4bit".
            return BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"accepted_at":"2027-01-15T08:00:01Z","candidate_id":"\(candidateID)","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"withdraw_event_test","generated_at":"2027-01-15T08:00:01Z","idempotency_key":"\(idempotencyKey)","previous_admission_state":"offer_submitted","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"submit_offer","state_label_key":"byom.admission.withdrawn","state_meaning_key":"byom.admission.not_earning","transition_reason_code":"wrong_model"},"provider_id":"provider-byom-a","reason_code":"wrong_model","resulting_admission_state":"withdrawn","schema":"model_admission_withdraw.v1","served_model_ref":"mlx-community/Substituted-Model-4bit","warnings":[]}
                """
            )
        }
        let runtime = BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            credentialStore: credentialStore,
            identityStore: identityStore,
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionDiscoveryHTTPClient()
        )

        do {
            _ = try await runtime.withdraw(
                providerID: "provider-byom-a",
                target: "mlx-community/Tiny-1B-4bit",
                reasonCode: "wrong_model"
            )
            XCTFail("a substituted withdrawal response tuple must fail closed")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .invalidStatusSchema)
        }
    }

    func testAdmissionRuntimeWithdrawFallsBackToCoordinatorStatusWhenRuntimeUnavailable() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-withdraw-status-fallback")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let candidateID = stableBYOMAdmissionCandidateID("q")
        let identity = Curve25519.Signing.PrivateKey()
        let credentialStore = BYOMAdmissionCredentialStore(token: "provider-token-test")
        let identityStore = BYOMAdmissionIdentityStore(identity: identity)
        let recorder = BYOMAdmissionRequestRecorder()
        let session = makeBYOMAdmissionSession { request in
            let count = recorder.record(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer provider-token-test")
            if request.url?.path == "/v1/provider/model-admission/status" {
                XCTAssertEqual(count, 1)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "candidate_id" })?.value, candidateID)
                return BYOMAdmissionMockHTTPResponse(
                    statusCode: 200,
                    body: """
                    {"admission_state":"offer_submitted","admission_state_source":"coordinator","allowed_next_states":["offer_rejected","sandbox_probe_only","network_visible_unpriced","network_admitted_unsettled","catalog_priced","withdrawn","revoked"],"candidate_id":"\(candidateID)","catalog_model_key":"qwen3-8b","cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"not_earning_yet_catalog_or_receipt_path_exists","next_action":"wait_for_coordinator","state_label_key":"byom.admission.offer_submitted","state_meaning_key":"byom.admission.not_earning","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3-8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                    """
                )
            }
            XCTAssertEqual(count, 2)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/provider/model-admission/withdrawals")
            let body = try XCTUnwrap(byomAdmissionRequestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["schema"] as? String, "model_admission_withdraw_request.v1")
            XCTAssertEqual(object["candidate_id"] as? String, candidateID)
            XCTAssertEqual(object["served_model_ref"] as? String, "ollama:qwen3-8b")
            XCTAssertEqual(object["catalog_model_key"] as? String, "qwen3-8b")
            XCTAssertEqual(object["reason_code"] as? String, "runtime_unavailable")
            let idempotencyKey = try XCTUnwrap(object["idempotency_key"] as? String)
            return BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"accepted_at":"2027-01-15T08:00:01Z","candidate_id":"\(candidateID)","catalog_model_key":"qwen3-8b","cli_version":"test","coordinator_event_id":"withdraw_event_test","generated_at":"2027-01-15T08:00:01Z","idempotency_key":"\(idempotencyKey)","previous_admission_state":"offer_submitted","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"submit_offer","state_label_key":"byom.admission.withdrawn","state_meaning_key":"byom.admission.not_earning","transition_reason_code":"runtime_unavailable"},"provider_id":"provider-byom-a","reason_code":"runtime_unavailable","resulting_admission_state":"withdrawn","schema":"model_admission_withdraw.v1","served_model_ref":"ollama:qwen3-8b","warnings":[]}
                """
            )
        }
        let runtime = BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            credentialStore: credentialStore,
            identityStore: identityStore,
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionDiscoveryHTTPClient()
        )

        let withdrawal = try await runtime.withdraw(
            providerID: "provider-byom-a",
            target: candidateID,
            reasonCode: "runtime_unavailable"
        )

        XCTAssertEqual(withdrawal.resultingAdmissionState, "withdrawn")
        XCTAssertEqual(withdrawal.servedModelRef, "ollama:qwen3-8b")
        XCTAssertEqual(withdrawal.catalogModelKey, "qwen3-8b")
        XCTAssertEqual(recorder.count, 2)
    }

    func testAdmissionStatusClientAcceptsCatalogPricedSettlementTransition() async throws {
        let session = makeBYOMAdmissionSession { _ in
            BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"catalog_priced","admission_state_source":"coordinator","allowed_next_states":["network_admitted_unsettled","settlement_capable","withdrawn","revoked"],"candidate_id":"\(stableBYOMAdmissionCandidateID("l"))","catalog_model_key":"qwen3-8b","cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"not_earning_yet_catalog_or_receipt_path_exists","next_action":"withdraw","state_label_key":"byom.admission.catalog_priced","state_meaning_key":"byom.admission.catalog_priced","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3:8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)
        let status = try await client.status(candidateID: stableBYOMAdmissionCandidateID("l"), bearerToken: "token")

        XCTAssertEqual(status.admissionState, "catalog_priced")
        XCTAssertEqual(status.allowedNextStates, ["network_admitted_unsettled", "settlement_capable", "withdrawn", "revoked"])
    }

    // A non-catalog candidate advanced to a pre-settlement admitted state honestly
    // reports no_earning_path_in_v0_1 with a null catalog_model_key. The strict
    // status decoder must accept it (otherwise `models admission status` and the
    // withdraw-by-candidate fallback fail closed on a valid coordinator state).
    func testAdmissionStatusClientAcceptsNonCatalogAdmittedStates() async throws {
        for state in ["sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled"] {
            let session = makeBYOMAdmissionSession { _ in
                BYOMAdmissionMockHTTPResponse(
                    statusCode: 200,
                    body: """
                    {"admission_state":"\(state)","admission_state_source":"coordinator","allowed_next_states":["catalog_priced","withdrawn","revoked"],"candidate_id":"\(stableBYOMAdmissionCandidateID("y"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"withdraw","state_label_key":"byom.admission.\(state)","state_meaning_key":"byom.admission.\(state)","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3-8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                    """
                )
            }
            let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)
            let status = try await client.status(candidateID: stableBYOMAdmissionCandidateID("y"), bearerToken: "token")
            XCTAssertEqual(status.admissionState, state)
            XCTAssertNil(status.catalogModelKey)
            XCTAssertEqual(status.providerGuidance.earningPathClass, "no_earning_path_in_v0_1")
        }
    }

    // catalog_priced always requires a catalog binding, so a null catalog_model_key
    // (or the non-catalog earning class) must be rejected.
    func testAdmissionStatusClientRejectsCatalogPricedWithoutCatalogKey() async throws {
        let session = makeBYOMAdmissionSession { _ in
            BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"catalog_priced","admission_state_source":"coordinator","allowed_next_states":["settlement_capable","withdrawn","revoked"],"candidate_id":"\(stableBYOMAdmissionCandidateID("z"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"withdraw","state_label_key":"byom.admission.catalog_priced","state_meaning_key":"byom.admission.catalog_priced","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3-8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)
        do {
            _ = try await client.status(candidateID: stableBYOMAdmissionCandidateID("z"), bearerToken: "token")
            XCTFail("catalog_priced without a catalog key must fail closed")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .invalidStatusSchema)
        }
    }

    func testAdmissionClientRejectsCredentialedURLAndOversizedStatus() async throws {
        XCTAssertThrowsError(try BYOMModelAdmissionClient(coordinatorURL: "wss://user:pass@coordinator.test/ws/provider")) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .invalidCoordinatorURL)
        }
        let session = makeBYOMAdmissionSession { _ in
            BYOMAdmissionMockHTTPResponse(statusCode: 200, body: String(repeating: " ", count: 64 * 1024 + 1))
        }
        let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)
        do {
            _ = try await client.status(candidateID: stableBYOMAdmissionCandidateID("d"), bearerToken: "token")
            XCTFail("oversized status responses must fail closed")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .invalidStatusSchema)
        }
    }

    func testOfferPackageRejectsUnstableCandidateAndBadEvaluationDigest() throws {
        let identity = Curve25519.Signing.PrivateKey()
        let unstable = byomAdmissionCandidate(
            candidateID: "byom_unstable_123",
            servedModelRef: "ollama:qwen3-8b",
            warningCodes: ["candidate_id_unstable"]
        )
        XCTAssertThrowsError(try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: unstable,
            admissionIdentity: identity,
            evaluationDigestSHA256: nil,
            requestedDisclosureClass: "non_earning_provider_asserted"
        )) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .candidateUnstable)
        }

        let stable = byomAdmissionCandidate(candidateID: stableBYOMAdmissionCandidateID("e"), servedModelRef: "ollama:qwen3-8b")
        XCTAssertThrowsError(try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: stable,
            admissionIdentity: identity,
            evaluationDigestSHA256: "ABC",
            requestedDisclosureClass: "non_earning_provider_asserted"
        )) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .invalidEvaluationDigest)
        }
    }

    func testOfferPackageAllowsMissingEvaluationDigestForNonEarningCandidate() throws {
        // SPEC-047-R002: evaluation_required is advisory, NOT a hard submit blocker,
        // for a non-earning (local_inventory_only) v0.1 candidate -- "offer submission
        // MAY omit the evaluation digest ... confined to non-earning states." So a
        // clean offerable candidate carrying only evaluation_required submits with or
        // without a digest, matching canSubmitLocalDryRun so the dry-run does not
        // over-promise the real submit.
        let identity = Curve25519.Signing.PrivateKey()
        let candidate = byomAdmissionCandidate(
            candidateID: stableBYOMAdmissionCandidateID("f"),
            servedModelRef: "ollama:qwen3-8b",
            warningCodes: ["evaluation_required"]
        )
        XCTAssertNoThrow(try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: candidate,
            admissionIdentity: identity,
            evaluationDigestSHA256: nil,
            requestedDisclosureClass: "non_earning_provider_asserted"
        ))
        XCTAssertNoThrow(try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: candidate,
            admissionIdentity: identity,
            evaluationDigestSHA256: String(repeating: "b", count: 64),
            requestedDisclosureClass: "non_earning_provider_asserted"
        ))
    }

    func testOfferPackageStillRejectsHardLocalBlockers() throws {
        // The advisory-evaluation relaxation must not turn canSubmit into a no-op:
        // every hard local blocker still fails closed with candidateNotOfferable,
        // including the adapter faults that were previously inconsistently gated
        // (adapter_unavailable / adapter_timeout) and every other code in the shared
        // submitBlockingWarningCodes set.
        let identity = Curve25519.Signing.PrivateKey()
        let hardBlockers = [
            "requires_preparation",
            "adapter_rejected_non_loopback",
            "adapter_malformed_response",
            "adapter_response_truncated",
            "adapter_unavailable",
            "adapter_timeout",
        ]
        for code in hardBlockers {
            let candidate = byomAdmissionCandidate(
                candidateID: stableBYOMAdmissionCandidateID("g"),
                servedModelRef: "ollama:qwen3-8b",
                warningCodes: [code, "evaluation_required"]
            )
            XCTAssertThrowsError(try BYOMOfferSubmissionBuilder.makePackage(
                providerID: "provider-byom-a",
                candidate: candidate,
                admissionIdentity: identity,
                evaluationDigestSHA256: nil,
                requestedDisclosureClass: "non_earning_provider_asserted"
            ), "hard blocker \(code) must fail closed") { error in
                XCTAssertEqual(error as? BYOMModelAdmissionError, .candidateNotOfferable, "wrong error for \(code)")
            }
            // A supplied evaluation digest must NOT override a hard local blocker.
            XCTAssertThrowsError(try BYOMOfferSubmissionBuilder.makePackage(
                providerID: "provider-byom-a",
                candidate: candidate,
                admissionIdentity: identity,
                evaluationDigestSHA256: String(repeating: "b", count: 64),
                requestedDisclosureClass: "non_earning_provider_asserted"
            ), "hard blocker \(code) must fail closed even with a digest") { error in
                XCTAssertEqual(error as? BYOMModelAdmissionError, .candidateNotOfferable, "wrong error for \(code) with digest")
            }
        }
    }

    func testWithdrawalPackageRejectsUnstableCandidateAndInvalidReason() throws {
        let identity = Curve25519.Signing.PrivateKey()
        let unstable = byomAdmissionCandidate(
            candidateID: "byom_unstable_123",
            servedModelRef: "ollama:qwen3-8b",
            warningCodes: ["candidate_id_unstable"]
        )
        XCTAssertThrowsError(try BYOMWithdrawalBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: unstable,
            admissionIdentity: identity,
            reasonCode: "provider_requested"
        )) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .candidateUnstable)
        }
        let stable = byomAdmissionCandidate(candidateID: stableBYOMAdmissionCandidateID("p"), servedModelRef: "ollama:qwen3-8b")
        XCTAssertThrowsError(try BYOMWithdrawalBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: stable,
            admissionIdentity: identity,
            reasonCode: "because I said so"
        )) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .invalidWithdrawalReason)
        }
    }

    func testAdmissionClientRejectsNonClosedOrInvalidStatusEnvelope() async throws {
        let invalidBodies = [
            """
            {"admission_state":"not_offered","admission_state_source":"coordinator","allowed_next_states":["offer_submitted"],"candidate_id":"\(stableBYOMAdmissionCandidateID("g"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":null,"generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"local_inventory_only","next_action":"submit_offer","state_label_key":"byom.admission.not_offered","state_meaning_key":"byom.admission.not_offered","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"","state_observed_at":"2027-01-15T08:00:00Z","warnings":[],"unexpected":true}
            """,
            """
            {"admission_state":"offer_submitted","admission_state_source":"coordinator","allowed_next_states":["settlement_capable"],"candidate_id":"\(stableBYOMAdmissionCandidateID("h"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"wait_for_coordinator","state_label_key":"byom.admission.offer_submitted","state_meaning_key":"byom.admission.not_earning","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3-8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
            """,
            """
            {"admission_state":"revoked","admission_state_source":"coordinator","allowed_next_states":["offer_submitted"],"candidate_id":"\(stableBYOMAdmissionCandidateID("i"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"no_earning_path_in_v0_1","next_action":"submit_offer","state_label_key":"byom.admission.revoked","state_meaning_key":"byom.admission.not_earning","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3-8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
            """,
            """
            {"admission_state":"catalog_priced","admission_state_source":"coordinator","allowed_next_states":["catalog_priced"],"candidate_id":"\(stableBYOMAdmissionCandidateID("l"))","catalog_model_key":"qwen3-8b","cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"not_earning_yet_catalog_or_receipt_path_exists","next_action":"maintain_runtime","state_label_key":"byom.admission.catalog_priced","state_meaning_key":"byom.admission.catalog_priced","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3:8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
            """,
            """
            {"admission_state":"offer_submitted","admission_state_source":"coordinator","allowed_next_states":["offer_rejected","sandbox_probe_only","network_visible_unpriced","network_admitted_unsettled","catalog_priced","withdrawn","revoked"],"candidate_id":"\(stableBYOMAdmissionCandidateID("m"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":"event_test","generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"settlement_capable","next_action":"wait_for_coordinator","state_label_key":"byom.admission.offer_submitted","state_meaning_key":"byom.admission.not_earning","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3:8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
            """,
        ]
        for body in invalidBodies {
            let session = makeBYOMAdmissionSession { _ in
                BYOMAdmissionMockHTTPResponse(statusCode: 200, body: body)
            }
            let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)
            do {
                _ = try await client.status(candidateID: stableBYOMAdmissionCandidateID("j"), bearerToken: "token")
                XCTFail("invalid status envelope succeeded: \(body)")
            } catch let error as BYOMModelAdmissionError {
                XCTAssertEqual(error, .invalidStatusSchema)
            }
        }
    }

    func testAdmissionStatusClientRejectsMismatchedStatusIdentity() async throws {
        let session = makeBYOMAdmissionSession { _ in
            BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"not_offered","admission_state_source":"coordinator","allowed_next_states":["offer_submitted"],"candidate_id":"\(stableBYOMAdmissionCandidateID("n"))","catalog_model_key":null,"cli_version":"test","coordinator_event_id":null,"generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"local_inventory_only","next_action":"submit_offer","state_label_key":"byom.admission.not_offered","state_meaning_key":"byom.admission.not_offered","transition_reason_code":null},"provider_id":"provider-byom-b","schema":"model_admission_status.v1","served_model_ref":"","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)

        do {
            _ = try await client.status(
                candidateID: stableBYOMAdmissionCandidateID("c"),
                providerID: "provider-byom-a",
                bearerToken: "token"
            )
            XCTFail("mismatched provider/candidate status succeeded")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .invalidStatusSchema)
        }
    }

    func testAdmissionStatusClientRejectsRemoteLocalDefaultGuidance() async throws {
        let candidateID = stableBYOMAdmissionCandidateID("c")
        let session = makeBYOMAdmissionSession { _ in
            BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: """
                {"admission_state":"offerable","admission_state_source":"local_default","allowed_next_states":[],"candidate_id":"\(candidateID)","catalog_model_key":null,"cli_version":"test","coordinator_event_id":null,"generated_at":"2027-01-15T08:00:00Z","provider_guidance":{"earning_path_class":"settlement_capable","next_action":"maintain_runtime","state_label_key":"byom.admission.offerable","state_meaning_key":"byom.admission.offerable","transition_reason_code":null},"provider_id":"provider-byom-a","schema":"model_admission_status.v1","served_model_ref":"ollama:qwen3:8b","state_observed_at":"2027-01-15T08:00:00Z","warnings":[]}
                """
            )
        }
        let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)

        do {
            _ = try await client.status(
                candidateID: candidateID,
                providerID: "provider-byom-a",
                bearerToken: "token"
            )
            XCTFail("remote local_default status succeeded")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .invalidStatusSchema)
        }
    }

    // #1248 old-client compatibility: a current CLI pointed at a pre-BYOM
    // coordinator (no SPEC-047 admission endpoints -> 404/405, or an unknown
    // response schema) must never fabricate a COORDINATOR admission state. The
    // transport still refuses to produce one; the provider is answered from the
    // SPEC-046-R003 local ladder instead (local_default `not_offered`), which is
    // what that ladder means by "coordinator state is unavailable".
    func testAdmissionStatusAgainstPreBYOMCoordinatorFailsClosedWithoutFabricatingState() async throws {
        for status in [404, 405] {
            let session = makeBYOMAdmissionSession { _ in
                BYOMAdmissionMockHTTPResponse(statusCode: status, body: "not found")
            }
            let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session)
            do {
                _ = try await client.status(candidateID: stableBYOMAdmissionCandidateID("p"), bearerToken: "token")
                XCTFail("pre-BYOM coordinator HTTP \(status) produced a status")
            } catch let error as BYOMModelAdmissionError {
                XCTAssertEqual(error, .httpStatus(status))
                XCTAssertTrue(error.description.contains("local_default"))
                XCTAssertTrue(error.description.contains("wait_for_coordinator"))
            }

            let runtime = try makeLocalLadderRuntime(
                name: "byom-admission-prebyom-\(status)",
                client: BYOMModelAdmissionClient(
                    baseURL: URL(string: "https://coordinator.test")!,
                    session: makeBYOMAdmissionSession { _ in
                        BYOMAdmissionMockHTTPResponse(statusCode: status, body: "not found")
                    }
                )
            )
            let document = try await runtime.status(
                providerID: "provider-byom-a",
                target: "mlx-community/Tiny-1B-4bit"
            )
            XCTAssertEqual(document.schema, "model_admission_status.v1")
            XCTAssertEqual(document.admissionStateSource, "local_default")
            XCTAssertNotEqual(document.admissionStateSource, "coordinator")
            XCTAssertEqual(document.admissionState, "not_offered")
            XCTAssertNil(document.coordinatorEventID)
            XCTAssertNil(document.stateObservedAt)
            XCTAssertEqual(document.allowedNextStates, [])
            XCTAssertTrue(document.warnings.contains("coordinator_state_unavailable"))
            XCTAssertEqual(document.providerGuidance.transitionReasonCode, "coordinator_state_unavailable")
            // Action-neutral with the `offerable` row it came from: this fixture
            // candidate is unevaluated, so both rows say evaluate first.
            XCTAssertEqual(document.providerGuidance.nextAction, "evaluate")
            XCTAssertEqual(document.providerGuidance.earningPathClass, "local_inventory_only")
        }

        // An older coordinator that answers 200 with a schema this release does
        // not know is rejected before it can become an admission state.
        let unknownSchema = makeBYOMAdmissionSession { _ in
            BYOMAdmissionMockHTTPResponse(
                statusCode: 200,
                body: #"{"schema":"models_browse.v1","rows":[]}"#
            )
        }
        let client = BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: unknownSchema)
        do {
            _ = try await client.status(candidateID: stableBYOMAdmissionCandidateID("p"), bearerToken: "token")
            XCTFail("unknown coordinator schema produced a status")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .invalidStatusSchema)
        }

        // A coordinator that answered with a decodable-but-wrong document is a
        // contract fault, not an unavailable coordinator: it must NOT be
        // relabelled as the local ladder's `not_offered`.
        let schemaFaultRuntime = try makeLocalLadderRuntime(
            name: "byom-admission-schema-fault",
            client: BYOMModelAdmissionClient(
                baseURL: URL(string: "https://coordinator.test")!,
                session: makeBYOMAdmissionSession { _ in
                    BYOMAdmissionMockHTTPResponse(
                        statusCode: 200,
                        body: #"{"schema":"models_browse.v1","rows":[]}"#
                    )
                }
            )
        )
        do {
            _ = try await schemaFaultRuntime.status(
                providerID: "provider-byom-a",
                target: "mlx-community/Tiny-1B-4bit"
            )
            XCTFail("an unknown coordinator schema became a local ladder state")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .invalidStatusSchema)
        }
    }

    // SPEC-046-R003 local ladder, trigger (a): no coordinator is configured at
    // all. The CLI must answer from local inventory and must not open a
    // connection to anything while doing it.
    func testAdmissionStatusWithoutConfiguredCoordinatorReportsLocalDefaultNotOffered() async throws {
        let probes = BYOMAdmissionRequestRecorder()
        let runtime = try makeLocalLadderRuntime(
            name: "byom-admission-no-coordinator",
            client: nil,
            httpClient: BYOMAdmissionRecordingDiscoveryHTTPClient(recorder: probes)
        )

        let document = try await runtime.status(
            providerID: "provider-byom-a",
            target: "mlx-community/Tiny-1B-4bit"
        )

        XCTAssertEqual(document.schema, "model_admission_status.v1")
        XCTAssertEqual(document.admissionStateSource, "local_default")
        XCTAssertEqual(document.admissionState, "not_offered")
        XCTAssertEqual(document.providerID, "provider-byom-a")
        XCTAssertEqual(document.servedModelRef, "mlx-community/Tiny-1B-4bit")
        XCTAssertNil(document.coordinatorEventID)
        XCTAssertNil(document.stateObservedAt)
        XCTAssertEqual(document.allowedNextStates, [])
        XCTAssertEqual(document.providerGuidance.stateLabelKey, "byom.local.not_offered")
        XCTAssertEqual(document.providerGuidance.transitionReasonCode, "coordinator_state_unavailable")
        XCTAssertEqual(document.providerGuidance.earningPathClass, "local_inventory_only")
        XCTAssertTrue(document.warnings.contains("coordinator_state_unavailable"))
        XCTAssertEqual(probes.count, 0, "the unconfigured-coordinator path made a request")

        // The ladder's `not_offered` row is action-neutral with the `offerable`
        // row it came from: the unevaluated fixture candidate is sent to
        // evaluation first, and a candidate with nothing outstanding is sent to
        // the offer dry run. Both are the offerable row's own choice.
        XCTAssertEqual(document.providerGuidance.nextAction, "evaluate")
        XCTAssertEqual(
            BYOMDiscoveryGuidance.localNotOfferedGuidance(warnings: []).nextAction,
            "offer_dry_run"
        )
        XCTAssertEqual(
            BYOMDiscoveryGuidance.localNotOfferedGuidance(warnings: ["evaluation_required"]).nextAction,
            BYOMDiscoveryGuidance.guidance(
                forAdmissionState: "offerable",
                warnings: ["evaluation_required"]
            ).nextAction
        )
    }

    // Trigger (b), transport half: the coordinator is configured but refuses the
    // connection. Same ladder row, and exactly the one attempted request.
    func testAdmissionStatusWithUnreachableCoordinatorReportsLocalDefaultNotOffered() async throws {
        let attempts = BYOMAdmissionRequestRecorder()
        let session = makeBYOMAdmissionSession { request in
            _ = attempts.record(request)
            throw URLError(.cannotConnectToHost)
        }
        let runtime = try makeLocalLadderRuntime(
            name: "byom-admission-unreachable",
            client: BYOMModelAdmissionClient(
                baseURL: URL(string: "https://coordinator.test")!,
                session: session
            )
        )

        let document = try await runtime.status(
            providerID: "provider-byom-a",
            target: "mlx-community/Tiny-1B-4bit"
        )

        XCTAssertEqual(document.admissionStateSource, "local_default")
        XCTAssertEqual(document.admissionState, "not_offered")
        XCTAssertTrue(document.warnings.contains("coordinator_state_unavailable"))
        XCTAssertEqual(document.providerGuidance.transitionReasonCode, "coordinator_state_unavailable")
        XCTAssertEqual(attempts.count, 1, "the unreachable-coordinator path did not make exactly one request")
    }

    // Auth faults are the provider's to fix and must stay errors: a 401/403 must
    // never be laundered into "no offer is known for this candidate".
    func testAdmissionStatusKeepsAuthenticationFailuresAsErrors() async throws {
        for status in [401, 403] {
            let runtime = try makeLocalLadderRuntime(
                name: "byom-admission-auth-\(status)",
                client: BYOMModelAdmissionClient(
                    baseURL: URL(string: "https://coordinator.test")!,
                    session: makeBYOMAdmissionSession { _ in
                        BYOMAdmissionMockHTTPResponse(statusCode: status, body: "denied")
                    }
                )
            )
            do {
                _ = try await runtime.status(
                    providerID: "provider-byom-a",
                    target: "mlx-community/Tiny-1B-4bit"
                )
                XCTFail("HTTP \(status) became a local ladder state")
            } catch let error as BYOMModelAdmissionError {
                XCTAssertEqual(error, .httpStatus(status))
            }
        }
    }

    // #1448 disablement mapping is unchanged: 503 stays an error whose guidance
    // is wait_for_coordinator, not a relabelled local state.
    func testAdmissionStatusKeepsUnavailableCoordinatorMappingFor503() async throws {
        let runtime = try makeLocalLadderRuntime(
            name: "byom-admission-503",
            client: BYOMModelAdmissionClient(
                baseURL: URL(string: "https://coordinator.test")!,
                session: makeBYOMAdmissionSession { _ in
                    BYOMAdmissionMockHTTPResponse(
                        statusCode: 503,
                        body: #"{"error":{"code":"submissions_disabled"}}"#
                    )
                }
            )
        )
        do {
            _ = try await runtime.status(
                providerID: "provider-byom-a",
                target: "mlx-community/Tiny-1B-4bit"
            )
            XCTFail("HTTP 503 became a local ladder state")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .httpStatus(503))
            XCTAssertTrue(error.description.contains("wait_for_coordinator"))
            XCTAssertTrue(error.description.contains("unchanged"))
        }
    }

    // A `local_only` candidate's blocker is local, so coordinator reachability
    // does not move it: it keeps its own state and its own guidance.
    func testAdmissionStatusKeepsLocalOnlyCandidateOnItsOwnLadderRow() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-local-only")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try createBYOMAdmissionMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        // No namespace file: the candidate id is unstable, which is a blocking
        // local warning, so the ladder holds the candidate at local_only.
        let runtime = BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("absent.namespace"),
                mlxCacheRoot: cache,
                ollamaOrigin: nil
            ),
            credentialStore: BYOMAdmissionCredentialStore(token: "provider-token-test"),
            identityStore: BYOMAdmissionIdentityStore(identity: Curve25519.Signing.PrivateKey()),
            client: nil,
            httpClient: BYOMAdmissionDiscoveryHTTPClient()
        )

        let document = try await runtime.status(
            providerID: "provider-byom-a",
            target: "mlx-community/Tiny-1B-4bit"
        )

        XCTAssertEqual(document.admissionStateSource, "local_default")
        XCTAssertEqual(document.admissionState, "local_only")
        XCTAssertEqual(document.providerGuidance.stateLabelKey, "byom.local.local_only")
        XCTAssertEqual(document.providerGuidance.nextAction, "fix_local_blocker")
        XCTAssertEqual(document.providerGuidance.transitionReasonCode, "candidate_id_unstable")
        XCTAssertTrue(document.warnings.contains("candidate_id_unstable"))
        XCTAssertTrue(document.warnings.contains("coordinator_state_unavailable"))
    }

    // The local-default document is the same closed envelope as a coordinator
    // one: it must survive the strict decoder, which requires the exact key set
    // (nullable keys present as null) and rejects any unknown field.
    func testLocalDefaultAdmissionStatusRoundTripsThroughTheStrictDecoder() async throws {
        let runtime = try makeLocalLadderRuntime(name: "byom-admission-roundtrip", client: nil)
        let document = try await runtime.status(
            providerID: "provider-byom-a",
            target: "mlx-community/Tiny-1B-4bit"
        )

        let encoded = try ModelSwitchingWireCodec.encode(document)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        XCTAssertTrue(object["coordinator_event_id"] is NSNull)
        XCTAssertTrue(object["state_observed_at"] is NSNull)

        let decoded = try BYOMAdmissionStatusWire.decodeStrictStatus(
            from: Data(encoded.utf8),
            expectedProviderID: "provider-byom-a",
            expectedCandidateID: document.candidateID
        )
        XCTAssertEqual(decoded, document)
    }

    private func makeLocalLadderRuntime(
        name: String,
        client: BYOMModelAdmissionClient?,
        httpClient: any BYOMDiscoveryHTTPClient = BYOMAdmissionDiscoveryHTTPClient()
    ) throws -> BYOMModelAdmissionRuntime {
        let root = try temporaryBYOMAdmissionDirectory(name)
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try createBYOMAdmissionMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        return BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: cache,
                ollamaOrigin: nil
            ),
            credentialStore: BYOMAdmissionCredentialStore(token: "provider-token-test"),
            identityStore: BYOMAdmissionIdentityStore(identity: Curve25519.Signing.PrivateKey()),
            client: client,
            httpClient: httpClient
        )
    }

    // #1248 disablement matrix, "Offer submit" row, provider side: the
    // coordinator's submissions_disabled rejection maps to the existing
    // wait_for_coordinator guidance and invents no new fields or states.
    func testOfferSubmitRejectedByDisabledCoordinatorMapsToWaitForCoordinator() async throws {
        let root = try temporaryBYOMAdmissionDirectory("byom-admission-disabled")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        try writeBYOMAdmissionNamespace(at: namespace)
        try createBYOMAdmissionMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let session = makeBYOMAdmissionSession { _ in
            BYOMAdmissionMockHTTPResponse(
                statusCode: 503,
                body: #"{"error":{"code":"submissions_disabled","message":"model admission offer submissions are disabled"}}"#
            )
        }
        let runtime = BYOMModelAdmissionRuntime(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil),
            credentialStore: BYOMAdmissionCredentialStore(token: "provider-token-test"),
            identityStore: BYOMAdmissionIdentityStore(identity: Curve25519.Signing.PrivateKey()),
            client: BYOMModelAdmissionClient(baseURL: URL(string: "https://coordinator.test")!, session: session),
            httpClient: BYOMAdmissionDiscoveryHTTPClient()
        )

        do {
            _ = try await runtime.submitOffer(
                providerID: "provider-byom-a",
                target: "mlx-community/Tiny-1B-4bit",
                evaluationDigestSHA256: String(repeating: "b", count: 64),
                requestedDisclosureClass: "non_earning_provider_asserted"
            )
            XCTFail("a disabled coordinator accepted an offer submission")
        } catch let error as BYOMModelAdmissionError {
            XCTAssertEqual(error, .httpStatus(503))
            XCTAssertTrue(error.description.contains("wait_for_coordinator"))
            XCTAssertTrue(error.description.contains("unchanged"))
        }
    }

    private func temporaryBYOMAdmissionDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func writeBYOMAdmissionNamespace(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try Data(repeating: 0x33, count: 32).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func createBYOMAdmissionMLXSnapshot(cacheRoot: URL, modelID: String) throws {
        let repo = cacheRoot
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(#"{"max_position_embeddings":2048}"#.utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0x7a, count: 128).write(to: repo.appendingPathComponent("model.safetensors"))
    }
}

private func byomAdmissionCandidate(
    candidateID: String,
    servedModelRef: String,
    catalogModelKey: String? = nil,
    warningCodes: [String] = []
) -> BYOMDiscoveryWire.Candidate {
    BYOMDiscoveryWire.Candidate(
        candidateID: candidateID,
        runtimeSource: servedModelRef.hasPrefix("ollama:") ? "ollama_loopback" : "mlx_cache",
        displayName: servedModelRef,
        servedModelRef: servedModelRef,
        catalogModelKey: catalogModelKey,
        identityState: "provider_asserted",
        locality: "local",
        estimatedGB: 1.0,
        contextWindowTokens: 2048,
        capabilities: BYOMDiscoveryWire.Capabilities(
            chatCompletions: true,
            streaming: nil,
            toolCallPassthrough: nil,
            structuredOutputPassthrough: nil,
            jsonMode: nil,
            usageReporting: nil,
            maxContextTokens: 2048,
            quantization: nil,
            family: nil,
            runtimeVersion: nil
        ),
        readinessState: "ready",
        fitState: "fits",
        evaluationState: "not_evaluated",
        admissionState: "offerable",
        admissionStateSource: "local_default",
        providerGuidance: BYOMDiscoveryWire.Guidance(
            stateLabelKey: "provider_models.state.not_offered",
            stateMeaningKey: "test",
            nextAction: "evaluate",
            transitionReasonCode: "test",
            earningPathClass: "local_inventory_only"
        ),
        warningCodes: warningCodes
    )
}

private func stableBYOMAdmissionCandidateID(_ character: Character) -> String {
    "byom_" + String(repeating: String(character), count: 52)
}

private struct BYOMAdmissionCredentialStore: ProviderCredentialStoring {
    let token: String?

    func load(providerID: String) throws -> String? { token }
    func importIfAbsentOrMatches(providerID: String, token: String) throws {}
    func replace(providerID: String, token: String) throws {}
    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws {}
    func deleteAll() throws {}
}

private struct BYOMAdmissionIdentityStore: ProviderIdentityKeyStoring {
    let identity: Curve25519.Signing.PrivateKey?

    func loadAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? { identity }
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { identity ?? Curve25519.Signing.PrivateKey() }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { identity }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
    func loadPendingAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? { nil }
    func beginAdmissionIdentityRotation(providerId: String) throws -> Curve25519.Signing.PrivateKey { Curve25519.Signing.PrivateKey() }
    func isAdmissionIdentityRecoveryPending(providerId: String, candidatePublicKey: Data) throws -> Bool { false }
    func beginAdmissionIdentityRecovery(providerId: String, allowExistingCurrent: Bool, afterPendingPersisted: (Curve25519.Signing.PrivateKey) throws -> Void) throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        try afterPendingPersisted(key)
        return key
    }
    func loadBootstrapIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? { identity }
    func loadOrStoreBootstrapIdentity(providerId: String, candidate: Curve25519.Signing.PrivateKey) throws -> Curve25519.Signing.PrivateKey { identity ?? candidate }
    func loadOrStoreAdmissionIdentity(providerId: String, candidate: Curve25519.Signing.PrivateKey) throws -> Curve25519.Signing.PrivateKey { identity ?? candidate }
    func loadPrevious(providerId: String) throws -> Curve25519.Signing.PrivateKey? { nil }
    func loadPreviousAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? { nil }
    func loadPreviousAdmissionIdentityState(providerId: String) throws -> AdmissionIdentityPreviousKeyState? { nil }
    func loadAdmissionIdentityRecoveryMarker(providerId: String) throws -> Data? { nil }
    func commitAdmissionIdentityRotation(providerId: String, expectedPublicKey: Data, previousValidUntil: Date?) throws -> Curve25519.Signing.PrivateKey { identity ?? Curve25519.Signing.PrivateKey() }
    func commitAdmissionIdentityRecovery(providerId: String, expectedPublicKey: Data) throws -> Curve25519.Signing.PrivateKey { identity ?? Curve25519.Signing.PrivateKey() }
    func cancelAdmissionIdentityRotation(providerId: String) throws {}
}

private struct BYOMAdmissionRecordingDiscoveryHTTPClient: BYOMDiscoveryHTTPClient {
    let recorder: BYOMAdmissionRequestRecorder

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        _ = recorder.record(URLRequest(url: url))
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(#"{"models":[]}"#.utf8))
    }
}

/// Ollama `/api/tags` stub for the submit path: the runtime lists the named
/// models; everything else about them comes from the local store.
private struct BYOMAdmissionOllamaTagsHTTPClient: BYOMDiscoveryHTTPClient {
    let models: [String]
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        let listed = models.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(#"{"models":[\#(listed)]}"#.utf8))
    }
}

private final class BYOMAdmissionPostedHashes: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String] = [:]
    var hashes: [String: String] { lock.withLock { value } }
    func record(_ hashes: [String: String]) { lock.withLock { value = hashes } }
}

private struct BYOMAdmissionDiscoveryHTTPClient: BYOMDiscoveryHTTPClient {
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(#"{"models":[]}"#.utf8))
    }
}

private struct BYOMAdmissionMockHTTPResponse {
    let statusCode: Int
    let body: String
}

private func makeBYOMAdmissionSession(
    handler: @escaping @Sendable (URLRequest) throws -> BYOMAdmissionMockHTTPResponse
) -> URLSession {
    BYOMAdmissionMockURLProtocol.requestHandler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BYOMAdmissionMockURLProtocol.self]
    return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
}

private func byomAdmissionRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

private final class BYOMAdmissionRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return requests.count
    }
}

private final class BYOMAdmissionMockURLProtocol: URLProtocol {
    static var requestHandler: (@Sendable (URLRequest) throws -> BYOMAdmissionMockHTTPResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let response = try handler(request)
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct BYOMAdmissionCapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureBYOMAdmissionOutput(_ body: () async throws -> Void) async -> BYOMAdmissionCapturedOutput {
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
    return BYOMAdmissionCapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
