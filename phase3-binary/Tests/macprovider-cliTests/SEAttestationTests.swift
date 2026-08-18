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
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })

        let attestation = try builder.build(
            signer: signer,
            providerECDHPublicKey: "test-ecdh-key"
        )
        let blob = attestation.blob
        XCTAssertEqual(blob.encryptionPublicKey, "test-ecdh-key")
        XCTAssertEqual(blob.serialNumber, "H2XX74T43X")

        let canonical = try blob.canonicalJSON()
        let parsed = try JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        XCTAssertNotNil(parsed)

        let jsonString = String(data: canonical, encoding: .utf8) ?? ""
        let keyOrder = ["encryptionPublicKey", "publicKey", "serialNumber"]
        var prevIdx = jsonString.startIndex
        for key in keyOrder {
            let range = try XCTUnwrap(jsonString.range(of: "\"\(key)\""))
            XCTAssertGreaterThanOrEqual(range.lowerBound, prevIdx,
                "Key '\(key)' appeared before expected position")
            prevIdx = range.upperBound
        }
    }

    func testCanonicalJSONOmitsNilSerial() throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(serialNumberOverride: { nil })
        let attestation = try builder.build(
            signer: signer,
            providerECDHPublicKey: "ecdh"
        )
        let json = String(data: try attestation.blob.canonicalJSON(), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("serialNumber"))
        XCTAssertFalse(json.contains("chipName"))
        XCTAssertFalse(json.contains("binaryHash"))
    }

    func testCanonicalJSONLeavesBase64SlashesLiteral() throws {
        let blob = AttestationBlob(
            publicKey: "abc/def+ghi=",
            encryptionPublicKey: "ecdh",
            serialNumber: nil
        )
        let json = String(data: try blob.canonicalJSON(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("abc/def+ghi="))
        XCTAssertFalse(json.contains("\\/"))
    }

    // MARK: SignedSEAttestation tokenJSON

    func testTokenJSONHasExpectedShape() throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(serialNumberOverride: { nil })
        let attestation = try builder.build(signer: signer, providerECDHPublicKey: "ecdh")
        let tokenData = try attestation.tokenJSON()
        let tokenObj = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any]

        XCTAssertNotNil(tokenObj?["attestation"] as? [String: Any])
        XCTAssertNotNil(tokenObj?["signature"] as? String)

        let inner = try XCTUnwrap(tokenObj?["attestation"] as? [String: Any])
        XCTAssertEqual(inner["encryptionPublicKey"] as? String, "ecdh")
        XCTAssertNotNil(inner["publicKey"] as? String)
        XCTAssertNil(inner["chipName"])
    }

    func testTokenBase64URLRoundTrips() throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(serialNumberOverride: { nil })
        let attestation = try builder.build(signer: signer, providerECDHPublicKey: "ecdh")
        let b64url = try attestation.tokenBase64URL()

        XCTAssertFalse(b64url.contains("+"))
        XCTAssertFalse(b64url.contains("/"))
        XCTAssertFalse(b64url.contains("="))

        let decoded = try Data(base64URLUnpadded: b64url)
        let obj = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        XCTAssertNotNil(obj?["attestation"])
        XCTAssertNotNil(obj?["signature"])
    }

    // MARK: Signature verification

    func testBlobSignatureVerifiesAgainstPublicKey() throws {
        let signer = MockSEBlobSigner()
        let p256Key = signer.p256Key
        let builder = SEAttestationBuilder(serialNumberOverride: { nil })
        let attestation = try builder.build(signer: signer, providerECDHPublicKey: "ecdh")

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
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })
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
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })
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
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })
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
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })
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

    func testRealisticEnvelopeFitsHandshakeCap() async throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })
        let generator = SecureEnclaveAttestationGenerator(
            signer: signer,
            builder: builder,
            now: { Date(timeIntervalSince1970: 1_716_768_000) }
        )
        let status = ProviderStatus(
            modelID: "mlx-community/Qwen3-8B-4bit",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let challenge = Data(repeating: 0x11, count: 32).base64URLUnpadded()
        let ecdh = Data(repeating: 0x22, count: 32).base64URLUnpadded()
        let envelope = await generator.makeAttestationToken(
            challengeBase64URL: challenge,
            authAttemptID: "attempt-001",
            providerID: "mp-26592d710fc97aa7c07b260665c67cf6",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: ecdh
        )
        let env = try XCTUnwrap(envelope)
        let encoded = try JSONSerialization.data(withJSONObject: env, options: [.withoutEscapingSlashes])
        XCTAssertLessThanOrEqual(
            encoded.count,
            SecureEnclaveAttestationGenerator.maxHandshakeTokenBytes,
            "SE attestation_token must fit coordinator maxHandshakeMetadataBytes"
        )
        let claimed = try XCTUnwrap(env["claimed"] as? [String: Any])
        XCTAssertNil(claimed["model_hash"])
        XCTAssertNil(claimed["weights_manifest_sha256"])
        let tokenB64 = try XCTUnwrap(env["token"] as? String)
        let tokenObj = try JSONSerialization.jsonObject(with: try Data(base64URLUnpadded: tokenB64)) as? [String: Any]
        let inner = try XCTUnwrap(tokenObj?["attestation"] as? [String: Any])
        XCTAssertEqual(inner["serialNumber"] as? String, "H2XX74T43X")
        XCTAssertNil(inner["chipName"])
    }

    func testBindingClaimedHashLeavesModelIDSlashLiteral() async throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })
        let generator = SecureEnclaveAttestationGenerator(
            signer: signer,
            builder: builder,
            now: { Date(timeIntervalSince1970: 1_716_768_000) }
        )
        let status = ProviderStatus(
            modelID: "mlx-community/Qwen3-8B-4bit",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let envelope = await generator.makeAttestationToken(
            challengeBase64URL: Data(repeating: 0x11, count: 32).base64URLUnpadded(),
            authAttemptID: "attempt-slash",
            providerID: "mp-26592d710fc97aa7c07b260665c67cf6",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: Data(repeating: 0x22, count: 32).base64URLUnpadded()
        )
        let env = try XCTUnwrap(envelope)
        let claimed = try XCTUnwrap(env["claimed"] as? [String: Any])
        let claimedJSON = String(data: try Spec008CanonicalJSON.marshal(claimed), encoding: .utf8) ?? ""
        XCTAssertTrue(claimedJSON.contains("mlx-community/Qwen3-8B-4bit"))
        XCTAssertFalse(claimedJSON.contains("\\/"))

        let payload = try ManagedDeviceAttestationGenerator.buildBindingPayload(
            envelope: env,
            authAttemptID: "attempt-slash"
        )
        let claimedHash = Data(SHA256.hash(data: try Spec008CanonicalJSON.marshal(claimed))).base64URLUnpadded()
        let payloadStr = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertTrue(payloadStr.contains(claimedHash))
    }

    func testOversizedClaimedOmitsTokenRatherThanExceedCap() async throws {
        let signer = MockSEBlobSigner()
        let builder = SEAttestationBuilder(serialNumberOverride: { "H2XX74T43X" })
        let generator = SecureEnclaveAttestationGenerator(signer: signer, builder: builder)
        let status = ProviderStatus(
            modelID: String(repeating: "m", count: 2000),
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 1_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let result = await generator.makeAttestationToken(
            challengeBase64URL: Data(repeating: 0x11, count: 32).base64URLUnpadded(),
            authAttemptID: "a",
            providerID: "mp-26592d710fc97aa7c07b260665c67cf6",
            binaryVersion: "1.8.99",
            snapshot: snapshot,
            providerECDHPublicKey: Data(repeating: 0x22, count: 32).base64URLUnpadded()
        )
        XCTAssertNil(result)
    }
}

final class MacProviderKeychainAccessGroupTests: XCTestCase {
    func testDefaultAccessGroupIsOmittedForDeveloperIDCLI() {
        XCTAssertEqual(
            MacProviderKeychainAccessGroup.namedProduction,
            "YF7XNRJUG4.live.malibu.provider"
        )
        XCTAssertEqual(MacProviderKeychainAccessGroup.productionTeamID, "YF7XNRJUG4")
        XCTAssertNil(MacProviderKeychainAccessGroup.resolve(nil))
        XCTAssertEqual(
            MacProviderKeychainAccessGroup.resolve("override.group"),
            "override.group"
        )
        XCTAssertNil(MacProviderKeychainAccessGroup.resolve("   "))
    }
}

final class SEAttestationFileStoreTests: XCTestCase {
    override func tearDown() {
        SEAttestationFileStore.urlOverride = nil
        super.tearDown()
    }

    func testDefaultURLIsUnderApplicationSupport() {
        let path = SEAttestationFileStore.defaultURL.path
        XCTAssertTrue(path.hasSuffix("Library/Application Support/macprovider/se-attestation-p256.v1"))
    }

    func testWriteExclusiveCreatesOwnerOnlyFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("se-file-store-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("se-attestation-p256.v1")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }

        let payload = Data("not-an-se-key".utf8)
        try SEAttestationFileStore.writeExclusive(url, data: payload)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try SEAttestationFileStore.read(url), payload)

        XCTAssertThrowsError(try SEAttestationFileStore.writeExclusive(url, data: payload)) { error in
            guard case SecureEnclaveIdentityError.fileStoreAlreadyExists = error else {
                XCTFail("expected fileStoreAlreadyExists, got \(error)")
                return
            }
        }
    }

    #if arch(arm64)
    func testFileBackedSERoundTripWhenAvailable() throws {
        try XCTSkipUnless(SecureEnclaveIdentity.isAvailable, "Secure Enclave required")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("se-file-store-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("se-attestation-p256.v1")
        SEAttestationFileStore.urlOverride = url
        addTeardownBlock {
            SEAttestationFileStore.urlOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }

        let first = try SecureEnclaveIdentity.loadOrCreateFileBacked()
        XCTAssertEqual(first.backendName, "file")
        XCTAssertEqual(first.publicKeyRaw.count, 64)

        let second = try SecureEnclaveIdentity.loadOrCreateFileBacked()
        XCTAssertEqual(first.publicKeyRaw, second.publicKeyRaw)

        let message = Data("hello-se-file".utf8)
        let signature = try first.sign(message)
        var x963 = Data([0x04])
        x963.append(first.publicKeyRaw)
        let publicKey = try P256.Signing.PublicKey(x963Representation: x963)
        let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: signature)
        XCTAssertTrue(publicKey.isValidSignature(ecdsa, for: message))
    }
    #endif
}


