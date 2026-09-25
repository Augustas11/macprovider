import ArgumentParser
import Darwin
import Foundation

// MARK: - models import

/// Adopt a signed catalog model's bytes from a local directory (USB, LAN, a
/// copied Hugging Face cache, or a downloaded mirror tree) without any
/// network access. The signed row hash is the only authority: bytes that do
/// not reproduce it are never adopted (#1737, SPEC-023 §3.2).
struct ModelsImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Adopt a signed catalog model from a local directory, with no download.",
        discussion: "Copies the snapshot from --from into the durable model store and verifies it against the "
            + "signed catalog row's macprovider.snapshot-manifest.v1 hash. --from may be a snapshot directory "
            + "(symlinks, as in a Hugging Face cache, are followed; .DS_Store and ._* files are ignored) or a "
            + "mirror tree holding manifest plus files/. It never changes config or the active model. "
            + "Exit 0 = adopted, 3 = bytes do not match the signed hash, 2 = refused."
    )

    @Argument(help: "Catalog key or model id, e.g. qwen/qwen3-8b or mlx-community/Qwen3-8B-4bit.")
    var model: String

    @Option(name: .customLong("from"), help: "Local directory holding the model files.")
    var from: String

    @Flag(name: .customLong("json"), help: "Emit one model_import_result.v1 JSON object.")
    var emitJSON = false

    @Option(help: "YAML config path used to resolve model_artifact_root. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    func run() async throws {
        let appConfig = try loadDiagnosticsConfig(config, command: "models import")
        let row: ModelArtifactSignedRow
        do {
            row = try await ModelArtifactSignedRowResolver.resolve(key: model)
        } catch {
            writeDiagnosticsStderr("models import refused: \(error)")
            throw ExitCode(2)
        }
        let resolver = CachedModelArtifactResolver.forConfig(appConfig)
        let source = URL(fileURLWithPath: (from as NSString).expandingTildeInPath, isDirectory: true)
        let outcome = ModelArtifactImporter.importArtifact(row: row.catalogRow, from: source, resolver: resolver)
        if emitJSON {
            try printDiagnosticsJSON(outcome.jsonObject(catalogKey: row.catalogKey))
        } else {
            print(outcome.humanText(catalogKey: row.catalogKey))
        }
        switch outcome {
        case .adopted:
            return
        case .mismatch:
            throw ExitCode(3)
        case .refused:
            throw ExitCode(2)
        }
    }
}

enum ModelArtifactImportOutcome: Equatable {
    case adopted(path: String, sha256: String)
    case mismatch(expected: String, actual: String)
    case refused(String)

    func jsonObject(catalogKey: String) -> [String: Any] {
        var object: [String: Any] = ["schema": "model_import_result.v1", "catalog_key": catalogKey]
        switch self {
        case .adopted(let path, let sha256):
            object["state"] = "adopted"
            object["artifact_path"] = path
            object["model_sha256"] = sha256
        case .mismatch(let expected, let actual):
            object["state"] = "hash_mismatch"
            object["expected_sha256"] = expected
            object["actual_sha256"] = actual
        case .refused(let reason):
            object["state"] = "refused"
            object["reason"] = reason
        }
        return object
    }

    func humanText(catalogKey: String) -> String {
        switch self {
        case .adopted(let path, let sha256):
            return "adopted \(catalogKey) sha256=\(sha256) at \(path)"
        case .mismatch(let expected, let actual):
            return "not adopted: \(catalogKey) bytes do not match the signed hash expected=\(expected) actual=\(actual)"
        case .refused(let reason):
            return "not adopted: \(reason)"
        }
    }
}

enum ModelArtifactImporter {
    /// Finder and macOS archive metadata that is never part of a snapshot.
    static func isPlatformMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    static func importArtifact(
        row: CandidateCatalog.Row,
        from source: URL,
        resolver: CachedModelArtifactResolver
    ) -> ModelArtifactImportOutcome {
        guard let revision = row.modelRevision, let expected = row.modelSHA256 else {
            return .refused("signed row is not pinned to a revision and hash")
        }
        var info = stat()
        guard stat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            return .refused("--from is not a directory")
        }
        if let verified = try? resolver.inspectedExistingArtifact(for: row),
           resolver.durableStore.contains(verified.modelArgument)
        {
            return .adopted(path: verified.modelArgument, sha256: verified.sha256)
        }
        // Staging sits beside, never inside, the durable root: a staged copy
        // inside it would count as already adopted.
        let staging = resolver.durableRoot.deletingLastPathComponent()
            .appendingPathComponent(".macprovider-import-\(revision)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            if isMirrorTree(source) {
                try copyMirrorTree(source, expectedSHA256: expected, to: staging)
            } else {
                try copySnapshotDirectory(source, to: staging)
            }
        } catch {
            return .refused("could not copy the model files: \(error)")
        }
        let inspection: ModelArtifactVerifier.CanonicalArtifactInspection
        do {
            inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: staging)
        } catch {
            return .refused("copied files are not a valid snapshot: \(error)")
        }
        guard inspection.sha256 == expected else {
            return .mismatch(expected: expected, actual: inspection.sha256)
        }
        do {
            let adopted = try resolver.verifiedExistingArtifact(for: row, at: staging)
            return .adopted(path: adopted.modelArgument, sha256: adopted.sha256)
        } catch {
            return .refused("could not adopt into the durable model store: \(error)")
        }
    }

    static func isMirrorTree(_ source: URL) -> Bool {
        var manifest = stat()
        var files = stat()
        return stat(source.appendingPathComponent("manifest").path, &manifest) == 0
            && (manifest.st_mode & S_IFMT) == S_IFREG
            && stat(source.appendingPathComponent("files").path, &files) == 0
            && (files.st_mode & S_IFMT) == S_IFDIR
    }

    /// Copy exactly the files a hash-verified mirror manifest names.
    private static func copyMirrorTree(_ source: URL, expectedSHA256: String, to staging: URL) throws {
        let manifestData = try Data(contentsOf: source.appendingPathComponent("manifest"))
        let entries = try ContentAddressedManifest.parse(manifestData, expectedSHA256: expectedSHA256)
        let filesRoot = source.appendingPathComponent("files", isDirectory: true)
        for entry in entries {
            try copyRegularFile(
                from: filesRoot.appendingPathComponent(entry.path, isDirectory: false),
                to: staging.appendingPathComponent(entry.path, isDirectory: false)
            )
        }
    }

    /// Copy every regular file under `source`, following symlinks (a Hugging
    /// Face cache snapshot links into blobs/) and skipping platform metadata.
    private static func copySnapshotDirectory(_ source: URL, to staging: URL) throws {
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw AutotuneRecommendError.invalidArtifact("cannot enumerate --from")
        }
        for case let url as URL in enumerator {
            if isPlatformMetadata(url.lastPathComponent) {
                var isDirectory = stat()
                if lstat(url.path, &isDirectory) == 0, (isDirectory.st_mode & S_IFMT) == S_IFDIR {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.path.hasPrefix(root.path + "/") else {
                throw AutotuneRecommendError.invalidArtifact("path escape \(url.lastPathComponent)")
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            try ModelArtifactRelativePathPolicy.validate(relative, context: "unsafe path in --from")
            var info = stat()
            guard stat(url.path, &info) == 0 else {
                throw AutotuneRecommendError.invalidArtifact("unreadable \(relative)")
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                var link = stat()
                if lstat(url.path, &link) == 0, (link.st_mode & S_IFMT) == S_IFLNK {
                    throw AutotuneRecommendError.invalidArtifact("directory symlink \(relative)")
                }
                continue
            case S_IFREG:
                try copyRegularFile(from: url, to: staging.appendingPathComponent(relative, isDirectory: false))
            default:
                throw AutotuneRecommendError.invalidArtifact("non-regular \(relative)")
            }
        }
    }

    /// Copies contents into a new regular file, so the staged tree never
    /// holds a symlink or a hardlink into the source.
    private static func copyRegularFile(from source: URL, to destination: URL) throws {
        var info = stat()
        guard stat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AutotuneRecommendError.invalidArtifact("missing file \(source.lastPathComponent)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AutotuneRecommendError.invalidArtifact("cannot create \(destination.lastPathComponent)")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }
}
