import CryptoKit
import Darwin
import Foundation

/// This value describes only the current request's observation, never a saved seal.
enum ModelCatalogLocalVerificationState: String, Codable, Sendable {
    case notApplicable = "not_applicable"
    case missing, unverified, verified, invalid, incomplete
}

final class ModelCatalogLocalInspection {
    struct Key: Hashable {
        let modelKey: String
        let modelID: String
        let revision: String
        let sha256: String
    }
    struct Entry {
        let state: ModelCatalogLocalVerificationState
        let inspection: ModelArtifactVerifier.CanonicalArtifactInspection?
        fileprivate let observation: ModelCatalogVerifiedArtifactObservation?
    }
    let root: URL
    let budget: ModelCatalogReadBudget?
    private var entries: [Key: Entry] = [:]

    init(root: URL, budget: ModelCatalogReadBudget? = nil) {
        self.root = root; self.budget = budget
    }
    func entry(for key: Key) -> Entry? { entries[key] }
    func entry(modelKey: String, modelID: String) -> Entry? {
        let matching = entries.filter { $0.key.modelKey == modelKey && $0.key.modelID == modelID }
        return matching.count == 1 ? matching.first?.value : nil
    }
    /// Cache metadata proves existence only; it never supplies exact durable readiness.
    func observeCacheCandidate(modelKey: String, modelID: String) {
        for key in Array(entries.keys) where key.modelKey == modelKey && key.modelID == modelID {
            if entries[key]?.state == .missing {
                entries[key] = Entry(state: .unverified, inspection: nil, observation: nil)
            }
        }
    }
    @discardableResult
    func inspect(key: Key, verify: Bool = false, measuredBytes: (UInt64) throws -> Void = { _ in }) throws -> Entry {
        try budget?.check()
        if let existing = entries[key], !verify || existing.state == .verified { return existing }
        let directory = try DurableModelArtifactStore(root: root).artifactURL(
            modelID: key.modelID, revision: key.revision, sha256: key.sha256)
        let value: Entry
        do {
            let observation = try ModelCatalogVerifiedArtifactObservation(directory: directory, check: { try self.budget?.check() })
            if verify {
                let inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(
                    observation: observation, budget: budget, measuredBytes: measuredBytes)
                guard inspection.sha256 == key.sha256, inspection.configJSONData != nil else {
                    throw ModelCatalogInspectionError.invalid
                }
                value = Entry(state: .verified, inspection: inspection, observation: observation)
            } else {
                _ = try observation.snapshot(check: { try self.budget?.check() })
                value = Entry(state: .unverified, inspection: nil, observation: nil)
            }
        } catch ModelCatalogInspectionError.missing {
            value = Entry(state: .missing, inspection: nil, observation: nil)
        } catch ModelCatalogInspectionError.invalid {
            value = Entry(state: .invalid, inspection: nil, observation: nil)
        } catch ModelCatalogInspectionError.limit {
            value = Entry(state: .incomplete, inspection: nil, observation: nil)
            entries[key] = value
            if verify { throw ModelCatalogInspectionError.limit }
        } catch {
            entries[key] = Entry(state: .incomplete, inspection: nil, observation: nil)
            throw error
        }
        entries[key] = value
        return value
    }
    func validateCompleteObservations() throws {
        try budget?.check()
        guard !entries.values.contains(where: { $0.state == .incomplete }) else {
            throw ModelCatalogInspectionError.incomplete
        }
    }
    func validateVerifiedPlacements() throws {
        for entry in entries.values where entry.state == .verified {
            try budget?.check()
            try entry.observation?.validateFinal(check: { try self.budget?.check() })
        }
    }
}

enum ModelCatalogInspectionError: Error {
    case missing, invalid, incomplete, limit
}

/// Retains every placement descriptor, including ancestors, until publication.
/// All descendant enumeration and reads use no-follow descriptor-relative opens.
final class ModelCatalogVerifiedArtifactObservation {
    private struct Link {
        let parent: Int32
        let name: String
        let identity: ModelCatalogArtifactSnapshot.Identity
    }
    struct Metadata: Equatable {
        let entry: ModelCatalogArtifactSnapshot.Entry
        let links: UInt16
        init(_ path: String, _ info: stat) {
            entry = .init(path: path, info: info); links = info.st_nlink
        }
    }
    private var descriptors: [Int32] = []
    private var links: [Link] = []
    private var verifiedSnapshot: [String: Metadata]?
    var rootFD: Int32 { descriptors.last! }

    init(directory: URL, check: () throws -> Void) throws {
        try check()
        let components = ModelTransactionDirectory.normalized(directory).split(separator: "/").map(String.init)
        let start = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard start >= 0 else { throw ModelCatalogInspectionError.incomplete }
        descriptors.append(start)
        do {
            for name in components {
                try check()
                let parent = descriptors.last!
                var placed = stat()
                guard fstatat(parent, name, &placed, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { throw ModelCatalogInspectionError.missing }
                    throw ModelCatalogInspectionError.incomplete
                }
                guard placed.st_mode & S_IFMT == S_IFDIR,
                      placed.st_uid == getuid() || placed.st_uid == 0,
                      placed.st_mode & 0o022 == 0 || (placed.st_uid == 0 && placed.st_mode & S_ISVTX != 0) else {
                    throw ModelCatalogInspectionError.invalid
                }
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ModelCatalogInspectionError.incomplete }
                descriptors.append(child)
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      Metadata(name, placed) == Metadata(name, opened) else { throw ModelCatalogInspectionError.invalid }
                links.append(Link(parent: parent, name: name, identity: .init(opened)))
                try check()
            }
            var root = stat()
            guard fstat(rootFD, &root) == 0, root.st_uid == getuid(), root.st_mode & 0o022 == 0 else {
                throw ModelCatalogInspectionError.invalid
            }
            try validatePlacement(check: check)
        } catch {
            descriptors.forEach { close($0) }; descriptors.removeAll()
            throw error
        }
    }
    deinit { descriptors.forEach { close($0) } }

    func validatePlacement(check: () throws -> Void) throws {
        for link in links {
            try check()
            var placed = stat()
            guard fstatat(link.parent, link.name, &placed, AT_SYMLINK_NOFOLLOW) == 0,
                  ModelCatalogArtifactSnapshot.Identity(placed) == link.identity else { throw ModelCatalogInspectionError.invalid }
            try check()
        }
    }

    func snapshot(check: () throws -> Void,
                  readFile: (Int32, String, stat) throws -> Void = { _, _, _ in }) throws -> [String: Metadata] {
        try validatePlacement(check: check)
        var result: [String: Metadata] = [:]
        var root = stat()
        guard fstat(rootFD, &root) == 0 else { throw ModelCatalogInspectionError.incomplete }
        result[""] = Metadata("", root)
        func walk(_ fd: Int32, _ prefix: String, _ depth: Int) throws {
            try check()
            guard depth <= 64 else { throw ModelCatalogInspectionError.limit }
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard copy >= 0 else { throw ModelCatalogInspectionError.incomplete }
            guard let stream = fdopendir(copy) else { close(copy); throw ModelCatalogInspectionError.incomplete }
            defer { closedir(stream) }
            while true {
                try check(); errno = 0
                guard let item = readdir(stream) else {
                    guard errno == 0 else { throw ModelCatalogInspectionError.incomplete }; break
                }
                try check()
                let bytes = withUnsafeBytes(of: item.pointee.d_name) { Array($0.prefix(while: { $0 != 0 })) }
                guard let name = String(bytes: bytes, encoding: .utf8) else { throw ModelCatalogInspectionError.invalid }
                if name == "." || name == ".." { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard result.count <= 10_000, path.utf8.count <= 4_096 else { throw ModelCatalogInspectionError.limit }
                do { try ModelArtifactRelativePathPolicy.validate(path) } catch { throw ModelCatalogInspectionError.invalid }
                guard result[path] == nil else { throw ModelCatalogInspectionError.invalid }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ModelCatalogInspectionError.incomplete }
                let directory = info.st_mode & S_IFMT == S_IFDIR
                guard info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_size >= 0,
                      directory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else { throw ModelCatalogInspectionError.invalid }
                if path == "config.json", info.st_size > 8 * 1_024 * 1_024 { throw ModelCatalogInspectionError.limit }
                try check()
                let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
                guard child >= 0 else { throw ModelCatalogInspectionError.incomplete }
                defer { close(child) }
                try check()
                var opened = stat()
                guard fstat(child, &opened) == 0, Metadata(path, opened) == Metadata(path, info) else { throw ModelCatalogInspectionError.invalid }
                result[path] = Metadata(path, info)
                if directory { try walk(child, path, depth + 1) }
                else { try readFile(child, path, info) }
                try check()
                var after = stat(), placed = stat()
                guard fstat(child, &after) == 0, fstatat(fd, name, &placed, AT_SYMLINK_NOFOLLOW) == 0,
                      Metadata(path, after) == Metadata(path, info), Metadata(path, placed) == Metadata(path, info) else {
                    throw ModelCatalogInspectionError.invalid
                }
            }
        }
        try walk(rootFD, "", 0)
        var after = stat()
        guard fstat(rootFD, &after) == 0, Metadata("", after) == result[""] else { throw ModelCatalogInspectionError.invalid }
        try validatePlacement(check: check)
        return result
    }

    func recordVerified(_ before: [String: Metadata], check: () throws -> Void) throws {
        guard try snapshot(check: check) == before else { throw ModelCatalogInspectionError.invalid }
        verifiedSnapshot = before
    }
    func validateFinal(check: () throws -> Void) throws {
        guard let verifiedSnapshot, try snapshot(check: check) == verifiedSnapshot else { throw ModelCatalogInspectionError.invalid }
    }
}
