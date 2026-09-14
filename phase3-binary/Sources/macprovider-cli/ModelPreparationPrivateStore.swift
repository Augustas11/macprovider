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
        fileprivate let locks: [String: ModelPreparationSecureFilesystem.OpenFile]
        private let state = NSLock()
        private var isClosed = false

        fileprivate init(authorityRootPath: String, locks: [String: ModelPreparationSecureFilesystem.OpenFile]) {
            self.authorityRootPath = authorityRootPath
            self.locks = locks
        }

        func close() {
            state.lock()
            let shouldClose = !isClosed
            isClosed = true
            state.unlock()
            guard shouldClose else { return }
            for file in locks.values {
                _ = flock(file.fd, LOCK_UN)
                file.close()
            }
        }

        deinit { close() }

        fileprivate func checkOpen() throws {
            state.lock()
            let closed = isClosed
            state.unlock()
            if closed {
                throw ModelPreparationSecureFilesystemError.unsafe(path: authorityRootPath, reason: "lock custody closed")
            }
        }
    }

    static let authorityDirectoryName = "model-preparation-v3"
    static let lockLeaves = ["operation.lock", "failure.lock", "cancel.lock"]
    static let stateKinds: [ModelPreparationPrivateStateEnvelopeKind] = [
        .reservations,
        .active,
        .cancel,
        .publishedInventory,
        .deletion,
    ]

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

    func bootstrapWithLockCustody() throws -> (snapshot: BootstrapSnapshot, lockCustody: LockCustody) {
        let authority = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        let stateTemp = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: authority,
            name: ModelPreparationSecureFilesystem.stateTempLeaf
        )
        stateTemp.close()
        for leaf in Self.lockLeaves {
            try ensureLock(leaf, in: authority)
        }
        let lockCustody = try acquireLockCustody(in: authority)
        do {
            let artifact = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: artifactRoot)
            defer { artifact.close() }
            let namespace = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
                parent: artifact,
                name: ModelPreparationSecureFilesystem.namespaceLeaf
            )
            defer { namespace.close() }
            let bootstrapTemp = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
                parent: namespace,
                name: ModelPreparationSecureFilesystem.bootstrapTempLeaf
            )
            defer { bootstrapTemp.close() }
            try ensureNamespaceSkeleton(namespace)
            let identity = try bootstrapRootIdentity(root: artifact, namespace: namespace, bootstrapTemp: bootstrapTemp)
            let locator = try ModelPreparationRootLocator(
                canonicalPath: artifact.path,
                stDev: identity.stDev,
                stIno: identity.stIno,
                identityVersion: identity.version,
                rootIdentityDigest: identity.digest
            )
            return (BootstrapSnapshot(
                authorityRootPath: authority.path,
                namespacePath: namespace.path,
                rootLocator: locator
            ), lockCustody)
        } catch {
            lockCustody.close()
            throw error
        }
    }

    func acquireLockCustody() throws -> LockCustody {
        let authority = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        for leaf in Self.lockLeaves {
            try ensureLock(leaf, in: authority)
        }
        return try acquireLockCustody(in: authority)
    }

    func writeRecord(
        kind: ModelPreparationPrivateStateEnvelopeKind,
        payload: Data,
        generation: Int,
        rootLocator: ModelPreparationRootLocator,
        lockCustody: LockCustody
    ) throws {
        guard Self.stateKinds.contains(kind) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: kind.rawValue, reason: "unsupported state kind")
        }
        try validatePayload(payload, kind: kind, rootLocator: rootLocator)
        let authority = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        try validate(lockCustody, matches: authority)
        let stateTemp = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: authority,
            name: ModelPreparationSecureFilesystem.stateTempLeaf
        )
        defer { stateTemp.close() }
        try writeUniqueTemp(
            kind: kind,
            payload: payload,
            generation: generation,
            rootLocator: rootLocator,
            tempDirectory: stateTemp,
            targetDirectory: authority
        )
    }

    func readRecord(kind: ModelPreparationPrivateStateEnvelopeKind, rootLocator: ModelPreparationRootLocator) throws -> Data? {
        guard Self.stateKinds.contains(kind) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: kind.rawValue, reason: "unsupported state kind")
        }
        let authority = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        let leaf = ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind)
        guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: authority,
            name: leaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        ) else {
            return nil
        }
        defer { file.close() }
        try ModelPreparationSecureFilesystem.revalidateFile(
            file,
            parent: authority,
            name: leaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        )
        let envelopeData = try ModelPreparationSecureFilesystem.readAll(
            fd: file.fd,
            path: file.path,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        let envelope = try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: envelopeData,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        try envelope.validateDurableTargetLeaf(leaf)
        try validatePayload(envelope.payload, kind: kind, rootLocator: rootLocator)
        return envelope.payload
    }

    @discardableResult
    func recoverStateTemps(rootLocator: ModelPreparationRootLocator, lockCustody: LockCustody) throws -> RecoveryReport {
        let authority = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: authorityRoot)
        defer { authority.close() }
        try validate(lockCustody, matches: authority)
        let stateTemp = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: authority,
            name: ModelPreparationSecureFilesystem.stateTempLeaf
        )
        defer { stateTemp.close() }
        return try recoverTemps(
            tempDirectory: stateTemp,
            targetDirectory: authority,
            allowedKinds: Self.stateKinds,
            rootLocator: rootLocator
        )
    }

    @discardableResult
    func recoverRootIdentityTemps() throws -> RecoveryReport {
        let artifact = try ModelPreparationSecureFilesystem.openOrCreatePrivateDirectory(at: artifactRoot)
        defer { artifact.close() }
        let namespace = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: artifact,
            name: ModelPreparationSecureFilesystem.namespaceLeaf
        )
        defer { namespace.close() }
        let bootstrapTemp = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: namespace,
            name: ModelPreparationSecureFilesystem.bootstrapTempLeaf
        )
        defer { bootstrapTemp.close() }
        return try recoverRootIdentityTemps(root: artifact, namespace: namespace, bootstrapTemp: bootstrapTemp)
    }

    private func acquireLockCustody(in authority: ModelPreparationSecureFilesystem.Directory) throws -> LockCustody {
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
            return LockCustody(authorityRootPath: authority.path, locks: locks)
        } catch {
            for file in locks.values {
                _ = flock(file.fd, LOCK_UN)
                file.close()
            }
            throw error
        }
    }

    private func validate(_ lockCustody: LockCustody, matches authority: ModelPreparationSecureFilesystem.Directory) throws {
        try lockCustody.checkOpen()
        guard lockCustody.authorityRootPath == authority.path else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: authority.path, reason: "lock custody root mismatch")
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
        }
    }

    private func validatePayload(
        _ payload: Data,
        kind: ModelPreparationPrivateStateEnvelopeKind,
        rootLocator: ModelPreparationRootLocator
    ) throws {
        switch kind {
        case .reservations:
            throw ModelPreparationSecureFilesystemError.unsafe(
                path: kind.rawValue,
                reason: "inner durable schema pending plan gate"
            )
        case .active:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationActiveRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.activeRecordMaxBytes
            )
            try require(record.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
        case .cancel:
            throw ModelPreparationSecureFilesystemError.unsafe(
                path: kind.rawValue,
                reason: "inner durable schema pending plan gate"
            )
        case .publishedInventory:
            let record = try ModelPreparationContracts.decode(
                ModelPreparationInventoryRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.inventoryMaxBytes
            )
            try require(record.root == rootLocator, path: kind.rawValue, reason: "root locator mismatch")
        case .deletion:
            throw ModelPreparationSecureFilesystemError.unsafe(
                path: kind.rawValue,
                reason: "inner durable schema pending plan gate"
            )
        }
    }

    private func require(_ condition: Bool, path: String, reason: String) throws {
        guard condition else { throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: reason) }
    }

    private func ensureNamespaceSkeleton(_ namespace: ModelPreparationSecureFilesystem.Directory) throws {
        let objects = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: namespace,
            name: ModelPreparationSecureFilesystem.objectsLeaf
        )
        objects.close()
        let work = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: namespace,
            name: ModelPreparationSecureFilesystem.workLeaf
        )
        defer { work.close() }
        let staging = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: work,
            name: ModelPreparationSecureFilesystem.stagingLeaf
        )
        staging.close()
        let unpublished = try ModelPreparationSecureFilesystem.openPrivateChildDirectory(
            parent: work,
            name: ModelPreparationSecureFilesystem.unpublishedLeaf
        )
        unpublished.close()
    }

    private func ensureLock(_ leaf: String, in directory: ModelPreparationSecureFilesystem.Directory) throws {
        if let existing = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: directory,
            name: leaf,
            maxBytes: 0,
            allowEmpty: true
        ) {
            existing.close()
            return
        }
        let file = try ModelPreparationSecureFilesystem.createPrivateFile(parent: directory, name: leaf)
        defer { file.close() }
        try ModelPreparationSecureFilesystem.revalidateFile(file, parent: directory, name: leaf, maxBytes: 0, allowEmpty: true)
        try ModelPreparationSecureFilesystem.syncFileAndFullSync(fd: file.fd, path: file.path)
        try ModelPreparationSecureFilesystem.syncDirectory(directory)
    }

    private func bootstrapRootIdentity(
        root: ModelPreparationSecureFilesystem.Directory,
        namespace: ModelPreparationSecureFilesystem.Directory,
        bootstrapTemp: ModelPreparationSecureFilesystem.Directory
    ) throws -> ModelPreparationRootIdentityRecord {
        if let final = try loadRootIdentityIfValid(namespace: namespace, root: root) {
            _ = try recoverRootIdentityTemps(root: root, namespace: namespace, bootstrapTemp: bootstrapTemp, final: final)
            return final
        }
        let report = try recoverRootIdentityTemps(root: root, namespace: namespace, bootstrapTemp: bootstrapTemp)
        if !report.completed.isEmpty, let final = try loadRootIdentityIfValid(namespace: namespace, root: root) {
            return final
        }
        let nonce = try ModelPreparationSecureFilesystem.hex(randomSource.randomBytes(count: 32))
        let record = try ModelPreparationRootIdentityRecord(
            version: "model_catalog_root_identity.v1",
            nonceHex: nonce,
            canonicalPath: root.path,
            stDev: root.identity.stDev,
            stIno: root.identity.stIno
        )
        let payload = try ModelPreparationContracts.encode(
            record,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        try writeRootIdentityTemp(payload: payload, tempDirectory: bootstrapTemp, targetDirectory: namespace)
        return record
    }

    private func loadRootIdentityIfValid(
        namespace: ModelPreparationSecureFilesystem.Directory,
        root: ModelPreparationSecureFilesystem.Directory
    ) throws -> ModelPreparationRootIdentityRecord? {
        guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: namespace,
            name: "root.identity",
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        ) else {
            return nil
        }
        defer { file.close() }
        try ModelPreparationSecureFilesystem.revalidateFile(
            file,
            parent: namespace,
            name: "root.identity",
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        )
        let data = try ModelPreparationSecureFilesystem.readAll(
            fd: file.fd,
            path: file.path,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        let record = try ModelPreparationContracts.decode(
            ModelPreparationRootIdentityRecord.self,
            from: data,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        guard record.canonicalPath == root.path,
              record.stDev == root.identity.stDev,
              record.stIno == root.identity.stIno else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "root identity mismatch")
        }
        _ = try record.digest
        return record
    }

    private func writeRootIdentityTemp(
        payload: Data,
        tempDirectory: ModelPreparationSecureFilesystem.Directory,
        targetDirectory: ModelPreparationSecureFilesystem.Directory
    ) throws {
        let writerUUID = try randomSource.uuidString()
        try ModelPreparationContracts.requireUUIDv4(writerUUID, field: "writer_uuid")
        let tempLeaf = "root.identity.\(writerUUID).tmp"
        let temp = try ModelPreparationSecureFilesystem.createPrivateFile(parent: tempDirectory, name: tempLeaf)
        var shouldRemoveTemp = true
        defer {
            temp.close()
            if shouldRemoveTemp { try? ModelPreparationSecureFilesystem.unlinkFile(parent: tempDirectory, name: tempLeaf, expected: temp) }
        }
        _ = try ModelPreparationContracts.decode(
            ModelPreparationRootIdentityRecord.self,
            from: payload,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        try ModelPreparationSecureFilesystem.revalidateFile(
            temp,
            parent: tempDirectory,
            name: tempLeaf,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: true
        )
        try ModelPreparationSecureFilesystem.writeAll(fd: temp.fd, data: payload, path: temp.path)
        try ModelPreparationSecureFilesystem.revalidateFile(
            temp,
            parent: tempDirectory,
            name: tempLeaf,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        )
        try ModelPreparationSecureFilesystem.syncFileAndFullSync(fd: temp.fd, path: temp.path)
        try ModelPreparationSecureFilesystem.revalidateFile(
            temp,
            parent: tempDirectory,
            name: tempLeaf,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        )
        let readback = try ModelPreparationSecureFilesystem.readAll(
            fd: temp.fd,
            path: temp.path,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        guard readback == payload else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: temp.path, reason: "root identity temp readback mismatch")
        }
        try ModelPreparationSecureFilesystem.renameExclusive(
            sourceParent: tempDirectory,
            source: tempLeaf,
            targetParent: targetDirectory,
            destination: "root.identity",
            sourceFile: temp
        )
        shouldRemoveTemp = false
        try ModelPreparationSecureFilesystem.syncDirectory(targetDirectory)
        guard let final = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: targetDirectory,
            name: "root.identity",
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        ) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: targetDirectory.path + "/root.identity", reason: "missing root identity")
        }
        defer { final.close() }
        try ModelPreparationSecureFilesystem.revalidateFile(
            final,
            parent: targetDirectory,
            name: "root.identity",
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
            allowEmpty: false
        )
        let finalData = try ModelPreparationSecureFilesystem.readAll(
            fd: final.fd,
            path: final.path,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        guard finalData == payload else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: final.path, reason: "root identity readback mismatch")
        }
    }

    private func recoverRootIdentityTemps(
        root: ModelPreparationSecureFilesystem.Directory,
        namespace: ModelPreparationSecureFilesystem.Directory,
        bootstrapTemp: ModelPreparationSecureFilesystem.Directory,
        final: ModelPreparationRootIdentityRecord? = nil
    ) throws -> RecoveryReport {
        let finalIdentity: ModelPreparationRootIdentityRecord?
        if let final {
            finalIdentity = final
        } else {
            finalIdentity = try loadRootIdentityIfValid(namespace: namespace, root: root)
        }
        var names: [String] = []
        try ModelPreparationSecureFilesystem.forEachDirectoryEntry(bootstrapTemp) { name in
            guard name.hasSuffix(".tmp") else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: bootstrapTemp.path + "/" + name, reason: "unexpected bootstrap entry")
            }
            names.append(name)
            if names.count > 16 {
                throw ModelPreparationSecureFilesystemError.limitExceeded("bootstrap temps exceed 16")
            }
        }
        names.sort()
        var validTemps: [(String, ModelPreparationRootIdentityRecord, ModelPreparationSecureFilesystem.OpenFile)] = []
        defer { for temp in validTemps { temp.2.close() } }
        var removed: [String] = []
        for name in names where name.hasSuffix(".tmp") {
            guard name.hasPrefix("root.identity."), name.utf8.count == "root.identity.".utf8.count + 36 + ".tmp".utf8.count else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: bootstrapTemp.path + "/" + name, reason: "unexpected bootstrap temp")
            }
            let uuidStart = name.index(name.startIndex, offsetBy: "root.identity.".count)
            let uuidEnd = name.index(uuidStart, offsetBy: 36)
            let uuid = String(name[uuidStart ..< uuidEnd])
            try ModelPreparationContracts.requireUUIDv4(uuid, field: "writer_uuid")
            guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
                parent: bootstrapTemp,
                name: name,
                maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
                allowEmpty: true
            ) else {
                continue
            }
            try ModelPreparationSecureFilesystem.revalidateFile(
                file,
                parent: bootstrapTemp,
                name: name,
                maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes,
                allowEmpty: true
            )
            let data = try ModelPreparationSecureFilesystem.readAll(
                fd: file.fd,
                path: file.path,
                maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
            )
            if data.isEmpty {
                try ModelPreparationSecureFilesystem.unlinkFile(parent: bootstrapTemp, name: name, expected: file)
                file.close()
                removed.append(name)
                continue
            }
            let record = try ModelPreparationContracts.decode(
                ModelPreparationRootIdentityRecord.self,
                from: data,
                maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
            )
            guard record.canonicalPath == root.path,
                  record.stDev == root.identity.stDev,
                  record.stIno == root.identity.stIno else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "root identity mismatch")
            }
            _ = try record.digest
            validTemps.append((name, record, file))
        }
        let distinctValidRecords = Set(try validTemps.map { try $0.1.digest })
        guard distinctValidRecords.count <= 1 else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: bootstrapTemp.path, reason: "conflicting root identity temps")
        }
        if let finalIdentity {
            for (name, record, file) in validTemps {
                guard record == finalIdentity else {
                    throw ModelPreparationSecureFilesystemError.unsafe(path: bootstrapTemp.path + "/" + name, reason: "conflicting root identity temp")
                }
                try ModelPreparationSecureFilesystem.unlinkFile(parent: bootstrapTemp, name: name, expected: file)
                removed.append(name)
            }
            if !removed.isEmpty { try ModelPreparationSecureFilesystem.syncDirectory(bootstrapTemp) }
            return RecoveryReport(completed: [], removed: removed.sorted())
        }
        guard let (name, _, file) = validTemps.first else {
            if !removed.isEmpty { try ModelPreparationSecureFilesystem.syncDirectory(bootstrapTemp) }
            return RecoveryReport(completed: [], removed: removed.sorted())
        }
        try ModelPreparationSecureFilesystem.renameExclusive(
            sourceParent: bootstrapTemp,
            source: name,
            targetParent: namespace,
            destination: "root.identity",
            sourceFile: file
        )
        try ModelPreparationSecureFilesystem.syncDirectory(namespace)
        return RecoveryReport(completed: [name], removed: removed.sorted())
    }

    private func writeUniqueTemp(
        kind: ModelPreparationPrivateStateEnvelopeKind,
        payload: Data,
        generation: Int,
        rootLocator: ModelPreparationRootLocator,
        tempDirectory: ModelPreparationSecureFilesystem.Directory,
        targetDirectory: ModelPreparationSecureFilesystem.Directory
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
        let envelopeData = try ModelPreparationContracts.encode(
            envelope,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        if let currentGeneration = try existingEnvelopeGeneration(targetLeaf, kind: kind, rootLocator: rootLocator, in: targetDirectory),
           currentGeneration >= generation {
            throw ModelPreparationSecureFilesystemError.unsafe(path: targetDirectory.path + "/" + targetLeaf, reason: "generation is not monotonic")
        }
        let temp = try ModelPreparationSecureFilesystem.createPrivateFile(parent: tempDirectory, name: tempLeaf)
        var shouldRemoveTemp = true
        defer {
            temp.close()
            if shouldRemoveTemp { try? ModelPreparationSecureFilesystem.unlinkFile(parent: tempDirectory, name: tempLeaf, expected: temp) }
        }
        try ModelPreparationSecureFilesystem.revalidateFile(
            temp,
            parent: tempDirectory,
            name: tempLeaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: true
        )
        try ModelPreparationSecureFilesystem.writeAll(fd: temp.fd, data: envelopeData, path: temp.path)
        try ModelPreparationSecureFilesystem.revalidateFile(
            temp,
            parent: tempDirectory,
            name: tempLeaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        )
        try ModelPreparationSecureFilesystem.syncFileAndFullSync(fd: temp.fd, path: temp.path)
        try ModelPreparationSecureFilesystem.revalidateFile(
            temp,
            parent: tempDirectory,
            name: tempLeaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        )
        let readback = try ModelPreparationSecureFilesystem.readAll(
            fd: temp.fd,
            path: temp.path,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        let decoded = try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: readback,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        try decoded.validateTempFilename(tempLeaf)
        guard decoded == envelope else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: temp.path, reason: "temp readback mismatch")
        }
        try ModelPreparationSecureFilesystem.renameReplacing(
            sourceParent: tempDirectory,
            source: tempLeaf,
            targetParent: targetDirectory,
            destination: targetLeaf,
            sourceFile: temp
        )
        shouldRemoveTemp = false
        try ModelPreparationSecureFilesystem.syncDirectory(targetDirectory)
        guard let final = try ModelPreparationSecureFilesystem.openPrivateFile(
            parent: targetDirectory,
            name: targetLeaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        ) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: targetDirectory.path + "/" + targetLeaf, reason: "missing target")
        }
        defer { final.close() }
        try ModelPreparationSecureFilesystem.revalidateFile(
            final,
            parent: targetDirectory,
            name: targetLeaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        )
        let finalData = try ModelPreparationSecureFilesystem.readAll(
            fd: final.fd,
            path: final.path,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        guard finalData == envelopeData else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: final.path, reason: "target readback mismatch")
        }
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
            let expected = try ModelPreparationPrivateStateEnvelope.expectedFilename(
                recordKind: kind,
                targetLeaf: leaf,
                writerUUID: uuid
            )
            guard expected == name else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: name, reason: "invalid temp filename")
            }
            return kind
        }
        throw ModelPreparationSecureFilesystemError.unsafe(path: name, reason: "unexpected state temp")
    }

    private func recoverTemps(
        tempDirectory: ModelPreparationSecureFilesystem.Directory,
        targetDirectory: ModelPreparationSecureFilesystem.Directory,
        allowedKinds: [ModelPreparationPrivateStateEnvelopeKind],
        rootLocator: ModelPreparationRootLocator
    ) throws -> RecoveryReport {
        var names: [String] = []
        try ModelPreparationSecureFilesystem.forEachDirectoryEntry(tempDirectory) { name in
            guard name.hasSuffix(".tmp") else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: tempDirectory.path + "/" + name, reason: "unexpected state entry")
            }
            names.append(name)
            if names.count > 16 {
                throw ModelPreparationSecureFilesystemError.limitExceeded("recognized temps exceed 16")
            }
        }
        names.sort()
        var candidates: [(String, ModelPreparationPrivateStateEnvelope, ModelPreparationSecureFilesystem.OpenFile)] = []
        defer { for candidate in candidates { candidate.2.close() } }
        var countByKind: [ModelPreparationPrivateStateEnvelopeKind: Int] = [:]
        var removed: [String] = []
        for name in names where name.hasSuffix(".tmp") {
            let expectedKind = try parseStateTempName(name)
            guard allowedKinds.contains(expectedKind) else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: tempDirectory.path + "/" + name, reason: "unexpected temp kind")
            }
            guard candidates.count < 16 else {
                throw ModelPreparationSecureFilesystemError.limitExceeded("recognized temps exceed 16")
            }
            guard let file = try ModelPreparationSecureFilesystem.openPrivateFile(
                parent: tempDirectory,
                name: name,
                maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
                allowEmpty: true
            ) else {
                continue
            }
            try ModelPreparationSecureFilesystem.revalidateFile(
                file,
                parent: tempDirectory,
                name: name,
                maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
                allowEmpty: true
            )
            let data = try ModelPreparationSecureFilesystem.readAll(
                fd: file.fd,
                path: file.path,
                maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
            )
            if data.isEmpty {
                try ModelPreparationSecureFilesystem.unlinkFile(parent: tempDirectory, name: name, expected: file)
                file.close()
                removed.append(name)
                continue
            }
            let temp = try ModelPreparationContracts.decode(
                ModelPreparationPrivateStateEnvelope.self,
                from: data,
                maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
            )
            try temp.validateTempFilename(name)
            guard temp.recordKind == expectedKind, allowedKinds.contains(temp.recordKind) else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "unexpected temp kind")
            }
            try validatePayload(temp.payload, kind: temp.recordKind, rootLocator: rootLocator)
            let nextCount = (countByKind[temp.recordKind] ?? 0) + 1
            guard nextCount <= 4 else {
                throw ModelPreparationSecureFilesystemError.limitExceeded("recognized temps exceed four per kind")
            }
            countByKind[temp.recordKind] = nextCount
            candidates.append((name, temp, file))
        }

        var completed: [String] = []
        let grouped = Dictionary(grouping: candidates, by: { $0.1.recordKind })
        for (kind, group) in grouped {
            let targetLeaf = ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind)
            var currentGeneration = try existingEnvelopeGeneration(targetLeaf, kind: kind, rootLocator: rootLocator, in: targetDirectory)
            for (name, temp, file) in group.sorted(by: { lhs, rhs in
                lhs.1.generation == rhs.1.generation ? lhs.0 < rhs.0 : lhs.1.generation > rhs.1.generation
            }) {
                if let currentGeneration, currentGeneration >= temp.generation {
                    try ModelPreparationSecureFilesystem.unlinkFile(parent: tempDirectory, name: name, expected: file)
                    removed.append(name)
                    continue
                }
                try ModelPreparationSecureFilesystem.renameReplacing(
                    sourceParent: tempDirectory,
                    source: name,
                    targetParent: targetDirectory,
                    destination: targetLeaf,
                    sourceFile: file
                )
                try ModelPreparationSecureFilesystem.syncDirectory(targetDirectory)
                currentGeneration = temp.generation
                completed.append(name)
            }
        }
        if !removed.isEmpty {
            try ModelPreparationSecureFilesystem.syncDirectory(tempDirectory)
        }
        return RecoveryReport(completed: completed.sorted(), removed: removed.sorted())
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
        ) else {
            return nil
        }
        defer { file.close() }
        try ModelPreparationSecureFilesystem.revalidateFile(
            file,
            parent: directory,
            name: leaf,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes,
            allowEmpty: false
        )
        let data = try ModelPreparationSecureFilesystem.readAll(
            fd: file.fd,
            path: file.path,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        let envelope = try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: data,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        try envelope.validateDurableTargetLeaf(leaf)
        guard envelope.recordKind == kind else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "wrong envelope kind")
        }
        try validatePayload(envelope.payload, kind: kind, rootLocator: rootLocator)
        return envelope.generation
    }
}
