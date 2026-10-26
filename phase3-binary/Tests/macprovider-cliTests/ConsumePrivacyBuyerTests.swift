import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class ConsumePrivacyBuyerTests: XCTestCase {
    func testDirectoryChecksPinnedSignerFreshnessAndExactPayload() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let now = Int64(Date().timeIntervalSince1970)
        let fresh = try directory(signer: signer, issued: now, expires: now + 300)
        XCTAssertNoThrow(try ConsumePrivacyBuyer.verifyDirectory(fresh, publicKey: signer.publicKey, now: Date()))
        XCTAssertThrowsError(try ConsumePrivacyBuyer.verifyDirectory(fresh, publicKey: Curve25519.Signing.PrivateKey().publicKey, now: Date()))
        XCTAssertThrowsError(try ConsumePrivacyBuyer.verifyDirectory(
            directory(signer: signer, issued: now - 301, expires: now - 1), publicKey: signer.publicKey, now: Date()))
        var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: fresh) as? [String: Any])
        let differentPayload = try directoryPayload(issued: now, expires: now + 301)
        altered["payload"] = RelayBlindBase64URL.encode(differentPayload)
        XCTAssertThrowsError(try ConsumePrivacyBuyer.verifyDirectory(json(altered), publicKey: signer.publicKey, now: Date()))
        let duplicate = Data("{\"version\":\"first\",\"version\":\"second\",\"key_id\":\"x\",\"payload\":\"x\",\"signature\":\"x\"}".utf8)
        XCTAssertThrowsError(try ConsumePrivacyBuyer.verifyDirectory(duplicate, publicKey: signer.publicKey, now: Date()))
    }

    func testResponseReturnsOriginalWireOnlyAfterFinalAuthentication() throws {
        for stream in [false, true] {
            let fixture = try ResponseFixture(stream: stream)
            let wire = stream ? Data("event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n".utf8)
                : Data("{\"id\":\"msg_1\",\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"answer\"}]}".utf8)
            let frames = try fixture.frames(plaintext: wire)
            let raw = try fixture.response(frames: frames)
            let opened = try fixture.open(raw)
            XCTAssertEqual(opened.body, wire)
            let usage = try XCTUnwrap(JSONSerialization.jsonObject(with: opened.usage) as? [String: Any])
            XCTAssertEqual(usage["prompt_tokens"] as? Int, 7)

            XCTAssertThrowsError(try fixture.open(fixture.response(frames: Array(frames.dropLast()))))
            XCTAssertThrowsError(try fixture.open(fixture.response(frames: Array(frames.reversed()))))
            var tampered = frames
            tampered[0]["ciphertext"] = RelayBlindBase64URL.encode(Data(repeating: 0, count: 32))
            XCTAssertThrowsError(try fixture.open(fixture.response(frames: tampered)))
            XCTAssertThrowsError(try fixture.open(fixture.response(frames: frames, promptTokens: 8)))
            XCTAssertThrowsError(try fixture.open(fixture.response(frames: frames, assurance: "code_bound_attested")))
            XCTAssertThrowsError(try fixture.open(raw, requestID: "different_request"))
        }
    }

    func testStreamRequiresCompleteOuterProtocolAndRejectsClearContent() throws {
        let fixture = try ResponseFixture(stream: true)
        let frames = try fixture.frames(plaintext: Data("data: {\"choices\":[]}\n\n".utf8))
        let raw = try fixture.response(frames: frames)
        let missingDone = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "data: [DONE]\n\n", with: "").utf8)
        XCTAssertThrowsError(try fixture.open(missingDone))
        var appended = raw
        appended.append(Data("data: {\"content\":\"plaintext\"}\n\n".utf8))
        XCTAssertThrowsError(try fixture.open(appended))
        let injected = Data("data: {\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[{\"content\":\"plaintext\"}]}\n\n".utf8) + raw
        XCTAssertThrowsError(try fixture.open(injected))
    }

    func testOriginalRequestMetadataRejectsDuplicateAndConflictingStream() throws {
        let body = Data("{\"model\":\"model-a\",\"input\":\"hello\",\"max_output_tokens\":32,\"stream\":true}".utf8)
        let copy = body
        let metadata = try ConsumePrivacyBuyer.requestMetadata(body, family: "responses", streaming: true)
        XCTAssertEqual(metadata.model, "model-a")
        XCTAssertEqual(metadata.outputCap, 32)
        XCTAssertEqual(body, copy)
        XCTAssertThrowsError(try ConsumePrivacyBuyer.requestMetadata(body, family: "responses", streaming: false))
        XCTAssertThrowsError(try ConsumePrivacyBuyer.requestMetadata(
            Data("{\"model\":\"model-a\",\"model\":\"other\",\"input\":\"x\"}".utf8), family: "responses", streaming: false))
    }

    func testReservationRejectsFamilySubstitutionRevocationAndAssuranceDowngrade() throws {
        let now = Int64(Date().timeIntervalSince1970)
        let identity = Curve25519.Signing.PrivateKey()
        let key = try RelayBlindKeyRecord.make(identityKey: identity, encryptionKey: Curve25519.KeyAgreement.PrivateKey(),
            models: ["model-a"], maxEncryptedRequestBytes: 1 << 20, notBeforeUnix: now, expiresAtUnix: now + 300,
            endpointFamilies: ["chat_completions", "messages", "responses"])
        let input = try ConsumePrivacyBuyer.requestMetadata(
            Data("{\"model\":\"model-a\",\"input\":\"x\",\"max_output_tokens\":32}".utf8), family: "responses", streaming: false)
        let attestation = PrivacyKeyAttestation(version: PrivacyClassConstants.keyAttestationVersion,
            keyRecordDigest: key.keyRecordDigest, privacyClass: PrivacyClassConstants.v1,
            assurance: PrivacyClassConstants.assurance, binaryVersion: "test", codeCDHash: String(repeating: "a", count: 40),
            notBeforeUnix: now, expiresAtUnix: now + 300)
        let entry: [String: Any] = ["identity_public_key": RelayBlindBase64URL.encode(identity.publicKey.rawRepresentation),
            "fingerprint": RelayBlindBase64URL.encode(key.identityFingerprint), "revoked": false]
        let directory = ConsumePrivacyBuyer.Directory(issuedAt: now, expiresAt: now + 300, entries: [entry])
        let reservation: [String: Any] = [
            "version": PrivacyClassConstants.reservationVersion,
            "provider_binding": RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
            "buyer_binding": RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
            "key_record_digest": key.keyRecordDigest, "key_record": key.wireObject, "kid": key.kid,
            "endpoint_family": "responses", "model": "model-a", "provider_model": "model-a", "stream": false,
            "max_encrypted_request_bytes": key.maxEncryptedRequestBytes,
            "max_output_tokens": input.outputCap, "input_token_upper_bound": input.inputCap,
            "reservation_token_cap": input.inputCap + input.outputCap,
            "expires_at_unix": now + 60, "cache_policy": "no-store", "failover_policy": "disabled",
            "privacy_class": PrivacyClassConstants.v1, "privacy_assurance": PrivacyClassConstants.assurance,
            "privacy_key_attestation": attestation.wireObject,
            "privacy_key_attestation_signature": RelayBlindBase64URL.encode(try attestation.sign(identityKey: identity)),
            "privacy_posture_verified_at_unix": now,
        ]
        func verify(_ raw: [String: Any], assurance: String = PrivacyClassConstants.assurance,
                    directory: ConsumePrivacyBuyer.Directory? = nil) throws {
            _ = try ConsumePrivacyBuyer.verifyReservation(json(raw), input: input, family: "responses", stream: false,
                assurance: assurance, directory: directory ?? ConsumePrivacyBuyer.Directory(issuedAt: now, expiresAt: now + 300, entries: [entry]), now: Date())
        }
        XCTAssertNoThrow(try verify(reservation))
        XCTAssertThrowsError(try verify(reservation, assurance: "code_bound_attested"))
        var changed = reservation
        changed["endpoint_family"] = "messages"
        XCTAssertThrowsError(try verify(changed))
        changed = reservation
        var record = key.wireObject
        record["endpoint_families"] = ["chat_completions", "messages"]
        changed["key_record"] = record
        XCTAssertThrowsError(try verify(changed))
        var revoked = entry
        revoked["revoked"] = true
        XCTAssertThrowsError(try verify(reservation, directory: ConsumePrivacyBuyer.Directory(
            issuedAt: directory.issuedAt, expiresAt: directory.expiresAt, entries: [revoked])))
    }

    private func directory(signer: Curve25519.Signing.PrivateKey, issued: Int64, expires: Int64) throws -> Data {
        let payload = try directoryPayload(issued: issued, expires: expires)
        var signed = Data()
        signed.appendFramed(Data("macprovider/spec049/identity-directory/v1".utf8))
        signed.appendFramed(payload)
        return try json(["version": "privacy-identity-directory-envelope-v1",
            "key_id": RelayBlindBase64URL.encode(Data(SHA256.hash(data: signer.publicKey.rawRepresentation))),
            "payload": RelayBlindBase64URL.encode(payload), "signature": RelayBlindBase64URL.encode(signer.signature(for: signed))])
    }

    private func directoryPayload(issued: Int64, expires: Int64) throws -> Data {
        try json(["version": "privacy-identity-directory-v1", "privacy_class": PrivacyClassConstants.v1,
                  "issued_at_unix": issued, "expires_at_unix": expires, "entries": []])
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    private struct ResponseFixture {
        let stream: Bool
        let secret: SharedSecret
        let aad = Data("buyer-test-aad".utf8)
        let digest = RelayBlindBase64URL.encode(Data(repeating: 3, count: 32))
        let kid = RelayBlindBase64URL.encode(Data(repeating: 4, count: 16))
        let requestID = "req_consume_buyer_test"

        init(stream: Bool) throws {
            self.stream = stream
            let provider = Curve25519.KeyAgreement.PrivateKey(), buyer = Curve25519.KeyAgreement.PrivateKey()
            secret = try provider.sharedSecretFromKeyAgreement(with: buyer.publicKey)
        }

        func frames(plaintext: Data) throws -> [[String: Any]] {
            var sealer = try PrivacyResponseSealer(sharedSecret: secret, aad: aad, envelopeDigest: digest,
                                                  kid: kid, requestID: requestID, stream: stream)
            var content = plaintext
            let frame = try sealer.seal(&content, final: false)
            var final = try JSONSerialization.data(withJSONObject: ["version": PrivacyClassConstants.finalVersion,
                "status": "complete", "prompt_tokens": 7, "completion_tokens": 3])
            return [frame, try sealer.seal(&final, final: true)]
        }

        func response(frames: [[String: Any]], promptTokens: Int = 7,
                      assurance: String = PrivacyClassConstants.assurance) throws -> Data {
            let labels = ConsumePrivacyDisclosure(assurance: assurance)
            let usage: [String: Any] = ["prompt_tokens": promptTokens, "completion_tokens": 3, "total_tokens": promptTokens + 3,
                "macprovider": ["requested_privacy_mode": "relay_blind_required", "effective_privacy_outcome": "relay_blind_satisfied",
                    "scope": "request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays",
                    "settlement": ["verified_model_settlement": "unavailable_for_relay_blind_request",
                                   "usage_settlement": "standard_usage_settlement_and_clear_cap_enforcement_still_apply"],
                    "privacy": ["class": PrivacyClassConstants.v1, "assurance": assurance, "scope": labels.scope,
                        "protects": labels.protects, "does_not_protect": labels.doesNotProtect,
                        "residual_risks": labels.residualRisks, "posture_verified_at_unix": 1]]]
            if !stream {
                return try JSONSerialization.data(withJSONObject: ["object": PrivacyClassConstants.responseObject,
                    "version": PrivacyClassConstants.responseVersion, "frames": frames, "usage": usage])
            }
            var result = Data()
            for frame in frames { result.append(Data("data: ".utf8)); result.append(try JSONSerialization.data(withJSONObject: frame)); result.append(Data("\n\n".utf8)) }
            result.append(Data("data: ".utf8))
            result.append(try JSONSerialization.data(withJSONObject: ["object": "chat.completion.chunk", "model": "model-a", "choices": [], "usage": usage]))
            result.append(Data("\n\ndata: [DONE]\n\n".utf8))
            return result
        }

        func open(_ raw: Data, requestID: String? = nil) throws -> (body: Data, usage: Data) {
            let keys = try PrivacyResponseSealer.derive(sharedSecret: secret, aad: aad)
            return try ConsumePrivacyBuyer.openResponse(raw, streaming: stream, responseKey: keys.key,
                noncePrefix: keys.noncePrefix, digest: digest, kid: kid, requestID: requestID ?? self.requestID,
                model: "model-a", inputCap: 100, outputCap: 32, assurance: PrivacyClassConstants.assurance)
        }
    }
}
