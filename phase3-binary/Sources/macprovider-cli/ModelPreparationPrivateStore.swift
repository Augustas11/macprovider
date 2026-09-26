import Darwin
import Foundation

struct ModelPreparationPrivateStore: Sendable {
    struct BootstrapSnapshot: Equatable, Sendable {
        let authorityRootPath: String
        let namespacePath: String
        let rootLocator: ModelPreparationRootLocator
    }

    struct RecoveryReport: Equatable, Sendable {
        let completed: [String]
        let removed: [String]
    }

    final class LockCustody: @unchecked Sendable {
        let authorityRootPath: String
        let artifactRootPath: String
        let rootLocator: ModelPreparationRootLocator
        fileprivate let authorityIdentity: ModelPreparationSecureFilesystem.FileIdentity
        fileprivate let artifactIdentity: ModelPreparationSecureFilesystem.FileIdentity
        fileprivate let locks: [String: ModelPreparationSecureFilesystem.OpenFile]
        private let state = NSLock()
        private var isClosed = false
        private var activeOperations = 0
        private var locksReleased = false

        fileprivate init(
            authorityRootPath: String,
            artifactRootPath: String,
            rootLocator: ModelPreparationRootLocator,
            authorityIdentity: ModelPreparationSecureFilesystem.FileIdentity,
            artifactIdentity: ModelPreparationSecureFilesystem.FileIdentity,
            locks: [String: ModelPreparationSecureFilesystem.OpenFile]
        ) {
            self.authorityRootPath = authorityRootPath
            self.artifactRootPath = artifactRootPath
            self.rootLocator = rootLocator
            self.authorityIdentity = authorityIdentity
            self.artifactIdentity = artifactIdentity
            self.locks = locks
        }

        func close() {
            releaseLocksWhenSafe(markClosed: true)
        }

        deinit { close() }

        fileprivate func withOpenLease<T>(_ body: () throws -> T) throws -> T {
            state.lock()
            if isClosed || locksReleased {
                state.unlock()
                throw ModelPreparationSecureFilesystemError.unsafe(path: authorityRootPath, reason: "lock custody closed")
            }
            activeOperations += 1
            state.unlock()

            do {
                let result = try body()
                finishLease()
                return result
            } catch {
                finishLease()
                throw error
            }
        }

        private func finishLease() {
            releaseLocksWhenSafe(markClosed: false)
        }

        private func releaseLocksWhenSafe(markClosed: Bool) {
            var filesToClose: [ModelPreparationSecureFilesystem.OpenFile] = []
            state.lock()
            if markClosed { isClosed = true }
            if !markClosed { activeOperations -= 1 }
            if isClosed, activeOperations == 0, !locksReleased {
                locksReleased = true
                filesToClose = Array(locks.values)
            }
            state.unlock()

            for file in filesToClose {
                _ = flock(file.fd, LOCK_UN)
                file.close()
            }
        }
    }

    static let lockLeaves = ["operation.lock", "failure.lock", "cancel.lock"]
    static let stateKinds = ModelPreparationPrivateStateEnvelopeKind.allCases
    private static let rootIdentityLeaf = "root.identity"
    private static let maxStateTemps = 16

    let authorityRoot: URL
    let artifactRoot: URL
    let randomSource: ModelPreparationRandomSource

    init(
        authorityRoot: URL,
        artifactRoot: URL,
        randomSource: ModelPreparationRandomSource = ModelPreparationSystemRandomSource()
    ) {
        self.authorityRoot = authorityRoot
        self.artifactRoot = artifactRoot
        self.randomSource = randomSource
    }

    func bootstrap() throws -> BootstrapSnapshot {
        let result = try bootstrapWithLockCustody()
        result.lockCustody.close()
        return result.snapshot
    }

    func bootstrapExisting() throws -> BootstrapSnapshot {
        let authority = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        let artifact = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: artifactRoot)
        defer { artifact.close() }
        let namespace = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: artifact,
            name: ModelPreparationSecureFilesystem.namespaceLeaf,
            create: false
        )
        defer { namespace.close() }
        guard let identity = try loadRootIdentityIfValid(namespace: namespace, root: artifact) else {
            throw ModelPreparationSecureFilesystemError.unsafe(
                path: namespace.path + "/" + Self.rootIdentityLeaf,
                reason: "missing root identity"
            )
        }
        let state = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: authority,
            name: ModelPreparationSecureFilesystem.stateLeaf,
            create: false
        )
        state.close()
        let locator = try ModelPreparationRootLocator(
            canonicalPath: artifact.path,
            stDev: identity.stDev,
            stIno: identity.stIno,
            identityVersion: identity.version,
            rootIdentityDigest: identity.digest
        )
        return BootstrapSnapshot(
            authorityRootPath: authority.path,
            namespacePath: namespace.path,
            rootLocator: locator
        )
    }

    func bootstrapWithLockCustody() throws -> (snapshot: BootstrapSnapshot, lockCustody: LockCustody) {
        let authority = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        for leaf in Self.lockLeaves {
            try ensureLock(leaf, in: authority)
        }
        let lockedFiles = try acquireAuthorityLocks(in: authority)
        var keepLocks = false
        defer {
            if !keepLocks {
                closeLocks(lockedFiles)
            }
        }
        let artifact = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: artifactRoot)
        defer { artifact.close() }
        let namespace = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: artifact,
            name: ModelPreparationSecureFilesystem.namespaceLeaf
        )
        defer { namespace.close() }
        let identity = try bootstrapRootIdentity(root: artifact, namespace: namespace)
        let state = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: authority,
            name: ModelPreparationSecureFilesystem.stateLeaf
        )
        state.close()
        try ensureNamespaceSkeleton(namespace)
        let locator = try ModelPreparationRootLocator(
            canonicalPath: artifact.path,
            stDev: identity.stDev,
            stIno: identity.stIno,
            identityVersion: identity.version,
            rootIdentityDigest: identity.digest
        )
        let lockCustody = LockCustody(
            authorityRootPath: authority.path,
            artifactRootPath: artifact.path,
            rootLocator: locator,
            authorityIdentity: authority.identity,
            artifactIdentity: artifact.identity,
            locks: lockedFiles
        )
        keepLocks = true
        let snapshot = BootstrapSnapshot(authorityRootPath: authority.path, namespacePath: namespace.path, rootLocator: locator)
        return (snapshot, lockCustody)
    }

    func acquireLockCustody() throws -> LockCustody {
        let boot = try bootstrapWithLockCustody()
        return boot.lockCustody
    }

    func writeRecord(
        kind: ModelPreparationPrivateStateEnvelopeKind,
        payload: Data,
        generation: Int,
        rootLocator: ModelPreparationRootLocator,
        lockCustody: LockCustody
    ) throws {
        guard generation >= 1 else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: kind.rawValue, reason: "generation must start at 1")
        }
        try validatePayload(payload, kind: kind, rootLocator: rootLocator)
        let authority = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        let artifact = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: artifactRoot)
        defer { artifact.close() }
        try lockCustody.withOpenLease {
            try validate(lockCustody, matches: authority, artifact: artifact, rootLocator: rootLocator)
            let state = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
                parent: authority,
                name: ModelPreparationSecureFilesystem.stateLeaf,
                create: false
            )
            defer { state.close() }
            try rejectLegacyStateTempIfPresent(authority: authority)
            try writeUniqueTemp(kind: kind, payload: payload, generation: generation, rootLocator: rootLocator, stateDirectory: state)
        }
    }

    func readRecord(kind: ModelPreparationPrivateStateEnvelopeKind, rootLocator: ModelPreparationRootLocator) throws -> Data? {
        try readRecordWithGeneration(kind: kind, rootLocator: rootLocator)?.payload
    }

    /// Reads the durable record and the envelope generation a writer must
    /// exceed to replace it. Same validation as `readRecord`.
    func readRecordWithGeneration(
        kind: ModelPreparationPrivateStateEnvelopeKind,
        rootLocator: ModelPreparationRootLocator
    ) throws -> (payload: Data, generation: Int)? {
        let authority = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        let artifact = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: artifactRoot)
        defer { artifact.close() }
        let namespace = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: artifact,
            name: ModelPreparationSecureFilesystem.namespaceLeaf,
            create: false
        )
        defer { namespace.close() }
        try validateRootIdentity(namespace: namespace, root: artifact, rootLocator: rootLocator)
        let state = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: authority,
            name: ModelPreparationSecureFilesystem.stateLeaf,
            create: false
        )
        defer { state.close() }
        let leaf = ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind)
        guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: state,
            name: leaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        ) else { return nil }
        defer { file.close() }
        let envelope = try readEnvelope(file: file, parent: state, leaf: leaf)
        guard envelope.recordKind == kind else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "wrong envelope kind")
        }
        try validateEnvelope(envelope, leaf: leaf, rootLocator: rootLocator)
        return (envelope.payload, envelope.generation)
    }

    @discardableResult
    func recoverStateTemps(rootLocator: ModelPreparationRootLocator, lockCustody: LockCustody) throws -> RecoveryReport {
        let authority = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        let artifact = try ModelPreparationSecureFilesystem.openExistingPrivateDirectory(at: artifactRoot)
        defer { artifact.close() }
        return try lockCustody.withOpenLease {
            try validate(lockCustody, matches: authority, artifact: artifact, rootLocator: rootLocator)
            try rejectLegacyStateTempIfPresent(authority: authority)
            let state = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
                parent: authority,
                name: ModelPreparationSecureFilesystem.stateLeaf,
                create: false
            )
            defer { state.close() }
            return try recoverTemps(stateDirectory: state, rootLocator: rootLocator)
        }
    }

    private func acquireAuthorityLocks(in authority: ModelPreparationSecureFilesystem.Directory) throws -> [String: ModelPreparationSecureFilesystem.OpenFile] {
        var locks: [String: ModelPreparationSecureFilesystem.OpenFile] = [:]
        do {
            for leaf in Self.lockLeaves.sorted() {
                guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
                    parent: authority,
                    name: leaf,
                    maxBytes: 0,
                    allowEmpty: true
                ) else {
                    throw ModelPreparationSecureFilesystemError.unsafe(path: authority.path + "/" + leaf, reason: "missing lock")
                }
                if flock(file.fd, LOCK_EX | LOCK_NB) != 0 {
                    file.close()
                    throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "lock already held")
                }
                locks[leaf] = file
            }
            return locks
        } catch {
            closeLocks(locks)
            throw error
        }
    }

    private func closeLocks(_ locks: [String: ModelPreparationSecureFilesystem.OpenFile]) {
        for file in locks.values {
            _ = flock(file.fd, LOCK_UN)
            file.close()
        }
    }

    private func validate(
        _ lockCustody: LockCustody,
        matches authority: ModelPreparationSecureFilesystem.Directory,
        artifact: ModelPreparationSecureFilesystem.Directory,
        rootLocator: ModelPreparationRootLocator
    ) throws {
        guard lockCustody.authorityRootPath == authority.path,
              lockCustody.authorityIdentity == authority.identity else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: authority.path, reason: "lock custody authority root mismatch")
        }
        guard lockCustody.artifactRootPath == artifact.path,
              lockCustody.artifactIdentity == artifact.identity else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: artifact.path, reason: "lock custody artifact root mismatch")
        }
        guard lockCustody.rootLocator == rootLocator else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: artifact.path, reason: "lock custody root locator mismatch")
        }
        for leaf in Self.lockLeaves {
            guard let file = lockCustody.locks[leaf] else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: authority.path + "/" + leaf, reason: "missing lock custody")
            }
            _ = try ModelPreparationSecureFilesystem.validateRegularFile(
                fd: file.fd,
                path: file.path,
                maxBytes: 0,
                allowEmpty: true
            )
            try ModelPreparationSecureFilesystem.revalidateFile(
                file,
                parent: authority,
                name: leaf,
                maxBytes: 0,
                allowEmpty: true
            )
        }
        let namespace = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: artifact,
            name: ModelPreparationSecureFilesystem.namespaceLeaf,
            create: false
        )
        defer { namespace.close() }
        try validateRootIdentity(namespace: namespace, root: artifact, rootLocator: rootLocator)
    }

    private func validatePayload(_ payload: Data, kind: ModelPreparationPrivateStateEnvelopeKind, rootLocator: ModelPreparationRootLocator) throws {
        try ModelPreparationPrivateStateEnvelope.validatePayload(payload, for: kind)
        switch kind {
        case .reservations:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationReservationsHistoryRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes
            )
            for reservation in record.projectedReservations {
                try require(reservation.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
            }
            for terminal in record.terminalHistory {
                try require(terminal.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
            }
        case .active:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationActiveRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.activeRecordMaxBytes
            )
            try require(record.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
        case .cancel:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationCancelMarker.self,
                from: payload,
                maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes
            )
            try require(record.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
        case .publishedInventory:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationInventoryRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.inventoryMaxBytes
            )
            try require(record.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
        case .deletion:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationCleanupRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.deletionRecordMaxBytes
            )
            try require(record.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
        case .stagingSources:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationStagingSourcesRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes
            )
            for entry in record.entries {
                try require(entry.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
            }
        case .failedDispatchPending:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationFailedDispatchRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.failedDispatchMaxBytes
            )
            try require(record.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
        }
    }

    private func ensureNamespaceSkeleton(_ namespace: ModelPreparationSecureFilesystem.Directory) throws {
        let objects = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(parent: namespace, name: ModelPreparationSecureFilesystem.objectsLeaf)
        objects.close()
        let work = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(parent: namespace, name: ModelPreparationSecureFilesystem.workLeaf)
        defer { work.close() }
        let staging = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(parent: work, name: ModelPreparationSecureFilesystem.stagingLeaf)
        staging.close()
        let unpublished = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(parent: work, name: ModelPreparationSecureFilesystem.unpublishedLeaf)
        unpublished.close()
    }

    private func ensureLock(_ leaf: String, in directory: ModelPreparationSecureFilesystem.Directory) throws {
        if let existing = try ModelPreparationSecureFilesystem.openPrivateFile(parent: directory, name: leaf, maxBytes: 0, allowEmpty: true) {
            existing.close()
            return
        }
        let file = try ModelPreparationSecureFilesystem.createPrivateFile(parent: directory, name: leaf)
        defer { file.close() }
        try ModelPreparationSecureFilesystem.syncFileAndFullSync(fd: file.fd, path: file.path)
        try ModelPreparationSecureFilesystem.syncDirectory(directory)
    }

    private func bootstrapRootIdentity(
        root: ModelPreparationSecureFilesystem.Directory,
        namespace: ModelPreparationSecureFilesystem.Directory
    ) throws -> ModelPreparationRootIdentityRecord {
        if let final = try loadRootIdentityIfValid(namespace: namespace, root: root) {
            try rejectRootIdentityBootstrapTemps(namespace: namespace, finalExists: true)
            return final
        }
        try requireNamespaceSafeForFreshIdentity(namespace: namespace)
        let nonce = try ModelPreparationSecureFilesystem.hex(randomSource.randomBytes(count: 32))
        let record = try ModelPreparationRootIdentityRecord(
            version: "model_catalog_root_identity.v1",
            nonceHex: nonce,
            canonicalPath: root.path,
            stDev: root.identity.stDev,
            stIno: root.identity.stIno
        )
        let payload = try ModelPreparationContracts.encode(record, maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes)
        let final = try ModelPreparationSecureFilesystem.createPrivateFile(parent: namespace, name: Self.rootIdentityLeaf)
        var shouldRemove = true
        defer {
            final.close()
            if shouldRemove { try? ModelPreparationSecureFilesystem.unlinkFile(parent: namespace, name: Self.rootIdentityLeaf, expected: final) }
        }
        try ModelPreparationSecureFilesystem.writeAll(fd: final.fd, data: payload, path: final.path)
        try ModelPreparationSecureFilesystem.revalidateFile(
            final,
            parent: namespace,
            name: Self.rootIdentityLeaf,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        )
        try ModelPreparationSecureFilesystem.syncFileAndFullSync(fd: final.fd, path: final.path)
        let readback = try ModelPreparationSecureFilesystem.readAll(fd: final.fd, path: final.path, maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes)
        guard readback == payload else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: final.path, reason: "root identity readback mismatch")
        }
        try ModelPreparationSecureFilesystem.syncDirectory(namespace)
        shouldRemove = false
        return record
    }

    private func loadRootIdentityIfValid(
        namespace: ModelPreparationSecureFilesystem.Directory,
        root: ModelPreparationSecureFilesystem.Directory
    ) throws -> ModelPreparationRootIdentityRecord? {
        guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: namespace,
            name: Self.rootIdentityLeaf,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        ) else { return nil }
        defer { file.close() }
        let data = try ModelPreparationSecureFilesystem.readAll(fd: file.fd, path: file.path, maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes)
        let record = try ModelPreparationContracts.decode(
            ModelPreparationRootIdentityRecord.self,
            from: data,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        guard record.canonicalPath == root.path,
              record.stDev == root.identity.stDev,
              record.stIno == root.identity.stIno,
              try record.digest == ModelPreparationContracts.rootIdentityDigest(
                version: record.version,
                nonceHex: record.nonceHex,
                canonicalPath: root.path,
                stDev: root.identity.stDev,
                stIno: root.identity.stIno
              ) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "root identity mismatch")
        }
        return record
    }

    private func validateRootIdentity(
        namespace: ModelPreparationSecureFilesystem.Directory,
        root: ModelPreparationSecureFilesystem.Directory,
        rootLocator: ModelPreparationRootLocator
    ) throws {
        let record = try loadRootIdentityIfValid(namespace: namespace, root: root)
        guard let record else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: namespace.path + "/" + Self.rootIdentityLeaf, reason: "missing root identity")
        }
        let digest = try record.digest
        guard rootLocator.canonicalPath == root.path,
              rootLocator.stDev == root.identity.stDev,
              rootLocator.stIno == root.identity.stIno,
              rootLocator.identityVersion == record.version,
              rootLocator.rootIdentityDigest == digest else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: namespace.path + "/" + Self.rootIdentityLeaf, reason: "root locator mismatch")
        }
    }

    private func rejectRootIdentityBootstrapTemps(namespace: ModelPreparationSecureFilesystem.Directory, finalExists: Bool) throws {
        try ModelPreparationSecureFilesystem.forEachDirectoryEntry(namespace) { name in
            if name.hasPrefix(Self.rootIdentityLeaf + ".") || name.hasSuffix(".tmp") || name == "bootstrap-tmp" {
                throw ModelPreparationSecureFilesystemError.unsafe(path: namespace.path + "/" + name, reason: "ambiguous root identity bootstrap evidence")
            }
        }
    }

    private func requireNamespaceSafeForFreshIdentity(namespace: ModelPreparationSecureFilesystem.Directory) throws {
        var entries = Set<String>()
        try ModelPreparationSecureFilesystem.forEachDirectoryEntry(namespace) { name in entries.insert(name) }
        guard entries.isEmpty else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: namespace.path, reason: "ambiguous namespace evidence without root identity")
        }
    }

    private func writeUniqueTemp(
        kind: ModelPreparationPrivateStateEnvelopeKind,
        payload: Data,
        generation: Int,
        rootLocator: ModelPreparationRootLocator,
        stateDirectory: ModelPreparationSecureFilesystem.Directory
    ) throws {
        let targetLeaf = ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind)
        let writerUUID = try randomSource.uuidString()
        let envelope = try ModelPreparationPrivateStateEnvelope(
            recordKind: kind,
            targetLeaf: targetLeaf,
            writerUUID: writerUUID,
            generation: generation,
            payload: payload
        )
        let tempLeaf = try envelope.expectedFilename()
        let envelopeData = try ModelPreparationContracts.encode(envelope, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
        if let currentGeneration = try existingEnvelopeGeneration(targetLeaf, kind: kind, rootLocator: rootLocator, in: stateDirectory),
           currentGeneration >= generation {
            throw ModelPreparationSecureFilesystemError.unsafe(path: stateDirectory.path + "/" + targetLeaf, reason: "generation is not monotonic")
        }
        let temp = try ModelPreparationSecureFilesystem.createPrivateFile(parent: stateDirectory, name: tempLeaf)
        var shouldRemoveTemp = true
        defer {
            temp.close()
            if shouldRemoveTemp { try? ModelPreparationSecureFilesystem.unlinkFile(parent: stateDirectory, name: tempLeaf, expected: temp) }
        }
        try ModelPreparationSecureFilesystem.writeAll(fd: temp.fd, data: envelopeData, path: temp.path)
        try ModelPreparationSecureFilesystem.revalidateFile(
            temp,
            parent: stateDirectory,
            name: tempLeaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        )
        try ModelPreparationSecureFilesystem.syncFileAndFullSync(fd: temp.fd, path: temp.path)
        let decoded = try readEnvelope(file: temp, parent: stateDirectory, leaf: tempLeaf)
        try decoded.validateTempFilename(tempLeaf)
        guard decoded == envelope else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: temp.path, reason: "temp readback mismatch")
        }
        if let currentGeneration = try existingEnvelopeGeneration(targetLeaf, kind: kind, rootLocator: rootLocator, in: stateDirectory),
           currentGeneration >= generation {
            throw ModelPreparationSecureFilesystemError.unsafe(path: stateDirectory.path + "/" + targetLeaf, reason: "generation is not monotonic")
        }
        try ModelPreparationSecureFilesystem.renameReplacing(parent: stateDirectory, source: tempLeaf, destination: targetLeaf, sourceFile: temp)
        shouldRemoveTemp = false
        try ModelPreparationSecureFilesystem.syncDirectory(stateDirectory)
        guard let final = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: stateDirectory,
            name: targetLeaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        ) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: stateDirectory.path + "/" + targetLeaf, reason: "missing target")
        }
        defer { final.close() }
        let finalData = try ModelPreparationSecureFilesystem.readAll(fd: final.fd, path: final.path, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
        guard finalData == envelopeData else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: final.path, reason: "target readback mismatch")
        }
    }

    private func recoverTemps(
        stateDirectory: ModelPreparationSecureFilesystem.Directory,
        rootLocator: ModelPreparationRootLocator
    ) throws -> RecoveryReport {
        var names: [String] = []
        try ModelPreparationSecureFilesystem.forEachDirectoryEntry(stateDirectory) { name in
            if ModelPreparationPrivateStateEnvelopeKind.allCases.contains(where: { ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: $0) == name }) {
                return
            }
            guard name.hasSuffix(".tmp") else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: stateDirectory.path + "/" + name, reason: "unexpected state entry")
            }
            names.append(name)
            if names.count > Self.maxStateTemps {
                throw ModelPreparationSecureFilesystemError.limitExceeded("recognized temps exceed 16")
            }
        }
        names.sort()

        var candidates: [(name: String, kind: ModelPreparationPrivateStateEnvelopeKind, envelope: ModelPreparationPrivateStateEnvelope?, file: ModelPreparationSecureFilesystem.OpenFile)] = []
        do {
            for name in names {
                let kind = try parseStateTempName(name)
                guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
                    parent: stateDirectory,
                    name: name,
                    maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
                    allowEmpty: true
                ) else { continue }
                let data = try ModelPreparationSecureFilesystem.readAll(fd: file.fd, path: file.path, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
                if data.isEmpty {
                    candidates.append((name, kind, nil, file))
                    continue
                }
                let envelope = try ModelPreparationContracts.decode(
                    ModelPreparationPrivateStateEnvelope.self,
                    from: data,
                    maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
                )
                try envelope.validateTempFilename(name)
                guard envelope.recordKind == kind else {
                    throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "unexpected temp kind")
                }
                try validateEnvelope(envelope, leaf: envelope.targetLeaf, rootLocator: rootLocator)
                _ = try existingEnvelopeGeneration(
                    ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind),
                    kind: kind,
                    rootLocator: rootLocator,
                    in: stateDirectory
                )
                candidates.append((name, kind, envelope, file))
            }
        } catch {
            for candidate in candidates { candidate.file.close() }
            throw error
        }

        var removed: [String] = []
        for candidate in candidates {
            defer { candidate.file.close() }
            guard let envelope = candidate.envelope else {
                try ModelPreparationSecureFilesystem.unlinkFile(parent: stateDirectory, name: candidate.name, expected: candidate.file)
                removed.append(candidate.name)
                continue
            }
            let targetLeaf = ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: candidate.kind)
            if let currentGeneration = try existingEnvelopeGeneration(targetLeaf, kind: candidate.kind, rootLocator: rootLocator, in: stateDirectory),
               currentGeneration >= envelope.generation {
                try ModelPreparationSecureFilesystem.unlinkFile(parent: stateDirectory, name: candidate.name, expected: candidate.file)
                removed.append(candidate.name)
            }
        }
        if !removed.isEmpty { try ModelPreparationSecureFilesystem.syncDirectory(stateDirectory) }
        return RecoveryReport(completed: [], removed: removed.sorted())
    }

    private func parseStateTempName(_ name: String) throws -> ModelPreparationPrivateStateEnvelopeKind {
        for kind in Self.stateKinds {
            let leaf = ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind)
            let prefix = leaf + "."
            guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { continue }
            guard name.utf8.count == prefix.utf8.count + 36 + ".tmp".utf8.count else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: name, reason: "invalid temp filename")
            }
            let uuidStart = name.index(name.startIndex, offsetBy: prefix.count)
            let uuidEnd = name.index(uuidStart, offsetBy: 36)
            let uuid = String(name[uuidStart ..< uuidEnd])
            try ModelPreparationContracts.requireUUIDv4(uuid, field: "writer_uuid")
            let expected = try ModelPreparationPrivateStateEnvelope.expectedFilename(recordKind: kind, targetLeaf: leaf, writerUUID: uuid)
            guard expected == name else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: name, reason: "invalid temp filename")
            }
            return kind
        }
        throw ModelPreparationSecureFilesystemError.unsafe(path: name, reason: "unexpected state temp")
    }

    private func readEnvelope(
        file: ModelPreparationSecureFilesystem.OpenFile,
        parent: ModelPreparationSecureFilesystem.Directory,
        leaf: String
    ) throws -> ModelPreparationPrivateStateEnvelope {
        try ModelPreparationSecureFilesystem.revalidateFile(
            file,
            parent: parent,
            name: leaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        )
        let data = try ModelPreparationSecureFilesystem.readAll(fd: file.fd, path: file.path, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
        return try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: data,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
    }

    private func validateEnvelope(_ envelope: ModelPreparationPrivateStateEnvelope, leaf: String, rootLocator: ModelPreparationRootLocator) throws {
        try envelope.validateDurableTargetLeaf(leaf)
        try validatePayload(envelope.payload, kind: envelope.recordKind, rootLocator: rootLocator)
        guard envelope.generation >= 1 else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: leaf, reason: "generation must start at 1")
        }
    }

    private func existingEnvelopeGeneration(
        _ leaf: String,
        kind: ModelPreparationPrivateStateEnvelopeKind,
        rootLocator: ModelPreparationRootLocator,
        in directory: ModelPreparationSecureFilesystem.Directory
    ) throws -> Int? {
        guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: directory,
            name: leaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        ) else { return nil }
        defer { file.close() }
        let envelope = try readEnvelope(file: file, parent: directory, leaf: leaf)
        guard envelope.recordKind == kind else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "wrong envelope kind")
        }
        try validateEnvelope(envelope, leaf: leaf, rootLocator: rootLocator)
        return envelope.generation
    }

    private func rejectLegacyStateTempIfPresent(authority: ModelPreparationSecureFilesystem.Directory) throws {
        let fd = openat(authority.fd, "state-tmp", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd >= 0 {
            Darwin.close(fd)
            throw ModelPreparationSecureFilesystemError.unsafe(path: authority.path + "/state-tmp", reason: "legacy state temp directory")
        }
        if errno != ENOENT {
            throw ModelPreparationSecureFilesystem.openError(path: authority.path + "/state-tmp", operation: "inspect legacy state temp")
        }
    }

    private func require(_ condition: Bool, path: String, reason: String) throws {
        guard condition else { throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: reason) }
    }
}
