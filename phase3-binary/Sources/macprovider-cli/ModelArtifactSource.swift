import CryptoKit
import Foundation

/// A host that can deliver the bytes of a signed catalog snapshot when
/// huggingface.co cannot. None of these hosts is an authority: whatever they
/// serve must reproduce the signed row's snapshot-manifest.v1 hash before it
/// is adopted (SPEC-023 §3.2 artifact byte sources, #1737).
enum ModelArtifactSource: Equatable, Sendable {
    /// `<base>/<model_sha256>/manifest` plus `<base>/<model_sha256>/files/<path>`.
    case contentAddressed(URL)
    /// The Hugging Face API and resolve layout on another host (`HF_ENDPOINT`).
    /// It is never sent `HF_TOKEN`.
    case huggingFaceCompatible(URL)

    /// Malibu's content-addressed weight mirror. The DNS name is ours, so the
    /// storage or CDN behind it can change without a CLI release.
    static let malibuMirror = URL(string: "https://models.malibu.tech")!

    static let mirrorsEnvironmentKey = "MACPROVIDER_MODEL_MIRRORS"

    var label: String {
        switch self {
        case .contentAddressed(let base), .huggingFaceCompatible(let base):
            return base.host ?? base.absoluteString
        }
    }

    /// Operator mirrors from `MACPROVIDER_MODEL_MIRRORS` (comma or whitespace
    /// separated HTTPS base URLs), then the Malibu mirror, then an
    /// `HF_ENDPOINT` that is not huggingface.co. Unusable entries are dropped.
    static func productionFallbacks(environment: [String: String]) -> [ModelArtifactSource] {
        var sources: [ModelArtifactSource] = []
        func append(_ source: ModelArtifactSource) {
            if !sources.contains(source) {
                sources.append(source)
            }
        }
        let configured = (environment[mirrorsEnvironmentKey] ?? "")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        for raw in configured {
            if let base = normalizedBase(raw) {
                append(.contentAddressed(base))
            }
        }
        append(.contentAddressed(malibuMirror))
        if let raw = environment["HF_ENDPOINT"],
           let endpoint = normalizedBase(raw),
           endpoint.host?.lowercased() != "huggingface.co"
        {
            append(.huggingFaceCompatible(endpoint))
        }
        return sources
    }

    /// HTTPS only, no credentials, query, or fragment; trailing slashes dropped.
    static func normalizedBase(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }
        components.scheme = "https"
        components.host = host.lowercased()
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        return components.url
    }

    static func contentAddressedManifestURL(base: URL, sha256: String) -> URL {
        base.appendingPathComponent(sha256, isDirectory: true)
            .appendingPathComponent("manifest", isDirectory: false)
    }

    /// `path` was validated by `ModelArtifactRelativePathPolicy`; each
    /// component is percent-encoded on its own so `/` keeps its meaning.
    static func contentAddressedFileURL(base: URL, sha256: String, path: String) -> URL {
        var url = base.appendingPathComponent(sha256, isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }
}

enum ContentAddressedManifest {
    struct Entry: Equatable, Sendable {
        var path: String
        var size: UInt64
        var sha256: String
    }

    static let maxManifestBytes = 8 * 1024 * 1024

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    /// Accept the manifest only when its bytes hash to the signed row hash;
    /// the entries then describe exactly the snapshot the catalog signed.
    static func parse(_ data: Data, expectedSHA256: String) throws -> [Entry] {
        guard data.count <= maxManifestBytes else {
            throw AutotuneRecommendError.invalidArtifact("mirror manifest too large")
        }
        guard sha256Hex(data) == expectedSHA256 else {
            throw AutotuneRecommendError.invalidArtifact("mirror manifest does not match the signed artifact hash")
        }
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else {
            throw AutotuneRecommendError.invalidArtifact("mirror manifest is malformed")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeLast()
        guard !lines.isEmpty, lines.count % 3 == 0 else {
            throw AutotuneRecommendError.invalidArtifact("mirror manifest is malformed")
        }
        var entries: [Entry] = []
        var seen = Set<String>()
        for index in stride(from: 0, to: lines.count, by: 3) {
            let path = lines[index]
            try ModelArtifactRelativePathPolicy.validate(path, context: "unsafe mirror manifest path")
            guard seen.insert(path).inserted,
                  !lines[index + 1].isEmpty,
                  lines[index + 1].utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  let size = UInt64(lines[index + 1]),
                  isSHA256Hex(lines[index + 2])
            else {
                throw AutotuneRecommendError.invalidArtifact("mirror manifest is malformed")
            }
            entries.append(Entry(path: path, size: size, sha256: lines[index + 2]))
        }
        return entries
    }
}

extension ModelArtifactVerifier {
    static func sizeAndSHA256(of url: URL, deadline: Date? = nil) throws -> (size: UInt64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while true {
            try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
            size += UInt64(chunk.count)
        }
        return (size, ContentAddressedManifest.hex(hasher.finalize()))
    }
}
