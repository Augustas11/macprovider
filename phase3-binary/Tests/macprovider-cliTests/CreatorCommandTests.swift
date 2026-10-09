import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

private final class RecordingCreatorTransport: CreatorTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let respond: @Sendable (URLRequest) -> CreatorResponse

    init(respond: @escaping @Sendable (URLRequest) -> CreatorResponse) { self.respond = respond }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> CreatorResponse {
        lock.withLock { _requests.append(request) }
        return respond(request)
    }
}

private func jsonResponse(_ status: Int, _ object: [String: Any]) -> CreatorResponse {
    CreatorResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
}

private func body(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody else { return [:] }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

final class CreatorCommandTests: XCTestCase {
    private var homeURL: URL!

    override func setUpWithError() throws {
        homeURL = FileManager.default.temporaryDirectory.appendingPathComponent("creator-home-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: homeURL)
    }

    private func transport() -> RecordingCreatorTransport {
        RecordingCreatorTransport { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/v1/creator/me"):
                return jsonResponse(200, ["creator": [
                    "creator_account_id": "acct_creator", "approval_record_id": "self-serve:acct_creator",
                    "current_approval_version": "self-serve-1", "allowed_launch_environment": "self_serve_private",
                ]])
            case ("POST", "/v1/creator/root-registration-nonces"):
                return jsonResponse(201, ["root_registration_nonce": [
                    "nonce": "nonce-1", "creator_account_id": "acct_creator", "approval_record_id": "self-serve:acct_creator",
                    "current_approval_version": "self-serve-1", "launch_environment": "self_serve_private",
                    "expires_at_utc": "2026-10-09T12:15:00.5Z", "purpose": "root_issuer_registration",
                ]])
            default:
                return jsonResponse(202, ["event": ["ok": true]])
            }
        }
    }

    func testCreatorFlowSignsLocallyAndSendsOnlyPublicMaterial() async throws {
        let home = CreatorHome(root: homeURL)
        let identity = try CreatorOperations.keygen(home: home)
        let keysPath = home.poolDir(identity.poolID).appendingPathComponent("keys.json").path
        let mode = try FileManager.default.attributesOfItem(atPath: keysPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try identity.identityCore.poolID(), identity.poolID)

        let fake = transport()
        let client = CreatorClient(login: CreatorLogin(gatewayURL: "http://127.0.0.1:9", apiKey: "mp_test_key"), transport: fake)
        _ = try await CreatorOperations.createPool(home: home, client: client, poolID: identity.poolID)
        _ = try await CreatorOperations.registerRoot(home: home, client: client, poolID: identity.poolID, displayName: "Studio Pool")

        let modelsURL = homeURL.appendingPathComponent("models.json")
        try Data("""
        {"model_entries":[{"pool_model_id":"pool/\(identity.poolID)/my-model","artifact_hash_algorithm":"macprovider.gguf-file.v1",
        "artifact_hash":"\(String(repeating: "a", count: 64))","allowed_runtime_sources":["ollama_loopback","llamacpp_loopback"],
        "license":"Apache-2.0","paid_serving_attested":true,
        "pricing":{"prompt_rate_per_mtok":100,"prompt_cache_hit_rate_per_mtok":50,"completion_rate_per_mtok":200},
        "disclosure_class":"pool_attested_unverified","max_context_tokens":32768}]}
        """.utf8).write(to: modelsURL)
        var options = CreatorOperations.ManifestOptions()
        (options.modelEntries, options.attestedMembers) = try CreatorOperations.loadModelsFile(modelsURL.path)
        let pending = try CreatorOperations.signManifest(home: home, poolID: identity.poolID, options: options)
        XCTAssertEqual(pending.state.manifestVersion, 1)
        XCTAssertTrue(fake.requests.count == 4, "signing must not touch the network")
        _ = try await CreatorOperations.submitManifest(home: home, client: client, poolID: identity.poolID)
        _ = try await CreatorOperations.admit(home: home, client: client, poolID: identity.poolID, providerID: "mp-owned")
        _ = try await CreatorOperations.authorizeBuyer(home: home, client: client, poolID: identity.poolID, accountID: "acct_buyer", remove: false)
        _ = try await CreatorOperations.promote(home: home, client: client, poolID: identity.poolID)

        let requests = fake.requests
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /v1/creator/me", "POST /v1/creator/events",
            "POST /v1/creator/root-registration-nonces", "POST /v1/creator/events",
            "POST /v1/creator/events", "POST /v1/creator/events", "POST /v1/creator/events",
            "POST /v1/creator/pools/\(identity.poolID)/promote",
        ])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mp_test_key")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-MacProvider-Creator-Account-ID"))
        }

        // No private key byte appears in any request.
        let keys = try home.keys(identity.poolID)
        for request in requests {
            let raw = request.httpBody ?? Data()
            for secret in [keys.rootIssuerP256, keys.manifestAuthorityEd25519, keys.policySignerEd25519] {
                XCTAssertNil(raw.range(of: secret.base64EncodedData()))
                XCTAssertNil(raw.range(of: secret))
            }
        }

        // Pool creation binds the identity core.
        let create = body(requests[1])
        XCTAssertEqual(create["event_type"] as? String, "pool_created")
        XCTAssertEqual(create["approval_record_id"] as? String, "self-serve:acct_creator")

        // The root registration proof verifies over the canonical message.
        let root = body(requests[3])
        var fields: [String: String] = [:]
        for key in ["approval_record_id", "creator_account_id", "current_approval_version", "environment", "genesis_nonce_digest",
                    "intended_pool_display_name_hash", "launch_environment", "nonce", "nonce_expiry", "purpose", "root_issuer_key_id",
                    "root_issuer_public_key_fingerprint", "root_signature_algorithm", "manifest_authority_root_key_id",
                    "manifest_authority_root_public_key", "structured_key_custody_disclosure_hash"] {
            fields[key] = try XCTUnwrap(root[key] as? String, key)
        }
        XCTAssertEqual(fields["launch_environment"], "self_serve_private")
        XCTAssertEqual(fields["nonce_expiry"], "2026-10-09T12:15:00.5Z")
        let rootKey = try P256.Signing.PublicKey(derRepresentation: identity.rootIssuerPublicKeyDER)
        let proof = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(root["proof_of_possession_signature"] as? String))))
        XCTAssertTrue(rootKey.isValidSignature(proof, for: try CreatorRootSigning.rootRegistrationMessage(fields)))

        // The manifest root signature and policy signature verify; the v2
        // core allowlists exactly the entry's external runtimes.
        let manifest = body(requests[4])
        let snapshot = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["manifest_snapshot"] as? String)))
        let state = try XCTUnwrap(try home.manifestState(identity.poolID))
        XCTAssertEqual(try state.snapshot.canonicalBytes(), snapshot)
        let core = try XCTUnwrap(state.snapshot.policies.last?.core)
        XCTAssertEqual(core.runtimeAllowlist, ["llamacpp_loopback", "ollama_loopback"])
        XCTAssertEqual(core.modelAllowlist, ["pool/\(identity.poolID)/my-model"])
        XCTAssertEqual(manifest["manifest_core_digest"] as? String, PoolBytes.hex(try core.manifestCoreDigest()))
        let message = try CreatorRootSigning.manifestAcceptanceMessage(
            poolID: identity.poolID, manifestVersion: 1, manifestCoreDigestHex: PoolBytes.hex(try core.manifestCoreDigest()),
            manifestSnapshot: snapshot, rootIssuerKeyID: identity.rootIssuerKeyID, rootFingerprint: identity.rootIssuerPublicKeyFingerprint
        )
        let manifestSig = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["manifest_signature"] as? String))))
        XCTAssertTrue(rootKey.isValidSignature(manifestSig, for: message))
        let policyKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.policySignerPublicKey)
        XCTAssertTrue(policyKey.isValidSignature(try XCTUnwrap(state.snapshot.policies.last?.signatures.first?.sig), for: try core.signingMessage()))
        let authorityKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.manifestAuthorityPublicKey)
        let genesis = try XCTUnwrap(state.snapshot.authorityLog.first)
        XCTAssertTrue(authorityKey.isValidSignature(try XCTUnwrap(genesis.signatures.first?.sig), for: try genesis.signingMessage()))

        // The next version chains to the accepted core.
        let next = try CreatorOperations.signManifest(home: home, poolID: identity.poolID, options: options)
        XCTAssertEqual(next.state.manifestVersion, 2)
        XCTAssertEqual(next.state.snapshot.policies.last?.core.prevManifestCoreHash, try core.manifestCoreDigest())
        XCTAssertGreaterThanOrEqual(next.state.snapshot.policies.last?.core.notBeforeUnix ?? 0, core.expiresAtUnix)

        if let out = ProcessInfo.processInfo.environment["MACPROVIDER_CREATOR_CROSSCHECK_OUT"], !out.isEmpty {
            let dump: [String: Any] = ["root_issuer_registered": root, "manifest_accepted": manifest, "pool_created": create]
            try JSONSerialization.data(withJSONObject: dump, options: [.sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
    }

    func testGatewayURLMustBeHTTPSOrLoopback() {
        XCTAssertNoThrow(try CreatorClient.validatedGatewayURL("https://api.malibu.tech"))
        XCTAssertNoThrow(try CreatorClient.validatedGatewayURL("http://127.0.0.1:8080"))
        XCTAssertThrowsError(try CreatorClient.validatedGatewayURL("http://example.com"))
        XCTAssertThrowsError(try CreatorClient.validatedGatewayURL("not a url"))
    }

    func testRetriedWritesReuseTheOperationIDUntilADefinitiveAnswer() async throws {
        final class Flaky: CreatorTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            private(set) var keys: [String] = []
            func send(_ request: URLRequest) async throws -> CreatorResponse {
                let attempt = lock.withLock { () -> Int in
                    calls += 1
                    keys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
                    return calls
                }
                switch attempt {
                case 1: throw CreatorCLIError.transport("connection reset")
                case 2: return jsonResponse(503, ["error": ["code": "unavailable"]])
                default: return jsonResponse(202, ["event": ["ok": true]])
                }
            }
        }
        let fake = Flaky()
        let home = CreatorHome(root: homeURL)
        let client = CreatorClient(login: CreatorLogin(gatewayURL: "https://api.malibu.tech", apiKey: "k"), transport: fake)
        let pool = "AAAAAAAAAAAAAAAAAAAAAA"
        do { _ = try await CreatorOperations.admit(home: home, client: client, poolID: pool, providerID: "mp-owned"); XCTFail("expected transport error") } catch {}
        do { _ = try await CreatorOperations.admit(home: home, client: client, poolID: pool, providerID: "mp-owned"); XCTFail("expected 503") } catch {}
        _ = try await CreatorOperations.admit(home: home, client: client, poolID: pool, providerID: "mp-owned")
        _ = try await CreatorOperations.admit(home: home, client: client, poolID: pool, providerID: "mp-owned")
        XCTAssertEqual(fake.keys.count, 4)
        XCTAssertEqual(Set(fake.keys[0...2]).count, 1, "retries before a definitive answer must reuse one operation id")
        XCTAssertNotEqual(fake.keys[3], fake.keys[2], "a new run after success is a new operation")
    }

    func testRootRegistrationRetryResendsTheCommittedEventUnchanged() async throws {
        final class LossyCoordinator: CreatorTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var committed: (key: String, body: Data)?
            private(set) var nonces = 0
            private(set) var rootAttempts = 0
            func send(_ request: URLRequest) async throws -> CreatorResponse {
                let path = request.url?.path ?? ""
                if path == "/v1/creator/root-registration-nonces" {
                    let n = lock.withLock { () -> Int in nonces += 1; return nonces }
                    return jsonResponse(201, ["root_registration_nonce": [
                        "nonce": "nonce-\(n)", "creator_account_id": "acct_creator", "approval_record_id": "self-serve:acct_creator",
                        "current_approval_version": "self-serve-1", "launch_environment": "self_serve_private",
                        "expires_at_utc": "2026-10-09T12:15:00.5Z", "purpose": "root_issuer_registration",
                    ]])
                }
                let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
                let payload = request.httpBody ?? Data()
                let outcome = lock.withLock { () -> Int in
                    rootAttempts += 1
                    guard let committed else {
                        self.committed = (key, payload)
                        return 0 // committed, response lost
                    }
                    return committed.key == key && committed.body == payload ? 202 : 409
                }
                if outcome == 0 { throw CreatorCLIError.transport("connection reset after commit") }
                return jsonResponse(outcome, outcome == 202 ? ["event": ["ok": true]] : ["error": ["code": "conflicting_operation_id"]])
            }
        }
        let fake = LossyCoordinator()
        let home = CreatorHome(root: homeURL)
        let client = CreatorClient(login: CreatorLogin(gatewayURL: "https://api.malibu.tech", apiKey: "k"), transport: fake)
        let identity = try CreatorOperations.keygen(home: home)
        do {
            _ = try await CreatorOperations.registerRoot(home: home, client: client, poolID: identity.poolID, displayName: "Studio Pool")
            XCTFail("expected the lost response to surface")
        } catch {}
        _ = try await CreatorOperations.registerRoot(home: home, client: client, poolID: identity.poolID, displayName: "Studio Pool")
        XCTAssertEqual(fake.nonces, 1, "a retry must not mint a new nonce or re-sign")
        XCTAssertEqual(fake.rootAttempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.poolDir(identity.poolID).appendingPathComponent("root-registration-pending.json").path))
    }

    func testRateLimitedRetryKeepsThePendingRootRegistration() async throws {
        final class RateLimitedCoordinator: CreatorTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var committed: (key: String, body: Data)?
            private(set) var nonces = 0
            private(set) var rootAttempts = 0
            func send(_ request: URLRequest) async throws -> CreatorResponse {
                if request.url?.path == "/v1/creator/root-registration-nonces" {
                    lock.withLock { nonces += 1 }
                    return jsonResponse(201, ["root_registration_nonce": [
                        "nonce": "nonce-1", "creator_account_id": "acct_creator", "approval_record_id": "self-serve:acct_creator",
                        "current_approval_version": "self-serve-1", "launch_environment": "self_serve_private",
                        "expires_at_utc": "2026-10-09T12:15:00.5Z", "purpose": "root_issuer_registration",
                    ]])
                }
                let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
                let payload = request.httpBody ?? Data()
                let attempt = lock.withLock { () -> Int in
                    rootAttempts += 1
                    if committed == nil { committed = (key, payload) }
                    return rootAttempts
                }
                switch attempt {
                case 1: throw CreatorCLIError.transport("connection reset after commit")
                case 2: return jsonResponse(429, ["error": ["code": "rate_limited"]])
                default:
                    let same = lock.withLock { committed?.key == key && committed?.body == payload }
                    return jsonResponse(same ? 202 : 409, same ? ["event": ["ok": true]] : ["error": ["code": "conflicting_operation_id"]])
                }
            }
        }
        let fake = RateLimitedCoordinator()
        let home = CreatorHome(root: homeURL)
        let client = CreatorClient(login: CreatorLogin(gatewayURL: "https://api.malibu.tech", apiKey: "k"), transport: fake)
        let identity = try CreatorOperations.keygen(home: home)
        let pending = home.poolDir(identity.poolID).appendingPathComponent("root-registration-pending.json")
        do { _ = try await CreatorOperations.registerRoot(home: home, client: client, poolID: identity.poolID, displayName: "Studio Pool"); XCTFail("expected lost response") } catch {}
        do { _ = try await CreatorOperations.registerRoot(home: home, client: client, poolID: identity.poolID, displayName: "Studio Pool"); XCTFail("expected 429") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), "a 429 must keep the signed registration")
        _ = try await CreatorOperations.registerRoot(home: home, client: client, poolID: identity.poolID, displayName: "Studio Pool")
        XCTAssertEqual(fake.nonces, 1)
        XCTAssertEqual(fake.rootAttempts, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertFalse(CreatorOperations.isDefinitive(429))
        XCTAssertFalse(CreatorOperations.isDefinitive(401))
        XCTAssertTrue(CreatorOperations.isDefinitive(409))
    }

    func testOptionalPoolMustBeAWellFormedPoolID() {
        XCTAssertThrowsError(try CreatorStatusCommand.parse(["--pool", "../me"]))
        XCTAssertThrowsError(try CreatorEarningsCommand.parse(["--pool", "short"]))
        XCTAssertNoThrow(try CreatorStatusCommand.parse(["--pool", "AAAAAAAAAAAAAAAAAAAAAA"]))
        XCTAssertNoThrow(try CreatorEarningsCommand.parse([]))
    }

    func testHTTPErrorsSurfaceTheGatewayBody() async throws {
        let fake = RecordingCreatorTransport { _ in jsonResponse(409, ["error": ["code": "promotion_precondition_failed", "reason": "member_missing"]]) }
        let client = CreatorClient(login: CreatorLogin(gatewayURL: "https://api.malibu.tech", apiKey: "k"), transport: fake)
        do {
            _ = try await CreatorOperations.promote(home: CreatorHome(root: homeURL), client: client, poolID: "AAAAAAAAAAAAAAAAAAAAAA")
            XCTFail("expected an error")
        } catch let error as CreatorCLIError {
            XCTAssertTrue(error.description.contains("member_missing"))
        }
    }
}
