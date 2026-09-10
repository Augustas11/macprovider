import CryptoKit
import Darwin
import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class RelayBlindProviderTests: XCTestCase {
    func testSharedGoldenVectorMatchesGoAndDecrypts() throws {
        let root = try goldenFixture()
        let keyRecord = try XCTUnwrap(root["key_record"] as? [String: Any])
        let envelopeObject = try XCTUnwrap(root["envelope"] as? [String: Any])
        let pin = try XCTUnwrap(root["pin"] as? [String: Any])
        let identity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: RelayBlindBase64URL.decode(try XCTUnwrap(root["identity_seed"] as? String), exactCount: 32)
        )
        let providerKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: RelayBlindBase64URL.decode(try XCTUnwrap(root["provider_x25519_private_key"] as? String), exactCount: 32)
        )
        let record = try RelayBlindKeyRecord.make(
            identityKey: identity,
            encryptionKey: providerKey,
            models: try XCTUnwrap(keyRecord["models"] as? [String]),
            maxEncryptedRequestBytes: try XCTUnwrap((keyRecord["max_encrypted_request_bytes"] as? NSNumber)?.uint64Value),
            notBeforeUnix: try XCTUnwrap((keyRecord["not_before_unix"] as? NSNumber)?.int64Value),
            expiresAtUnix: try XCTUnwrap((keyRecord["expires_at_unix"] as? NSNumber)?.int64Value)
        )
        XCTAssertEqual(record.kid, keyRecord["kid"] as? String)
        XCTAssertEqual(record.keyRecordDigest, keyRecord["key_record_digest"] as? String)
        XCTAssertEqual(identity.publicKey.rawRepresentation, try RelayBlindBase64URL.decode(try XCTUnwrap(pin["identity_public_key"] as? String)))

        let immutable = RelayBlindFraming.keyRecordImmutable(
            publicKey: record.publicKey,
            identityFingerprint: record.identityFingerprint,
            models: record.models,
            maxEncryptedRequestBytes: record.maxEncryptedRequestBytes
        )
        XCTAssertEqual(immutable.hex, root["immutable_framing_hex"] as? String)
        var signed = immutable
        signed.append(contentsOf: record.notBeforeUnix.bigEndianBytes)
        signed.append(contentsOf: record.expiresAtUnix.bigEndianBytes)
        XCTAssertEqual(signed.hex, root["signed_framing_hex"] as? String)
        let goldenSignature = try RelayBlindBase64URL.decode(try XCTUnwrap(keyRecord["signature"] as? String), exactCount: 64)
        XCTAssertTrue(identity.publicKey.isValidSignature(goldenSignature, for: signed))
        XCTAssertTrue(identity.publicKey.isValidSignature(record.signature, for: signed))

        let envelopeData = try JSONSerialization.data(withJSONObject: envelopeObject)
        let envelopeText = try XCTUnwrap(String(data: envelopeData, encoding: .utf8))
        let issuedAt = try XCTUnwrap((envelopeObject["issued_at_unix"] as? NSNumber)?.int64Value)
        let envelope = try RelayBlindEnvelope.parse(envelopeText, nowUnix: issuedAt)
        XCTAssertEqual(envelope.aad.hex, root["aad_hex"] as? String)

        let buyerPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.buyerEphemeralPublicKey)
        let secret = try providerKey.sharedSecretFromKeyAgreement(with: buyerPublic)
        let shared = secret.withUnsafeBytes { Data($0) }
        XCTAssertEqual(RelayBlindBase64URL.encode(shared), root["shared_secret"] as? String)
        let transcript = Data(SHA256.hash(data: Data("macprovider/spec041/relay-blind/transcript/v1".utf8) + envelope.aad))
        XCTAssertEqual(RelayBlindBase64URL.encode(transcript), root["transcript"] as? String)
        let requestKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead/v1".utf8),
            outputByteCount: 32
        )
        XCTAssertEqual(requestKey.withUnsafeBytes { RelayBlindBase64URL.encode(Data($0)) }, root["request_key"] as? String)
        let nonceKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead-nonce/v1".utf8),
            outputByteCount: 12
        )
        XCTAssertEqual(nonceKey.withUnsafeBytes { RelayBlindBase64URL.encode(Data($0)) }, root["aead_nonce"] as? String)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) }),
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        let plaintext = try AES.GCM.open(box, using: requestKey, authenticating: envelope.aad)
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), root["plaintext_utf8"] as? String)
    }

    func testKeyPersistenceModelScopingRotationAndRevocation() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = try RelayBlindKeyManager(directory: root, models: ["model-b", "model-a"], now: now)
        let identity = first.identityPublicKeyBase64URL()
        let records = try first.currentRecords(now: now)
        XCTAssertEqual(records.map(\.models), [["model-a"], ["model-b"]])
        XCTAssertEqual(Set(records.map(\.kid)).count, 2)

        let restored = try RelayBlindKeyManager(directory: root, models: ["model-b", "model-a"], now: now)
        XCTAssertEqual(restored.identityPublicKeyBase64URL(), identity)
        XCTAssertEqual(try restored.currentRecords(now: now).map(\.kid), records.map(\.kid))

        _ = try restored.rotate(now: now.addingTimeInterval(10))
        let rotated = try restored.currentRecords(now: now.addingTimeInterval(10))
        XCTAssertEqual(restored.identityPublicKeyBase64URL(), identity)
        XCTAssertTrue(Set(records.map(\.kid)).isDisjoint(with: Set(rotated.map(\.kid))))
        try restored.revoke(kid: rotated[0].kid)
        XCTAssertEqual(try restored.currentRecords(now: now.addingTimeInterval(10)).map(\.models), [["model-b"]])
        let liveProvider = try RelayBlindKeyManager(directory: root, models: ["model-b", "model-a"], now: now.addingTimeInterval(10))
        let operatorProcess = try RelayBlindKeyManager(directory: root, models: ["model-b", "model-a"], now: now.addingTimeInterval(10))
        try operatorProcess.revoke(kid: rotated[1].kid)
        XCTAssertEqual(try liveProvider.currentRecords(now: now.addingTimeInterval(11)), [])
        XCTAssertThrowsError(try liveProvider.key(
            for: rotated[1].kid,
            digest: rotated[1].keyRecordDigest,
            now: now.addingTimeInterval(11)
        )) { XCTAssertEqual($0 as? RelayBlindProviderError, .ciphertextInvalid) }

        for name in ["identity.ed25519", "encryption.current.x25519", "encryption.current.json", "revoked-kids.json"] {
            var value = stat()
            XCTAssertEqual(lstat(root.appendingPathComponent(name).path, &value), 0)
            XCTAssertEqual(value.st_mode & 0o077, 0)
        }
    }

    func testSecureStateRejectsParentSymlinkAndSurvivesAncestorSwap() throws {
        let base = temporaryStateDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(base.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: base) }

        let realParent = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(realParent.path, 0o700), 0)
        let linkedParent = base.appendingPathComponent("linked", isDirectory: true)
        XCTAssertEqual(symlink(realParent.path, linkedParent.path), 0)
        XCTAssertThrowsError(try RelayBlindKeyManager(
            directory: linkedParent.appendingPathComponent("state", isDirectory: true),
            models: ["model-a"]
        ))

        let parent = base.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        let state = parent.appendingPathComponent("state", isDirectory: true)
        let journal = try RelayBlindExecutionJournal(directory: state)

        let retainedParent = base.appendingPathComponent("retained", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: retainedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(state.path, 0o700), 0)

        let digest = RelayBlindBase64URL.encode(Data(repeating: 7, count: 32))
        let claim = try journal.claim(
            buyerBinding: RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
            providerBinding: RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
            kid: RelayBlindBase64URL.encode(Data(repeating: 3, count: 16)),
            requestID: "ancestor-swap",
            envelopeDigest: digest,
            inputTokenUpperBound: 20,
            maxOutputTokens: 10,
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retainedParent.appendingPathComponent("state/\(claim.filename)").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent(claim.filename).path))
    }

    func testJournalExclusiveClaimRecoveryAndRedaction() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RelayBlindExecutionJournal(directory: root)
        let digest = RelayBlindBase64URL.encode(Data(repeating: 7, count: 32))
        let claim = try journal.claim(
            buyerBinding: RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
            providerBinding: RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
            kid: RelayBlindBase64URL.encode(Data(repeating: 3, count: 16)),
            requestID: "request-1",
            envelopeDigest: digest,
            inputTokenUpperBound: 20,
            maxOutputTokens: 10,
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertThrowsError(try journal.claim(
            buyerBinding: RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
            providerBinding: RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
            kid: RelayBlindBase64URL.encode(Data(repeating: 3, count: 16)),
            requestID: "request-1", envelopeDigest: digest,
            inputTokenUpperBound: 20, maxOutputTokens: 10, now: Date()
        )) { XCTAssertEqual($0 as? RelayBlindProviderError, .executionAlreadyClaimed) }

        _ = try RelayBlindExecutionJournal(directory: root)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: claim.path))
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.contains("unknown_postdispatch"))
        XCTAssertTrue(text.contains("input_token_upper_bound"))
        XCTAssertFalse(text.contains("secret prompt"))
        XCTAssertFalse(text.contains("ciphertext"))
        var value = stat()
        XCTAssertEqual(lstat(claim.path, &value), 0)
        XCTAssertEqual(value.st_mode & 0o077, 0)
    }

    func testJournalPrunesOnlyExpiredTerminalFencesBeforeCapacityAdmission() throws {
        func claim(_ journal: RelayBlindExecutionJournal, _ requestID: String, at seconds: TimeInterval) throws -> RelayBlindExecutionJournal.Claim {
            try journal.claim(
                buyerBinding: RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
                providerBinding: RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
                kid: RelayBlindBase64URL.encode(Data(repeating: 3, count: 16)),
                requestID: requestID,
                envelopeDigest: RelayBlindBase64URL.encode(Data(repeating: 7, count: 32)),
                inputTokenUpperBound: 20,
                maxOutputTokens: 10,
                now: Date(timeIntervalSince1970: seconds)
            )
        }

        let terminalRoot = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: terminalRoot) }
        let terminalJournal = try RelayBlindExecutionJournal(
            directory: terminalRoot, maxEntries: 1, replayRetentionSeconds: 60,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let terminal = try claim(terminalJournal, "terminal", at: 1_000)
        try terminalJournal.markTerminal(terminal, inputTokens: 4, now: Date(timeIntervalSince1970: 1_001))
        XCTAssertThrowsError(try claim(terminalJournal, "terminal", at: 1_030)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .executionAlreadyClaimed)
        }
        XCTAssertThrowsError(try claim(terminalJournal, "capacity", at: 1_030)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .journalUnavailable)
        }
        let replacement = try claim(terminalJournal, "capacity", at: 1_062)
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))

        let recoveryRoot = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let preCrash = try RelayBlindExecutionJournal(
            directory: recoveryRoot, maxEntries: 1, replayRetentionSeconds: 60,
            now: Date(timeIntervalSince1970: 2_000)
        )
        let uncertain = try claim(preCrash, "uncertain", at: 2_000)
        let recovered = try RelayBlindExecutionJournal(
            directory: recoveryRoot, maxEntries: 1, replayRetentionSeconds: 60,
            now: Date(timeIntervalSince1970: 2_001)
        )
        XCTAssertThrowsError(try claim(recovered, "too-soon", at: 2_060)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .journalUnavailable)
        }
        _ = try claim(recovered, "after-retention", at: 2_062)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uncertain.path))

        let activeRoot = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: activeRoot) }
        let activeJournal = try RelayBlindExecutionJournal(
            directory: activeRoot, maxEntries: 2, replayRetentionSeconds: 60,
            now: Date(timeIntervalSince1970: 3_000)
        )
        _ = try claim(activeJournal, "claimed-active", at: 3_000)
        let validated = try claim(activeJournal, "validated-active", at: 3_001)
        try activeJournal.markValidated(validated, inputTokens: 4, now: Date(timeIntervalSince1970: 3_002))
        XCTAssertThrowsError(try claim(activeJournal, "must-not-prune-active", at: 3_200)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .journalUnavailable)
        }
    }

    func testJournalCrashCutMatrixNeverReentersGenerationAfterRestart() throws {
        let cuts = [
            "claimed-before-decrypt",
            "decrypted-before-tokenization",
            "validated-before-generation",
            "partial-output",
            "terminal-send-loss",
            "terminal-update-loss",
        ]
        for (index, cut) in cuts.enumerated() {
            let root = temporaryStateDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let now = Date(timeIntervalSince1970: 4_000 + Double(index * 100))
            let journal = try RelayBlindExecutionJournal(directory: root, now: now)
            let digest = RelayBlindBase64URL.encode(Data(repeating: UInt8(index + 1), count: 32))
            let claim = try journal.claim(
                buyerBinding: RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
                providerBinding: RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
                kid: RelayBlindBase64URL.encode(Data(repeating: 3, count: 16)),
                requestID: cut,
                envelopeDigest: digest,
                inputTokenUpperBound: 20,
                maxOutputTokens: 10,
                now: now
            )
            if cut == "validated-before-generation" || cut == "partial-output" || cut == "terminal-update-loss" {
                try journal.markValidated(claim, inputTokens: 4, now: now.addingTimeInterval(1))
            } else if cut == "terminal-send-loss" {
                try journal.markTerminal(claim, inputTokens: 4, now: now.addingTimeInterval(1))
            }

            let recovered = try RelayBlindExecutionJournal(directory: root, now: now.addingTimeInterval(2))
            let stateBytes = try Data(contentsOf: URL(fileURLWithPath: claim.path))
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateBytes) as? [String: Any])
            XCTAssertEqual(
                state["state"] as? String,
                cut == "terminal-send-loss" ? "terminal" : "unknown_postdispatch",
                cut
            )
            var generationCount = 0
            do {
                _ = try recovered.claim(
                    buyerBinding: RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
                    providerBinding: RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
                    kid: RelayBlindBase64URL.encode(Data(repeating: 3, count: 16)),
                    requestID: cut,
                    envelopeDigest: digest,
                    inputTokenUpperBound: 20,
                    maxOutputTokens: 10,
                    now: now.addingTimeInterval(3)
                )
                generationCount += 1
            } catch {
                XCTAssertEqual(error as? RelayBlindProviderError, .executionAlreadyClaimed, cut)
            }
            XCTAssertEqual(generationCount, 0, cut)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1, cut)
        }
    }

    func testJournalRecoversOnlyExactPrivateOrphanTemps() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 5_000)
        let journal = try RelayBlindExecutionJournal(directory: root, now: now)
        let claim = try journal.claim(
            buyerBinding: RelayBlindBase64URL.encode(Data(repeating: 1, count: 32)),
            providerBinding: RelayBlindBase64URL.encode(Data(repeating: 2, count: 32)),
            kid: RelayBlindBase64URL.encode(Data(repeating: 3, count: 16)),
            requestID: "temp-recovery",
            envelopeDigest: RelayBlindBase64URL.encode(Data(repeating: 7, count: 32)),
            inputTokenUpperBound: 20,
            maxOutputTokens: 10,
            now: now
        )
        let orphanName = ".\(claim.filename).\(UUID().uuidString).tmp"
        let orphan = root.appendingPathComponent(orphanName)
        try Data("partial replacement".utf8).write(to: orphan)
        XCTAssertEqual(chmod(orphan.path, 0o600), 0)
        _ = try RelayBlindExecutionJournal(directory: root, now: now.addingTimeInterval(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))

        let unknown = root.appendingPathComponent(".unknown.\(UUID().uuidString).tmp")
        try Data().write(to: unknown)
        XCTAssertEqual(chmod(unknown.path, 0o600), 0)
        XCTAssertThrowsError(try RelayBlindExecutionJournal(directory: root, now: now.addingTimeInterval(2)))
        try FileManager.default.removeItem(at: unknown)

        let unsafeName = ".\(claim.filename).\(UUID().uuidString).tmp"
        let unsafe = root.appendingPathComponent(unsafeName)
        try Data().write(to: unsafe)
        XCTAssertEqual(chmod(unsafe.path, 0o644), 0)
        XCTAssertThrowsError(try RelayBlindExecutionJournal(directory: root, now: now.addingTimeInterval(3)))
    }

    func testRelayBlindDefaultsOffAndConfigOverridesAreExplicit() throws {
        let defaults = AppConfig.defaults(configPath: "/tmp/no-relay-blind.yaml")
        XCTAssertFalse(defaults.relayBlindEnabled)
        XCTAssertNil(defaults.relayBlindStateDirectory)
        let emptyConfig = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-blind-config-\(UUID().uuidString).yaml")
        try Data().write(to: emptyConfig)
        defer { try? FileManager.default.removeItem(at: emptyConfig) }
        let config = try ConfigLoader.load(
            cli: CLIOverrides(configPath: emptyConfig.path),
            environment: [
                "MACPROVIDER_RELAY_BLIND_ENABLED": "true",
                "MACPROVIDER_RELAY_BLIND_STATE_DIRECTORY": "/tmp/macprovider-relay-blind-test",
            ]
        )
        XCTAssertTrue(config.relayBlindEnabled)
        XCTAssertEqual(config.relayBlindStateDirectory, "/tmp/macprovider-relay-blind-test")
    }

    func testTier2ProtectsRelayBlindMarkerContextAndValidationEvidence() throws {
        let session = try Tier2ProviderSession(
            providerID: "provider-1",
            assignedID: "assigned-1",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "tier2-key",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([1, 2, 3, 4]),
            p2cNonceBase: Data([5, 6, 7, 8])
        )
        let context: [String: Any] = ["kid": "private-context"]
        let request = try Tier2ProviderSession.sealRequestForTest(
            session: session,
            requestID: "tier2-relay-blind",
            stream: false,
            plaintext: "opaque-envelope",
            bodyEncoding: RelayBlindEnvelope.version,
            relayBlindContext: context
        )
        XCTAssertNil(request["body_encoding"])
        XCTAssertNil(request["relay_blind_context"])
        let opened = try session.openRequestPayload(message: request, requestID: "tier2-relay-blind", stream: false)
        XCTAssertEqual(opened.bodyEncoding, RelayBlindEnvelope.version)
        XCTAssertEqual(opened.relayBlindContext?["kid"] as? String, "private-context")

        let evidence: [String: Any] = [
            "type": "inference_response_validation",
            "request_id": "tier2-relay-blind",
            "relay_blind_validation": ["state": "validated"],
        ]
        let sealed = try session.sealResponseValidation(
            requestID: "tier2-relay-blind", stream: false, payload: evidence
        )
        XCTAssertNil(sealed["relay_blind_validation"])
        let reopened = try Tier2ProviderSession.openResponseValidationForTest(
            session: session, frame: sealed, requestID: "tier2-relay-blind", stream: false
        )
        XCTAssertEqual((reopened["relay_blind_validation"] as? [String: Any])?["state"] as? String, "validated")
    }

    func testInferenceRelayValidatesActualTokensBeforeGenerationAndEmitsBoundEvidence() async throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = "mlx-community/relay-blind-test"
        let session = "assigned-test-session"
        let keys = try RelayBlindKeyManager(directory: root, models: [model])
        let journal = try RelayBlindExecutionJournal(directory: root.appendingPathComponent("journal"))
        let providerRuntime = RelayBlindProviderRuntime(keyManager: keys, journal: journal, assignedSession: session)
        let modelRuntime = RelayBlindTestRuntime(inputTokens: 5)
        let frames = RelayBlindFrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: modelRuntime,
            providerStatus: ProviderStatus(
                modelID: model,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
            ),
            loadedModelID: model,
            maxActiveRequests: 1,
            maxBodyBytes: 1_200_000,
            relayBlindRuntime: providerRuntime,
            sendFrame: { frame in await frames.append(frame) }
        )

        let valid = try makeInferenceMessage(
            keys: keys, model: model, session: session, requestID: "relay-valid", inputCap: 5, outputCap: 4
        )
        try await relay.handleInferenceRequest(valid)
        let validBecameIdle = await relay.waitUntilIdle(timeoutSeconds: 5)
        XCTAssertTrue(validBecameIdle)
        let validFrames = await frames.values
        let types = validFrames.compactMap { $0["type"] as? String }
        XCTAssertEqual(types.first, "inference_response_validation")
        XCTAssertTrue(types.contains("inference_response_chunk"))
        XCTAssertEqual(types.last, "inference_response_end")
        let validation = try XCTUnwrap(validFrames.first?["relay_blind_validation"] as? [String: Any])
        XCTAssertEqual(validation["state"] as? String, "validated")
        XCTAssertEqual(validation["input_tokens"] as? Int, 5)
        XCTAssertEqual(validation["assigned_session"] as? String, session)
        let terminal = try XCTUnwrap(validFrames.last?["relay_blind_validation"] as? [String: Any])
        XCTAssertEqual(terminal["state"] as? String, "terminal")
        let validCompletionCount = await modelRuntime.completionCount()
        XCTAssertEqual(validCompletionCount, 1)
        let usedPreparedHandle = await modelRuntime.usedPreparedHandleForGeneration()
        XCTAssertTrue(usedPreparedHandle)

        await frames.removeAll()
        let underdeclared = try makeInferenceMessage(
            keys: keys, model: model, session: session, requestID: "relay-over-cap", inputCap: 4, outputCap: 4
        )
        try await relay.handleInferenceRequest(underdeclared)
        let rejectedBecameIdle = await relay.waitUntilIdle(timeoutSeconds: 5)
        XCTAssertTrue(rejectedBecameIdle)
        let rejected = await frames.values
        XCTAssertEqual(rejected.first?["type"] as? String, "inference_response_validation")
        let rejectedEvidence = try XCTUnwrap(rejected.first?["relay_blind_validation"] as? [String: Any])
        XCTAssertEqual(rejectedEvidence["state"] as? String, "rejected")
        XCTAssertEqual(rejectedEvidence["input_tokens"] as? Int, 0)
        XCTAssertEqual(rejectedEvidence["error_code"] as? String, RelayBlindProviderError.ciphertextInvalid.code)
        XCTAssertFalse(rejected.contains { $0["type"] as? String == "inference_response_chunk" })
        XCTAssertEqual(rejected.last?["status"] as? String, RelayBlindProviderError.ciphertextInvalid.code)
        XCTAssertEqual(
            (rejected.last?["relay_blind_validation"] as? [String: Any])?["state"] as? String,
            "rejected"
        )
        let rejectedCompletionCount = await modelRuntime.completionCount()
        XCTAssertEqual(rejectedCompletionCount, 1)

        try await relay.handleInferenceRequest(valid)
        let replay = await frames.values.last
        XCTAssertEqual(replay?["status"] as? String, RelayBlindProviderError.executionAlreadyClaimed.code)
        let replayCompletionCount = await modelRuntime.completionCount()
        XCTAssertEqual(replayCompletionCount, 1)
    }

    func testEnvelopeRejectsUnknownVersionLowOrderKeyAndAEADTamper() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = "mlx-community/relay-blind-test"
        let session = "assigned-test-session"
        let keys = try RelayBlindKeyManager(directory: root, models: [model])
        let journal = try RelayBlindExecutionJournal(directory: root.appendingPathComponent("journal"))
        let runtime = RelayBlindProviderRuntime(keyManager: keys, journal: journal, assignedSession: session)

        let unknownVersion = try mutateEnvelopeMessage(
            makeInferenceMessage(keys: keys, model: model, session: session, requestID: "unknown-version", inputCap: 5, outputCap: 4),
            updates: ["version": "relay-blind-request-v2"]
        )
        XCTAssertThrowsError(try open(runtime, message: unknownVersion)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .invalidEnvelope)
        }

        let lowOrder = try mutateEnvelopeMessage(
            makeInferenceMessage(keys: keys, model: model, session: session, requestID: "low-order", inputCap: 5, outputCap: 4),
            updates: ["buyer_ephemeral_public_key": RelayBlindBase64URL.encode(Data(repeating: 0, count: 32))]
        )
        XCTAssertThrowsError(try open(runtime, message: lowOrder)) {
            XCTAssertEqual(($0 as? RelayBlindProviderRejection)?.error, .ciphertextInvalid)
        }

        let tamperedTag = try mutateEnvelopeMessage(
            makeInferenceMessage(keys: keys, model: model, session: session, requestID: "aead-tamper", inputCap: 5, outputCap: 4),
            updates: ["tag": RelayBlindBase64URL.encode(Data(repeating: 0, count: 16))]
        )
        XCTAssertThrowsError(try open(runtime, message: tamperedTag)) {
            XCTAssertEqual(($0 as? RelayBlindProviderRejection)?.error, .ciphertextInvalid)
        }

        let numericStream = try replaceRawEnvelopeToken(
            makeInferenceMessage(keys: keys, model: model, session: session, requestID: "numeric-stream", inputCap: 5, outputCap: 4),
            needle: "\"stream\":false", replacement: "\"stream\":1"
        )
        XCTAssertThrowsError(try open(runtime, message: numericStream)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .invalidEnvelope)
        }
        let fractionalCap = try replaceRawEnvelopeToken(
            makeInferenceMessage(keys: keys, model: model, session: session, requestID: "fraction-cap", inputCap: 5, outputCap: 4),
            needle: "\"max_output_tokens\":4", replacement: "\"max_output_tokens\":4.0"
        )
        XCTAssertThrowsError(try open(runtime, message: fractionalCap)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .invalidEnvelope)
        }
        let exponentCap = try replaceRawEnvelopeToken(
            makeInferenceMessage(keys: keys, model: model, session: session, requestID: "exponent-cap", inputCap: 5, outputCap: 4),
            needle: "\"input_token_upper_bound\":5", replacement: "\"input_token_upper_bound\":5e0"
        )
        XCTAssertThrowsError(try open(runtime, message: exponentCap)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .invalidEnvelope)
        }
        let timeMessage = try makeInferenceMessage(
            keys: keys, model: model, session: session, requestID: "fraction-time", inputCap: 5, outputCap: 4
        )
        let timeBody = try XCTUnwrap(timeMessage["body"] as? String)
        let timeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(timeBody.utf8)) as? [String: Any])
        let issued = try XCTUnwrap((timeObject["issued_at_unix"] as? NSNumber)?.stringValue)
        let fractionalTime = try replaceRawEnvelopeToken(
            timeMessage,
            needle: "\"issued_at_unix\":\(issued)", replacement: "\"issued_at_unix\":\(issued).0"
        )
        XCTAssertThrowsError(try open(runtime, message: fractionalTime)) {
            XCTAssertEqual($0 as? RelayBlindProviderError, .invalidEnvelope)
        }
    }

    func testEnvelopeSerializedLimitAllowsMaximumCiphertext() throws {
        let root = try goldenFixture()
        var envelope = try XCTUnwrap(root["envelope"] as? [String: Any])
        envelope["issued_at_unix"] = Int64(Date().timeIntervalSince1970)
        envelope["ciphertext"] = RelayBlindBase64URL.encode(Data(repeating: 0x5a, count: RelayBlindEnvelope.maxCiphertextBytes))
        let maximumData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        XCTAssertGreaterThan(maximumData.count, 1_200_000)
        XCTAssertLessThanOrEqual(maximumData.count, RelayBlindEnvelope.maxSerializedBytes)
        let parsed = try RelayBlindEnvelope.parse(
            try XCTUnwrap(String(data: maximumData, encoding: .utf8)),
            nowUnix: Int64(Date().timeIntervalSince1970)
        )
        XCTAssertEqual(parsed.ciphertext.count, RelayBlindEnvelope.maxCiphertextBytes)

        envelope["ciphertext"] = RelayBlindBase64URL.encode(Data(repeating: 0x5a, count: RelayBlindEnvelope.maxCiphertextBytes + 1))
        let oversized = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        XCTAssertThrowsError(try RelayBlindEnvelope.parse(
            try XCTUnwrap(String(data: oversized, encoding: .utf8)),
            nowUnix: Int64(Date().timeIntervalSince1970)
        )) { XCTAssertEqual($0 as? RelayBlindProviderError, .invalidEnvelope) }
    }

    func testInferenceRelayBindsCatalogProviderModelToPinnedRuntimeModel() async throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeModel = "local/actual-model-snapshot"
        let catalogModel = "catalog/canonical-model"
        let session = "assigned-alias-session"
        let keys = try RelayBlindKeyManager(directory: root, models: [catalogModel])
        let providerRuntime = RelayBlindProviderRuntime(
            keyManager: keys,
            journal: try RelayBlindExecutionJournal(directory: root.appendingPathComponent("journal")),
            assignedSession: session
        )
        let modelRuntime = RelayBlindTestRuntime(inputTokens: 5, model: runtimeModel)
        let frames = RelayBlindFrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: modelRuntime,
            providerStatus: ProviderStatus(
                modelID: runtimeModel,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
            ),
            loadedModelID: runtimeModel,
            catalogModelIDAlias: catalogModel,
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 1_200_000,
            relayBlindRuntime: providerRuntime,
            sendFrame: { frame in await frames.append(frame) }
        )
        try await relay.handleInferenceRequest(try makeInferenceMessage(
            keys: keys, model: catalogModel, session: session, requestID: "alias-valid", inputCap: 5, outputCap: 4
        ))
        let becameIdle = await relay.waitUntilIdle(timeoutSeconds: 5)
        XCTAssertTrue(becameIdle)
        let emitted = await frames.values
        XCTAssertEqual(emitted.first?["type"] as? String, "inference_response_validation")
        XCTAssertEqual(emitted.last?["status"] as? String, "complete")
        let completionCount = await modelRuntime.completionCount()
        XCTAssertEqual(completionCount, 1)
    }

    private func goldenFixture() throws -> [String: Any] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = tests.appendingPathComponent("../../../test/fixtures/relay-blind/golden-v1.json").standardizedFileURL
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func temporaryStateDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macprovider-relay-blind-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeInferenceMessage(
        keys: RelayBlindKeyManager,
        model: String,
        session: String,
        requestID: String,
        inputCap: UInt64,
        outputCap: UInt64
    ) throws -> [String: Any] {
        let record = try keys.currentRecord()
        let buyer = Curve25519.KeyAgreement.PrivateKey()
        let providerBinding = RelayBlindBase64URL.encode(Data(repeating: 0x41, count: 32))
        let buyerBinding = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(requestID.utf8))))
        let replay = Data(SHA256.hash(data: Data("replay-\(requestID)".utf8)))
        let now = Int64(Date().timeIntervalSince1970)
        let empty = RelayBlindEnvelope(
            model: model,
            providerModel: model,
            stream: false,
            requestID: requestID,
            maxOutputTokens: outputCap,
            inputTokenUpperBound: inputCap,
            reservationTokenCap: inputCap + outputCap,
            providerBinding: providerBinding,
            buyerBinding: buyerBinding,
            keyRecordDigest: record.keyRecordDigest,
            kid: record.kid,
            buyerEphemeralPublicKey: buyer.publicKey.rawRepresentation,
            requestReplayNonce: replay,
            issuedAtUnix: now,
            ciphertext: Data([0]),
            tag: Data(repeating: 0, count: 16)
        )
        let shared = try buyer.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: record.publicKey)
        )
        let transcript = Data(SHA256.hash(data: Data("macprovider/spec041/relay-blind/transcript/v1".utf8) + empty.aad))
        let requestKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead/v1".utf8),
            outputByteCount: 32
        )
        let nonceKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead-nonce/v1".utf8),
            outputByteCount: 12
        )
        let inner: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "secret prompt"]],
            "max_tokens": outputCap,
            "stream": false,
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys])
        let sealed = try AES.GCM.seal(
            plaintext,
            using: requestKey,
            nonce: AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) }),
            authenticating: empty.aad
        )
        let envelopeObject: [String: Any] = [
            "version": RelayBlindEnvelope.version,
            "mode": RelayBlindEnvelope.mode,
            "endpoint_family": RelayBlindEnvelope.endpointFamily,
            "model": model,
            "provider_model": model,
            "stream": false,
            "request_id": requestID,
            "max_output_tokens": outputCap,
            "input_token_upper_bound": inputCap,
            "reservation_token_cap": inputCap + outputCap,
            "provider_binding": providerBinding,
            "buyer_binding": buyerBinding,
            "key_record_digest": record.keyRecordDigest,
            "kid": record.kid,
            "buyer_ephemeral_public_key": RelayBlindBase64URL.encode(buyer.publicKey.rawRepresentation),
            "request_replay_nonce": RelayBlindBase64URL.encode(replay),
            "issued_at_unix": now,
            "algorithm": RelayBlindKeyRecord.algorithm,
            "ciphertext": RelayBlindBase64URL.encode(sealed.ciphertext),
            "tag": RelayBlindBase64URL.encode(sealed.tag),
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelopeObject, options: [.sortedKeys])
        let body = try XCTUnwrap(String(data: envelopeData, encoding: .utf8))
        let digest: (String) -> String = { value in
            RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(value.utf8))))
        }
        return [
            "type": "inference_request",
            "request_id": requestID,
            "stream": false,
            "body": body,
            "body_encoding": RelayBlindEnvelope.version,
            "relay_blind_context": [
                "execution_auth_digest": digest("execution-auth-\(requestID)"),
                "envelope_digest": digest(body),
                "provider_binding_digest": digest(providerBinding),
                "buyer_binding_digest": digest(buyerBinding),
                "kid": record.kid,
                "assigned_session": session,
                "request_id": requestID,
                "input_token_upper_bound": inputCap,
                "max_output_tokens": outputCap,
            ],
        ]
    }

    private func mutateEnvelopeMessage(_ message: [String: Any], updates: [String: Any]) throws -> [String: Any] {
        var result = message
        let body = try XCTUnwrap(message["body"] as? String)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        for (key, value) in updates { envelope[key] = value }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let mutatedBody = try XCTUnwrap(String(data: data, encoding: .utf8))
        result["body"] = mutatedBody
        var context = try XCTUnwrap(message["relay_blind_context"] as? [String: Any])
        context["envelope_digest"] = RelayBlindBase64URL.encode(Data(SHA256.hash(data: data)))
        result["relay_blind_context"] = context
        return result
    }

    private func replaceRawEnvelopeToken(
        _ message: [String: Any], needle: String, replacement: String
    ) throws -> [String: Any] {
        var result = message
        let body = try XCTUnwrap(message["body"] as? String)
        XCTAssertTrue(body.contains(needle))
        let mutatedBody = body.replacingOccurrences(of: needle, with: replacement)
        result["body"] = mutatedBody
        var context = try XCTUnwrap(message["relay_blind_context"] as? [String: Any])
        context["envelope_digest"] = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(mutatedBody.utf8))))
        result["relay_blind_context"] = context
        return result
    }

    private func open(_ runtime: RelayBlindProviderRuntime, message: [String: Any]) throws -> RelayBlindProviderRuntime.OpenedRequest {
        try runtime.open(
            envelopeBody: try XCTUnwrap(message["body"] as? String),
            outerRequestID: try XCTUnwrap(message["request_id"] as? String),
            outerStream: try XCTUnwrap(message["stream"] as? Bool),
            contextObject: try XCTUnwrap(message["relay_blind_context"] as? [String: Any]),
            expectedAssignedSession: nil
        )
    }
}

private actor RelayBlindFrameRecorder {
    private(set) var values: [[String: Any]] = []
    func append(_ frame: [String: Any]) { values.append(frame) }
    func removeAll() { values.removeAll() }
}

private actor RelayBlindTestRuntime: ModelRuntimeServing {
    private let inputTokens: Int
    private let model: String
    private var completions = 0
    private var usedPreparedHandle = false

    init(inputTokens: Int, model: String = "mlx-community/relay-blind-test") {
        self.inputTokens = inputTokens
        self.model = model
    }
    func completionCount() -> Int { completions }
    func usedPreparedHandleForGeneration() -> Bool { usedPreparedHandle }
    func currentSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: nil)
    }
    func relayBlindPrepare(_ request: ChatCompletionRequest) throws -> RelayBlindPreparedRequest {
        RelayBlindPreparedRequest(handle: try acquireRequestHandle(request), inputTokens: inputTokens)
    }
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        completions += 1
        return CompletionResult(content: "fixture result", finishReason: "stop", promptTokens: inputTokens, completionTokens: 2)
    }
    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        usedPreparedHandle = true
        return (try await complete(request, shouldCancel: shouldCancel), handle.snapshot)
    }
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: nil),
            registrationID: 1,
            drainCancelled: DrainCancelToken()
        )
    }
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {}
    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        completions += 1
        onChunk(.content("fixture result"))
        return CompletionResult(content: "fixture result", finishReason: "stop", promptTokens: inputTokens, completionTokens: 2)
    }
    func unregisterInFlight(_ id: Int) {}
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Int64 {
    var bigEndianBytes: [UInt8] {
        let value = UInt64(bitPattern: self)
        return stride(from: 56, through: 0, by: -8).map { UInt8((value >> UInt64($0)) & 0xff) }
    }
}
