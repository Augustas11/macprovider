import CryptoKit
import Foundation
import MacProviderCore

// SPEC-010-R009 / SPEC-046-R009 `mlxlm_loopback` (#1690 M8): an external
// `mlx_lm.server` process serving a catalog MLX snapshot. The identity the CLI
// reports is the `macprovider.snapshot-manifest.v1` pair it computes itself
// over the operator-declared snapshot directory, with the native `mlx_cache`
// algorithm (`ModelArtifactVerifier.canonicalArtifactHash`). The runtime is
// bound to that directory by its `GET /v1/models` listing, and chat requests
// name `default_model`, so the runtime never loads another model by name.

/// Serve-time recognition of an `mlxlm_loopback` model ref (`mlxlm:<name>`).
enum MLXLMLoopbackServeModel {
    static let servedRefPrefix = "mlxlm:"
    static let runtimeSource = "mlxlm_loopback"
    /// mlx_lm.server's own default port. It is also the provider's serve port,
    /// so the `/v1/models` binding check refuses anything that does not list
    /// the declared snapshot.
    static let defaultOrigin = "http://127.0.0.1:8080"
    /// The model name mlx_lm.server maps to the model it was started with.
    static let upstreamModelName = "default_model"
    static let snapshotPathEnvironmentKey = "MACPROVIDER_MLXLM_MODEL_PATH"
    static let originEnvironmentKey = "MACPROVIDER_MLXLM_ORIGIN"
    static let maxModelsBodyBytes = 4 * 1024 * 1024

    static func isMLXLMLoopbackRef(_ ref: String?) -> Bool {
        guard let ref else { return false }
        return ref.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(servedRefPrefix)
    }

    /// `loopback_origin` config key, else `MACPROVIDER_MLXLM_ORIGIN`, else the
    /// mlx_lm.server default.
    static func resolveOrigin(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        LoopbackServeSelection.nonEmpty(configured)
            ?? LoopbackServeSelection.nonEmpty(environment[originEnvironmentKey])
            ?? defaultOrigin
    }

    /// The operator-declared snapshot directory, resolved and standardized.
    /// Nil when unset: there is then no identity leg, and serving fails closed.
    static func snapshotDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = LoopbackServeSelection.nonEmpty(environment[snapshotPathEnvironmentKey]), path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }

    /// The served ref for a snapshot directory: its last path component.
    static func servedModelRef(for directory: URL) -> String {
        servedRefPrefix + directory.lastPathComponent
    }

    /// True when the runtime's `GET /v1/models` lists `directory` (compared
    /// after resolving symlinks) as a model id. mlx_lm.server lists the model
    /// it was started with by its resolved path. Throws when the runtime is
    /// unreachable or does not answer 200 with a model list.
    static func listsSnapshot(
        _ client: any BYOMDiscoveryHTTPClient,
        origin: URL,
        directory: URL
    ) async throws -> Bool {
        let response = try await client.get(
            origin.appendingPathComponent("v1/models"),
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: maxModelsBodyBytes
        )
        guard response.statusCode == 200, let ids = modelIDs(from: response.body) else {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(runtimeSource)
        }
        let wanted = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return ids.contains { id in
            id.hasPrefix("/") && URL(fileURLWithPath: id).resolvingSymlinksInPath().standardizedFileURL.path == wanted
        }
    }

    /// The `data[].id` strings of an OpenAI `GET /v1/models` list, or nil when
    /// the body is not one.
    static func modelIDs(from data: Data) -> [String]? {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let models)? = root["data"]
        else { return nil }
        var ids: [String] = []
        for model in models {
            guard case .object(let object) = model, case .string(let id)? = object["id"] else { return nil }
            ids.append(id)
        }
        return ids
    }
}

enum MLXSnapshotIdentityError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case changedWhileHashing

    var description: String {
        switch self {
        case .unreadable(let reason):
            return "MLX snapshot directory is not a plain snapshot: \(reason)"
        case .changedWhileHashing:
            return "MLX snapshot changed while it was hashed; identity not reported (SPEC-010-R009(a))"
        }
    }
}

/// SPEC-010-R009(a): the snapshot-manifest pair of a local MLX snapshot plus
/// the file identity of every file it covers, so a later change fails closed
/// without re-hashing.
struct MLXSnapshotIdentity: Equatable, Sendable {
    struct FileStamp: Equatable, Sendable {
        let relativePath: String
        let size: Int64
        let device: Int64
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        /// The inode change time: any write updates it and no caller can set
        /// it, so an in-place rewrite that restores size and mtime still
        /// changes the stamp.
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(relativePath: String, info: stat) {
            self.relativePath = relativePath
            self.size = Int64(info.st_size)
            self.device = Int64(info.st_dev)
            self.inode = UInt64(info.st_ino)
            self.modifiedSeconds = info.st_mtimespec.tv_sec
            self.modifiedNanoseconds = info.st_mtimespec.tv_nsec
            self.changedSeconds = info.st_ctimespec.tv_sec
            self.changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// Resolved, standardized snapshot directory.
    let directory: URL
    /// `macprovider.snapshot-manifest.v1` digest (lowercase hex).
    let digest: String
    let files: [FileStamp]

    var algorithm: String { ModelArtifactIdentity.snapshotManifestV1 }

    /// Hashes the complete snapshot into the native `snapshot-manifest.v1`
    /// digest (the `ModelArtifactVerifier.canonicalArtifactHash` format:
    /// sorted `path\nsize\nsha256\n` lines). Each file is hashed over one
    /// descriptor opened with O_NOFOLLOW whose stamp (size, inode, mtime,
    /// ctime) must equal the directory listing's before and after the read,
    /// and the whole listing is re-read after hashing. A replaced, rewritten,
    /// added, or removed file fails closed (SPEC-010-R009(a)).
    static func compute(directory: URL, deadline: Date? = nil) throws -> MLXSnapshotIdentity {
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let before = try stamps(of: resolved)
        var manifest = ""
        for stamp in before {
            try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
            let sha = try hashFile(root: resolved, stamp: stamp, deadline: deadline)
            manifest += "\(stamp.relativePath)\n\(stamp.size)\n\(sha)\n"
        }
        guard try stamps(of: resolved) == before else {
            throw MLXSnapshotIdentityError.changedWhileHashing
        }
        let digest = Data(SHA256.hash(data: Data(manifest.utf8))).map { String(format: "%02x", $0) }.joined()
        return MLXSnapshotIdentity(directory: resolved, digest: digest, files: before)
    }

    private static func hashFile(root: URL, stamp: FileStamp, deadline: Date?) throws -> String {
        let path = root.path + "/" + stamp.relativePath
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MLXSnapshotIdentityError.unreadable("open failed") }
        defer { close(fd) }
        func current() throws -> FileStamp {
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink <= 1 else {
                throw MLXSnapshotIdentityError.unreadable("not a regular single-link file")
            }
            return FileStamp(relativePath: stamp.relativePath, info: info)
        }
        guard try current() == stamp else { throw MLXSnapshotIdentityError.changedWhileHashing }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        var total: Int64 = 0
        while true {
            try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw MLXSnapshotIdentityError.unreadable("read failed") }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            total += Int64(count)
        }
        guard total == stamp.size, try current() == stamp else { throw MLXSnapshotIdentityError.changedWhileHashing }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    /// True while every file still has the identity it had when hashed, and
    /// no file was added or removed.
    func isCurrent() -> Bool {
        (try? Self.stamps(of: directory)) == files
    }

    /// Every regular file under `root`, sorted by relative path. Symlinks,
    /// hardlinks and other file types fail, as in the canonical hash.
    static func stamps(of root: URL) throws -> [FileStamp] {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw MLXSnapshotIdentityError.unreadable("root is not a directory")
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            throw MLXSnapshotIdentityError.unreadable("cannot enumerate")
        }
        let base = root.path
        var out: [FileStamp] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else {
                throw MLXSnapshotIdentityError.unreadable("path escape")
            }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw MLXSnapshotIdentityError.unreadable("lstat failed")
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG where info.st_nlink <= 1:
                let relative = String(path.dropFirst(base.count + 1))
                try ModelArtifactRelativePathPolicy.validate(relative)
                out.append(FileStamp(relativePath: relative, info: info))
            default:
                throw MLXSnapshotIdentityError.unreadable("not a regular single-link file")
            }
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }
}

extension BYOMModelAdmissionRuntime {
    /// The `mlxlm_loopback` candidate `target` names (candidate id, served ref,
    /// or display name), when the operator configured the adapter. `models
    /// offer` dispatches on it, so every target form of an mlxlm candidate
    /// reaches `submitMLXLMOffer` and its snapshot-manifest leg.
    func mlxlmCandidate(target: String) async -> BYOMDiscoveryWire.Candidate? {
        guard let origin = environment.mlxlmOrigin, let directory = environment.mlxlmModelPath else { return nil }
        let namespace = BYOMDiscoveryNamespaceStore().readNamespace(at: environment.namespaceURL)
        let discovery = await BYOMMLXLMDiscovery(
            origin: origin,
            snapshotDirectory: directory,
            namespace: namespace.bytes,
            namespaceWarnings: namespace.warnings,
            httpClient: httpClient
        ).discover()
        return Self.selectCandidate(target: target, candidates: discovery.candidates)
    }

    /// SPEC-010-R009 / SPEC-046 v0.3.0 offer for an `mlxlm:` candidate (#1690
    /// M8; closes the #1486 gap for this runtime). The candidate comes from the
    /// `mlxlm_loopback` adapter only, and the offer always carries the
    /// snapshot-manifest pair the CLI computes over the declared snapshot. The
    /// snapshot must still be unchanged and listed by the runtime when the
    /// signed package leaves the machine; any failure fails the offer closed.
    func submitMLXLMOffer(
        providerID: String,
        target: String,
        evaluationDigestSHA256: String?,
        requestedDisclosureClass: String
    ) async throws -> BYOMAdmissionStatusWire {
        guard let client else {
            throw BYOMModelAdmissionError.missingCoordinatorURL
        }
        let namespaceStore = BYOMDiscoveryNamespaceStore()
        namespaceStore.provisionNamespaceIfMissing(at: environment.namespaceURL)
        guard let origin = environment.mlxlmOrigin,
              let directory = environment.mlxlmModelPath,
              let baseURL = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin)
        else {
            throw BYOMModelAdmissionError.candidateNotFound
        }
        let namespace = namespaceStore.readNamespace(at: environment.namespaceURL)
        let discovery = await BYOMMLXLMDiscovery(
            origin: origin,
            snapshotDirectory: directory,
            namespace: namespace.bytes,
            namespaceWarnings: namespace.warnings,
            httpClient: httpClient
        ).discover()
        guard let candidate = Self.selectCandidate(target: target, candidates: discovery.candidates) else {
            throw BYOMModelAdmissionError.candidateNotFound
        }
        guard let bearer = try credentialStore.load(providerID: providerID) else {
            throw BYOMModelAdmissionError.missingBearer(providerID: providerID)
        }
        guard let identity = try identityStore.loadAdmissionIdentity(providerId: providerID) else {
            throw BYOMModelAdmissionError.missingAdmissionIdentity(providerID: providerID)
        }
        let snapshot: MLXSnapshotIdentity
        do {
            snapshot = try MLXSnapshotIdentity.compute(
                directory: directory,
                deadline: Date().addingTimeInterval(Self.artifactHashBudgetSeconds)
            )
        } catch AutotuneContextCalibrationError.deadlineExceeded {
            throw BYOMModelAdmissionError.artifactHashingTimedOut
        } catch {
            throw BYOMModelAdmissionError.artifactIdentityChanged
        }
        let package = try BYOMOfferSubmissionBuilder.makePackage(
            providerID: providerID,
            candidate: candidate,
            admissionIdentity: identity,
            evaluationDigestSHA256: evaluationDigestSHA256,
            requestedDisclosureClass: requestedDisclosureClass,
            artifactHashes: [snapshot.algorithm: snapshot.digest]
        )
        guard snapshot.isCurrent(),
              (try? await MLXLMLoopbackServeModel.listsSnapshot(httpClient, origin: baseURL, directory: snapshot.directory)) == true
        else {
            throw BYOMModelAdmissionError.artifactIdentityChanged
        }
        return try await client.submitOffer(package, bearerToken: bearer)
    }
}
