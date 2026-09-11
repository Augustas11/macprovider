import CryptoKit
import Foundation
import MacProviderCore

/// SPEC-010 v1.7 R007(a): the `macprovider.gguf-file.v1` digest of a GGUF
/// artifact is the lowercase SHA-256 of the COMPLETE file bytes, computed by
/// the CLI over the bytes it holds locally — never a digest a runtime reports
/// about itself. An Ollama manifest's layer digest MAY locate the blob; it is
/// never reported.
enum GGUFArtifactDigest {
    static let magic = Data("GGUF".utf8)
    private static let chunkBytes = 1 << 20

    /// Streams the file through an ALREADY OPEN descriptor and returns the
    /// digest, so the caller binds the digest to the identity of the very
    /// file it read (`fstat` before and after) — never to a pathname that
    /// could resolve differently between opening and checking. There is
    /// deliberately no pathname entry point. Fails closed when the bytes do
    /// not start with the GGUF magic. `deadline` bounds the work: once it
    /// passes (checked between chunks, as is task cancellation) the
    /// incomplete digest is discarded and `hashingBudgetExceeded` is thrown.
    static func compute(handle: FileHandle, deadline: Date? = nil) throws -> String {
        var hasher = SHA256()
        var first = true
        while true {
            if Task.isCancelled || (deadline.map { Date() >= $0 } ?? false) {
                throw BYOMArtifactDigestError.hashingBudgetExceeded
            }
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            if first {
                guard chunk.count >= magic.count, chunk.prefix(magic.count) == magic else {
                    throw BYOMArtifactDigestError.notGGUF
                }
                first = false
            }
            hasher.update(data: chunk)
        }
        guard !first else { throw BYOMArtifactDigestError.notGGUF }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }
}

enum BYOMArtifactDigestError: Error, Equatable, CustomStringConvertible {
    case notGGUF
    case unresolvedBlob
    case fileIdentityChanged
    case hashingBudgetExceeded

    var description: String {
        switch self {
        case .notGGUF: return "artifact is not a GGUF file"
        case .unresolvedBlob: return "served model blob could not be resolved in the local Ollama store"
        case .fileIdentityChanged: return "artifact file changed between hashing and reporting; identity not reported (SPEC-010-R007(a))"
        case .hashingBudgetExceeded: return "artifact hashing exceeded its time budget; no digest recorded"
        }
    }
}

/// The identity of the exact file a digest was computed over: a later report
/// binds only while the file it resolved for the runtime instance is the same
/// (path, size, inode, modification time) — SPEC-010-R007(a).
struct BYOMArtifactFileIdentity: Codable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int
    let inode: UInt64
    let device: UInt64
    /// Modification time at the filesystem's own precision (seconds and
    /// nanoseconds from `stat`), so two same-size in-place rewrites are not
    /// one identity.
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case inode
        case device
        case modifiedSeconds = "modified_seconds"
        case modifiedNanoseconds = "modified_nanoseconds"
    }

    /// The identity the PATH currently resolves to.
    static func current(of url: URL) -> BYOMArtifactFileIdentity? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var status = stat()
        guard stat(resolved.path, &status) == 0 else { return nil }
        return from(status: status, path: resolved.path)
    }

    /// The identity of the file an OPEN descriptor refers to (`fstat`): the
    /// file actually being read, whatever the pathname resolves to now.
    static func of(descriptor: Int32, path: String) -> BYOMArtifactFileIdentity? {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return from(status: status, path: path)
    }

    private static func from(status: stat, path: String) -> BYOMArtifactFileIdentity? {
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else { return nil }
        return BYOMArtifactFileIdentity(
            path: path,
            sizeBytes: Int(status.st_size),
            inode: UInt64(status.st_ino),
            device: UInt64(status.st_dev),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }
}

/// A digest bound to the exact file it was computed over. An offer holds one
/// of these until the moment it submits, re-validating the binding then.
struct BYOMArtifactEvidence: Equatable, Sendable {
    let algorithm: String
    let digest: String
    let file: BYOMArtifactFileIdentity
    /// The manifest layer digest that LOCATED the blob (never reported).
    let locatorDigest: String

    var hashes: [String: String] { [algorithm: digest] }
}

/// SPEC-046-R002 / SPEC-010 v1.7 R007(a): a runtime-specific step that maps a
/// served model reference to the GGUF file on disk. Everything downstream —
/// opening the descriptor, binding the identity, streaming the digest, the
/// cache — is runtime-neutral and lives in `BYOMArtifactDigestResolver`.
///
/// Invariant every conformer keeps: the resolved file is a regular file
/// contained in a root the OPERATOR declared (never one the runtime named),
/// resolved through symlinks before the containment check, and identified by
/// a `locator` that is stable for the runtime instance so the resolver can
/// prove the reference still names the very file it hashed. Locators are never
/// reported as digests.
protocol BYOMGGUFArtifactLocator: Sendable {
    /// The SPEC-046-R002 adapter this locator serves (`ollama_loopback`, ...).
    var runtimeSource: String { get }
    /// `servedModelRef` is the candidate's `served_model_ref`, prefix and all.
    func resolveArtifact(servedModelRef: String) -> BYOMResolvedArtifact?
}

struct BYOMResolvedArtifact: Equatable, Sendable {
    /// Canonical (symlinks resolved) URL of the regular file to hash.
    let fileURL: URL
    /// Stable re-check token: the Ollama manifest layer digest, an LM Studio
    /// path relative to its models root, a llama.cpp canonical path. Compared
    /// verbatim by `validateCurrent`; never surfaced as a digest.
    let locator: String
}

/// Shared containment check: `url`, after resolving symlinks, must be `root`
/// or strictly beneath it. Used by every locator so a symlink or `..` cannot
/// escape the operator-declared root.
enum BYOMArtifactPathPolicy {
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        if target == base { return true }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

/// Locates the GGUF blob an Ollama model name is served from, in the local
/// Ollama store (`$OLLAMA_MODELS`, default `~/.ollama/models`): the manifest at
/// `manifests/registry.ollama.ai/<namespace>/<repo>/<tag>` names the model
/// layer, whose digest LOCATES `blobs/sha256-<hex>`. Filesystem only — no
/// network, no dereferencing anything the runtime reports beyond the name.
struct BYOMOllamaModelStore: BYOMGGUFArtifactLocator, Sendable {
    let runtimeSource = "ollama_loopback"
    let root: URL
    private let fileManager: FileManager
    private static let manifestMaxBytes = 256 * 1024
    private static let modelLayerMediaType = "application/vnd.ollama.image.model"
    private static let namePart = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let models = environment["OLLAMA_MODELS"], !models.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: models)
        }
        return homeDirectory.appendingPathComponent(".ollama/models", isDirectory: true)
    }

    struct ResolvedBlob: Equatable, Sendable {
        let manifestURL: URL
        let blobURL: URL
        /// The manifest's layer digest: a LOCATOR, never the reported digest.
        let locatorDigest: String
    }

    /// `name` is the served model name as the runtime reports it
    /// (`llama3.2:3b`, `ns/model:tag`); a missing tag is `latest`.
    func resolveModelBlob(name: String) -> ResolvedBlob? {
        guard let path = Self.manifestComponents(for: name) else { return nil }
        let manifestURL = path.reduce(root.appendingPathComponent("manifests/registry.ollama.ai", isDirectory: true)) { $0.appendingPathComponent($1) }
        guard let manifest = boundedFileContents(at: manifestURL, maxBytes: Self.manifestMaxBytes),
              let text = String(data: manifest, encoding: .utf8),
              case .object(let object)? = try? StrictJSONParser.parse(text),
              case .array(let layers)? = object["layers"]
        else {
            return nil
        }
        var locator: String?
        for layer in layers {
            guard case .object(let entry) = layer,
                  case .string(let mediaType)? = entry["mediaType"], mediaType == Self.modelLayerMediaType,
                  case .string(let digest)? = entry["digest"]
            else { continue }
            guard locator == nil else { return nil } // two model layers: ambiguous, no identity
            locator = digest
        }
        guard let locator, locator.hasPrefix("sha256:"), locator.count == 7 + 64,
              locator.dropFirst(7).allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
        else {
            return nil
        }
        let blobURL = root.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent("sha256-" + locator.dropFirst(7))
        let resolved = blobURL.resolvingSymlinksInPath()
        guard pathIsContained(resolved, in: root),
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else {
            return nil
        }
        return ResolvedBlob(manifestURL: manifestURL, blobURL: resolved, locatorDigest: locator)
    }

    static func manifestComponents(for name: String) -> [String]? {
        var reference = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.hasPrefix("ollama:") { reference = String(reference.dropFirst("ollama:".count)) }
        var tag = "latest"
        if let colon = reference.lastIndex(of: ":") {
            tag = String(reference[reference.index(after: colon)...])
            reference = String(reference[..<colon])
        }
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let components: [String]
        switch parts.count {
        case 1: components = ["library", parts[0], tag]
        case 2: components = [parts[0], parts[1], tag]
        default: return nil
        }
        for component in components {
            let range = NSRange(component.startIndex..., in: component)
            guard let match = namePart.firstMatch(in: component, range: range), match.range == range else { return nil }
        }
        return components
    }

    func resolveArtifact(servedModelRef: String) -> BYOMResolvedArtifact? {
        guard let blob = resolveModelBlob(name: servedModelRef) else { return nil }
        return BYOMResolvedArtifact(fileURL: blob.blobURL, locator: blob.locatorDigest)
    }

    private func pathIsContained(_ url: URL, in root: URL) -> Bool {
        BYOMArtifactPathPolicy.isContained(url, in: root)
    }

    private func boundedFileContents(at url: URL, maxBytes: Int) -> Data? {
        let resolved = url.resolvingSymlinksInPath()
        guard pathIsContained(resolved, in: root),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size >= 0, size <= maxBytes else {
            return nil
        }
        return try? Data(contentsOf: resolved)
    }
}

/// Locates the GGUF file an LM Studio model id is served from, in the local
/// LM Studio models directory (default `~/.lmstudio/models`, layout
/// `<publisher>/<repo>/<file>.gguf`). Filesystem only, from the NAME the
/// runtime reports — the same principle as `BYOMOllamaModelStore`: the runtime
/// never names the file that gets hashed.
///
/// Matching rule (v1, to be confirmed against a live LM Studio in the #1478
/// hardware pass and adjusted in `matches(id:publisher:repo:fileStem:)` alone):
/// the id equals, case-insensitively, one of `<publisher>/<repo>`, `<repo>`,
/// `<repo>` minus a trailing `-gguf`, or the file stem. Exactly ONE `.gguf`
/// file may answer; zero or several means no identity (fail closed, as an
/// Ollama manifest with two model layers does). MLX-format LM Studio models
/// have no `.gguf` and therefore never resolve here.
struct BYOMLMStudioModelStore: BYOMGGUFArtifactLocator, Sendable {
    let runtimeSource = "lmstudio_loopback"
    static let servedModelRefPrefix = "lmstudio:"
    let root: URL
    private let fileManager: FileManager
    /// Bounds the directory walk so a pathological models tree cannot turn a
    /// read-only discovery into a filesystem scan.
    private static let maxEntriesVisited = 8192
    private static let idPart = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}(/[A-Za-z0-9][A-Za-z0-9._-]{0,127})?$")

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        // LM Studio has no runtime-defined env var (unlike OLLAMA_MODELS); the
        // CLI-scoped override keeps the operator, not the runtime, in charge
        // of which tree may be hashed.
        if let models = environment["MACPROVIDER_LMSTUDIO_MODELS_ROOT"], !models.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: models)
        }
        return homeDirectory.appendingPathComponent(".lmstudio/models", isDirectory: true)
    }

    static func modelID(from servedModelRef: String) -> String? {
        var id = servedModelRef.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix(servedModelRefPrefix) { id = String(id.dropFirst(servedModelRefPrefix.count)) }
        let range = NSRange(id.startIndex..., in: id)
        guard let match = idPart.firstMatch(in: id, range: range), match.range == range else { return nil }
        return id
    }

    static func matches(id: String, publisher: String, repo: String, fileStem: String) -> Bool {
        let wanted = id.lowercased()
        let repoLower = repo.lowercased()
        var repoTrimmed = repoLower
        if repoTrimmed.hasSuffix("-gguf") { repoTrimmed.removeLast(5) }
        return wanted == "\(publisher.lowercased())/\(repoLower)"
            || wanted == repoLower
            || wanted == repoTrimmed
            || wanted == fileStem.lowercased()
    }

    func resolveArtifact(servedModelRef: String) -> BYOMResolvedArtifact? {
        guard let id = Self.modelID(from: servedModelRef) else { return nil }
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard let publishers = try? fileManager.contentsOfDirectory(at: rootResolved, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var visited = 0
        var hits: [(url: URL, relative: String)] = []
        for publisherURL in publishers {
            guard (try? publisherURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let publisher = publisherURL.lastPathComponent
            guard let repos = try? fileManager.contentsOfDirectory(at: publisherURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for repoURL in repos {
                visited += 1
                if visited > Self.maxEntriesVisited { return nil }
                guard (try? repoURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let repo = repoURL.lastPathComponent
                guard let files = try? fileManager.contentsOfDirectory(at: repoURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for fileURL in files {
                    visited += 1
                    if visited > Self.maxEntriesVisited { return nil }
                    guard fileURL.pathExtension.lowercased() == "gguf" else { continue }
                    let stem = fileURL.deletingPathExtension().lastPathComponent
                    guard Self.matches(id: id, publisher: publisher, repo: repo, fileStem: stem) else { continue }
                    let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
                    guard BYOMArtifactPathPolicy.isContained(resolved, in: rootResolved),
                          (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    else { continue }
                    hits.append((resolved, "\(publisher)/\(repo)/\(fileURL.lastPathComponent)"))
                }
            }
        }
        // One file answers or none does: several matching GGUFs (e.g. every
        // quantization of a repo when the id names the repo) is ambiguous and
        // must not pick silently.
        guard hits.count == 1, let hit = hits.first else { return nil }
        return BYOMResolvedArtifact(fileURL: hit.url, locator: hit.relative)
    }
}

/// Locates the GGUF file a llama.cpp `llama-server` model is served from,
/// under an OPERATOR-declared root (`--llamacpp-model-root` /
/// `MACPROVIDER_LLAMACPP_MODEL_ROOT`; no default). Filesystem only, from the
/// NAME.
///
/// Why a name and not the path llama-server reports: `llama-server` exposes
/// the loaded file's path both as the `/v1/models` id (absent `--alias`) and
/// as `/props.model_path`. Adopting either would let the runtime choose which
/// file gets recorded as artifact evidence (#1478 `harm:supply`), and the
/// #1246 harness already refuses any served reference containing `/` so a
/// filesystem path never reaches `candidate_id`, display names or evidence
/// JSON. So the adapter reduces the id to its file stem (`foo-q4_k_m` for
/// `/x/models/foo-q4_k_m.gguf`), and this store resolves that stem to exactly
/// one `<stem>.gguf` under the root, one or two levels deep, symlink-resolved
/// and root-contained. No root, an aliased server whose alias names no file,
/// or several files with that stem ⇒ no identity (`runtime_reported`).
struct BYOMLlamaCppModelStore: BYOMGGUFArtifactLocator, Sendable {
    let runtimeSource = "llamacpp_loopback"
    static let servedModelRefPrefix = "llamacpp:"
    /// nil ⇒ the operator declared no root ⇒ nothing is ever hashed.
    let root: URL?
    private let fileManager: FileManager
    private static let maxEntriesVisited = 8192
    private static let stemPart = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$")

    init(root: URL?, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let models = environment["MACPROVIDER_LLAMACPP_MODEL_ROOT"], !models.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: models)
        }
        return nil
    }

    /// The served reference the adapter emits for a llama-server model id:
    /// a path-shaped id becomes its file stem, anything else is kept as-is.
    /// The harness's safe-reference check runs on the result, not here.
    static func stem(fromRuntimeModelID id: String) -> String {
        var value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("/") {
            value = (value as NSString).lastPathComponent
        }
        if value.lowercased().hasSuffix(".gguf") { value.removeLast(5) }
        return value
    }

    static func stem(from servedModelRef: String) -> String? {
        var value = servedModelRef.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(servedModelRefPrefix) { value = String(value.dropFirst(servedModelRefPrefix.count)) }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = stemPart.firstMatch(in: value, range: range), match.range == range else { return nil }
        return value
    }

    func resolveArtifact(servedModelRef: String) -> BYOMResolvedArtifact? {
        guard let root, let stem = Self.stem(from: servedModelRef) else { return nil }
        let wanted = stem.lowercased()
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        var visited = 0
        var hits: [(url: URL, relative: String)] = []
        func consider(_ fileURL: URL, relative: String) {
            guard fileURL.pathExtension.lowercased() == "gguf",
                  fileURL.deletingPathExtension().lastPathComponent.lowercased() == wanted
            else { return }
            let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard BYOMArtifactPathPolicy.isContained(resolved, in: rootResolved),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return }
            hits.append((resolved, relative))
        }
        guard let top = try? fileManager.contentsOfDirectory(at: rootResolved, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for entry in top {
            visited += 1
            if visited > Self.maxEntriesVisited { return nil }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                guard let inner = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for fileURL in inner {
                    visited += 1
                    if visited > Self.maxEntriesVisited { return nil }
                    consider(fileURL, relative: "\(entry.lastPathComponent)/\(fileURL.lastPathComponent)")
                }
            } else {
                consider(entry, relative: entry.lastPathComponent)
            }
        }
        guard hits.count == 1, let hit = hits.first else { return nil }
        return BYOMResolvedArtifact(fileURL: hit.url, locator: hit.relative)
    }
}

/// Digests already computed over local artifact bytes, keyed by the exact
/// file identity, so discovery (read-only, cheap) can report
/// `artifact_hash_available` / match by digest without re-hashing gigabytes.
/// A binding report (offer) always recomputes (SPEC-010-R007(a)).
struct BYOMArtifactDigestCache: Sendable {
    let url: URL
    private let fileManager: FileManager

    struct Entry: Codable, Equatable, Sendable {
        let file: BYOMArtifactFileIdentity
        let algorithm: String
        let digest: String
        let computedAt: String

        enum CodingKeys: String, CodingKey {
            case file, algorithm, digest
            case computedAt = "computed_at"
        }
    }

    private struct Document: Codable {
        var schema: String
        var entries: [Entry]
    }

    static let schema = "byom_artifact_digest_cache.v1"

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    static func defaultURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".config/macprovider", isDirectory: true)
            .appendingPathComponent("byom", isDirectory: true)
            .appendingPathComponent("artifact-digests.json")
    }

    /// A cached digest drives ONLY the read-only discovery view
    /// (`identity_state`, the advisory `catalog_model_key`). Every report that
    /// binds identity (`models offer`) recomputes over the bytes and never
    /// reads this cache, and the coordinator resolves the key from the hash
    /// against the signed feed (SPEC-047-R003: the asserted key is advisory),
    /// so a tampered entry can at most mislabel local output — it cannot
    /// produce a false binding report.
    func lookup(_ identity: BYOMArtifactFileIdentity, algorithm: String) -> String? {
        load().entries.first { $0.file == identity && $0.algorithm == algorithm }?.digest
    }

    func store(_ identity: BYOMArtifactFileIdentity, algorithm: String, digest: String, now: Date = Date()) {
        var document = load()
        document.entries.removeAll { $0.file.path == identity.path && $0.algorithm == algorithm }
        document.entries.append(Entry(file: identity, algorithm: algorithm, digest: digest, computedAt: ModelSwitchingWireCodec.timestamp(now)))
        document.entries.sort { ($0.file.path, $0.algorithm) < ($1.file.path, $1.algorithm) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(document) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".artifact-digests.\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? fileManager.replaceItemAt(url, withItemAt: temporary)
        // replaceItemAt keeps an existing destination's mode; the published
        // file (absolute paths inside) is private regardless of what was there.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func load() -> Document {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schema == Self.schema
        else {
            return Document(schema: Self.schema, entries: [])
        }
        return document
    }
}

/// The CLI's one path from a served Ollama model name to a
/// `macprovider.gguf-file.v1` digest: resolve the blob, hash the complete
/// bytes, and bind the result to the exact file identity.
struct BYOMArtifactDigestResolver: Sendable {
    /// Locators keyed by `runtime_source`. A runtime with no locator has no
    /// artifact leg: `knownDigest` is nil and `computeEvidence` throws
    /// `unresolvedBlob`, exactly as an unresolvable Ollama name does.
    private let locators: [String: any BYOMGGUFArtifactLocator]
    let cache: BYOMArtifactDigestCache

    /// The Ollama store, kept addressable for callers that predate the
    /// locator protocol.
    var store: BYOMOllamaModelStore {
        locators["ollama_loopback"] as! BYOMOllamaModelStore
    }

    init(locators: [any BYOMGGUFArtifactLocator], cache: BYOMArtifactDigestCache) {
        var table: [String: any BYOMGGUFArtifactLocator] = [:]
        for locator in locators {
            precondition(table[locator.runtimeSource] == nil, "duplicate locator for \(locator.runtimeSource)")
            table[locator.runtimeSource] = locator
        }
        self.locators = table
        self.cache = cache
    }

    init(store: BYOMOllamaModelStore, cache: BYOMArtifactDigestCache) {
        self.init(locators: [store], cache: cache)
    }

    // MARK: Runtime-neutral entry points

    /// Discovery-time: a digest previously computed over the SAME file (path,
    /// size, inode, mtime), or nil. Never hashes.
    func knownDigest(runtimeSource: String, servedModelRef: String) -> String? {
        guard let artifact = locators[runtimeSource]?.resolveArtifact(servedModelRef: servedModelRef),
              let identity = BYOMArtifactFileIdentity.current(of: artifact.fileURL)
        else {
            return nil
        }
        return cache.lookup(identity, algorithm: ModelArtifactIdentity.ggufFileV1)
    }

    /// Binding-time: recompute over the complete bytes, fail closed if the
    /// file's identity changed while hashing, record the result, and return
    /// the digest BOUND to the file so the caller can re-validate right
    /// before it reports (SPEC-010-R007(a)).
    ///
    /// The file is opened ONCE; the identity is taken from that descriptor
    /// (`fstat`) before and after hashing, so the digest is bound to the file
    /// that was actually read. The pathname is then re-resolved and must name
    /// that same file: a path that pointed elsewhere while it was opened, or
    /// a file rewritten while it was read, fails closed. `deadline` bounds
    /// the hashing; on expiry nothing is recorded.
    func computeEvidence(runtimeSource: String, servedModelRef: String, deadline: Date? = nil) throws -> BYOMArtifactEvidence {
        guard let artifact = locators[runtimeSource]?.resolveArtifact(servedModelRef: servedModelRef) else {
            throw BYOMArtifactDigestError.unresolvedBlob
        }
        let path = artifact.fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw BYOMArtifactDigestError.unresolvedBlob
        }
        defer { try? handle.close() }
        guard let before = BYOMArtifactFileIdentity.of(descriptor: handle.fileDescriptor, path: path) else {
            throw BYOMArtifactDigestError.unresolvedBlob
        }
        let digest = try GGUFArtifactDigest.compute(handle: handle, deadline: deadline)
        guard BYOMArtifactFileIdentity.of(descriptor: handle.fileDescriptor, path: path) == before else {
            throw BYOMArtifactDigestError.fileIdentityChanged
        }
        let evidence = BYOMArtifactEvidence(algorithm: ModelArtifactIdentity.ggufFileV1, digest: digest, file: before, locatorDigest: artifact.locator)
        try validateCurrent(evidence, runtimeSource: runtimeSource, servedModelRef: servedModelRef)
        cache.store(before, algorithm: evidence.algorithm, digest: digest)
        return evidence
    }

    func computeDigest(runtimeSource: String, servedModelRef: String, deadline: Date? = nil) throws -> String {
        try computeEvidence(runtimeSource: runtimeSource, servedModelRef: servedModelRef, deadline: deadline).digest
    }

    /// The reference must STILL resolve — through the runtime's locator — to
    /// the very file the digest was computed over, with an unchanged identity:
    /// a reference retargeted to another file, or a file rewritten in place,
    /// fails closed.
    func validateCurrent(_ evidence: BYOMArtifactEvidence, runtimeSource: String, servedModelRef: String) throws {
        guard let artifact = locators[runtimeSource]?.resolveArtifact(servedModelRef: servedModelRef),
              artifact.locator == evidence.locatorDigest,
              let now = BYOMArtifactFileIdentity.current(of: artifact.fileURL),
              now == evidence.file
        else {
            throw BYOMArtifactDigestError.fileIdentityChanged
        }
    }

    // MARK: Ollama-named shims (pre-#1478 call sites and tests)

    func knownDigest(forOllamaModel name: String) -> String? {
        knownDigest(runtimeSource: "ollama_loopback", servedModelRef: name)
    }

    func computeEvidence(forOllamaModel name: String, deadline: Date? = nil) throws -> BYOMArtifactEvidence {
        try computeEvidence(runtimeSource: "ollama_loopback", servedModelRef: name, deadline: deadline)
    }

    func computeDigest(forOllamaModel name: String, deadline: Date? = nil) throws -> String {
        try computeDigest(runtimeSource: "ollama_loopback", servedModelRef: name, deadline: deadline)
    }

    func validateCurrent(_ evidence: BYOMArtifactEvidence, forOllamaModel name: String) throws {
        try validateCurrent(evidence, runtimeSource: "ollama_loopback", servedModelRef: name)
    }
}
