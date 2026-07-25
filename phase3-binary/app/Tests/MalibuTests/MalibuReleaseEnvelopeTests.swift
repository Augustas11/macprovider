import CryptoKit
import Foundation
import XCTest
@testable import Malibu

final class MalibuReleaseEnvelopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCanonicalJSONMatchesPublicationFixture() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("schemas/fixtures/malibu-release-canonical-parity.json")
        let expectedHex = root.appendingPathComponent("schemas/fixtures/malibu-release-canonical-parity.hex")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
        let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(object))
        XCTAssertEqual(canonical.hexString, try String(contentsOf: expectedHex).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testBundledBootstrapTrustMatchesPublicationInputs() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let bundled = root.appendingPathComponent(
            "phase3-binary/app/Sources/Malibu/Resources/ReleaseTrust",
            isDirectory: true
        )
        let publication = root.appendingPathComponent(
            "phase3-binary/app/release-trust",
            isDirectory: true
        )
        XCTAssertEqual(
            try Data(contentsOf: bundled.appendingPathComponent("malibu-release-keyring.json")),
            try Data(contentsOf: publication.appendingPathComponent("malibu-release-keyring.json"))
        )
        XCTAssertEqual(
            try Data(contentsOf: bundled.appendingPathComponent("malibu-release-revocations.json")),
            try Data(contentsOf: publication.appendingPathComponent("malibu-release-revocations.json"))
        )
        XCTAssertEqual(
            try Data(contentsOf: bundled.appendingPathComponent("release-signing-public.pem")),
            try Data(contentsOf: publication.appendingPathComponent("release-signing-public.pem"))
        )
    }

    func testValidIndependentAppAndCLIEnvelopeAndIndexAdvanceState() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        let index = try fixture.index(envelope: envelope)
        let accepted = try MalibuReleaseEnvelopeValidator.validateIndex(
            index,
            envelopeData: envelope,
            trust: fixture.trust,
            now: now,
            state: .empty
        )
        XCTAssertEqual(accepted.highestBuild, 41)
        XCTAssertEqual(accepted.highestEnvelopeGeneration, 41)
        XCTAssertEqual(accepted.highestIndexGeneration, 1)
        XCTAssertEqual(accepted.envelopeSHA256, SHA256.hash(data: envelope).hexString)
    }

    func testDuplicateUnknownAndNoncanonicalDocumentsFailClosed() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        let duplicate = Data(envelope.dropLast())
            + Data(",\"schema_version\":\"malibu-release-envelope.v1\"}".utf8)
        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateEnvelope(
                duplicate,
                trust: fixture.trust,
                now: now,
                state: .empty
            )
        ) { error in
            guard case MalibuReleaseContractError.duplicateKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        var payload = fixture.envelopePayload()
        payload["unknown"] = "forbidden"
        let unknown = try fixture.sign(schema: "malibu-release-envelope.v1", context: "malibu.release-envelope.v1", payload: payload)
        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateEnvelope(unknown, trust: fixture.trust, now: now, state: .empty)
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .invalidFields("envelope signed payload"))
        }

        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateEnvelope(envelope + Data([0x0A]), trust: fixture.trust, now: now, state: .empty)
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .nonCanonical("Malibu release envelope"))
        }
    }

    func testTamperedUnknownAndRevokedKeysFailClosed() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        var signature = try XCTUnwrap(document["signature"] as? [String: Any])
        signature["key_id"] = "unknown-key"
        document["signature"] = signature
        let unknown = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(document))
        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateEnvelope(unknown, trust: fixture.trust, now: now, state: .empty)
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .unknownKey("unknown-key"))
        }

        signature["key_id"] = "test-key"
        signature["signature"] = String(repeating: "A", count: 16)
        document["signature"] = signature
        let tampered = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(document))
        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateEnvelope(tampered, trust: fixture.trust, now: now, state: .empty)
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .invalidSignature)
        }

        let revoked = try fixture.makeTrust(revokedKeyIDs: ["test-key"])
        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateEnvelope(envelope, trust: revoked, now: now, state: .empty)
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .revokedKey("test-key"))
        }
    }

    func testRevokedAndRollbackKeyringGenerationsFailClosed() throws {
        let fixture = try Fixture(now: now)
        XCTAssertThrowsError(try fixture.makeTrust(revokedGenerations: [1])) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .revokedKeyringGeneration(1))
        }
        XCTAssertThrowsError(try fixture.makeTrust(minimumGeneration: 2)) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .keyringRollback)
        }
    }

    func testExpiredFutureDatedAndOverlongIndexesFailClosed() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        for payload in [
            fixture.indexPayload(envelope: envelope, issuedOffset: -700_000, expiresOffset: -1),
            fixture.indexPayload(envelope: envelope, issuedOffset: 301, expiresOffset: 600),
            fixture.indexPayload(envelope: envelope, issuedOffset: 0, expiresOffset: 604_801),
        ] {
            let index = try fixture.sign(schema: "malibu-release-index.v1", context: "malibu.release-index.v1", payload: payload)
            XCTAssertThrowsError(
                try MalibuReleaseEnvelopeValidator.validateIndex(index, envelopeData: envelope, trust: fixture.trust, now: now, state: .empty)
            )
        }
    }

    func testIndexBuildGenerationAndDigestRollbackFailClosed() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        let prior = MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: 2,
            highestBuild: 42,
            highestEnvelopeGeneration: 42,
            envelopeSHA256: String(repeating: "a", count: 64)
        )
        let index = try fixture.index(envelope: envelope)
        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateIndex(index, envelopeData: envelope, trust: fixture.trust, now: now, state: prior)
        ) { error in
            XCTAssertTrue(
                error as? MalibuReleaseContractError == .buildRollback
                    || error as? MalibuReleaseContractError == .envelopeRollback
            )
        }

        var wrongDigest = fixture.indexPayload(envelope: envelope)
        var row = try XCTUnwrap(wrongDigest["envelope"] as? [String: Any])
        row["sha256"] = String(repeating: "b", count: 64)
        wrongDigest["envelope"] = row
        let signed = try fixture.sign(schema: "malibu-release-index.v1", context: "malibu.release-index.v1", payload: wrongDigest)
        XCTAssertThrowsError(
            try MalibuReleaseEnvelopeValidator.validateIndex(signed, envelopeData: envelope, trust: fixture.trust, now: now, state: .empty)
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .digestMismatch)
        }
    }

    func testAntiReplayStoreIsAtomicOwnerOnlyAndRejectsLooseMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Malibu/release-anti-replay-v1.json")
        let state = MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: 7,
            highestBuild: 41,
            highestEnvelopeGeneration: 41,
            envelopeSHA256: String(repeating: "c", count: 64)
        )
        try MalibuReleaseAntiReplayStore.commit(state, to: url)
        XCTAssertEqual(try MalibuReleaseAntiReplayStore.load(from: url), state)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try MalibuReleaseAntiReplayStore.load(from: url)) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .insecureState("mode must be 0600"))
        }
    }

    func testProtectedStateDeletionAndResetFailClosedWithPriorMalibuReleaseEvidence() throws {
        let fixture = try Fixture(now: now)
        let runtime = try makeRuntimeSidecars(fixture: fixture, includePreviousSidecars: true)
        defer { try? FileManager.default.removeItem(at: runtime.root) }

        _ = try MalibuReleaseRuntimeAuthorization.authorize(
            paths: runtime.paths,
            trust: fixture.trust,
            app: runtimeApp,
            installedProvider: runtimeProvider,
            requireInstalledProvider: true,
            now: now,
            protectedStore: runtime.protectedStore,
            priorReleaseEvidenceExists: false
        )
        runtime.protectedBacking.values.removeAll()

        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now,
                protectedStore: runtime.protectedStore,
                priorReleaseEvidenceExists: true
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseRuntimeAuthorization.Error, .protectedStateMissing)
        }
    }

    func testFirstIndependentMalibuTransactionBootstrapsOverExistingProvider() throws {
        let fixture = try Fixture(now: now)
        let runtime = try makeRuntimeSidecars(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: runtime.root) }

        XCTAssertNoThrow(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now,
                protectedStore: runtime.protectedStore
            )
        )
        XCTAssertNotNil(try runtime.protectedStore.load())
    }

    func testRootInstallMarkerPreventsProtectedStateResetWithoutPreviousSidecars() throws {
        let fixture = try Fixture(now: now)
        let runtime = try makeRuntimeSidecars(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let envelopeDigest = SHA256.hash(data: try Data(contentsOf: runtime.paths.envelope))
            .map { String(format: "%02x", $0) }.joined()
        let indexDigest = SHA256.hash(data: try Data(contentsOf: runtime.paths.index))
            .map { String(format: "%02x", $0) }.joined()
        let marker = MalibuReleaseRuntimeAuthorization.RootInstallMarker(
            appVersion: runtimeApp.marketingVersion,
            appBuild: runtimeApp.build,
            envelopeSHA256: envelopeDigest,
            indexSHA256: indexDigest,
            helperSHA256: String(repeating: "d", count: 64)
        )
        _ = try MalibuReleaseRuntimeAuthorization.authorize(
            paths: runtime.paths,
            trust: fixture.trust,
            app: runtimeApp,
            installedProvider: runtimeProvider,
            requireInstalledProvider: true,
            now: now,
            protectedStore: runtime.protectedStore,
            priorReleaseEvidenceExists: false,
            rootInstallMarker: marker,
            requireRootInstallMarker: true
        )
        runtime.protectedBacking.values.removeAll()

        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now,
                protectedStore: runtime.protectedStore,
                priorReleaseEvidenceExists: false,
                rootInstallMarker: MalibuReleaseRuntimeAuthorization.RootInstallMarker(
                    appVersion: marker.appVersion,
                    appBuild: marker.appBuild,
                    envelopeSHA256: String(repeating: "e", count: 64),
                    indexSHA256: marker.indexSHA256,
                    helperSHA256: marker.helperSHA256
                ),
                requireRootInstallMarker: true
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseRuntimeAuthorization.Error, .protectedStateMissing)
        }
    }

    func testProtectedStateRejectsForgedAuthenticatedReceiptAndLowerFloor() throws {
        let fixture = try Fixture(now: now)
        let backing = MalibuReleaseMemoryBacking()
        let store = MalibuReleaseProtectedStateStore(
            backing: backing,
            keyGenerator: { Data(repeating: 0xA5, count: 32) }
        )
        let floor = MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: 9,
            highestBuild: 50,
            highestEnvelopeGeneration: 50,
            envelopeSHA256: String(repeating: "a", count: 64)
        )
        try store.save(.bootstrap(release: floor, trust: fixture.trust), expectedRevision: nil)
        let current = try XCTUnwrap(store.load())
        let lower = MalibuReleaseAntiReplayState(
            schemaVersion: floor.schemaVersion,
            highestIndexGeneration: 8,
            highestBuild: 49,
            highestEnvelopeGeneration: 49,
            envelopeSHA256: String(repeating: "b", count: 64)
        )
        XCTAssertThrowsError(
            try store.save(
                MalibuReleaseProtectedState(
                    schemaVersion: current.schemaVersion,
                    revision: current.revision + 1,
                    highWater: lower,
                    activeRelease: lower,
                    keyringGenerationFloor: current.keyringGenerationFloor,
                    keyringSHA256: current.keyringSHA256,
                    revocationsGenerationFloor: current.revocationsGenerationFloor,
                    revocationsSHA256: current.revocationsSHA256,
                    rollback: nil,
                    rotation: nil,
                    retirement: nil
                ),
                expectedRevision: current.revision
            )
        )

        let blobKey = try XCTUnwrap(backing.values.first(where: { $0.value.count != 32 })?.key)
        var blob = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backing.values[blobKey]!) as? [String: Any]
        )
        var payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(blob["payload"] as? String)))
        payload[payload.startIndex] ^= 0x01
        blob["payload"] = payload.base64EncodedString()
        backing.values[blobKey] = try JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys])
        XCTAssertThrowsError(try store.load()) { error in
            guard case MalibuReleaseContractError.insecureState = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLiveAppIdentityFailsClosedWhenStrictCodeSealCheckRejects() throws {
        var checks = 0
        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.AppIdentity.live(
                bundle: .main,
                verifyCode: { _ in
                    checks += 1
                    throw MalibuReleaseRuntimeAuthorization.Error.appSigningIdentityMismatch
                },
                readTree: { _ in
                    .init(entryCount: 1, rootMode: 0o755, treeSHA256: String(repeating: "9", count: 64))
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? MalibuReleaseRuntimeAuthorization.Error,
                .appSigningIdentityMismatch
            )
        }
        XCTAssertEqual(checks, 1)
    }

    func testRuntimeAuthorizationAcceptsExactIndependentAppAndProviderTuple() throws {
        let fixture = try Fixture(now: now)
        let runtime = try makeRuntimeSidecars(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: runtime.root) }

        let receipt = try MalibuReleaseRuntimeAuthorization.authorize(
            paths: runtime.paths,
            trust: fixture.trust,
            app: runtimeApp,
            installedProvider: runtimeProvider,
            requireInstalledProvider: true,
            now: now,
            protectedStore: runtime.protectedStore
        )

        XCTAssertEqual(receipt.envelope.marketingVersion, "1.8.41")
        XCTAssertEqual(receipt.envelope.providerCLIVersion, "1.8.40")
        XCTAssertEqual(receipt.installedProvider, runtimeProvider)
        XCTAssertEqual(
            try XCTUnwrap(runtime.protectedStore.load()).highWater,
            receipt.antiReplayState
        )
    }

    func testAuthorizeLiveLoadsAcceptedSuccessorTrustFromProtectedRotation() throws {
        let bootstrap = try Fixture(now: now, generation: 1, keyID: "old-key")
        let successor = try Fixture(now: now, generation: 2, keyID: "new-key")
        let envelope = try successor.envelope()
        let index = try successor.index(envelope: envelope)
        let runtime = try makeRuntimeSidecars(
            fixture: successor,
            envelope: envelope,
            index: index
        )
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let release = try MalibuReleaseEnvelopeValidator.validateIndex(
            index,
            envelopeData: envelope,
            trust: successor.trust,
            now: now,
            state: .empty
        )
        try runtime.protectedStore.save(
            .bootstrap(release: release, trust: bootstrap.trust),
            expectedRevision: nil
        )
        let protected = try XCTUnwrap(runtime.protectedStore.load())
        let rotation = MalibuReleaseRotationReceipt(
            rotationID: String(repeating: "a", count: 64),
            currentKeyringGeneration: bootstrap.trust.generation,
            currentKeyringSHA256: bootstrap.trust.keyringSHA256,
            successorKeyringGeneration: successor.trust.generation,
            successorKeyringSHA256: successor.trust.keyringSHA256,
            successorRevocationsGeneration: successor.trust.revocationsGeneration,
            successorRevocationsSHA256: successor.trust.revocationsSHA256,
            overlapIndexGeneration: release.highestIndexGeneration,
            overlapIndexSHA256: SHA256.hash(data: index).map { String(format: "%02x", $0) }.joined(),
            retiringKeyID: "old-key",
            successorKeyID: "new-key",
            successorTrustBundle: try successor.trustBundle(),
            status: .pending
        )
        try runtime.protectedStore.save(
            MalibuReleaseProtectedState(
                schemaVersion: protected.schemaVersion,
                revision: protected.revision + 1,
                highWater: protected.highWater,
                activeRelease: protected.activeRelease,
                keyringGenerationFloor: protected.keyringGenerationFloor,
                keyringSHA256: protected.keyringSHA256,
                revocationsGenerationFloor: protected.revocationsGenerationFloor,
                revocationsSHA256: protected.revocationsSHA256,
                rollback: nil,
                rotation: rotation,
                retirement: nil
            ),
            expectedRevision: protected.revision
        )

        let receipt = try MalibuReleaseRuntimeAuthorization.authorizeLive(
            requireInstalledProvider: true,
            now: now,
            protectedStore: runtime.protectedStore,
            verifyApp: { self.runtimeApp },
            paths: runtime.paths,
            bundledTrustLoader: { bootstrap.trust },
            installedProviderLoader: { _ in self.runtimeProvider },
            rootInstallMarkerLoader: { _ in
                MalibuReleaseRuntimeAuthorization.RootInstallMarker(
                    appVersion: self.runtimeApp.marketingVersion,
                    appBuild: self.runtimeApp.build,
                    envelopeSHA256: String(repeating: "a", count: 64),
                    indexSHA256: String(repeating: "b", count: 64),
                    helperSHA256: String(repeating: "c", count: 64)
                )
            },
            recoverTransaction: { _, _ in }
        )

        XCTAssertEqual(receipt.antiReplayState, release)
        let activated = try XCTUnwrap(runtime.protectedStore.load())
        XCTAssertEqual(activated.rotation?.status, .completed)
        XCTAssertEqual(activated.keyringGenerationFloor, successor.trust.generation)
        XCTAssertEqual(activated.keyringSHA256, successor.trust.keyringSHA256)
    }

    func testRuntimeAuthorizationAcceptsExactUpgradeStateWithPairedPreviousSidecars() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        let runtime = try makeRuntimeSidecars(
            fixture: fixture,
            envelope: envelope,
            includePreviousSidecars: true
        )
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let installed = MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: 1,
            highestBuild: 41,
            highestEnvelopeGeneration: 41,
            envelopeSHA256: SHA256.hash(data: envelope).hexString
        )
        try runtime.protectedStore.save(
            .bootstrap(release: installed, trust: fixture.trust),
            expectedRevision: nil
        )

        XCTAssertNoThrow(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now,
                protectedStore: runtime.protectedStore
            )
        )
    }

    func testRuntimeAuthorizationRejectsMutableLegacySourceVersion() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        let runtime = try makeRuntimeSidecars(
            fixture: fixture,
            envelope: envelope,
            includePreviousSidecars: true
        )
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let installed = MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: 1,
            highestBuild: 41,
            highestEnvelopeGeneration: 41,
            envelopeSHA256: SHA256.hash(data: envelope).hexString
        )
        try runtime.protectedStore.save(
            .bootstrap(release: installed, trust: fixture.trust),
            expectedRevision: nil
        )
        var record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: runtime.paths.transaction))
                as? [String: Any]
        )
        var previous = try XCTUnwrap(record["previous"] as? [String: Any])
        previous["marketing_version"] = "1.8.39"
        record["previous"] = previous
        try (canonical(record) + Data([0x0A])).write(to: runtime.paths.transaction)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: runtime.paths.transaction.path
        )

        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now,
                protectedStore: runtime.protectedStore
            )
        ) { error in
            XCTAssertEqual(
                error as? MalibuReleaseRuntimeAuthorization.Error,
                .insecureSidecar("transaction.json previous app evidence")
            )
        }
    }

    func testRollbackInputReconciliationRemovesAbandonedFiles() throws {
        let release = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputs = release.appendingPathComponent("rollback-inputs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: release) }
        try FileManager.default.createDirectory(
            at: inputs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let abandoned = inputs.appendingPathComponent(
            "authorization-\(String(repeating: "a", count: 64)).json"
        )
        try Data("stale".utf8).write(to: abandoned)

        try MalibuReleaseRuntimeAuthorization.reconcileRollbackInputs(
            releaseDirectory: release
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: inputs.path))
    }

    func testRuntimeAuthorizationAcceptsInstalledTransactionAfterDiscoveryAndBootstrapExpiry() throws {
        let fixture = try Fixture(now: now)
        for elapsed in [8.0 * 24 * 60 * 60, 31.0 * 24 * 60 * 60] {
            let runtime = try makeRuntimeSidecars(fixture: fixture)
            defer { try? FileManager.default.removeItem(at: runtime.root) }

            _ = try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now,
                protectedStore: runtime.protectedStore
            )

            XCTAssertNoThrow(
                try MalibuReleaseRuntimeAuthorization.authorize(
                    paths: runtime.paths,
                    trust: fixture.trust,
                    app: runtimeApp,
                    installedProvider: runtimeProvider,
                    requireInstalledProvider: true,
                    now: now.addingTimeInterval(elapsed),
                    protectedStore: runtime.protectedStore
                )
            )
        }
    }

    func testFreshInstalledTransactionBootstrapsAfterDiscoveryExpiryWithRootAuthority() throws {
        let fixture = try Fixture(now: now)
        let runtime = try makeRuntimeSidecars(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let marker = MalibuReleaseRuntimeAuthorization.RootInstallMarker(
            appVersion: runtimeApp.marketingVersion,
            appBuild: runtimeApp.build,
            envelopeSHA256: SHA256.hash(data: try Data(contentsOf: runtime.paths.envelope)).hexString,
            indexSHA256: SHA256.hash(data: try Data(contentsOf: runtime.paths.index)).hexString,
            helperSHA256: String(repeating: "a", count: 64)
        )
        let afterDiscoveryExpiry = now.addingTimeInterval(8 * 24 * 60 * 60)

        XCTAssertNoThrow(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: afterDiscoveryExpiry,
                protectedStore: runtime.protectedStore,
                rootInstallMarker: marker,
                requireRootInstallMarker: true
            )
        )
    }

    func testFreshDiscoveryStillRejectsExpiredMetadataWithoutRootAuthority() throws {
        let fixture = try Fixture(now: now)
        let runtime = try makeRuntimeSidecars(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: runtime.root) }

        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now.addingTimeInterval(8 * 24 * 60 * 60),
                protectedStore: runtime.protectedStore
            )
        )
    }

    func testRuntimeAuthorizationRejectsFutureIssuedInstalledTransactionMetadata() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        let futureIndex = try fixture.sign(
            schema: "malibu-release-index.v1",
            context: "malibu.release-index.v1",
            payload: fixture.indexPayload(
                envelope: envelope,
                issuedOffset: 301,
                expiresOffset: 600
            )
        )
        let runtime = try makeRuntimeSidecars(
            fixture: fixture,
            envelope: envelope,
            index: futureIndex
        )
        defer { try? FileManager.default.removeItem(at: runtime.root) }

        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now,
                protectedStore: runtime.protectedStore
            )
        ) { error in
            XCTAssertEqual(
                error as? MalibuReleaseRuntimeAuthorization.Error,
                .releaseContract(MalibuReleaseContractError.futureDated.localizedDescription)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.antiReplayState.path))
    }

    func testRuntimeAuthorizationRejectsPartialOrUnexpectedUpgradeSidecars() throws {
        let fixture = try Fixture(now: now)
        for unexpectedName in ["previous-release-envelope.json", "unexpected.json"] {
            let runtime = try makeRuntimeSidecars(fixture: fixture)
            defer { try? FileManager.default.removeItem(at: runtime.root) }
            let unexpected = runtime.paths.activeDirectory.appendingPathComponent(unexpectedName)
            try Data("not runtime authority".utf8).write(to: unexpected)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unexpected.path
            )

            XCTAssertThrowsError(
                try MalibuReleaseRuntimeAuthorization.authorize(
                    paths: runtime.paths,
                    trust: fixture.trust,
                    app: runtimeApp,
                    installedProvider: runtimeProvider,
                    requireInstalledProvider: true,
                    now: now,
                    protectedStore: runtime.protectedStore
                )
            ) { error in
                XCTAssertEqual(
                    error as? MalibuReleaseRuntimeAuthorization.Error,
                    .insecureSidecar("active release transaction directory has unexpected entries")
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.antiReplayState.path))
        }
    }

    func testSignedRollbackTargetStartsWhileProtectedHighWaterRemainsImmutable() throws {
        let fixture = try Fixture(now: now)
        let envelope = try fixture.envelope()
        let target = MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: 1,
            highestBuild: 41,
            highestEnvelopeGeneration: 41,
            envelopeSHA256: SHA256.hash(data: envelope).hexString
        )
        let current = MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: 2,
            highestBuild: 42,
            highestEnvelopeGeneration: 42,
            envelopeSHA256: String(repeating: "a", count: 64)
        )
        let rollbackPayload: [String: Any] = [
            "current": releaseStateObject(current),
            "expires_at": timestamp(now.addingTimeInterval(1_800)),
            "incident": "INC-585-runtime",
            "issued_at": timestamp(now),
            "issuer": "release-security@example.test",
            "nonce": String(repeating: "c", count: 64),
            "target": releaseStateObject(target),
        ]
        let authorization = try fixture.sign(
            schema: MalibuReleaseRollbackAuthorization.schema,
            context: "malibu.release-rollback.v1",
            payload: rollbackPayload
        )
        let runtime = try makeRuntimeSidecars(
            fixture: fixture,
            envelope: envelope,
            transactionState: "rolled_back",
            rollbackAuthorizationSHA256: SHA256.hash(data: authorization).hexString,
            rolledBackFromState: current
        )
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        try runtime.protectedStore.save(
            .bootstrap(release: current, trust: fixture.trust),
            expectedRevision: nil
        )
        try MalibuReleaseRuntimeAuthorization.prepareRollback(
            authorizationData: authorization,
            trust: fixture.trust,
            target: target,
            now: now,
            protectedStore: runtime.protectedStore
        )
        let pending = try XCTUnwrap(runtime.protectedStore.load())
        XCTAssertEqual(pending.rollback?.status, .pending)
        XCTAssertEqual(pending.activeRelease, current)
        XCTAssertEqual(pending.highWater, current)
        try MalibuReleaseRuntimeAuthorization.prepareRollback(
            authorizationData: authorization,
            trust: fixture.trust,
            target: target,
            now: now,
            protectedStore: runtime.protectedStore
        )
        XCTAssertEqual(try runtime.protectedStore.load(), pending)
        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.prepareRollback(
                authorizationData: authorization,
                trust: fixture.trust,
                target: target,
                now: now.addingTimeInterval(3_600),
                protectedStore: runtime.protectedStore
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .expired)
        }

        var conflictingPayload = rollbackPayload
        conflictingPayload["nonce"] = String(repeating: "d", count: 64)
        let conflictingAuthorization = try fixture.sign(
            schema: MalibuReleaseRollbackAuthorization.schema,
            context: "malibu.release-rollback.v1",
            payload: conflictingPayload
        )
        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.prepareRollback(
                authorizationData: conflictingAuthorization,
                trust: fixture.trust,
                target: target,
                now: now,
                protectedStore: runtime.protectedStore
            )
        ) { error in
            XCTAssertEqual(error as? MalibuReleaseContractError, .authorizationReplay)
        }
        XCTAssertEqual(try runtime.protectedStore.load(), pending)

        let retryNow = now.addingTimeInterval(3_600)
        var replacementPayload = rollbackPayload
        replacementPayload["issued_at"] = timestamp(retryNow)
        replacementPayload["expires_at"] = timestamp(retryNow.addingTimeInterval(1_800))
        replacementPayload["nonce"] = String(repeating: "e", count: 64)
        let replacementAuthorization = try fixture.sign(
            schema: MalibuReleaseRollbackAuthorization.schema,
            context: "malibu.release-rollback.v1",
            payload: replacementPayload
        )
        try MalibuReleaseRuntimeAuthorization.prepareRollback(
            authorizationData: replacementAuthorization,
            trust: fixture.trust,
            target: target,
            now: retryNow,
            protectedStore: runtime.protectedStore
        )
        let replaced = try XCTUnwrap(runtime.protectedStore.load())
        XCTAssertEqual(
            replaced.rollback?.authorizationSHA256,
            SHA256.hash(data: replacementAuthorization).hexString
        )
        XCTAssertEqual(replaced.revision, pending.revision + 1)
        var transaction = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: runtime.paths.transaction))
                as? [String: Any]
        )
        transaction["rollback_authorization_sha256"] = SHA256.hash(
            data: replacementAuthorization
        ).hexString
        try (canonical(transaction) + Data([0x0A])).write(to: runtime.paths.transaction)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: runtime.paths.transaction.path
        )

        for _ in 0..<2 {
            _ = try MalibuReleaseRuntimeAuthorization.authorize(
                paths: runtime.paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: retryNow,
                protectedStore: runtime.protectedStore
            )
        }
        let protected = try XCTUnwrap(runtime.protectedStore.load())
        XCTAssertEqual(protected.highWater, current)
        XCTAssertEqual(protected.activeRelease, target)
        XCTAssertEqual(protected.rollback?.status, .completed)
        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.prepareRollback(
                authorizationData: replacementAuthorization,
                trust: fixture.trust,
                target: target,
                now: retryNow,
                protectedStore: runtime.protectedStore
            )
        )
    }

    func testRuntimeAuthorizationMissingSidecarsFailsWithoutAdvancingState() throws {
        let fixture = try Fixture(now: now)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = MalibuReleaseRuntimeAuthorization.Paths(appSupport: root)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try MalibuReleaseRuntimeAuthorization.authorize(
                paths: paths,
                trust: fixture.trust,
                app: runtimeApp,
                installedProvider: runtimeProvider,
                requireInstalledProvider: true,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? MalibuReleaseRuntimeAuthorization.Error,
                .missingSidecar("active release transaction directory")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.antiReplayState.path))
    }

    func testRuntimeAuthorizationTamperedAndUnsupportedMetadataFailWithoutAdvancingState() throws {
        let fixture = try Fixture(now: now)
        let validEnvelope = try fixture.envelope()

        for envelope in [
            validEnvelope + Data([0x0A]),
            try fixture.sign(
                schema: "malibu-release-envelope.v2",
                context: "malibu.release-envelope.v1",
                payload: fixture.envelopePayload()
            ),
        ] {
            let runtime = try makeRuntimeSidecars(fixture: fixture, envelope: envelope)
            defer { try? FileManager.default.removeItem(at: runtime.root) }
            XCTAssertThrowsError(
                try MalibuReleaseRuntimeAuthorization.authorize(
                    paths: runtime.paths,
                    trust: fixture.trust,
                    app: runtimeApp,
                    installedProvider: runtimeProvider,
                    requireInstalledProvider: true,
                    now: now,
                    protectedStore: runtime.protectedStore
                )
            ) { error in
                guard case MalibuReleaseRuntimeAuthorization.Error.releaseContract = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.antiReplayState.path))
        }
    }

    func testRuntimeAuthorizationRejectsUnsupportedAppAndProviderTuplesBeforeStateCommit() throws {
        let fixture = try Fixture(now: now)
        let cases: [(MalibuReleaseRuntimeAuthorization.AppIdentity, MalibuReleaseRuntimeAuthorization.InstalledProviderIdentity?, MalibuReleaseRuntimeAuthorization.Error)] = [
            (
                .init(
                    marketingVersion: "1.8.40",
                    build: 41,
                    bundleID: "tech.malibu.app",
                    teamID: "YF7XNRJUG4",
                    bundlePath: "/Applications/Malibu.app",
                    entryCount: 1,
                    rootMode: 0o755,
                    treeSHA256: String(repeating: "9", count: 64)
                ),
                runtimeProvider,
                .appVersionMismatch(expected: "1.8.41", actual: "1.8.40")
            ),
            (
                runtimeApp,
                .init(
                    version: "1.8.39",
                    binarySHA256: String(repeating: "2", count: 64),
                    compatibilitySetID: MalibuReleaseEnvelopeValidator.compatibilitySetID,
                    compatibilityManifestSHA256: MalibuReleaseEnvelopeValidator.compatibilityManifestSHA256
                ),
                .providerVersionMismatch(expected: "1.8.40", actual: "1.8.39")
            ),
            (
                .init(
                    marketingVersion: runtimeApp.marketingVersion,
                    build: runtimeApp.build,
                    bundleID: runtimeApp.bundleID,
                    teamID: runtimeApp.teamID,
                    bundlePath: runtimeApp.bundlePath,
                    entryCount: runtimeApp.entryCount,
                    rootMode: runtimeApp.rootMode,
                    treeSHA256: String(repeating: "7", count: 64)
                ),
                runtimeProvider,
                .appIdentityUnavailable("signed bundle tree mismatch")
            ),
            (runtimeApp, nil, .installedProviderRequired),
        ]

        for (app, provider, expected) in cases {
            let runtime = try makeRuntimeSidecars(fixture: fixture)
            defer { try? FileManager.default.removeItem(at: runtime.root) }
            XCTAssertThrowsError(
                try MalibuReleaseRuntimeAuthorization.authorize(
                    paths: runtime.paths,
                    trust: fixture.trust,
                    app: app,
                    installedProvider: provider,
                    requireInstalledProvider: true,
                    now: now,
                    protectedStore: runtime.protectedStore
                )
            ) { error in
                XCTAssertEqual(error as? MalibuReleaseRuntimeAuthorization.Error, expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.antiReplayState.path))
        }
    }

    func testRuntimeAuthorizationRejectsUnsafeOrMismatchedActiveTransactionEvidence() throws {
        let fixture = try Fixture(now: now)
        for mutate in [
            { (paths: MalibuReleaseRuntimeAuthorization.Paths) throws in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o666],
                    ofItemAtPath: paths.transaction.path
                )
            },
            { (paths: MalibuReleaseRuntimeAuthorization.Paths) throws in
                var record = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: paths.transaction))
                        as? [String: Any]
                )
                record["release_index_sha256"] = String(repeating: "0", count: 64)
                try (canonical(record) + Data([0x0A])).write(to: paths.transaction)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: paths.transaction.path
                )
            },
            { (paths: MalibuReleaseRuntimeAuthorization.Paths) throws in
                var record = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: paths.transaction))
                        as? [String: Any]
                )
                record["destination_app"] = "/Applications/Other/Malibu.app"
                try (canonical(record) + Data([0x0A])).write(to: paths.transaction)
            },
            { (paths: MalibuReleaseRuntimeAuthorization.Paths) throws in
                var record = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: paths.transaction))
                        as? [String: Any]
                )
                var installed = try XCTUnwrap(record["installed"] as? [String: Any])
                installed["tree_sha256"] = String(repeating: "7", count: 64)
                record["installed"] = installed
                try (canonical(record) + Data([0x0A])).write(to: paths.transaction)
            },
        ] {
            let runtime = try makeRuntimeSidecars(fixture: fixture)
            defer { try? FileManager.default.removeItem(at: runtime.root) }
            try mutate(runtime.paths)
            XCTAssertThrowsError(
                try MalibuReleaseRuntimeAuthorization.authorize(
                    paths: runtime.paths,
                    trust: fixture.trust,
                    app: runtimeApp,
                    installedProvider: runtimeProvider,
                    requireInstalledProvider: true,
                    now: now,
                    protectedStore: runtime.protectedStore
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.antiReplayState.path))
        }
    }

    @MainActor
    func testAgentMutationEntryPointFailsClosedBeforeControlUse() async {
        var authorizationAttempts = 0
        let agent = MalibuAgent(authorizeProviderMutation: {
            authorizationAttempts += 1
            throw MalibuReleaseRuntimeAuthorization.Error.providerDigestMismatch
        })

        await agent.pause()

        XCTAssertEqual(authorizationAttempts, 1)
        XCTAssertTrue(agent.snapshot.releaseAuthorityBlocked)
        XCTAssertEqual(agent.snapshot.state, .error)
        XCTAssertEqual(
            agent.snapshot.lastError,
            "The installed provider CLI does not match the signed Malibu release authority."
        )
        XCTAssertFalse(AgentSnapshotPresenter.providerMutationActionsAllowed(agent.snapshot))
    }

    private var runtimeApp: MalibuReleaseRuntimeAuthorization.AppIdentity {
        .init(
            marketingVersion: "1.8.41",
            build: 41,
            bundleID: "tech.malibu.app",
            teamID: "YF7XNRJUG4",
            bundlePath: "/Applications/Malibu.app",
            entryCount: 1,
            rootMode: 0o755,
            treeSHA256: String(repeating: "9", count: 64)
        )
    }

    private var runtimeProvider: MalibuReleaseRuntimeAuthorization.InstalledProviderIdentity {
        .init(
            version: "1.8.40",
            binarySHA256: String(repeating: "2", count: 64),
            compatibilitySetID: MalibuReleaseEnvelopeValidator.compatibilitySetID,
            compatibilityManifestSHA256: MalibuReleaseEnvelopeValidator.compatibilityManifestSHA256
        )
    }

    private func makeRuntimeSidecars(
        fixture: Fixture,
        envelope: Data? = nil,
        index: Data? = nil,
        includePreviousSidecars: Bool = false,
        transactionState: String = "installed",
        rollbackAuthorizationSHA256: String? = nil,
        rolledBackFromState: MalibuReleaseAntiReplayState? = nil
    ) throws -> (
        root: URL,
        paths: MalibuReleaseRuntimeAuthorization.Paths,
        protectedStore: MalibuReleaseProtectedStateStore,
        protectedBacking: MalibuReleaseMemoryBacking
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = MalibuReleaseRuntimeAuthorization.Paths(appSupport: root)
        let protectedBacking = MalibuReleaseMemoryBacking()
        let protectedStore = MalibuReleaseProtectedStateStore(
            backing: protectedBacking,
            keyGenerator: { Data(repeating: 0x5A, count: 32) }
        )
        try FileManager.default.createDirectory(
            at: paths.envelope.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let envelopeData = try envelope ?? fixture.envelope()
        let indexData = try index ?? fixture.index(envelope: envelopeData)
        let appEvidence: [String: Any] = [
            "build": 41,
            "bundle_id": "tech.malibu.app",
            "entry_count": 1,
            "marketing_version": "1.8.41",
            "root_mode": 0o755,
            "tree_sha256": String(repeating: "9", count: 64),
        ]
        let releaseEvidence: [String: Any] = [
            "app_build": 41,
            "app_entry_count": 1,
            "app_root_mode": 0o755,
            "app_tree_sha256": String(repeating: "9", count: 64),
            "app_version": "1.8.41",
            "envelope_generation": 41,
            "index_generation": 1,
        ]
        let releaseState: [String: Any] = [
            "build": 41,
            "envelope_generation": 41,
            "envelope_sha256": SHA256.hash(data: envelopeData).hexString,
            "index_generation": 1,
        ]
        var transaction: [String: Any] = [
            "destination_app": "/Applications/Malibu.app",
            "installed": appEvidence,
            "installed_release_state": releaseState,
            "previous": includePreviousSidecars ? appEvidence : NSNull(),
            "previous_release": includePreviousSidecars ? releaseEvidence : NSNull(),
            "previous_release_index_sha256": includePreviousSidecars
                ? SHA256.hash(data: indexData).hexString
                : NSNull(),
            "previous_release_state": includePreviousSidecars ? releaseState : NSNull(),
            "release": releaseEvidence,
            "release_envelope_sha256": SHA256.hash(data: envelopeData).hexString,
            "release_index_sha256": SHA256.hash(data: indexData).hexString,
            "rollback_backup": NSNull(),
            "schema_version": "malibu.app-transaction.v1",
            "state": transactionState,
            "transaction_id": String(repeating: "8", count: 32),
            "unix_time": 1_800_000_000,
        ]
        if transactionState == "rolled_back" {
            let authorizationSHA256 = try XCTUnwrap(rollbackAuthorizationSHA256)
            let rolledBackFromState = try XCTUnwrap(rolledBackFromState)
            transaction["rollback_authorization_sha256"] = authorizationSHA256
            transaction["rolled_back_from"] = appEvidence
            transaction["rolled_back_from_release_state"] = releaseStateObject(rolledBackFromState)
        }
        let transactionData = try canonical(transaction) + Data([0x0A])
        try transactionData.write(to: paths.transaction)
        try envelopeData.write(to: paths.envelope)
        try indexData.write(to: paths.index)
        if includePreviousSidecars {
            try envelopeData.write(to: paths.previousEnvelope)
            try indexData.write(to: paths.previousIndex)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.transaction.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.envelope.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.index.path
        )
        if includePreviousSidecars {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.previousEnvelope.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.previousIndex.path
            )
        }
        return (root, paths, protectedStore, protectedBacking)
    }

    private func releaseStateObject(_ state: MalibuReleaseAntiReplayState) -> [String: Any] {
        [
            "build": state.highestBuild,
            "envelope_generation": state.highestEnvelopeGeneration,
            "envelope_sha256": state.envelopeSHA256,
            "index_generation": state.highestIndexGeneration,
        ]
    }
}

private struct Fixture {
    let now: Date
    let privateKey: P256.Signing.PrivateKey
    let generation: Int
    let keyID: String
    let trust: MalibuReleaseTrustPolicy

    init(
        now: Date,
        generation: Int = 1,
        keyID: String = "test-key",
        privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()
    ) throws {
        self.now = now
        self.privateKey = privateKey
        self.generation = generation
        self.keyID = keyID
        trust = try Fixture.buildTrust(
            privateKey: privateKey,
            now: now,
            generation: generation,
            keyID: keyID
        )
    }

    func makeTrust(
        revokedKeyIDs: [String] = [],
        revokedGenerations: [Int] = [],
        minimumGeneration: Int = 1
    ) throws -> MalibuReleaseTrustPolicy {
        try Fixture.buildTrust(
            privateKey: privateKey,
            now: now,
            generation: generation,
            keyID: keyID,
            revokedKeyIDs: revokedKeyIDs,
            revokedGenerations: revokedGenerations,
            minimumGeneration: minimumGeneration
        )
    }

    private static func buildTrust(
        privateKey: P256.Signing.PrivateKey,
        now: Date,
        generation: Int,
        keyID: String,
        revokedKeyIDs: [String] = [],
        revokedGenerations: [Int] = [],
        minimumGeneration: Int = 1
    ) throws -> MalibuReleaseTrustPolicy {
        let keyring: [String: Any] = [
            "generation": generation,
            "keys": [[
                "algorithm": "ecdsa-p256-sha256",
                "key_id": keyID,
                "public_key_path": "\(keyID).pem",
                "public_key_spki_sha256": SHA256.hash(data: privateKey.publicKey.derRepresentation).hexString,
                "status": "active",
            ]],
            "schema_version": "malibu-release-keyring.v1",
        ]
        let revocations: [String: Any] = [
            "generation": generation,
            "issued_at": timestamp(now),
            "keyring_generation": generation,
            "revoked_key_ids": revokedKeyIDs,
            "revoked_keyring_generations": revokedGenerations,
            "schema_version": "malibu-release-revocations.v1",
        ]
        return try MalibuReleaseTrustPolicy.parse(
            keyringData: try canonical(keyring),
            revocationsData: try canonical(revocations),
            minimumGeneration: max(minimumGeneration, generation),
            publicKeyLoader: { _ in Data(privateKey.publicKey.pemRepresentation.utf8) }
        )
    }

    func trustBundle() throws -> MalibuReleaseTrustBundle {
        let keyring: [String: Any] = [
            "generation": generation,
            "keys": [[
                "algorithm": "ecdsa-p256-sha256",
                "key_id": keyID,
                "public_key_path": "\(keyID).pem",
                "public_key_spki_sha256": SHA256.hash(data: privateKey.publicKey.derRepresentation).hexString,
                "status": "active",
            ]],
            "schema_version": "malibu-release-keyring.v1",
        ]
        let revocations: [String: Any] = [
            "generation": generation,
            "issued_at": timestamp(now),
            "keyring_generation": generation,
            "revoked_key_ids": [],
            "revoked_keyring_generations": [],
            "schema_version": "malibu-release-revocations.v1",
        ]
        return MalibuReleaseTrustBundle(
            keyringData: try canonical(keyring),
            revocationsData: try canonical(revocations),
            publicKeys: ["\(keyID).pem": Data(privateKey.publicKey.pemRepresentation.utf8)]
        )
    }

    func envelopePayload() -> [String: Any] {
        [
            "app": [
                "build": 41,
                "bundle_id": "tech.malibu.app",
                "designated_requirement": "identifier tech.malibu.app and certificate leaf[subject.OU] = YF7XNRJUG4",
                "entry_count": 1,
                "marketing_version": "1.8.41",
                "release_tag": "malibu-v1.8.41",
                "root_mode": 0o755,
                "source_commit": String(repeating: "1", count: 40),
                "team_id": "YF7XNRJUG4",
                "tree_sha256": String(repeating: "9", count: 64),
            ],
            "artifacts": [
                "bundled_provider_cli": ["sha256": String(repeating: "2", count: 64), "version": "1.8.40"],
                "dmg": ["name": "Malibu-v1.8.41.dmg", "sha256": String(repeating: "3", count: 64)],
            ],
            "envelope_generation": 41,
            "legacy_bootstrap": [
                "allowed_source_cohorts": [
                    [
                        "app_build": 39,
                        "app_entry_count": 38,
                        "app_root_mode": 0o755,
                        "app_tree_sha256": String(repeating: "4", count: 64),
                        "app_version": "1.8.39",
                        "cli_version": "1.8.30",
                    ],
                    [
                        "app_build": 39,
                        "app_entry_count": 38,
                        "app_root_mode": 0o755,
                        "app_tree_sha256": String(repeating: "4", count: 64),
                        "app_version": "1.8.39",
                        "cli_version": "1.8.32",
                    ],
                ],
                "backend_handoff_required": true,
                "caller_selected_target": false,
                "expires_at": timestamp(now.addingTimeInterval(86_400)),
                "no_downgrade": true,
                "target_cli_version": "1.8.40",
                "target_manifest_sha256": MalibuReleaseEnvelopeValidator.compatibilityManifestSHA256,
            ],
            "publication": ["published_at": timestamp(now)],
            "runtime_posture": ["hardened_runtime": true, "notarized": true, "stapled": true],
            "supported_provider": [
                "capabilities": [
                    "admission_recovery": ["v1"],
                    "control_socket": ["v1"],
                    "credential_handoff": ["v1"],
                    "local_status_reader": ["v1"],
                ],
                "compatibility_sets": [[
                    "id": MalibuReleaseEnvelopeValidator.compatibilitySetID,
                    "manifest_sha256": MalibuReleaseEnvelopeValidator.compatibilityManifestSHA256,
                    "provider_cli": [
                        "designated_identifier": "live.streamvc.macprovider.cli",
                        "team_id": "YF7XNRJUG4",
                        "version": "1.8.40",
                    ],
                ]],
                "provider_mutation": "forbidden",
            ],
        ]
    }

    func envelope() throws -> Data {
        try sign(schema: "malibu-release-envelope.v1", context: "malibu.release-envelope.v1", payload: envelopePayload())
    }

    func indexPayload(
        envelope: Data,
        issuedOffset: TimeInterval = 0,
        expiresOffset: TimeInterval = 604_800
    ) -> [String: Any] {
        [
            "channel": "stable",
            "envelope": [
                "build": 41,
                "generation": 41,
                "name": "malibu-release-envelope-v1.8.41.json",
                "sha256": SHA256.hash(data: envelope).hexString,
            ],
            "expires_at": timestamp(now.addingTimeInterval(expiresOffset)),
            "index_generation": 1,
            "issued_at": timestamp(now.addingTimeInterval(issuedOffset)),
            "minimum_accepted_envelope_generation": 41,
            "trust": [
                "keyring_generation": trust.generation,
                "keyring_sha256": trust.keyringSHA256,
                "revocations_generation": trust.revocationsGeneration,
                "revocations_sha256": trust.revocationsSHA256,
            ],
        ]
    }

    func index(envelope: Data) throws -> Data {
        try sign(
            schema: "malibu-release-index.v1",
            context: "malibu.release-index.v1",
            payload: indexPayload(envelope: envelope)
        )
    }

    func sign(schema: String, context: String, payload: [String: Any]) throws -> Data {
        let signedBytes = Data(context.utf8) + Data([0]) + (try canonical(payload))
        let signature = try privateKey.signature(for: signedBytes)
        let document: [String: Any] = [
            "schema_version": schema,
            "signature": [
                "algorithm": "ecdsa-p256-sha256",
                "key_id": keyID,
                "signature": signature.derRepresentation.base64URLEncodedString(),
            ],
            "signed": payload,
        ]
        return try canonical(document)
    }
}

private func canonical(_ value: Any) throws -> Data {
    try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(value))
}

private func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
