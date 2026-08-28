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

    func testOfferPackageRequiresEvaluationDigestWhenDiscoveryStillRequiresEvaluation() throws {
        let identity = Curve25519.Signing.PrivateKey()
        let candidate = byomAdmissionCandidate(
            candidateID: stableBYOMAdmissionCandidateID("f"),
            servedModelRef: "ollama:qwen3-8b",
            warningCodes: ["evaluation_required"]
        )
        XCTAssertThrowsError(try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: candidate,
            admissionIdentity: identity,
            evaluationDigestSHA256: nil,
            requestedDisclosureClass: "non_earning_provider_asserted"
        )) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .candidateNotOfferable)
        }
        XCTAssertNoThrow(try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-byom-a",
            candidate: candidate,
            admissionIdentity: identity,
            evaluationDigestSHA256: String(repeating: "b", count: 64),
            requestedDisclosureClass: "non_earning_provider_asserted"
        ))
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
