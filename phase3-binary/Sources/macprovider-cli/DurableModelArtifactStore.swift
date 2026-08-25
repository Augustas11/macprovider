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
        sha256: String
    ) throws -> URL {
        let destination = try artifactURL(modelID: modelID, revision: revision, sha256: sha256)
        try ensureRoot()
        try validateNoSymlinkAncestors(
            of: destination,
            requireComplete: fileManager.fileExists(atPath: destination.path)
        )
        if fileManager.fileExists(atPath: destination.path) {
            let existing: String?
            do {
                existing = try ModelArtifactVerifier.canonicalArtifactHash(directory: destination)
            } catch {
                existing = nil
            }
            if existing != sha256 {
                try fileManager.removeItem(at: destination)
                try copyRegularTree(from: staging, to: destination)
            }
        } else {
            try copyRegularTree(from: staging, to: destination)
        }
        let actual = try ModelArtifactVerifier.canonicalArtifactHash(directory: destination)
        guard actual == sha256 else {
            throw AutotuneRecommendError.invalidArtifact(
                "durable artifact hash mismatch expected=\(sha256) actual=\(actual)"
            )
        }
        return destination
    }

    /// Remove inactive durable artifacts. Never deletes `keeping`.
    func gcInactive(keeping: Set<String>) throws {
        let rootPath = root.standardizedFileURL.path
        guard fileManager.fileExists(atPath: rootPath) else { return }
        let kept = Set(keeping.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
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

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var st = stat()
        guard lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw AutotuneRecommendError.invalidArtifact("durable artifact root is not a directory")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: root.path
        )
    }

    private func validateNoSymlinkAncestors(of url: URL, requireComplete: Bool) throws {
        let rootURL = root.standardizedFileURL
        var rootStat = stat()
        if lstat(rootURL.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFLNK {
            throw AutotuneRecommendError.invalidArtifact("durable artifact root must not be a symlink")
        }
        let rootPath = rootURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw AutotuneRecommendError.invalidArtifact("durable path escapes artifact root")
        }
        var current = rootURL
        let relative = targetPath.dropFirst(rootPath.count).split(separator: "/").map(String.init)
        for component in relative where !component.isEmpty {
            current.appendPathComponent(component)
            var st = stat()
            if lstat(current.path, &st) != 0 {
                if requireComplete {
                    throw AutotuneRecommendError.invalidArtifact("durable path is missing")
                }
                return
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                throw AutotuneRecommendError.invalidArtifact("symlink in durable path")
            }
        }
    }

    private func copyRegularTree(from source: URL, to destination: URL) throws {
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
                try fileManager.copyItem(at: url, to: target)
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
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
