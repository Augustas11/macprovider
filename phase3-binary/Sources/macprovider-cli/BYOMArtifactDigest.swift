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

    /// Streams the file and returns the digest. Fails closed when the file is
    /// not a regular readable file or does not start with the GGUF magic.
    static func compute(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var first = true
        while true {
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

    var description: String {
        switch self {
        case .notGGUF: return "artifact is not a GGUF file"
        case .unresolvedBlob: return "served model blob could not be resolved in the local Ollama store"
        case .fileIdentityChanged: return "artifact file changed between hashing and reporting; identity not reported (SPEC-010-R007(a))"
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
    let modifiedUnixMS: Int64

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case inode
        case modifiedUnixMS = "modified_unix_ms"
    }

    static func current(of url: URL, fileManager: FileManager = .default) -> BYOMArtifactFileIdentity? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return BYOMArtifactFileIdentity(path: resolved.path, sizeBytes: size, inode: inode, modifiedUnixMS: Int64(modified.timeIntervalSince1970 * 1000))
    }
}

/// Locates the GGUF blob an Ollama model name is served from, in the local
/// Ollama store (`$OLLAMA_MODELS`, default `~/.ollama/models`): the manifest at
/// `manifests/registry.ollama.ai/<namespace>/<repo>/<tag>` names the model
/// layer, whose digest LOCATES `blobs/sha256-<hex>`. Filesystem only — no
/// network, no dereferencing anything the runtime reports beyond the name.
struct BYOMOllamaModelStore: Sendable {
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

    private func pathIsContained(_ url: URL, in root: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        if target == base { return true }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
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
    let store: BYOMOllamaModelStore
    let cache: BYOMArtifactDigestCache

    /// Discovery-time: a digest previously computed over the SAME file (path,
    /// size, inode, mtime), or nil. Never hashes.
    func knownDigest(forOllamaModel name: String) -> String? {
        guard let blob = store.resolveModelBlob(name: name),
              let identity = BYOMArtifactFileIdentity.current(of: blob.blobURL)
        else {
            return nil
        }
        return cache.lookup(identity, algorithm: ModelArtifactIdentity.ggufFileV1)
    }

    /// Binding-time: recompute over the complete bytes, fail closed if the
    /// file's identity changed while hashing, record the result.
    func computeDigest(forOllamaModel name: String) throws -> String {
        guard let blob = store.resolveModelBlob(name: name),
              let before = BYOMArtifactFileIdentity.current(of: blob.blobURL)
        else {
            throw BYOMArtifactDigestError.unresolvedBlob
        }
        let digest = try GGUFArtifactDigest.compute(fileURL: blob.blobURL)
        guard BYOMArtifactFileIdentity.current(of: blob.blobURL) == before else {
            throw BYOMArtifactDigestError.fileIdentityChanged
        }
        cache.store(before, algorithm: ModelArtifactIdentity.ggufFileV1, digest: digest)
        return digest
    }
}
