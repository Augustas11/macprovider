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

    /// The serve-time snapshot hashing deadline: the same budget the BYOM
    /// offer path gives artifact hashing, so startup fails closed instead of
    /// blocking on a large or slow snapshot.
    static func snapshotHashingDeadline(now: Date = Date()) -> Date {
        now.addingTimeInterval(BYOMModelAdmissionRuntime.artifactHashBudgetSeconds)
    }

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

    /// The port docs and help recommend for mlx_lm.server on a provider Mac,
    /// whose own `serve` already holds mlx_lm.server's default 8080.
    static let recommendedOrigin = "http://127.0.0.1:8081"

    /// Origins `models discover` probes when MACPROVIDER_MLXLM_MODEL_PATH is
    /// unset: the operator's MACPROVIDER_MLXLM_ORIGIN alone, else the
    /// mlx_lm.server default and the recommended non-clashing port. A port
    /// the provider's own serve listens on is never probed.
    static func discoveryOrigins(configured: String?, excludingPort servePort: Int? = nil) -> [String] {
        if let configured = LoopbackServeSelection.nonEmpty(configured) { return [configured] }
        return [defaultOrigin, recommendedOrigin].filter { origin in
            guard let servePort else { return true }
            return URL(string: origin)?.port != servePort
        }
    }

    /// Where an auto-detected snapshot may live: serve's durable model store
    /// and the Hugging Face hub cache's `models--*/snapshots/<revision>`
    /// directories. A directory reported by a loopback server is only
    /// accepted inside them after symlinks are resolved; anything else must
    /// be named explicitly in MACPROVIDER_MLXLM_MODEL_PATH.
    struct ApprovedSnapshotRoots: Equatable, Sendable {
        let durableModelRoot: URL
        let hubCacheRoot: URL

        static func `default`(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> ApprovedSnapshotRoots {
            ApprovedSnapshotRoots(
                durableModelRoot: BYOMDiscoveryEnvironment.defaultDurableModelRoot(environment: environment, homeDirectory: homeDirectory),
                hubCacheRoot: BYOMDiscoveryEnvironment.defaultMLXCacheRoot(environment: environment, homeDirectory: homeDirectory)
            )
        }

        func contains(_ directory: URL) -> Bool {
            let dir = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let durable = durableModelRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            if dir.count > durable.count, Array(dir.prefix(durable.count)) == durable {
                return true
            }
            let hub = hubCacheRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return dir.count == hub.count + 3
                && Array(dir.prefix(hub.count)) == hub
                && dir[hub.count].hasPrefix("models--")
                && dir[hub.count + 1] == "snapshots"
        }
    }

    /// What a running mlx_lm.server's model list names.
    enum SnapshotInference: Equatable {
        /// No server, no list, or not exactly one listed local directory.
        case none
        case found(URL)
        /// Exactly one listed directory, outside the approved roots.
        case outsideApprovedRoots(URL)
    }

    /// The snapshot directory a running mlx_lm.server was started with.
    /// mlx_lm.server lists its `--model` path, resolved, beside the repo ids
    /// of every MLX model in the HF cache; only that absolute path names the
    /// loaded model, so exactly one listed existing directory is required. A
    /// macprovider `serve` on the same port lists catalog ids and yields none.
    /// Any loopback process can answer this list, so the directory is only
    /// accepted inside `roots` once symlinks are resolved.
    static func inferSnapshotDirectory(_ client: any BYOMDiscoveryHTTPClient, origin: URL, roots: ApprovedSnapshotRoots) async -> SnapshotInference {
        guard let response = try? await client.get(
            origin.appendingPathComponent("v1/models"),
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: maxModelsBodyBytes
        ), response.statusCode == 200, let ids = modelIDs(from: response.body) else {
            return .none
        }
        var directories = Set<URL>()
        for id in ids where id.hasPrefix("/") {
            let url = URL(fileURLWithPath: id, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.insert(url)
            }
        }
        guard directories.count == 1, let directory = directories.first else { return .none }
        return roots.contains(directory) ? .found(directory) : .outsideApprovedRoots(directory)
    }

    /// The error serve answers when MACPROVIDER_MLXLM_MODEL_PATH is unset and
    /// no running mlx_lm.server reports a local snapshot path.
    static let undetectedSnapshotMessage = "\(snapshotPathEnvironmentKey) is unset and no mlx_lm.server on the loopback origin lists a local snapshot directory. A server started with a Hugging Face repo id is not supported: start it with `mlx_lm.server --model <path written by macprovider-cli models prepare> --host 127.0.0.1 --port 8081` (and loopback_origin: http://127.0.0.1:8081), or set \(snapshotPathEnvironmentKey) to the served snapshot directory"

    /// Serve's mlx_lm.server target: the declared snapshot directory with the
    /// configured origin, else the first probe origin (`loopback_origin`, then
    /// MACPROVIDER_MLXLM_ORIGIN, then 8080 and 8081, skipping serve's own
    /// port) whose server lists one local snapshot path inside the approved
    /// roots. A malformed declared path or a detected directory outside the
    /// roots is an error, never a fallback. The serve-time binding check
    /// still runs on the result.
    static func serveTarget(
        configuredOrigin: String?,
        client: any BYOMDiscoveryHTTPClient,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        servePort: Int? = nil,
        roots: ApprovedSnapshotRoots? = nil
    ) async throws -> (origin: String, directory: URL?) {
        let resolved = resolveOrigin(configured: configuredOrigin, environment: environment)
        switch snapshotPathSetting(environment: environment) {
        case .invalid(let path):
            throw MLXLMSnapshotSelectionError.invalidDeclaredPath(path)
        case .declared(let directory):
            return (resolved, directory)
        case .unset:
            break
        }
        let roots = roots ?? .default(environment: environment)
        let explicit = LoopbackServeSelection.nonEmpty(configuredOrigin) ?? LoopbackServeSelection.nonEmpty(environment[originEnvironmentKey])
        for origin in discoveryOrigins(configured: explicit, excludingPort: servePort) {
            guard let baseURL = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else { continue }
            switch await inferSnapshotDirectory(client, origin: baseURL, roots: roots) {
            case .none:
                continue
            case .found(let directory):
                servingSnapshot.set(directory)
                return (origin, directory)
            case .outsideApprovedRoots(let directory):
                throw MLXLMSnapshotSelectionError.outsideApprovedRoots(origin: origin, directory: directory.path)
            }
        }
        return (resolved, nil)
    }

    /// The snapshot directory serve bound to: declared, else inferred at
    /// startup. Pool usage recounts read it.
    static func servingSnapshotDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        snapshotDirectory(environment: environment) ?? servingSnapshot.get()
    }

    private static let servingSnapshot = MLXLMServingSnapshotBox()

    /// MACPROVIDER_MLXLM_MODEL_PATH as the operator set it.
    enum SnapshotPathSetting: Equatable {
        /// Absent or blank: auto-detection may run.
        case unset
        case declared(URL)
        /// Set but not an absolute path: a configuration error, never unset.
        case invalid(String)
    }

    static func snapshotPathSetting(environment: [String: String] = ProcessInfo.processInfo.environment) -> SnapshotPathSetting {
        guard let path = LoopbackServeSelection.nonEmpty(environment[snapshotPathEnvironmentKey]) else { return .unset }
        guard path.hasPrefix("/") else { return .invalid(path) }
        return .declared(URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL)
    }

    /// The operator-declared snapshot directory, resolved and standardized.
    /// Nil when unset or invalid: there is then no identity leg, and serving
    /// fails closed.
    static func snapshotDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if case .declared(let directory) = snapshotPathSetting(environment: environment) { return directory }
        return nil
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

/// Why the CLI will not pick an mlx_lm.server snapshot on its own.
enum MLXLMSnapshotSelectionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidDeclaredPath(String)
    case outsideApprovedRoots(origin: String, directory: String)

    var description: String {
        switch self {
        case .invalidDeclaredPath(let path):
            return "\(MLXLMLoopbackServeModel.snapshotPathEnvironmentKey) is set to \"\(path)\", which is not an absolute path; set it to the absolute snapshot directory mlx_lm.server serves, or unset it to auto-detect"
        case .outsideApprovedRoots(let origin, let directory):
            return "the server on \(origin) lists \(directory), which is outside the provider model store and the Hugging Face hub cache snapshots, so it is not used automatically; if that is the snapshot you serve, set \(MLXLMLoopbackServeModel.snapshotPathEnvironmentKey)=\(directory)"
        }
    }

    var errorDescription: String? { description }
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
        let before = try stamps(of: resolved, deadline: deadline)
        var manifest = ""
        for stamp in before {
            try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
            let sha = try hashFile(root: resolved, stamp: stamp, deadline: deadline)
            manifest += "\(stamp.relativePath)\n\(stamp.size)\n\(sha)\n"
        }
        guard try stamps(of: resolved, deadline: deadline) == before else {
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

    /// Wall-clock budget for one per-request revalidation (`isCurrent`).
    static let revalidationBudgetSeconds: TimeInterval = 5
    /// Upper bound on the regular files one snapshot may hold; a larger tree
    /// is refused rather than walked without end.
    static let maxSnapshotFiles = 100_000

    /// True while every file still has the identity it had when hashed, and
    /// no file was added or removed. Bounded: the walk stops, and the answer
    /// is false (fail closed), once it passes `deadline` or sees more regular
    /// files than were hashed.
    func isCurrent(deadline: Date = Date().addingTimeInterval(MLXSnapshotIdentity.revalidationBudgetSeconds)) -> Bool {
        (try? Self.stamps(of: directory, deadline: deadline, maxFiles: files.count)) == files
    }

    /// Every regular file under `root`, sorted by relative path. Symlinks,
    /// hardlinks and other file types fail, as in the canonical hash. The walk
    /// checks `deadline` at every entry and once more at the end, and fails
    /// when it sees more than `maxFiles` regular files.
    static func stamps(of root: URL, deadline: Date?, maxFiles: Int = maxSnapshotFiles) throws -> [FileStamp] {
        try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
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
            try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
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
                guard out.count < maxFiles else {
                    throw MLXSnapshotIdentityError.unreadable("more than \(maxFiles) files")
                }
                out.append(FileStamp(relativePath: relative, info: info))
            default:
                throw MLXSnapshotIdentityError.unreadable("not a regular single-link file")
            }
        }
        try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
        return out.sorted { $0.relativePath < $1.relativePath }
    }
}

extension BYOMModelAdmissionRuntime {
    /// The `mlxlm_loopback` or (#1690 M9) `omlx_loopback` candidate `target`
    /// names (candidate id, served ref, or display name), when the operator
    /// configured that adapter. `models offer` dispatches on it, so every
    /// target form of such a candidate reaches `submitMLXLMOffer` and its
    /// snapshot-manifest leg.
    func mlxlmCandidate(target: String) async -> BYOMDiscoveryWire.Candidate? {
        await mlxSnapshotCandidate(target: target)?.candidate
    }

    private func mlxSnapshotCandidate(
        target: String
    ) async -> (candidate: BYOMDiscoveryWire.Candidate, kind: MLXSnapshotLoopbackKind, origin: String, directory: URL)? {
        let namespace = BYOMDiscoveryNamespaceStore().readNamespace(at: environment.namespaceURL)
        for loopback in environment.mlxSnapshotLoopbacks {
            let discovery = await BYOMMLXLMDiscovery(
                origin: loopback.origin,
                snapshotDirectory: loopback.directory,
                namespace: namespace.bytes,
                namespaceWarnings: namespace.warnings,
                httpClient: httpClient,
                kind: loopback.kind
            ).discover()
            if let candidate = Self.selectCandidate(target: target, candidates: discovery.candidates) {
                return (candidate, loopback.kind, loopback.origin, loopback.directory)
            }
        }
        return nil
    }

    /// SPEC-010-R009 / SPEC-046 v0.3.0 offer for an `mlxlm:` candidate (#1690
    /// M8; closes the #1486 gap for this runtime), and (v0.5.0, #1690 M9) for
    /// an `omlx:` candidate. The candidate comes from that runtime's adapter
    /// only, and the offer always carries the
    /// snapshot-manifest pair the CLI computes over the declared snapshot. The
    /// snapshot must still be unchanged and listed by the runtime when the
    /// signed package leaves the machine; any failure fails the offer closed.
    func submitMLXLMOffer(
        providerID: String,
        target: String,
        evaluationDigestSHA256: String?,
        requestedDisclosureClass: String
    ) async throws -> BYOMAdmissionStatusWire {
        try await submitMLXLMOfferDetailed(
            providerID: providerID,
            target: target,
            evaluationDigestSHA256: evaluationDigestSHA256,
            requestedDisclosureClass: requestedDisclosureClass
        ).status
    }

    /// #1816 `models propose` without submitting: the candidate and its
    /// snapshot-manifest pair, computed over the declared snapshot exactly as
    /// the offer computes it.
    func mlxSnapshotProposalArtifact(
        target: String
    ) async throws -> (candidate: BYOMDiscoveryWire.Candidate, artifactHashes: [String: String]) {
        BYOMDiscoveryNamespaceStore().provisionNamespaceIfMissing(at: environment.namespaceURL)
        guard let found = await mlxSnapshotCandidate(target: target) else {
            throw BYOMModelAdmissionError.candidateNotFound
        }
        let snapshot: MLXSnapshotIdentity
        do {
            snapshot = try MLXSnapshotIdentity.compute(
                directory: found.directory,
                deadline: Date().addingTimeInterval(Self.artifactHashBudgetSeconds)
            )
        } catch AutotuneContextCalibrationError.deadlineExceeded {
            throw BYOMModelAdmissionError.artifactHashingTimedOut
        } catch {
            throw BYOMModelAdmissionError.artifactIdentityChanged
        }
        return (found.candidate, [snapshot.algorithm: snapshot.digest])
    }

    /// `submitMLXLMOffer`, also returning the candidate and the exact
    /// snapshot-manifest pair the signed offer carried.
    func submitMLXLMOfferDetailed(
        providerID: String,
        target: String,
        evaluationDigestSHA256: String?,
        requestedDisclosureClass: String
    ) async throws -> (status: BYOMAdmissionStatusWire, candidate: BYOMDiscoveryWire.Candidate, artifactHashes: [String: String]) {
        guard let client else {
            throw BYOMModelAdmissionError.missingCoordinatorURL
        }
        let namespaceStore = BYOMDiscoveryNamespaceStore()
        namespaceStore.provisionNamespaceIfMissing(at: environment.namespaceURL)
        guard let found = await mlxSnapshotCandidate(target: target),
              let baseURL = BYOMLoopbackOriginValidator.validatedHTTPOrigin(found.origin)
        else {
            throw BYOMModelAdmissionError.candidateNotFound
        }
        let (candidate, kind, directory) = (found.candidate, found.kind, found.directory)
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
            artifactHashes: [snapshot.algorithm: snapshot.digest],
            requestedPoolModelID: requestedPoolModelID
        )
        guard snapshot.isCurrent(),
              (try? await kind.listedModelName(httpClient, origin: baseURL, directory: snapshot.directory)) != nil
        else {
            throw BYOMModelAdmissionError.artifactIdentityChanged
        }
        let status = try await client.submitOffer(package, bearerToken: bearer)
        return (status, candidate, [snapshot.algorithm: snapshot.digest])
    }
}

private final class MLXLMServingSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?

    func set(_ url: URL) { lock.lock(); value = url; lock.unlock() }
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return value }
}
