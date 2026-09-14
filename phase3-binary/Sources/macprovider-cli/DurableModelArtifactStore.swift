import Foundation

/// Provider-owned model weight store. Hugging Face cache is staging only.
struct DurableModelArtifactStore {
    var root: URL
    var fileManager: FileManager = .default

    static let cacheBackedWarning =
        "model_artifact_cache_backed: active artifact is under Hugging Face cache; serving now uses the durable store copy"

    static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MACPROVIDER_MODEL_ARTIFACT_ROOT"],
           !override.isEmpty,
           override.hasPrefix("/")
        {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider/models", isDirectory: true)
            .standardizedFileURL
    }

    static func isHuggingFaceCachePath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.contains("/.cache/huggingface/") {
            return true
        }
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"], !hfHome.isEmpty {
            let hub = URL(fileURLWithPath: hfHome).appendingPathComponent("hub", isDirectory: true)
                .standardizedFileURL.path
            if standardized == hub || standardized.hasPrefix(hub + "/") {
                return true
            }
        }
        return false
    }

    func artifactURL(modelID: String, revision: String, sha256: String) throws -> URL {
        let escapedID = try Self.escapedComponent(modelID, label: "model id")
        let escapedRevision = try Self.escapedComponent(revision, label: "revision")
        guard sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw AutotuneRecommendError.invalidArtifact("durable artifact hash must be 64 lowercase hex characters")
        }
        return root
            .appendingPathComponent(escapedID, isDirectory: true)
            .appendingPathComponent(escapedRevision, isDirectory: true)
            .appendingPathComponent(sha256, isDirectory: true)
            .standardizedFileURL
    }

    func contains(_ path: String) -> Bool {
        (try? validatedContainedDirectory(path)) != nil
    }

    func validatedContainedDirectory(_ path: String) throws -> URL {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        try validateNoSymlinkAncestors(of: standardized, requireComplete: true)
        return standardized
    }

    func isModelMaterialized(modelID: String) -> Bool {
        guard let escapedID = try? Self.escapedComponent(modelID, label: "model id") else {
            return false
        }
        let modelRoot = root.appendingPathComponent(escapedID, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: modelRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                return true
            }
        }
        return false
    }

    /// Copy a verified regular-file snapshot into the durable store.
    func adoptVerifiedStaging(
        staging: URL,
        modelID: String,
        revision: String,
        sha256: String,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        beforePublish: () throws -> Void = {},
        didPublish: () throws -> Void = {}
    ) throws -> URL {
        let destination = try artifactURL(modelID: modelID, revision: revision, sha256: sha256)
        try ensureRoot()
        try validateNoSymlinkAncestors(of: destination, requireComplete: fileManager.fileExists(atPath: destination.path))
        if fileManager.fileExists(atPath: destination.path) {
            guard try ModelArtifactVerifier.canonicalArtifactHash(directory: destination) == sha256 else {
                // A corrupt published object can still be an incumbent/recovery reference.
                // Repair must never erase it as a side effect of preparation.
                throw AutotuneRecommendError.invalidArtifact("published artifact is corrupt; preserved for recovery")
            }
            try checkCancellation()
            try beforePublish()
            try didPublish()
            return destination
        }
        try copyRegularTree(from: staging, to: destination, expectedSHA256: sha256,
                            checkCancellation: checkCancellation, beforePublish: beforePublish, didPublish: didPublish)
        return destination
    }

    /// Transaction-owned copy stays unpublished until the caller refreshes authority.
    func stageVerifiedCopy(from source: URL, to temporary: URL, sha256: String,
                           checkCancellation: () throws -> Void) throws {
        try ensureRoot()
        try validateNoSymlinkAncestors(of: temporary, requireComplete: false)
        guard !fileManager.fileExists(atPath: temporary.path) else {
            throw AutotuneRecommendError.invalidArtifact("transaction copy already exists")
        }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw AutotuneRecommendError.invalidArtifact("source artifact is not a regular directory")
        }
        let sourceRoot = source.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(atPath: sourceRoot.path) else {
            throw AutotuneRecommendError.invalidArtifact("cannot enumerate artifact")
        }
        for case let relative as String in enumerator {
            try checkCancellation()
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw AutotuneRecommendError.invalidArtifact("unsafe relative artifact path")
            }
            let url = sourceRoot.appendingPathComponent(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw AutotuneRecommendError.invalidArtifact("artifact changed during copy") }
            if (info.st_mode & S_IFMT) == S_IFDIR { continue }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw AutotuneRecommendError.invalidArtifact("artifact contains unsafe file")
            }
            let target = temporary.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw AutotuneRecommendError.invalidArtifact("cannot open artifact") }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }
            let outputFD = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard outputFD >= 0 else { throw AutotuneRecommendError.invalidArtifact("cannot create copy") }
            let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
            defer { try? output.close() }
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                try checkCancellation(); try output.write(contentsOf: data)
            }
            try output.synchronize()
        }
        guard try ModelArtifactVerifier.canonicalArtifactHash(directory: temporary, checkCancellation: checkCancellation) == sha256 else {
            throw AutotuneRecommendError.invalidArtifact("copied artifact hash mismatch")
        }
        try checkCancellation()
    }

    func publishVerifiedCopy(_ temporary: URL, modelID: String, revision: String, sha256: String) throws -> URL {
        let destination = try artifactURL(modelID: modelID, revision: revision, sha256: sha256)
        try validateNoSymlinkAncestors(of: temporary, requireComplete: true)
        try validateNoSymlinkAncestors(of: destination, requireComplete: false)
        if fileManager.fileExists(atPath: destination.path) {
            guard try ModelArtifactVerifier.canonicalArtifactHash(directory: destination) == sha256 else {
                throw AutotuneRecommendError.invalidArtifact("published artifact corrupt; preserved")
            }
            return destination
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw AutotuneRecommendError.invalidArtifact("atomic artifact publication failed")
        }
        let fd = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw AutotuneRecommendError.invalidArtifact("publication sync failed") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw AutotuneRecommendError.invalidArtifact("publication sync failed") }
        return destination
    }

    /// Parent creation is outside the journal lock. Publication itself never hashes.
    func preparePublicationDirectory(_ destination: URL) throws -> Int32 {
        try ensureRoot()
        try validateNoSymlinkAncestors(of: destination, requireComplete: false)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validateNoSymlinkAncestors(of: destination.deletingLastPathComponent(), requireComplete: true)
        return try ModelCatalogArtifactSnapshot.openDirectory(destination.deletingLastPathComponent())
    }

    func publishSealedCopy(_ temporary: URL, destination: URL,
                           observation: ModelCatalogArtifactSnapshot.Observation, existing: Bool, destinationParent: Int32) throws -> URL {
        try observation.validatePlacement()
        if existing {
            var info = stat()
            guard fstatat(destinationParent, destination.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  ModelCatalogArtifactSnapshot.Identity(info) == observation.identity else { throw ModelCatalogTransactionError.invalidTransaction }
            return destination
        }
        // The owner has already verified the source object; an unexpected
        // incumbent wins the no-replace race and is preserved without hashing.
        guard renameatx_np(observation.parentFD, observation.name, destinationParent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw AutotuneRecommendError.invalidArtifact("atomic artifact publication failed")
        }
        guard fsync(destinationParent) == 0 else { throw AutotuneRecommendError.invalidArtifact("publication sync failed") }
        return destination
    }

    /// Remove inactive durable artifacts. Never deletes `keeping`.
    func gcInactive(keeping: Set<String>) throws {
        let rootPath = root.standardizedFileURL.path
        guard fileManager.fileExists(atPath: rootPath) else { return }
        let kept = Set(keeping.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        try validateNoSymlinkAncestors(of: root, requireComplete: true)
        try gcDirectory(root, keeping: kept)
    }

    private func gcDirectory(_ directory: URL, keeping: Set<String>) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            if entry.lastPathComponent.hasPrefix(".tmp-") {
                try? fileManager.removeItem(at: entry)
                continue
            }
            var st = stat()
            guard lstat(entry.path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                let path = entry.standardizedFileURL.path
                if !keeping.contains(path) {
                    try fileManager.removeItem(at: entry)
                }
                continue
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let path = entry.standardizedFileURL.path
            if keeping.contains(path) {
                continue
            }
            if keeping.contains(where: { $0.hasPrefix(path + "/") }) {
                try gcDirectory(entry, keeping: keeping)
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }

    /// Walk from the filesystem root with no-follow descriptors before any mutation.
    /// macOS exposes these system-owned aliases; arbitrary user symlinks are rejected.
    static func secureOwnedDirectory(_ url: URL) throws {
        try walkDirectory(url, create: true, requireComplete: true)
    }

    private static func walkDirectory(_ url: URL, create: Bool, requireComplete: Bool) throws {
        var path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
            break
        }
        guard path.hasPrefix("/"), path != "/" else {
            throw AutotuneRecommendError.invalidArtifact("unsafe storage root")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AutotuneRecommendError.invalidArtifact("cannot open filesystem root") }
        defer { close(descriptor) }
        for component in path.split(separator: "/").map(String.init) {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create {
                    if !requireComplete { return }
                    throw AutotuneRecommendError.invalidArtifact("storage directory is missing")
                }
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    throw AutotuneRecommendError.invalidArtifact("cannot create storage directory")
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                throw AutotuneRecommendError.invalidArtifact("symlink or unsafe storage directory")
            }
            close(descriptor); descriptor = next
        }
        if create {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), fchmod(descriptor, 0o700) == 0 else {
                throw AutotuneRecommendError.invalidArtifact("storage directory ownership is unsafe")
            }
        }
    }

    private func ensureRoot() throws {
        try Self.secureOwnedDirectory(root)
    }

    private func validateNoSymlinkAncestors(of url: URL, requireComplete: Bool) throws {
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw AutotuneRecommendError.invalidArtifact("durable path escapes artifact root")
        }
        try Self.walkDirectory(url, create: false, requireComplete: requireComplete)
    }

    private func copyRegularTree(
        from source: URL, to destination: URL, expectedSHA256: String,
        checkCancellation: () throws -> Void, beforePublish: () throws -> Void,
        didPublish: () throws -> Void
    ) throws {
        let destPath = destination.standardizedFileURL.path
        try validateNoSymlinkAncestors(of: destination.deletingLastPathComponent(), requireComplete: false)
        let rootPath = root.standardizedFileURL.path
        guard destPath == rootPath || destPath.hasPrefix(rootPath + "/") else {
            throw AutotuneRecommendError.invalidArtifact("durable destination escapes artifact root")
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: source)
            _ = inspection
            guard let enumerator = fileManager.enumerator(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: []
            ) else {
                throw AutotuneRecommendError.invalidArtifact("cannot enumerate staging artifact")
            }
            let basePath = source.resolvingSymlinksInPath().path
            for case let url as URL in enumerator {
                try checkCancellation()
                var statbuf = stat()
                guard lstat(url.path, &statbuf) == 0 else {
                    throw AutotuneRecommendError.invalidArtifact("lstat during durable copy")
                }
                if (statbuf.st_mode & S_IFMT) == S_IFLNK {
                    throw AutotuneRecommendError.invalidArtifact("symlink in staging artifact")
                }
                if (statbuf.st_mode & S_IFMT) == S_IFDIR {
                    continue
                }
                guard (statbuf.st_mode & S_IFMT) == S_IFREG else {
                    throw AutotuneRecommendError.invalidArtifact("non-regular file in staging artifact")
                }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(basePath + "/") else {
                    throw AutotuneRecommendError.invalidArtifact("path escape during durable copy")
                }
                let rel = String(path.dropFirst(basePath.count + 1))
                let target = staging.appendingPathComponent(rel)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                guard fileManager.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw AutotuneRecommendError.invalidArtifact("cannot create durable staging file")
                }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try checkCancellation()
                    try output.write(contentsOf: chunk)
                }
                try output.synchronize()
            }
            guard try ModelArtifactVerifier.canonicalArtifactHash(directory: staging) == expectedSHA256 else {
                throw AutotuneRecommendError.invalidArtifact("temporary durable artifact hash mismatch")
            }
            try checkCancellation()
            try beforePublish()
            try checkCancellation()
            // moveItem fails if another publisher created the immutable destination.
            // Never remove a published destination to make publication succeed.
            try fileManager.moveItem(at: staging, to: destination)
            try didPublish()
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func escapedComponent(_ value: String, label: String) throws -> String {
        let escaped = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "--")
        guard !escaped.isEmpty,
              !escaped.contains("\0"),
              !escaped.contains("/"),
              escaped != ".",
              escaped != "..",
              !escaped.contains("..")
        else {
            throw AutotuneRecommendError.invalidArtifact("unsafe durable \(label)")
        }
        return escaped
    }
}
