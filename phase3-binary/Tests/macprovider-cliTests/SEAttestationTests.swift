import CryptoKit
import XCTest
@testable import macprovider_cli

// MARK: - Mock signer (P256 software key, no SE required)

private final class MockSEBlobSigner: SEBlobSigner {
    let p256Key: P256.Signing.PrivateKey

    init() {
        self.p256Key = P256.Signing.PrivateKey()
    }

    func sign(_ data: Data) throws -> Data {
        let signature = try p256Key.signature(for: data)
        return signature.derRepresentation
    }

    var publicKeyRaw: Data {
        // X9.62 uncompressed: 0x04 || X (32 bytes) || Y (32 bytes); strip 0x04 prefix
        let x963 = p256Key.publicKey.x963Representation
        return x963.count == 65 ? Data(x963.dropFirst()) : x963
    }
}

// MARK: - SEAttestationBuilderTests

final class SEAttestationBuilderTests: XCTestCase {

    // MARK: AttestationBlob canonical JSON

    func testCanonicalJSONProducesSortedKeys() throws {
        let signer = MockSEBlobSigner()
        let fixedDate = Date(timeIntervalSince1970: 1_716_768_000)
        let builder = SEAttestationBuilder(
            now: { fixedDate },
            sysctlStringOverride: { name in
                switch name {
                case "machdep.cpu.brand_string": return "Apple M4"
                case "hw.model": return "Mac15,3"
                default: return nil
                }
            }
        )

        let attestation = try builder.build(
            signer: signer,
            providerECDHPublicKey: "test-ecdh-key"
        )
        let blob = attestation.blob
        XCTAssertEqual(blob.chipName, "Apple M4")
        XCTAssertEqual(blob.hardwareModel, "Mac15,3")
        XCTAssertEqual(blob.encryptionPublicKey, "test-ecdh-key")
        XCTAssertEqual(blob.timestamp, "2024-05-27T00:00:00Z")

        // Canonical JSON must have sorted keys
        let canonical = try blob.canonicalJSON()
        let parsed = try JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        XCTAssertNotNil(parsed)

        // Verify the JSON string has keys in ascending order
        let jsonString = String(data: canonical, encoding: .utf8) ?? ""
        let keyOrder = ["binaryHash", "chipName", "encryptionPublicKey", "hardwareModel",
                        "osVersion", "publicKey", "secureBootEnabled", "secureEnclaveAvailable",
                        "serialNumber", "sipEnabled", "timestamp"]
        var prevIdx = jsonString.startIndex
        for key in keyOrder {
            if let range = jsonString.range(of: "\"\(key)\"") {
                XCTAssertGreaterThanOrEqual(range.lowerBound, prevIdx,
                    "Key '\(key)' appeared before expected position")
                prevIdx = range.upperBound
            }
        }
    }

    func testCanonicalJSONOmitsNilOptionals() throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(
            now: { Date(timeIntervalSince1970: 0) },
            sysctlStringOverride: { _ in nil },
            serialNumberOverride: { nil }
        )
        let attestation = try builder.build(
            signer: signer,
            providerECDHPublicKey: "ecdh",
            binaryHash: nil
        )
        let json = String(data: try attestation.blob.canonicalJSON(), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("binaryHash"))
        XCTAssertFalse(json.contains("serialNumber"))
    }

    func testCanonicalJSONIncludesBinaryHashWhenProvided() throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(
            now: { Date(timeIntervalSince1970: 0) },
            sysctlStringOverride: { _ in nil }
        )
        let attestation = try builder.build(
            signer: signer,
            providerECDHPublicKey: "ecdh",
            binaryHash: "abc123"
        )
        let json = String(data: try attestation.blob.canonicalJSON(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"binaryHash\""))
        XCTAssertTrue(json.contains("abc123"))
    }

    // MARK: SignedSEAttestation tokenJSON

    func testTokenJSONHasExpectedShape() throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(
            now: { Date(timeIntervalSince1970: 1_716_768_000) },
            sysctlStringOverride: { _ in nil }
        )
        let attestation = try builder.build(signer: signer, providerECDHPublicKey: "ecdh")
        let tokenData = try attestation.tokenJSON()
        let tokenObj = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any]

        XCTAssertNotNil(tokenObj?["attestation"] as? [String: Any])
        XCTAssertNotNil(tokenObj?["signature"] as? String)

        let inner = try XCTUnwrap(tokenObj?["attestation"] as? [String: Any])
        XCTAssertEqual(inner["chipName"] as? String, "Apple Silicon")
        XCTAssertEqual(inner["encryptionPublicKey"] as? String, "ecdh")
    }

    func testTokenBase64URLRoundTrips() throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(
            now: { Date(timeIntervalSince1970: 1_716_768_000) },
            sysctlStringOverride: { _ in nil }
        )
        let attestation = try builder.build(signer: signer, providerECDHPublicKey: "ecdh")
        let b64url = try attestation.tokenBase64URL()

        // Must be valid base64url (no +, /, =)
        XCTAssertFalse(b64url.contains("+"))
        XCTAssertFalse(b64url.contains("/"))
        XCTAssertFalse(b64url.contains("="))

        // Must decode back to the same JSON
        let decoded = try Data(base64URLUnpadded: b64url)
        let obj = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        XCTAssertNotNil(obj?["attestation"])
        XCTAssertNotNil(obj?["signature"])
    }

    // MARK: Signature verification

    func testBlobSignatureVerifiesAgainstPublicKey() throws {
        let signer = MockSEBlobSigner()
        let p256Key = signer.p256Key
        let builder = SEAttestationBuilder(
            now: { Date(timeIntervalSince1970: 1_716_768_000) },
            sysctlStringOverride: { _ in nil }
        )
        let attestation = try builder.build(signer: signer, providerECDHPublicKey: "ecdh")

        // Re-derive canonical JSON and verify the outer signature
        let canonical = try attestation.blob.canonicalJSON()
        let sigData = Data(base64Encoded: attestation.signatureBase64) ?? Data()
        let sig = try P256.Signing.ECDSASignature(derRepresentation: sigData)
        XCTAssertTrue(p256Key.publicKey.isValidSignature(sig, for: canonical))
    }
}

// MARK: - SEAttestationGeneratorEnvelopeTests

final class SEAttestationGeneratorEnvelopeTests: XCTestCase {

    private func makeSnapshot() async -> ProviderSnapshot {
        let status = ProviderStatus(
            modelID: "model-test",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        return await status.snapshot()
    }

    func testEnvelopeShapeMatchesSpecFormat() async throws {
        let signer = MockSEBlobSigner()
        let fixedDate = Date(timeIntervalSince1970: 1_716_768_000)
        let builder = SEAttestationBuilder(
            now: { fixedDate },
            sysctlStringOverride: { _ in nil }
        )
        let generator = SecureEnclaveAttestationGenerator(
            signer: signer,
            builder: builder,
            now: { fixedDate }
        )

        let snapshot = await makeSnapshot()
        let challenge = Data(repeating: 0x11, count: 32).base64URLUnpadded()
        let envelope = await generator.makeAttestationToken(
            challengeBase64URL: challenge,
            authAttemptID: "attempt-001",
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: "ecdh-key-b64"
        )

        let env = try XCTUnwrap(envelope)
        XCTAssertEqual(env["format"] as? String, SecureEnclaveAttestationGenerator.format)
        XCTAssertEqual(env["challenge"] as? String, challenge)
        XCTAssertEqual(env["provider_id"] as? String, "provider-test")
        XCTAssertEqual(env["binary_version"] as? String, CoordinatorClient.binaryVersion)
        XCTAssertEqual(env["issued_at"] as? String, "2024-05-27T00:00:00Z")
        XCTAssertEqual(env["expires_at"] as? String, "2024-05-27T00:10:00Z")

        let binding = try XCTUnwrap(env["key_binding"] as? [String: Any])
        XCTAssertEqual(binding["provider_ecdh_public_key"] as? String, "ecdh-key-b64")

        let claimed = try XCTUnwrap(env["claimed"] as? [String: Any])
        XCTAssertEqual(claimed["hardware_family"] as? String, "apple_silicon")
        XCTAssertEqual(claimed["model_id"] as? String, "model-test")

        // Token must be base64url-encoded SignedSEAttestation JSON
        let tokenB64 = try XCTUnwrap(env["token"] as? String)
        let tokenData = try Data(base64URLUnpadded: tokenB64)
        let tokenObj = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any]
        XCTAssertNotNil(tokenObj?["attestation"])
        XCTAssertNotNil(tokenObj?["signature"])
    }

    func testEnvelopeContainsBindingSignature() async throws {
        let signer = MockSEBlobSigner()
        let fixedDate = Date(timeIntervalSince1970: 1_716_768_000)
        let builder = SEAttestationBuilder(
            now: { fixedDate },
            sysctlStringOverride: { _ in nil }
        )
        let generator = SecureEnclaveAttestationGenerator(
            signer: signer,
            builder: builder,
            now: { fixedDate }
        )
        let snapshot = await makeSnapshot()
        let challenge = Data(repeating: 0x22, count: 32).base64URLUnpadded()

        let envelope = await generator.makeAttestationToken(
            challengeBase64URL: challenge,
            authAttemptID: "attempt-bind",
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: "ecdh-key"
        )

        let env = try XCTUnwrap(envelope)
        let sig = try XCTUnwrap(env["signature"] as? [String: Any])
        XCTAssertEqual(sig["alg"] as? String, "ES256")
        let sigStr = try XCTUnwrap(sig["signature"] as? String)
        XCTAssertFalse(sigStr.isEmpty)

        // Binding signature must be base64url (no + / =)
        XCTAssertFalse(sigStr.contains("+"))
        XCTAssertFalse(sigStr.contains("/"))
        XCTAssertFalse(sigStr.contains("="))
    }

    func testBindingSignatureMatchesBINDINGPayloadFormat() async throws {
        let signer = MockSEBlobSigner()
        let fixedDate = Date(timeIntervalSince1970: 1_716_768_000)
        let builder = SEAttestationBuilder(
            now: { fixedDate },
            sysctlStringOverride: { _ in nil }
        )
        let generator = SecureEnclaveAttestationGenerator(
            signer: signer,
            builder: builder,
            now: { fixedDate }
        )
        let snapshot = await makeSnapshot()
        let challenge = Data(repeating: 0x33, count: 32).base64URLUnpadded()
        let providerECDH = "ecdh-pub-b64"
        let attemptID = "attempt-verify"

        let envelope = await generator.makeAttestationToken(
            challengeBase64URL: challenge,
            authAttemptID: attemptID,
            providerID: "provider-verify",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: providerECDH
        )
        let env = try XCTUnwrap(envelope)

        // Reconstruct the binding payload exactly as the coordinator will
        let payload = try ManagedDeviceAttestationGenerator.buildBindingPayload(
            envelope: env,
            authAttemptID: attemptID
        )

        // Binding payload must start with version field (Go attestationBindingPayload format)
        let payloadStr = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertTrue(payloadStr.contains("macprovider/spec008/attestation-binding/v1"))
        XCTAssertTrue(payloadStr.contains("provider-verify"))
        XCTAssertTrue(payloadStr.contains(attemptID))

        // Verify the signature against the mock signer's public key
        let sigDict = try XCTUnwrap(env["signature"] as? [String: Any])
        let sigB64URL = try XCTUnwrap(sigDict["signature"] as? String)
        let sigDER = try Data(base64URLUnpadded: sigB64URL)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: sigDER)
        XCTAssertTrue(signer.p256Key.publicKey.isValidSignature(sig, for: payload))
    }

    func testGeneratorReturnsNilWhenChallengeAbsent() async {
        let signer = MockSEBlobSigner()
        let generator = SecureEnclaveAttestationGenerator(signer: signer)
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 1_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let result = await generator.makeAttestationToken(
            challengeBase64URL: nil,
            authAttemptID: "a",
            providerID: "p",
            binaryVersion: "1.0",
            snapshot: snapshot,
            providerECDHPublicKey: "k"
        )
        XCTAssertNil(result)
    }

    func testGeneratorReturnsNilWhenChallengeEmpty() async {
        let signer = MockSEBlobSigner()
        let generator = SecureEnclaveAttestationGenerator(signer: signer)
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 1_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let result = await generator.makeAttestationToken(
            challengeBase64URL: "",
            authAttemptID: "a",
            providerID: "p",
            binaryVersion: "1.0",
            snapshot: snapshot,
            providerECDHPublicKey: "k"
        )
        XCTAssertNil(result)
    }

    func testPublicKeyInBlobMatchesMockSignerKey() async throws {
        let signer = MockSEBlobSigner()
        let fixedDate = Date(timeIntervalSince1970: 0)
        let builder = SEAttestationBuilder(
            now: { fixedDate },
            sysctlStringOverride: { _ in nil }
        )
        let generator = SecureEnclaveAttestationGenerator(
            signer: signer,
            builder: builder,
            now: { fixedDate }
        )
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 1_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let challenge = Data(repeating: 0x44, count: 32).base64URLUnpadded()

        let envelope = await generator.makeAttestationToken(
            challengeBase64URL: challenge,
            authAttemptID: "attempt-key",
            providerID: "p",
            binaryVersion: "1",
            snapshot: snapshot,
            providerECDHPublicKey: "ecdh"
        )
        let env = try XCTUnwrap(envelope)
        let tokenB64 = try XCTUnwrap(env["token"] as? String)
        let tokenData = try Data(base64URLUnpadded: tokenB64)
        let tokenObj = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any]
        let inner = try XCTUnwrap(tokenObj?["attestation"] as? [String: Any])
        let pubKeyB64 = try XCTUnwrap(inner["publicKey"] as? String)
        let pubKeyData = try XCTUnwrap(Data(base64Encoded: pubKeyB64))

        XCTAssertEqual(pubKeyData, signer.publicKeyRaw)
    }
}

final class MacProviderKeychainAccessGroupTests: XCTestCase {
    func testProductionAccessGroupMatchesReleaseEntitlement() {
        XCTAssertEqual(
            MacProviderKeychainAccessGroup.production,
            "YF7XNRJUG4.live.malibu.provider"
        )
        XCTAssertEqual(MacProviderKeychainAccessGroup.productionTeamID, "YF7XNRJUG4")
        XCTAssertEqual(
            MacProviderKeychainAccessGroup.resolve("override.group"),
            "override.group"
        )
    }
}


