import CryptoKit
import Foundation
import XCTest
@testable import Malibu

final class MalibuReleaseRollbackRotationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRollbackAuthorizationConsumesNonceExactlyOnce() throws {
        let key = P256.Signing.PrivateKey()
        let trust = try makeTrust(generation: 1, keys: [("release-key", key, "active")])
        let current = state(index: 9, build: 50, envelope: 50, digest: "a")
        let target = state(index: 7, build: 48, envelope: 48, digest: "b")
        let payload = rollbackPayload(current: current, target: target)
        let document = try sign(
            payload: payload,
            schema: MalibuReleaseRollbackAuthorization.schema,
            context: "malibu.release-rollback.v1",
            keyID: "release-key",
            key: key
        )
        let receipts = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: receipts) }
        try MalibuReleaseRollbackAuthorization.validateAndConsume(
            document,
            trust: trust,
            now: now,
            current: current,
            target: target,
            receiptDirectory: receipts
        )
        XCTAssertThrowsError(
            try MalibuReleaseRollbackAuthorization.validateAndConsume(
                document,
                trust: trust,
                now: now,
                current: current,
                target: target,
                receiptDirectory: receipts
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .authorizationReplay)
        }
    }

    func testRollbackRejectsFutureExpiredWrongCurrentTargetAndSignatureContext() throws {
        let key = P256.Signing.PrivateKey()
        let trust = try makeTrust(generation: 1, keys: [("release-key", key, "active")])
        let current = state(index: 9, build: 50, envelope: 50, digest: "a")
        let target = state(index: 7, build: 48, envelope: 48, digest: "b")
        let receipts = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: receipts) }

        var future = rollbackPayload(current: current, target: target)
        future["issued_at"] = stamp(now.addingTimeInterval(301))
        var expired = rollbackPayload(current: current, target: target)
        expired["expires_at"] = stamp(now)
        let wrongCurrent = state(index: 10, build: 50, envelope: 50, digest: "a")
        let newerTarget = state(index: 10, build: 51, envelope: 51, digest: "c")
        let digestSwap = state(index: 9, build: 50, envelope: 50, digest: "d")
        let cases: [(payload: [String: Any], current: MalibuReleaseAntiReplayState, target: MalibuReleaseAntiReplayState)] = [
            (future, current, target),
            (expired, current, target),
            (rollbackPayload(current: current, target: target), wrongCurrent, target),
            (rollbackPayload(current: current, target: newerTarget), current, newerTarget),
            (rollbackPayload(current: current, target: digestSwap), current, digestSwap),
        ]
        for item in cases {
            let document = try sign(
                payload: item.payload,
                schema: MalibuReleaseRollbackAuthorization.schema,
                context: "malibu.release-rollback.v1",
                keyID: "release-key",
                key: key
            )
            XCTAssertThrowsError(
                try MalibuReleaseRollbackAuthorization.validateAndConsume(
                    document,
                    trust: trust,
                    now: now,
                    current: item.current,
                    target: item.target,
                    receiptDirectory: receipts
                )
            )
        }
        let wrongContext = try sign(
            payload: rollbackPayload(current: current, target: target),
            schema: MalibuReleaseRollbackAuthorization.schema,
            context: "malibu.release-envelope.v1",
            keyID: "release-key",
            key: key
        )
        XCTAssertThrowsError(
            try MalibuReleaseRollbackAuthorization.validateAndConsume(
                wrongContext,
                trust: trust,
                now: now,
                current: current,
                target: target,
                receiptDirectory: receipts
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .invalidSignature)
        }
    }

    func testRotationRequiresDualPolicyOverlapThenReceiptGatesRetirement() throws {
        let retiring = P256.Signing.PrivateKey()
        let successor = P256.Signing.PrivateKey()
        let current = try makeTrust(generation: 1, keys: [("old-key", retiring, "active")])
        let overlap = try makeTrust(generation: 2, keys: [("old-key", retiring, "retiring"), ("new-key", successor, "active")])
        let overlapIndex = Data("exact overlap index".utf8)
        let rotationID = String(repeating: "6", count: 64)
        let payload = rotationPayload(current: current, successor: overlap, overlapIndex: overlapIndex, rotationID: rotationID)
        let document = try dualSign(payload: payload, retiring: retiring, successor: successor)
        let receipts = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: receipts) }
        try MalibuReleaseKeyRotationAuthorization.validateOverlapAndCommit(
            document,
            currentTrust: current,
            successorTrust: overlap,
            retiringKeyID: "old-key",
            successorKeyID: "new-key",
            overlapIndexData: overlapIndex,
            minimumIndexGeneration: 10,
            now: now,
            receiptDirectory: receipts
        )

        let retirement = try makeTrust(generation: 3, keys: [("new-key", successor, "active")])
        try MalibuReleaseKeyRotationAuthorization.authorizeRetirement(
            overlapTrust: overlap,
            retirementTrust: retirement,
            retiringKeyID: "old-key",
            successorKeyID: "new-key",
            rotationID: rotationID,
            receiptDirectory: receipts
        )
        XCTAssertThrowsError(
            try MalibuReleaseKeyRotationAuthorization.authorizeRetirement(
                overlapTrust: overlap,
                retirementTrust: retirement,
                retiringKeyID: "old-key",
                successorKeyID: "new-key",
                rotationID: String(repeating: "7", count: 64),
                receiptDirectory: receipts
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .rotationPolicyViolation)
        }
    }

    func testRotationRejectsWrongSuccessorSignatureDigestAndNonAdvancingPolicy() throws {
        let retiring = P256.Signing.PrivateKey()
        let successor = P256.Signing.PrivateKey()
        let attacker = P256.Signing.PrivateKey()
        let current = try makeTrust(generation: 1, keys: [("old-key", retiring, "active")])
        let overlap = try makeTrust(generation: 2, keys: [("old-key", retiring, "retiring"), ("new-key", successor, "active")])
        let index = Data("exact overlap index".utf8)
        let payload = rotationPayload(current: current, successor: overlap, overlapIndex: index, rotationID: String(repeating: "8", count: 64))
        let wrongSignature = try dualSign(payload: payload, retiring: retiring, successor: attacker)
        let receipts = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: receipts) }
        XCTAssertThrowsError(
            try MalibuReleaseKeyRotationAuthorization.validateOverlapAndCommit(
                wrongSignature,
                currentTrust: current,
                successorTrust: overlap,
                retiringKeyID: "old-key",
                successorKeyID: "new-key",
                overlapIndexData: index,
                minimumIndexGeneration: 10,
                now: now,
                receiptDirectory: receipts
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .invalidSignature)
        }
        let valid = try dualSign(payload: payload, retiring: retiring, successor: successor)
        XCTAssertThrowsError(
            try MalibuReleaseKeyRotationAuthorization.validateOverlapAndCommit(
                valid,
                currentTrust: current,
                successorTrust: overlap,
                retiringKeyID: "old-key",
                successorKeyID: "new-key",
                overlapIndexData: Data("different index".utf8),
                minimumIndexGeneration: 10,
                now: now,
                receiptDirectory: receipts
            )
        )
        XCTAssertThrowsError(
            try MalibuReleaseKeyRotationAuthorization.validateOverlapAndCommit(
                valid,
                currentTrust: overlap,
                successorTrust: overlap,
                retiringKeyID: "old-key",
                successorKeyID: "new-key",
                overlapIndexData: index,
                minimumIndexGeneration: 10,
                now: now,
                receiptDirectory: receipts
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .rotationPolicyViolation)
        }
    }

    func testRetirementRejectsForgedExpiredWrongDigestAndWrongGeneration() throws {
        let retiring = P256.Signing.PrivateKey()
        let successor = P256.Signing.PrivateKey()
        let attacker = P256.Signing.PrivateKey()
        let overlap = try makeTrust(
            generation: 2,
            keys: [("old-key", retiring, "retiring"), ("new-key", successor, "active")]
        )
        let retirement = try makeTrust(generation: 3, keys: [("new-key", successor, "active")])
        let release = state(index: 10, build: 50, envelope: 50, digest: "a")
        let protected = MalibuReleaseProtectedState(
            schemaVersion: "malibu-release-protected-state.v1",
            revision: 7,
            highWater: release,
            activeRelease: release,
            keyringGenerationFloor: overlap.generation,
            keyringSHA256: overlap.keyringSHA256,
            revocationsGenerationFloor: overlap.revocationsGeneration,
            revocationsSHA256: overlap.revocationsSHA256,
            rollback: nil,
            rotation: nil,
            retirement: nil
        )
        let rotationID = String(repeating: "e", count: 64)
        let validPayload = retirementPayload(
            rotationID: rotationID,
            overlap: overlap,
            retirement: retirement,
            protected: protected
        )
        let forged = try signRetirement(payload: validPayload, successor: attacker)
        XCTAssertThrowsError(
            try MalibuReleaseKeyRetirementAuthorization.validate(
                forged,
                activeSuccessorTrust: overlap,
                retirementTrust: retirement,
                rotationID: rotationID,
                retiringKeyID: "old-key",
                successorKeyID: "new-key",
                protectedRevision: protected.revision,
                highWater: protected.highWater,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .invalidSignature)
        }

        var expiredPayload = validPayload
        expiredPayload["expires_at"] = stamp(now)
        var wrongDigestPayload = validPayload
        var wrongDigestTrust = try XCTUnwrap(wrongDigestPayload["retirement_trust"] as? [String: Any])
        wrongDigestTrust["keyring_sha256"] = String(repeating: "f", count: 64)
        wrongDigestPayload["retirement_trust"] = wrongDigestTrust
        var wrongGenerationPayload = validPayload
        var wrongGenerationTrust = try XCTUnwrap(wrongGenerationPayload["retirement_trust"] as? [String: Any])
        wrongGenerationTrust["keyring_generation"] = retirement.generation + 1
        wrongGenerationPayload["retirement_trust"] = wrongGenerationTrust

        for payload in [expiredPayload, wrongDigestPayload, wrongGenerationPayload] {
            let document = try signRetirement(payload: payload, successor: successor)
            XCTAssertThrowsError(
                try MalibuReleaseKeyRetirementAuthorization.validate(
                    document,
                    activeSuccessorTrust: overlap,
                    retirementTrust: retirement,
                    rotationID: rotationID,
                    retiringKeyID: "old-key",
                    successorKeyID: "new-key",
                    protectedRevision: protected.revision,
                    highWater: protected.highWater,
                    now: now
                )
            )
        }
    }

    func testProtectedRotationIngestAndSeparateRetirementAdvanceTrustFloors() throws {
        let retiring = P256.Signing.PrivateKey()
        let successor = P256.Signing.PrivateKey()
        let currentTrust = try makeTrust(generation: 1, keys: [("old-key", retiring, "active")])
        let overlapMaterial = try makeTrustMaterial(
            generation: 2,
            keys: [("old-key", retiring, "retiring"), ("new-key", successor, "active")]
        )
        let overlapTrust = overlapMaterial.policy
        let overlapIndex = Data("exact protected overlap index".utf8)
        let rotationID = String(repeating: "9", count: 64)
        let authorization = try dualSign(
            payload: rotationPayload(
                current: currentTrust,
                successor: overlapTrust,
                overlapIndex: overlapIndex,
                rotationID: rotationID
            ),
            retiring: retiring,
            successor: successor
        )
        let backing = MalibuReleaseMemoryBacking()
        let store = MalibuReleaseProtectedStateStore(
            backing: backing,
            keyGenerator: { Data(repeating: 0x33, count: 32) }
        )
        let release = state(index: 10, build: 50, envelope: 50, digest: "a")
        try store.save(.bootstrap(release: release, trust: currentTrust), expectedRevision: nil)
        try MalibuReleaseRuntimeAuthorization.prepareRotation(
            authorizationData: authorization,
            currentTrust: currentTrust,
            successorTrustBundle: overlapMaterial.bundle,
            retiringKeyID: "old-key",
            successorKeyID: "new-key",
            overlapIndexData: overlapIndex,
            minimumIndexGeneration: 10,
            now: now,
            protectedStore: store
        )
        var protected = try XCTUnwrap(store.load())
        XCTAssertEqual(protected.rotation?.status, .pending)
        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.prepareRotation(
                authorizationData: authorization,
                currentTrust: currentTrust,
                successorTrustBundle: overlapMaterial.bundle,
                retiringKeyID: "old-key",
                successorKeyID: "new-key",
                overlapIndexData: overlapIndex,
                minimumIndexGeneration: 10,
                now: now,
                protectedStore: store
            )
        )

        let pendingRotation = try XCTUnwrap(protected.rotation)
        let reboundRotation = MalibuReleaseRotationReceipt(
            rotationID: pendingRotation.rotationID,
            currentKeyringGeneration: pendingRotation.currentKeyringGeneration,
            currentKeyringSHA256: pendingRotation.currentKeyringSHA256,
            successorKeyringGeneration: pendingRotation.successorKeyringGeneration,
            successorKeyringSHA256: pendingRotation.successorKeyringSHA256,
            successorRevocationsGeneration: pendingRotation.successorRevocationsGeneration,
            successorRevocationsSHA256: pendingRotation.successorRevocationsSHA256,
            overlapIndexGeneration: pendingRotation.overlapIndexGeneration + 1,
            overlapIndexSHA256: String(repeating: "f", count: 64),
            retiringKeyID: pendingRotation.retiringKeyID,
            successorKeyID: pendingRotation.successorKeyID,
            successorTrustBundle: pendingRotation.successorTrustBundle,
            status: .completed
        )
        let reboundState = MalibuReleaseProtectedState(
            schemaVersion: protected.schemaVersion,
            revision: protected.revision + 1,
            highWater: protected.highWater,
            activeRelease: protected.activeRelease,
            keyringGenerationFloor: overlapTrust.generation,
            keyringSHA256: overlapTrust.keyringSHA256,
            revocationsGenerationFloor: overlapTrust.revocationsGeneration,
            revocationsSHA256: overlapTrust.revocationsSHA256,
            rollback: protected.rollback,
            rotation: reboundRotation,
            retirement: nil
        )
        XCTAssertThrowsError(
            try store.save(reboundState, expectedRevision: protected.revision)
        )

        let completedRotation = MalibuReleaseRotationReceipt(
            rotationID: pendingRotation.rotationID,
            currentKeyringGeneration: pendingRotation.currentKeyringGeneration,
            currentKeyringSHA256: pendingRotation.currentKeyringSHA256,
            successorKeyringGeneration: pendingRotation.successorKeyringGeneration,
            successorKeyringSHA256: pendingRotation.successorKeyringSHA256,
            successorRevocationsGeneration: pendingRotation.successorRevocationsGeneration,
            successorRevocationsSHA256: pendingRotation.successorRevocationsSHA256,
            overlapIndexGeneration: pendingRotation.overlapIndexGeneration,
            overlapIndexSHA256: pendingRotation.overlapIndexSHA256,
            retiringKeyID: pendingRotation.retiringKeyID,
            successorKeyID: pendingRotation.successorKeyID,
            successorTrustBundle: pendingRotation.successorTrustBundle,
            status: .completed
        )
        let activated = MalibuReleaseProtectedState(
            schemaVersion: protected.schemaVersion,
            revision: protected.revision + 1,
            highWater: protected.highWater,
            activeRelease: protected.activeRelease,
            keyringGenerationFloor: overlapTrust.generation,
            keyringSHA256: overlapTrust.keyringSHA256,
            revocationsGenerationFloor: overlapTrust.revocationsGeneration,
            revocationsSHA256: overlapTrust.revocationsSHA256,
            rollback: protected.rollback,
            rotation: completedRotation,
            retirement: nil
        )
        try store.save(activated, expectedRevision: protected.revision)
        let retirementMaterial = try makeTrustMaterial(
            generation: 3,
            keys: [("new-key", successor, "active")]
        )
        let retirementTrust = retirementMaterial.policy
        protected = try XCTUnwrap(store.load())
        let retirementAuthorization = try signRetirement(
            payload: retirementPayload(
                rotationID: rotationID,
                overlap: overlapTrust,
                retirement: retirementTrust,
                protected: protected
            ),
            successor: successor
        )
        try MalibuReleaseRuntimeAuthorization.prepareRetirement(
            authorizationData: retirementAuthorization,
            overlapTrust: overlapTrust,
            retirementTrustBundle: retirementMaterial.bundle,
            now: now,
            protectedStore: store
        )
        XCTAssertEqual(try store.load()?.retirement?.status, .pending)

        // Recreate the store to prove the authenticated pending receipt survives
        // restart and is the sole authority consumed by completion.
        let restartedStore = MalibuReleaseProtectedStateStore(
            backing: backing,
            keyGenerator: { Data(repeating: 0x44, count: 32) }
        )
        try MalibuReleaseRuntimeAuthorization.retireRotation(
            overlapTrust: overlapTrust,
            retirementTrust: retirementTrust,
            protectedStore: restartedStore
        )
        protected = try XCTUnwrap(restartedStore.load())
        XCTAssertEqual(protected.rotation?.status, .completed)
        XCTAssertEqual(protected.retirement?.status, .completed)
        XCTAssertEqual(protected.keyringGenerationFloor, 3)
        XCTAssertEqual(protected.keyringSHA256, retirementTrust.keyringSHA256)
        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.prepareRetirement(
                authorizationData: retirementAuthorization,
                overlapTrust: overlapTrust,
                retirementTrustBundle: retirementMaterial.bundle,
                now: now,
                protectedStore: restartedStore
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .authorizationReplay)
        }
    }

    private func state(index: Int, build: Int, envelope: Int, digest: Character) -> MalibuReleaseAntiReplayState {
        MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: index,
            highestBuild: build,
            highestEnvelopeGeneration: envelope,
            envelopeSHA256: String(repeating: digest, count: 64)
        )
    }

    private func stateObject(_ state: MalibuReleaseAntiReplayState) -> [String: Any] {
        [
            "build": state.highestBuild,
            "envelope_generation": state.highestEnvelopeGeneration,
            "envelope_sha256": state.envelopeSHA256,
            "index_generation": state.highestIndexGeneration,
        ]
    }

    private func rollbackPayload(current: MalibuReleaseAntiReplayState, target: MalibuReleaseAntiReplayState) -> [String: Any] {
        [
            "current": stateObject(current),
            "expires_at": stamp(now.addingTimeInterval(1_800)),
            "incident": "INC-585",
            "issued_at": stamp(now),
            "issuer": "release-security@example.test",
            "nonce": String(repeating: "c", count: 64),
            "target": stateObject(target),
        ]
    }

    private func rotationPayload(
        current: MalibuReleaseTrustPolicy,
        successor: MalibuReleaseTrustPolicy,
        overlapIndex: Data,
        rotationID: String
    ) -> [String: Any] {
        [
            "audit": ["report_sha256": String(repeating: "5", count: 64), "reviewer": "security-reviewer@example.test"],
            "current_trust": trustObject(current, keyLabel: "retiring_key_id", keyID: "old-key"),
            "expires_at": stamp(now.addingTimeInterval(3_600)),
            "incident": "ROT-585",
            "issued_at": stamp(now),
            "issuer": "release-security@example.test",
            "overlap_index": ["index_generation": 11, "sha256": SHA256.hash(data: overlapIndex).testHex],
            "rotation_id": rotationID,
            "successor_trust": trustObject(successor, keyLabel: "successor_key_id", keyID: "new-key"),
        ]
    }

    private func retirementPayload(
        rotationID: String,
        overlap: MalibuReleaseTrustPolicy,
        retirement: MalibuReleaseTrustPolicy,
        protected: MalibuReleaseProtectedState,
        issuedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> [String: Any] {
        [
            "expires_at": stamp(expiresAt ?? now.addingTimeInterval(1_800)),
            "high_water": stateObject(protected.highWater),
            "issued_at": stamp(issuedAt ?? now),
            "nonce": String(repeating: "d", count: 64),
            "overlap_trust": trustObject(overlap, keyLabel: "successor_key_id", keyID: "new-key"),
            "protected_revision": protected.revision,
            "retirement_trust": [
                "keyring_generation": retirement.generation,
                "keyring_sha256": retirement.keyringSHA256,
                "retiring_key_id": "old-key",
                "revocations_generation": retirement.revocationsGeneration,
                "revocations_sha256": retirement.revocationsSHA256,
                "successor_key_id": "new-key",
            ],
            "retiring_key_id": "old-key",
            "rotation_id": rotationID,
            "successor_key_id": "new-key",
        ]
    }

    private func trustObject(_ trust: MalibuReleaseTrustPolicy, keyLabel: String, keyID: String) -> [String: Any] {
        [
            "keyring_generation": trust.generation,
            "keyring_sha256": trust.keyringSHA256,
            keyLabel: keyID,
            "revocations_generation": trust.revocationsGeneration,
            "revocations_sha256": trust.revocationsSHA256,
        ]
    }

    private func makeTrust(
        generation: Int,
        keys: [(String, P256.Signing.PrivateKey, String)]
    ) throws -> MalibuReleaseTrustPolicy {
        try makeTrustMaterial(generation: generation, keys: keys).policy
    }

    private func makeTrustMaterial(
        generation: Int,
        keys: [(String, P256.Signing.PrivateKey, String)]
    ) throws -> (policy: MalibuReleaseTrustPolicy, bundle: MalibuReleaseTrustBundle) {
        let keyring: [String: Any] = [
            "generation": generation,
            "keys": keys.map { keyID, key, status in
                [
                    "algorithm": "ecdsa-p256-sha256",
                    "key_id": keyID,
                    "public_key_path": "\(keyID).pem",
                    "public_key_spki_sha256": SHA256.hash(data: key.publicKey.derRepresentation).testHex,
                    "status": status,
                ]
            },
            "schema_version": "malibu-release-keyring.v1",
        ]
        let revocations: [String: Any] = [
            "generation": generation,
            "issued_at": stamp(now),
            "keyring_generation": generation,
            "revoked_key_ids": [],
            "revoked_keyring_generations": [],
            "schema_version": "malibu-release-revocations.v1",
        ]
        let lookup = Dictionary(uniqueKeysWithValues: keys.map { ("\($0.0).pem", Data($0.1.publicKey.pemRepresentation.utf8)) })
        let keyringData = try canonicalTest(keyring)
        let revocationsData = try canonicalTest(revocations)
        let bundle = MalibuReleaseTrustBundle(
            keyringData: keyringData,
            revocationsData: revocationsData,
            publicKeys: lookup
        )
        let policy = try MalibuReleaseTrustPolicy.parse(
            keyringData: keyringData,
            revocationsData: revocationsData,
            minimumGeneration: generation,
            publicKeyLoader: { try XCTUnwrap(lookup[$0]) }
        )
        return (policy, bundle)
    }

    private func sign(payload: [String: Any], schema: String, context: String, keyID: String, key: P256.Signing.PrivateKey) throws -> Data {
        let canonical = try canonicalTest(payload)
        let signature = try key.signature(for: Data(context.utf8) + Data([0]) + canonical)
        return try canonicalTest([
            "schema_version": schema,
            "signature": ["algorithm": "ecdsa-p256-sha256", "key_id": keyID, "signature": signature.derRepresentation.testBase64URL],
            "signed": payload,
        ])
    }

    private func dualSign(payload: [String: Any], retiring: P256.Signing.PrivateKey, successor: P256.Signing.PrivateKey) throws -> Data {
        let canonical = try canonicalTest(payload)
        let oldSignature = try retiring.signature(for: Data("malibu.release-key-rotation.v1.retiring".utf8) + Data([0]) + canonical)
        let newSignature = try successor.signature(for: Data("malibu.release-key-rotation.v1.successor".utf8) + Data([0]) + canonical)
        return try canonicalTest([
            "schema_version": MalibuReleaseKeyRotationAuthorization.schema,
            "signatures": [
                "retiring": ["algorithm": "ecdsa-p256-sha256", "key_id": "old-key", "signature": oldSignature.derRepresentation.testBase64URL],
                "successor": ["algorithm": "ecdsa-p256-sha256", "key_id": "new-key", "signature": newSignature.derRepresentation.testBase64URL],
            ],
            "signed": payload,
        ])
    }

    private func signRetirement(
        payload: [String: Any],
        successor: P256.Signing.PrivateKey
    ) throws -> Data {
        try sign(
            payload: payload,
            schema: MalibuReleaseKeyRetirementAuthorization.schema,
            context: "malibu.release-key-retirement.v1",
            keyID: "new-key",
            key: successor
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private func canonicalTest(_ value: Any) throws -> Data {
    try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(value))
}

private func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
}

private extension Digest {
    var testHex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    var testBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
