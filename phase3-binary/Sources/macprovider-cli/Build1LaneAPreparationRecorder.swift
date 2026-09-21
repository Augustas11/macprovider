import Darwin
import Foundation

/// Private preparation-state evidence returned for the adopted Build 1 Lane A
/// artifact. Digests only: nothing here carries a path, nonce, or feed body.
///
/// The persisted inventory and receipt are owner-only `0600` private records
/// and, as SPEC-044 requires of every reopening lifecycle record and
/// managed-object receipt, carry the saved root locator (canonical path,
/// device, inode, identity version, digest). They never carry the root nonce,
/// and nothing from them reaches public JSON except digests.
struct Build1LaneAPreparationRecord: Equatable, Sendable {
    var artifactIdentityDigest: String
    var receiptSHA256: String
    var rootIdentityDigest: String
    var inventoryGeneration: Int
    /// `true` when the published inventory already carried this exact tuple
    /// and its receipt re-verified; nothing was written.
    var reusedExistingRecord: Bool
}

enum Build1LaneAPreparationRecordError: Error, Equatable, Sendable {
    /// The private state authority could not be bootstrapped or read.
    case stateUnavailable(String)
    /// Another process holds the private-state locks.
    case stateLocked
    /// The existing published inventory or a referenced receipt is invalid.
    case inventoryInvalid(String)
    /// The durable artifact the record would describe is absent, escapes the
    /// bound root, or its bytes do not hash to the signed authority digest.
    case adoptedArtifactMismatch
    /// The receipt or inventory could not be durably written.
    case writeFailed(String)
}

/// Records the adopted Lane A artifact in the existing private
/// preparation-state store (`ModelPreparationPrivateStore`), using the
/// `published_inventory` envelope contract and a `model_catalog_publication_receipt.v1`
/// under the managed-v3 namespace. Build 1 Lane A only.
///
/// The record is private evidence for `models catalog-economics` v2
/// projection and the later `serve`/status evidence binding. It grants no
/// admission, settlement, earnings, rewards, payouts, or production
/// activation, and it never changes the active model.
struct Build1LaneAPreparationRecorder: Sendable {
    /// Lock and state authority for the private store, hidden inside the
    /// durable root next to the Lane A prepare lock so the state follows the
    /// bound `model_artifact_root`. Hidden entries are skipped by the durable
    /// store's inactive-artifact GC.
    static let authorityLeaf = ".macprovider-preparation-state-v3"
    static let receiptLeaf = "receipt.json"
    /// No `cleanup_published_artifact` transaction has landed, so the entry is
    /// projected as protected rather than advertising a cleanup it cannot run.
    static let protectedReason = "cleanup_transaction_unavailable"
    static let tupleIDPrefix = Build1LaneAPrepareProfile.profile

    let durableRoot: URL
    let store: ModelPreparationPrivateStore
    let now: @Sendable () -> Date

    init(
        durableRoot: URL,
        randomSource: ModelPreparationRandomSource = ModelPreparationSystemRandomSource(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let root = durableRoot.standardizedFileURL
        self.durableRoot = root
        self.store = ModelPreparationPrivateStore(
            authorityRoot: root.appendingPathComponent(Self.authorityLeaf, isDirectory: true),
            artifactRoot: root,
            randomSource: randomSource
        )
        self.now = now
    }

    /// Bootstraps the private state authority, takes its locks, recovers
    /// stale state temps, and validates any existing published inventory
    /// including every target's persisted receipt. Everything that can refuse
    /// does so here, before any transfer.
    func open() throws -> Session {
        let boot: (snapshot: ModelPreparationPrivateStore.BootstrapSnapshot, lockCustody: ModelPreparationPrivateStore.LockCustody)
        do {
            boot = try store.bootstrapWithLockCustody()
        } catch let error as ModelPreparationSecureFilesystemError {
            if case .unsafe(_, let reason) = error, reason == "lock already held" {
                throw Build1LaneAPreparationRecordError.stateLocked
            }
            throw Build1LaneAPreparationRecordError.stateUnavailable(String(describing: error))
        } catch {
            throw Build1LaneAPreparationRecordError.stateUnavailable(String(describing: error))
        }
        var keepCustody = false
        defer { if !keepCustody { boot.lockCustody.close() } }
        let locator = boot.snapshot.rootLocator
        do {
            try store.recoverStateTemps(rootLocator: locator, lockCustody: boot.lockCustody)
        } catch {
            throw Build1LaneAPreparationRecordError.stateUnavailable(String(describing: error))
        }
        let existing: Session.ExistingInventory?
        do {
            if let current = try store.readRecordWithGeneration(kind: .publishedInventory, rootLocator: locator) {
                let record = try ModelPreparationContracts.decode(
                    ModelPreparationInventoryRecord.self,
                    from: current.payload,
                    maxBytes: ModelPreparationContracts.inventoryMaxBytes
                )
                guard record.root == locator else {
                    throw Build1LaneAPreparationRecordError.inventoryInvalid("root locator mismatch")
                }
                var receipts: [String: ModelPreparationPublicationReceipt] = [:]
                for target in record.targets {
                    receipts[target.artifactIdentityDigest] = try Session.validatedReceipt(
                        for: target,
                        rootLocator: locator,
                        store: store
                    )
                }
                existing = Session.ExistingInventory(record: record, generation: current.generation, receipts: receipts)
            } else {
                existing = nil
            }
        } catch let error as Build1LaneAPreparationRecordError {
            throw error
        } catch {
            throw Build1LaneAPreparationRecordError.inventoryInvalid(String(describing: error))
        }
        keepCustody = true
        return Session(recorder: self, lockCustody: boot.lockCustody, rootLocator: locator, existing: existing)
    }

    /// Open private-state custody for one prepare run. `record` is called at
    /// most once, after durable adoption; `close` releases the locks.
    final class Session: @unchecked Sendable {
        struct ExistingInventory {
            let record: ModelPreparationInventoryRecord
            let generation: Int
            /// Receipts validated at `open()` time, keyed by artifact identity digest.
            let receipts: [String: ModelPreparationPublicationReceipt]
        }

        private let recorder: Build1LaneAPreparationRecorder
        private let lockCustody: ModelPreparationPrivateStore.LockCustody
        let rootLocator: ModelPreparationRootLocator
        private let existing: ExistingInventory?

        fileprivate init(
            recorder: Build1LaneAPreparationRecorder,
            lockCustody: ModelPreparationPrivateStore.LockCustody,
            rootLocator: ModelPreparationRootLocator,
            existing: ExistingInventory?
        ) {
            self.recorder = recorder
            self.lockCustody = lockCustody
            self.rootLocator = rootLocator
            self.existing = existing
        }

        func close() {
            lockCustody.close()
        }

        deinit { close() }

        /// Writes (or re-verifies) the published-inventory entry for the exact
        /// adopted Lane A tuple. Refuses unless the durable artifact directory
        /// for that tuple exists inside the bound root and its bytes hash to
        /// the signed authority digest at record time.
        func record(
            authority: Build1LaneAArtifactAuthority,
            adoptedSHA256: String,
            adoptedBytes: Int64
        ) throws -> Build1LaneAPreparationRecord {
            guard adoptedSHA256 == authority.hash, adoptedBytes >= 0 else {
                throw Build1LaneAPreparationRecordError.adoptedArtifactMismatch
            }
            let durableStore = DurableModelArtifactStore(root: recorder.durableRoot)
            guard let durable = try? durableStore.artifactURL(
                modelID: authority.modelID,
                revision: authority.revision,
                sha256: authority.hash
            ), durableStore.contains(durable.path), Self.isDirectory(durable) else {
                throw Build1LaneAPreparationRecordError.adoptedArtifactMismatch
            }
            // The record is evidence about bytes on disk, so it binds to the
            // durable bytes as they are now, not to the caller's claim.
            guard let actual = try? ModelArtifactVerifier.canonicalArtifactHash(directory: durable),
                  actual == authority.hash
            else {
                throw Build1LaneAPreparationRecordError.adoptedArtifactMismatch
            }

            if let existing, let match = existing.record.targets.first(where: { Self.describes($0, authority: authority) }) {
                // Receipt binding was validated at open(); reuse additionally
                // requires the recorded Lane A identity, feed size, and measured
                // bytes to equal what this run adopted.
                guard let receipt = existing.receipts[match.artifactIdentityDigest],
                      match.modelKey == authority.catalogKey,
                      match.eventModelKey == authority.catalogKey,
                      match.estimatedBytes == adoptedBytes,
                      receipt.tuple.artifactSHA256 == authority.hash,
                      receipt.tuple.estimatedBytes == Int64(authority.sizeBytes)
                else {
                    throw Build1LaneAPreparationRecordError.inventoryInvalid("recorded tuple does not match the adopted Lane A authority")
                }
                return Build1LaneAPreparationRecord(
                    artifactIdentityDigest: match.artifactIdentityDigest,
                    receiptSHA256: match.receiptSHA256,
                    rootIdentityDigest: rootLocator.rootIdentityDigest,
                    inventoryGeneration: existing.generation,
                    reusedExistingRecord: true
                )
            }

            let timestamp = ModelSwitchingWireCodec.timestamp(recorder.now())
            let tuple: ModelPreparationTupleRecord
            let receipt: ModelPreparationPublicationReceipt
            let receiptBytes: Data
            let receiptSHA256: String
            let artifactIdentityDigest: String
            let target: ModelPreparationCleanupTarget
            let inventory: ModelPreparationInventoryRecord
            let payload: Data
            do {
                tuple = try ModelPreparationTupleRecord(
                    tupleID: "\(Build1LaneAPreparationRecorder.tupleIDPrefix):\(authority.catalogKey):\(authority.artifactID)@\(authority.revision)",
                    eventModelKey: authority.catalogKey,
                    displayModelID: authority.modelID,
                    modelRevision: authority.revision,
                    artifactID: authority.artifactID,
                    releaseID: authority.releaseID,
                    artifactSHA256: authority.hash,
                    estimatedBytes: Int64(authority.sizeBytes),
                    root: rootLocator,
                    authorityOrder: 0
                )
                receipt = try ModelPreparationPublicationReceipt(
                    eventModelKey: authority.catalogKey,
                    root: rootLocator,
                    tuple: tuple,
                    tupleSHA256: try ModelPreparationContracts.tupleSHA256(tuple),
                    publishedAt: timestamp
                )
                receiptBytes = try ModelPreparationContracts.encode(receipt, maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes)
                receiptSHA256 = try ModelPreparationContracts.publicationReceiptSHA256(from: receiptBytes)
                artifactIdentityDigest = try ModelPreparationContracts.artifactIdentityDigest(
                    displayModelID: authority.modelID,
                    modelRevision: authority.revision,
                    artifactID: authority.artifactID,
                    releaseID: authority.releaseID,
                    rootIdentityDigest: rootLocator.rootIdentityDigest,
                    receiptSHA256: receiptSHA256
                )
                target = try ModelPreparationCleanupTarget(
                    artifactIdentityDigest: artifactIdentityDigest,
                    displayModelID: authority.modelID,
                    modelRevision: authority.revision,
                    artifactID: authority.artifactID,
                    releaseID: authority.releaseID,
                    modelKey: authority.catalogKey,
                    eventModelKey: authority.catalogKey,
                    rootIdentityDigest: rootLocator.rootIdentityDigest,
                    receiptSHA256: receiptSHA256,
                    estimatedBytes: adoptedBytes,
                    keepSetStatus: .protected,
                    protectedReason: Build1LaneAPreparationRecorder.protectedReason,
                    cleanup: try ModelPreparationAction(
                        available: false,
                        requiresConfirmation: false,
                        transactionKind: nil,
                        transactionID: nil,
                        actionTimeoutSeconds: nil,
                        estimatedBytes: nil,
                        unavailableReason: Build1LaneAPreparationRecorder.protectedReason,
                        artifactIdentityDigest: nil
                    )
                )
                var targets = existing?.record.targets ?? []
                targets.append(target)
                targets.sort { $0.artifactIdentityDigest < $1.artifactIdentityDigest }
                inventory = try ModelPreparationInventoryRecord(root: rootLocator, targets: targets, generatedAt: timestamp)
                payload = try ModelPreparationContracts.encode(inventory, maxBytes: ModelPreparationContracts.inventoryMaxBytes)
            } catch {
                throw Build1LaneAPreparationRecordError.inventoryInvalid(String(describing: error))
            }

            let generation = (existing?.generation ?? 0) + 1
            do {
                try writeReceipt(receiptBytes, artifactIdentityDigest: artifactIdentityDigest)
            } catch {
                throw Build1LaneAPreparationRecordError.writeFailed(String(describing: error))
            }
            do {
                try recorder.store.writeRecord(
                    kind: .publishedInventory,
                    payload: payload,
                    generation: generation,
                    rootLocator: rootLocator,
                    lockCustody: lockCustody
                )
            } catch {
                removeReceiptBestEffort(artifactIdentityDigest: artifactIdentityDigest)
                throw Build1LaneAPreparationRecordError.writeFailed(String(describing: error))
            }
            return Build1LaneAPreparationRecord(
                artifactIdentityDigest: artifactIdentityDigest,
                receiptSHA256: receiptSHA256,
                rootIdentityDigest: rootLocator.rootIdentityDigest,
                inventoryGeneration: generation,
                reusedExistingRecord: false
            )
        }

        private static func describes(_ target: ModelPreparationCleanupTarget, authority: Build1LaneAArtifactAuthority) -> Bool {
            target.displayModelID == authority.modelID
                && target.modelRevision == authority.revision
                && target.artifactID == authority.artifactID
                && target.releaseID == authority.releaseID
        }

        /// Loads the persisted receipt for one inventory target and proves it
        /// binds that target: receipt digest, root locator, immutable event
        /// key, tuple identity, and the recomputed artifact identity digest.
        fileprivate static func validatedReceipt(
            for target: ModelPreparationCleanupTarget,
            rootLocator: ModelPreparationRootLocator,
            store: ModelPreparationPrivateStore
        ) throws -> ModelPreparationPublicationReceipt {
            guard target.rootIdentityDigest == rootLocator.rootIdentityDigest else {
                throw Build1LaneAPreparationRecordError.inventoryInvalid("target root identity mismatch")
            }
            let receipt = try loadReceipt(artifactIdentityDigest: target.artifactIdentityDigest, artifactRoot: store.artifactRoot)
            let recomputed = try ModelPreparationContracts.artifactIdentityDigest(
                displayModelID: target.displayModelID,
                modelRevision: target.modelRevision,
                artifactID: target.artifactID,
                releaseID: target.releaseID,
                rootIdentityDigest: rootLocator.rootIdentityDigest,
                receiptSHA256: receipt.sha256
            )
            guard receipt.sha256 == target.receiptSHA256,
                  recomputed == target.artifactIdentityDigest,
                  receipt.record.root == rootLocator,
                  receipt.record.tuple.root == rootLocator,
                  receipt.record.eventModelKey == target.eventModelKey,
                  receipt.record.tuple.eventModelKey == target.eventModelKey,
                  receipt.record.tuple.displayModelID == target.displayModelID,
                  receipt.record.tuple.modelRevision == target.modelRevision,
                  receipt.record.tuple.artifactID == target.artifactID,
                  receipt.record.tuple.releaseID == target.releaseID
            else {
                throw Build1LaneAPreparationRecordError.inventoryInvalid("receipt does not bind the recorded target")
            }
            return receipt.record
        }

        private static func isDirectory(_ url: URL) -> Bool {
            var st = stat()
            return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }

        // MARK: - Receipt persistence under objects/<artifact_identity_digest>/

        private func openObjects() throws -> (root: ModelPreparationSecureFilesystem.Directory, namespace: ModelPreparationSecureFilesystem.Directory, objects: ModelPreparationSecureFilesystem.Directory) {
            try Self.openObjects(artifactRoot: recorder.store.artifactRoot)
        }

        private static func openObjects(artifactRoot: URL) throws -> (root: ModelPreparationSecureFilesystem.Directory, namespace: ModelPreparationSecureFilesystem.Directory, objects: ModelPreparationSecureFilesystem.Directory) {
            let root = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: artifactRoot)
            do {
                let namespace = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
                    parent: root,
                    name: ModelPreparationSecureFilesystem.namespaceLeaf,
                    create: false
                )
                do {
                    let objects = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
                        parent: namespace,
                        name: ModelPreparationSecureFilesystem.objectsLeaf,
                        create: false
                    )
                    return (root, namespace, objects)
                } catch {
                    namespace.close()
                    throw error
                }
            } catch {
                root.close()
                throw error
            }
        }

        private func writeReceipt(_ bytes: Data, artifactIdentityDigest: String) throws {
            try ModelPreparationContracts.requireHex64(artifactIdentityDigest, field: "artifact_identity_digest")
            let opened = try openObjects()
            defer { opened.root.close(); opened.namespace.close(); opened.objects.close() }
            let object = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(parent: opened.objects, name: artifactIdentityDigest)
            defer { object.close() }
            let file = try ModelPreparationSecureFilesystem.createPrivateFile(parent: object, name: Build1LaneAPreparationRecorder.receiptLeaf)
            var shouldRemove = true
            defer {
                file.close()
                if shouldRemove {
                    try? ModelPreparationSecureFilesystem.unlinkFile(parent: object, name: Build1LaneAPreparationRecorder.receiptLeaf, expected: file)
                }
            }
            try ModelPreparationSecureFilesystem.writeAll(fd: file.fd, data: bytes, path: file.path)
            try ModelPreparationSecureFilesystem.revalidateFile(
                file,
                parent: object,
                name: Build1LaneAPreparationRecorder.receiptLeaf,
                maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes,
                allowEmpty: false
            )
            try ModelPreparationSecureFilesystem.syncFileAndFullSync(fd: file.fd, path: file.path)
            let readback = try ModelPreparationSecureFilesystem.readAll(fd: file.fd, path: file.path, maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes)
            guard readback == bytes else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "receipt readback mismatch")
            }
            try ModelPreparationSecureFilesystem.syncDirectory(object)
            try ModelPreparationSecureFilesystem.syncDirectory(opened.objects)
            shouldRemove = false
        }

        private static func loadReceipt(artifactIdentityDigest: String, artifactRoot: URL) throws -> (record: ModelPreparationPublicationReceipt, sha256: String) {
            do {
                try ModelPreparationContracts.requireHex64(artifactIdentityDigest, field: "artifact_identity_digest")
                let opened = try openObjects(artifactRoot: artifactRoot)
                defer { opened.root.close(); opened.namespace.close(); opened.objects.close() }
                let object = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(parent: opened.objects, name: artifactIdentityDigest, create: false)
                defer { object.close() }
                guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
                    parent: object,
                    name: Build1LaneAPreparationRecorder.receiptLeaf,
                    maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes,
                    allowEmpty: false
                ) else {
                    throw Build1LaneAPreparationRecordError.inventoryInvalid("receipt missing")
                }
                defer { file.close() }
                let bytes = try ModelPreparationSecureFilesystem.readAll(fd: file.fd, path: file.path, maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes)
                let record = try ModelPreparationContracts.decode(
                    ModelPreparationPublicationReceipt.self,
                    from: bytes,
                    maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes
                )
                let sha256 = try ModelPreparationContracts.publicationReceiptSHA256(from: bytes)
                return (record, sha256)
            } catch let error as Build1LaneAPreparationRecordError {
                throw error
            } catch {
                throw Build1LaneAPreparationRecordError.inventoryInvalid(String(describing: error))
            }
        }

        private func removeReceiptBestEffort(artifactIdentityDigest: String) {
            guard let opened = try? openObjects() else { return }
            defer { opened.root.close(); opened.namespace.close(); opened.objects.close() }
            guard let object = try? ModelPreparationSecureFilesystem.openPrivateChildDirectory(parent: opened.objects, name: artifactIdentityDigest, create: false) else { return }
            defer { object.close() }
            try? ModelPreparationSecureFilesystem.unlinkFile(parent: object, name: Build1LaneAPreparationRecorder.receiptLeaf)
            _ = unlinkat(opened.objects.fd, artifactIdentityDigest, AT_REMOVEDIR)
        }
    }
}
