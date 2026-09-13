import Darwin
import Foundation
@testable import macprovider_cli
import XCTest

final class ModelPreparationPrivateStoreTests: XCTestCase {
    func testWritesAndReadsAllSevenPrivateStateKindsUnderStateDirectory() throws {
        let fixture = try StoreFixture.make("model-prep-store-all-kinds")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }

        for (offset, kind) in ModelPreparationPrivateStateEnvelopeKind.allCases.enumerated() {
            let payload = try StorePayloadFactory.payload(for: kind, root: boot.snapshot.rootLocator)
            try fixture.store.writeRecord(kind: kind, payload: payload, generation: offset + 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
            XCTAssertEqual(try fixture.store.readRecord(kind: kind, rootLocator: boot.snapshot.rootLocator), payload)
            let target = fixture.authority.appendingPathComponent("state", isDirectory: true).appendingPathComponent(ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind))
            try assertMode(target, type: S_IFREG, mode: 0o600, expectedLinkCount: 1)
            let durableData = try Data(contentsOf: target)
            XCTAssertNotEqual(durableData, payload)
            let envelope = try ModelPreparationContracts.decode(ModelPreparationPrivateStateEnvelope.self, from: durableData, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
            try envelope.validateDurableTargetLeaf(target.lastPathComponent)
            XCTAssertEqual(envelope.recordKind, kind)
            XCTAssertEqual(envelope.generation, offset + 1)
            XCTAssertEqual(envelope.payload, payload)
        }
    }

    func testWriteRequiresOpenMatchingLockCustodyAndMonotonicGeneration() throws {
        let fixture = try StoreFixture.make("model-prep-store-custody")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let payload = try StorePayloadFactory.inventoryPayload(root: boot.snapshot.rootLocator)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 0, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("generation must start at 1"), String(describing: error))
        }
        try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
        let target = fixture.authority.appendingPathComponent("state/published-inventory.json")
        let before = try Data(contentsOf: target)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("monotonic"), String(describing: error))
        }
        XCTAssertEqual(try Data(contentsOf: target), before)

        let other = try StoreFixture.make("model-prep-store-other")
        defer { try? FileManager.default.removeItem(at: other.root) }
        let otherBoot = try other.store.bootstrapWithLockCustody()
        defer { otherBoot.lockCustody.close() }
        XCTAssertThrowsError(try other.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 2, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("lock custody"), String(describing: error))
        }
        boot.lockCustody.close()
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 2, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("closed"), String(describing: error))
        }
    }

    func testReadAndWriteRejectRootDriftWithoutMutatingExistingFinal() throws {
        let fixture = try StoreFixture.make("model-prep-store-root-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let payload = try StorePayloadFactory.inventoryPayload(root: boot.snapshot.rootLocator)
        let drifted = try StorePayloadFactory.driftedRoot(from: boot.snapshot.rootLocator)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 1, rootLocator: drifted, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("root locator mismatch"), String(describing: error))
        }
        try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
        XCTAssertThrowsError(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: drifted)) { error in
            XCTAssert(String(describing: error).contains("root locator mismatch"), String(describing: error))
        }
    }

    func testReadDoesNotCreateMissingRoots() throws {
        let root = try temporaryDirectory("model-prep-store-read-no-create")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifact", isDirectory: true)
        let locator = try ModelPreparationRootLocator(
            canonicalPath: artifact.path,
            stDev: 1,
            stIno: 2,
            identityVersion: "model_catalog_root_identity.v1",
            rootIdentityDigest: String(repeating: "a", count: 64)
        )
        let store = ModelPreparationPrivateStore(authorityRoot: authority, artifactRoot: artifact)
        XCTAssertThrowsError(try store.readRecord(kind: .publishedInventory, rootLocator: locator))
        XCTAssertFalse(FileManager.default.fileExists(atPath: authority.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    }

    func testRecoveryOnlyRemovesSafeStaleAndEmptySameParentTemps() throws {
        let fixture = try StoreFixture.make("model-prep-store-recover")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let state = fixture.authority.appendingPathComponent("state", isDirectory: true)
        let payload = try StorePayloadFactory.inventoryPayload(root: boot.snapshot.rootLocator)
        try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 5, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
        let stale = try writeTemp(kind: .publishedInventory, payload: payload, generation: 3, writer: "33333333-3333-4333-8333-333333333333", in: state)
        let empty = state.appendingPathComponent("active.json.44444444-4444-4444-8444-444444444444.tmp")
        FileManager.default.createFile(atPath: empty.path, contents: Data(), attributes: [.posixPermissions: 0o600])

        let report = try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
        XCTAssertEqual(report.completed, [])
        XCTAssertEqual(report.removed.sorted(), [empty.lastPathComponent, stale.lastPathComponent].sorted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: boot.snapshot.rootLocator), payload)
    }

    func testRecoveryFailsClosedWithoutMutationForUnknownLegacyHostileAndOverBudgetTemps() throws {
        let fixture = try StoreFixture.make("model-prep-store-hostile-recover")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let state = fixture.authority.appendingPathComponent("state", isDirectory: true)
        let payload = try StorePayloadFactory.inventoryPayload(root: boot.snapshot.rootLocator)
        let empty = state.appendingPathComponent("published-inventory.json.55555555-5555-4555-8555-555555555555.tmp")
        FileManager.default.createFile(atPath: empty.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let unknown = state.appendingPathComponent("notes.tmp")
        try Data().write(to: unknown)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknown.path)
        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody))
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        try FileManager.default.removeItem(at: unknown)

        let fifo = state.appendingPathComponent("published-inventory.json.66666666-6666-4666-8666-666666666666.tmp")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody))
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
        try FileManager.default.removeItem(at: fifo)

        let legacy = fixture.authority.appendingPathComponent("state-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("legacy state temp"), String(describing: error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        try FileManager.default.removeItem(at: legacy)

        for index in 0 ..< 17 {
            let leaf = String(format: "active.json.77777777-7777-4777-8777-%012d.tmp", index)
            FileManager.default.createFile(atPath: state.appendingPathComponent(leaf).path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("exceed 16"), String(describing: error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        _ = payload
    }

    func testRecoverDoesNotCreateMissingRootsOrStateBeforeCustodyValidation() throws {
        let owner = try StoreFixture.make("model-prep-store-recover-owner")
        defer { try? FileManager.default.removeItem(at: owner.root) }
        let boot = try owner.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }

        let missing = try temporaryDirectory("model-prep-store-recover-missing")
        defer { try? FileManager.default.removeItem(at: missing) }
        let authority = missing.appendingPathComponent("authority", isDirectory: true)
        let artifact = missing.appendingPathComponent("artifact", isDirectory: true)
        let store = ModelPreparationPrivateStore(authorityRoot: authority, artifactRoot: artifact)
        XCTAssertThrowsError(try store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody))
        XCTAssertFalse(FileManager.default.fileExists(atPath: authority.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))

        let other = try StoreFixture.make("model-prep-store-recover-other")
        defer { try? FileManager.default.removeItem(at: other.root) }
        let otherBoot = try other.store.bootstrapWithLockCustody()
        defer { otherBoot.lockCustody.close() }
        let sentinel = other.root.appendingPathComponent("sentinel")
        try Data("outside".utf8).write(to: sentinel)
        XCTAssertThrowsError(try other.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("lock custody"), String(describing: error))
        }
        XCTAssertEqual(try String(contentsOf: sentinel), "outside")
    }

    func testHostileDurableStateFilesAreRejectedAndPreserved() throws {
        let fixture = try StoreFixture.make("model-prep-store-hostile-durable")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let state = fixture.authority.appendingPathComponent("state", isDirectory: true)
        let target = state.appendingPathComponent("published-inventory.json")
        let payload = try StorePayloadFactory.inventoryPayload(root: boot.snapshot.rootLocator)

        try Data("raw-state".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody))
        XCTAssertEqual(try Data(contentsOf: target), Data("raw-state".utf8))
        try FileManager.default.removeItem(at: target)

        let activeEnvelope = try ModelPreparationPrivateStateEnvelope(
            recordKind: .active,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .active),
            writerUUID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            generation: 1,
            payload: try StorePayloadFactory.payload(for: .active, root: boot.snapshot.rootLocator)
        )
        let activeData = try ModelPreparationContracts.encode(activeEnvelope, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
        try activeData.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        XCTAssertThrowsError(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: boot.snapshot.rootLocator)) { error in
            XCTAssert(String(describing: error).contains("wrong envelope kind"), String(describing: error))
        }
        XCTAssertEqual(try Data(contentsOf: target), activeData)
        try FileManager.default.removeItem(at: target)

        let goodEnvelope = try ModelPreparationPrivateStateEnvelope(
            recordKind: .publishedInventory,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .publishedInventory),
            writerUUID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            generation: 1,
            payload: payload
        )
        var object = try JSONSerialization.jsonObject(with: ModelPreparationContracts.encode(goodEnvelope, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)) as! [String: Any]
        object["payload_sha256"] = String(repeating: "0", count: 64)
        let corrupted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try corrupted.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        XCTAssertThrowsError(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: boot.snapshot.rootLocator))
        XCTAssertEqual(try Data(contentsOf: target), corrupted)
        try FileManager.default.removeItem(at: target)

        let outside = fixture.root.appendingPathComponent("outside-sentinel")
        try Data("sentinel".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: target)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("hard link"), String(describing: error))
        }
        XCTAssertEqual(try String(contentsOf: outside), "sentinel")
    }

    func testRootIdentityDriftRejectsReadBeforeTrustingStatePayload() throws {
        let fixture = try StoreFixture.make("model-prep-store-root-identity-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let payload = try StorePayloadFactory.inventoryPayload(root: boot.snapshot.rootLocator)
        try fixture.store.writeRecord(kind: .publishedInventory, payload: payload, generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
        let identityURL = fixture.artifact.appendingPathComponent(".macprovider-prepared-v3/root.identity")
        let drifted = try ModelPreparationRootIdentityRecord(
            version: "model_catalog_root_identity.v1",
            nonceHex: String(repeating: "2", count: 64),
            canonicalPath: boot.snapshot.rootLocator.canonicalPath,
            stDev: boot.snapshot.rootLocator.stDev,
            stIno: boot.snapshot.rootLocator.stIno
        )
        let driftedBytes = try ModelPreparationContracts.encode(drifted, maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes)
        try driftedBytes.write(to: identityURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
        XCTAssertThrowsError(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: boot.snapshot.rootLocator)) { error in
            XCTAssert(String(describing: error).contains("root locator mismatch"), String(describing: error))
        }
        XCTAssertEqual(try Data(contentsOf: identityURL), driftedBytes)
    }


    func testCloseDuringWriteKeepsLocksUntilOperationFinishes() throws {
        let root = try temporaryDirectory("model-prep-store-close-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let random = BlockingUUIDModelPreparationRandomSource()
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifact", isDirectory: true)
        let store = ModelPreparationPrivateStore(authorityRoot: authority, artifactRoot: artifact, randomSource: random)
        let boot = try store.bootstrapWithLockCustody()
        let payload = try StorePayloadFactory.inventoryPayload(root: boot.snapshot.rootLocator)
        let resultLock = NSLock()
        var writeResult: Result<Void, Error>?
        let writeDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let result = Result {
                try store.writeRecord(
                    kind: .publishedInventory,
                    payload: payload,
                    generation: 1,
                    rootLocator: boot.snapshot.rootLocator,
                    lockCustody: boot.lockCustody
                )
            }
            resultLock.lock()
            writeResult = result
            resultLock.unlock()
            writeDone.signal()
        }

        XCTAssertEqual(random.waitUntilUUIDRequested(), .success)
        boot.lockCustody.close()
        XCTAssertThrowsError(try store.acquireLockCustody()) { error in
            XCTAssert(String(describing: error).contains("lock already held"), String(describing: error))
        }

        random.releaseUUID()
        XCTAssertEqual(writeDone.wait(timeout: .now() + 5), .success)
        resultLock.lock()
        let completed = writeResult
        resultLock.unlock()
        XCTAssertNoThrow(try completed?.get())
        let next = try store.acquireLockCustody()
        next.close()
    }

    @discardableResult
    private func writeTemp(kind: ModelPreparationPrivateStateEnvelopeKind, payload: Data, generation: Int, writer: String, in directory: URL) throws -> URL {
        let envelope = try ModelPreparationPrivateStateEnvelope(recordKind: kind, targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind), writerUUID: writer, generation: generation, payload: payload)
        let url = directory.appendingPathComponent(try envelope.expectedFilename())
        try ModelPreparationContracts.encode(envelope, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

final class BlockingUUIDModelPreparationRandomSource: @unchecked Sendable, ModelPreparationRandomSource {
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func randomBytes(count: Int) throws -> Data {
        Data(repeating: 0x33, count: count)
    }

    func uuidString() throws -> String {
        entered.signal()
        _ = proceed.wait(timeout: .now() + 5)
        return "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }

    func waitUntilUUIDRequested() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 5)
    }

    func releaseUUID() {
        proceed.signal()
    }
}

struct StoreFixture {
    let root: URL
    let authority: URL
    let artifact: URL
    let store: ModelPreparationPrivateStore

    static func make(_ name: String) throws -> StoreFixture {
        let root = try temporaryDirectory(name)
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifact", isDirectory: true)
        let random = DeterministicModelPreparationRandomSource(uuids: [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444",
            "55555555-5555-4555-8555-555555555555",
            "66666666-6666-4666-8666-666666666666",
            "77777777-7777-4777-8777-777777777777",
            "88888888-8888-4888-8888-888888888888",
            "99999999-9999-4999-8999-999999999999",
        ])
        return StoreFixture(root: root, authority: authority, artifact: artifact, store: ModelPreparationPrivateStore(authorityRoot: authority, artifactRoot: artifact, randomSource: random))
    }
}

final class DeterministicModelPreparationRandomSource: @unchecked Sendable, ModelPreparationRandomSource {
    private let nonce: Data
    private let lock = NSLock()
    private var uuids: [String]

    init(nonce: Data = Data(repeating: 0x11, count: 32), uuids: [String] = ["11111111-1111-4111-8111-111111111111"]) {
        self.nonce = nonce
        self.uuids = uuids
    }

    func randomBytes(count: Int) throws -> Data { Data(nonce.prefix(count)) }

    func uuidString() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if uuids.isEmpty { return UUID().uuidString.lowercased() }
        return uuids.removeFirst()
    }
}

struct StorePayloadFactory {
    private static let transactionID = "00000000-0000-4000-8000-000000000001"
    private static let attemptID = "11111111-1111-4111-8111-111111111111"
    private static let sourceTransactionID = "22222222-2222-4222-8222-222222222222"
    private static let sourceAttemptID = "33333333-3333-4333-8333-333333333333"
    private static let terminalTransactionID = "66666666-6666-4666-8666-666666666666"
    private static let terminalAttemptID = "77777777-7777-4777-8777-777777777777"
    private static let timestamp = "2026-09-12T00:00:00.000Z"
    private static let secondTimestamp = "2026-09-12T00:00:00Z"
    private static let hexA = String(repeating: "a", count: 64)
    private static let hexB = String(repeating: "b", count: 64)

    static func payload(for kind: ModelPreparationPrivateStateEnvelopeKind, root: ModelPreparationRootLocator) throws -> Data {
        switch kind {
        case .reservations: return try reservationsPayload(root: root)
        case .active: return try activePayload(root: root)
        case .cancel: return try cancelMarkerPayload(root: root)
        case .publishedInventory: return try inventoryPayload(root: root)
        case .deletion: return try deletionPayload(root: root)
        case .stagingSources: return try stagingSourcesPayload(root: root)
        case .failedDispatchPending: return try failedDispatchPayload(root: root)
        }
    }

    static func driftedRoot(from root: ModelPreparationRootLocator) throws -> ModelPreparationRootLocator {
        try ModelPreparationRootLocator(canonicalPath: root.canonicalPath, stDev: root.stDev, stIno: root.stIno, identityVersion: root.identityVersion, rootIdentityDigest: String(repeating: "0", count: 64))
    }

    static func inventoryPayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(try ModelPreparationInventoryRecord(root: root, targets: [], generatedAt: timestamp), maxBytes: ModelPreparationContracts.inventoryMaxBytes)
    }

    private static func tuple(root: ModelPreparationRootLocator) throws -> ModelPreparationTupleRecord {
        try ModelPreparationTupleRecord(tupleID: "tuple-1", eventModelKey: "catalog/model", displayModelID: "display", modelRevision: "rev", artifactID: "artifact", releaseID: "release", artifactSHA256: hexB, estimatedBytes: 4096, root: root, authorityOrder: 0)
    }

    private static func tupleDigest(root: ModelPreparationRootLocator) throws -> String {
        try ModelPreparationContracts.tupleSHA256(tuple(root: root))
    }

    private static func failedDispatch(root: ModelPreparationRootLocator) throws -> ModelPreparationFailedDispatchRecord {
        try ModelPreparationFailedDispatchRecord(transactionID: transactionID, attemptID: attemptID, transactionKind: .prepareModel, eventModelKey: "catalog/model", root: root, tupleSHA256: try tupleDigest(root: root), projectionBindingSHA256: hexB, errorCode: .operationConflict)
    }

    private static func cancelMarker(root: ModelPreparationRootLocator) throws -> ModelPreparationCancelMarker {
        let tuple = try tuple(root: root)
        return try ModelPreparationCancelMarker(transactionID: transactionID, attemptID: attemptID, transactionKind: .prepareModel, eventModelKey: tuple.eventModelKey, root: tuple.root, tupleSHA256: try tupleDigest(root: root), projectionBindingSHA256: hexB, recordedAt: secondTimestamp)
    }

    private static func activeRecord(root: ModelPreparationRootLocator) throws -> ModelPreparationActiveRecord {
        let tuple = try tuple(root: root)
        return try ModelPreparationActiveRecord(transactionID: transactionID, attemptID: attemptID, transactionKind: .prepareModel, eventModelKey: tuple.eventModelKey, root: tuple.root, tuple: tuple, tupleSHA256: try tupleDigest(root: root), projectionBindingSHA256: hexB, nextEventSequence: 2, phase: .transferring, counters: try ModelPreparationActiveCounters(bytesCompleted: 1, bytesExpected: 4096, filesCompleted: 0, filesExpected: 1), recordedLeaves: [hexA], barrierProgress: ModelPreparationBarrierProgress(objectParentSynced: false, objectParentFullSynced: false, phaseRecordSynced: false, phaseRecordReadBack: false), terminalResult: nil, cancellationRequested: false)
    }

    private static func receipt(root: ModelPreparationRootLocator) throws -> ModelPreparationPublicationReceipt {
        let tuple = try tuple(root: root)
        return try ModelPreparationPublicationReceipt(eventModelKey: tuple.eventModelKey, root: root, tuple: tuple, tupleSHA256: try tupleDigest(root: root), publishedAt: timestamp)
    }

    private static func receiptDigest(root: ModelPreparationRootLocator) throws -> String {
        try ModelPreparationContracts.receiptSHA256(receipt(root: root))
    }

    private static func artifactDigest(root: ModelPreparationRootLocator) throws -> String {
        let tuple = try tuple(root: root)
        return try ModelPreparationContracts.artifactIdentityDigest(displayModelID: tuple.displayModelID, modelRevision: tuple.modelRevision, artifactID: tuple.artifactID, releaseID: tuple.releaseID, rootIdentityDigest: root.rootIdentityDigest, receiptSHA256: try receiptDigest(root: root))
    }

    private static func cleanupRecord(root: ModelPreparationRootLocator) throws -> ModelPreparationCleanupRecord {
        let tuple = try tuple(root: root)
        let receipt = try receipt(root: root)
        let receiptSHA = try ModelPreparationContracts.receiptSHA256(receipt)
        let artifactSHA = try artifactDigest(root: root)
        return try ModelPreparationCleanupRecord(targetKind: .published, phase: .intent, transactionID: transactionID, attemptID: attemptID, eventModelKey: tuple.eventModelKey, root: root, tuple: tuple, tupleSHA256: try tupleDigest(root: root), finalLeaf: "objects/\(artifactSHA)", tombstoneLeaf: "objects/.tombstone-\(transactionID)", expectedBytes: 4096, expectedFiles: 1, receipt: receipt, receiptSHA256: receiptSHA, artifactIdentityDigest: artifactSHA)
    }

    private static func cleanupStagingReservation(root: ModelPreparationRootLocator) throws -> ModelPreparationReservationRecord {
        let tuple = try tuple(root: root)
        return try ModelPreparationReservationRecord(transactionID: transactionID, transactionKind: .cleanupStaging, eventModelKey: tuple.eventModelKey, root: root, tuple: tuple, tupleSHA256: try tupleDigest(root: root), projectionBindingSHA256: hexB, createdAt: timestamp, sourceTransactionID: sourceTransactionID, sourceAttemptID: sourceAttemptID, sourceRecordSHA256: hexA)
    }

    private static func terminalHistoryEntry(root: ModelPreparationRootLocator) throws -> ModelPreparationReservationsTerminalHistoryEntry {
        .ordinary(try ModelPreparationTerminalHistoryRecord(transactionID: terminalTransactionID, attemptID: terminalAttemptID, transactionKind: .prepareModel, eventModelKey: "catalog/model", root: root, tupleSHA256: try tupleDigest(root: root), projectionBindingSHA256: hexB, eventSequence: 1, terminalState: .failed, errorCode: .operationConflict, completedAt: timestamp))
    }

    private static func failedDispatchHistoryEntry(root: ModelPreparationRootLocator) throws -> ModelPreparationReservationsTerminalHistoryEntry {
        .failedDispatch(try ModelPreparationFailedDispatchRecord(transactionID: "44444444-4444-4444-8444-444444444444", attemptID: "55555555-5555-4555-8555-555555555555", transactionKind: .prepareModel, eventModelKey: "catalog/model", root: root, tupleSHA256: try tupleDigest(root: root), projectionBindingSHA256: hexB, errorCode: .operationConflict))
    }

    private static func reservationsPayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(try ModelPreparationReservationsHistoryRecord(projectedReservations: [cleanupStagingReservation(root: root)], terminalHistory: [try terminalHistoryEntry(root: root), try failedDispatchHistoryEntry(root: root)]), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes)
    }

    private static func activePayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(activeRecord(root: root), maxBytes: ModelPreparationContracts.activeRecordMaxBytes)
    }

    private static func cancelMarkerPayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(cancelMarker(root: root), maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes)
    }

    private static func deletionPayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(cleanupRecord(root: root), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes)
    }

    private static func stagingSourcesPayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(try ModelPreparationStagingSourcesRecord(entries: [ModelPreparationStagingSourceEntry(sourceTransactionID: sourceTransactionID, sourceAttemptID: sourceAttemptID, root: root, sourceRecordSHA256: hexA)]), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes)
    }

    private static func failedDispatchPayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(failedDispatch(root: root), maxBytes: ModelPreparationContracts.failedDispatchMaxBytes)
    }
}

func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

func assertMode(_ url: URL, type: mode_t, mode: mode_t, expectedLinkCount: nlink_t? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0, file: file, line: line)
    XCTAssertEqual(info.st_mode & S_IFMT, type, file: file, line: line)
    XCTAssertEqual(info.st_mode & 0o777, mode, file: file, line: line)
    if let expectedLinkCount { XCTAssertEqual(info.st_nlink, expectedLinkCount, file: file, line: line) }
}

func assertNoExtendedACL(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(fd, 0, file: file, line: line)
    defer { close(fd) }
    errno = 0
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
        XCTAssertTrue(errno == 0 || errno == ENOENT, file: file, line: line)
        return
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    XCTAssertEqual(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), 0, file: file, line: line)
    XCTAssertNil(entry, file: file, line: line)
}

func addReadACLEntry(to url: URL) throws {
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/bin/chmod")
    command.arguments = ["+a", "\(NSUserName()) allow read", url.path]
    try command.run()
    command.waitUntilExit()
    XCTAssertEqual(command.terminationStatus, 0)
}
