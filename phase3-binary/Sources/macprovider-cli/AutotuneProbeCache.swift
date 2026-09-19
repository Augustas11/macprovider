import Darwin
import Foundation

/// Incremental SPEC-023 probe memo that is *not* part of the installer
/// transaction. `last-recommendation.json` is snapshotted/rolled back with the
/// install; this cache lives beside it so a Ctrl-C / rollback / declined-start
/// re-run can skip already-completed eligible probes. Admission still goes
/// through `AutotuneRecommendEngine.cachedBenchmarkAdmitted`.
struct AutotuneProbeCacheEntry: Equatable {
    var modelKey: String
    var modelID: String
    var sustainedTPS: Double
    var ttftMS: Int
    var swapDetected: Bool
    var thermalThrottleDetected: Bool
    var artifactSHA256: String
    var modelArtifactPath: String
    var benchmarkID: String?
    var generatedAt: Date
    var candidateCatalogSHA256: String
    var binaryVersion: String
    var hardwareIdentityHash: String
    var candidateRowIdentity: String

    init(benchmark: CandidateBenchmark) {
        modelKey = benchmark.modelKey
        modelID = benchmark.modelID
        sustainedTPS = benchmark.sustainedTPS
        ttftMS = benchmark.ttftMS
        swapDetected = benchmark.swapDetected
        thermalThrottleDetected = benchmark.thermalThrottleDetected
        artifactSHA256 = benchmark.artifactSHA256
        modelArtifactPath = benchmark.modelArtifactPath
        benchmarkID = benchmark.benchmarkID
        generatedAt = benchmark.generatedAt
        candidateCatalogSHA256 = benchmark.candidateCatalogSHA256
        binaryVersion = benchmark.binaryVersion
        hardwareIdentityHash = benchmark.hardwareIdentityHash
        candidateRowIdentity = benchmark.candidateRowIdentity
    }

    func asBenchmark() -> CandidateBenchmark {
        CandidateBenchmark(
            modelKey: modelKey,
            sustainedTPS: sustainedTPS,
            ttftMS: ttftMS,
            swapDetected: swapDetected,
            thermalThrottleDetected: thermalThrottleDetected,
            artifactSHA256: artifactSHA256,
            modelArtifactPath: modelArtifactPath,
            benchmarkID: benchmarkID,
            generatedAt: generatedAt,
            candidateCatalogSHA256: candidateCatalogSHA256,
            binaryVersion: binaryVersion,
            modelID: modelID,
            hardwareIdentityHash: hardwareIdentityHash,
            candidateRowIdentity: candidateRowIdentity
        )
    }
}

struct AutotuneProbeCacheStore {
    static let schemaVersion = "macprovider.autotune-probe-cache.v1"
    static let maxEntries = 64

    var url: URL
    var now: () -> Date = Date.init

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macprovider/autotune-probe-cache.json")
    }

    init(url: URL = AutotuneProbeCacheStore.defaultURL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    func loadAdmitted(
        modelKey: String,
        request: AutotuneRecommendRequest
    ) -> CandidateBenchmark? {
        guard let entry = ((try? read()) ?? []).first(where: { $0.modelKey == modelKey }) else {
            return nil
        }
        let benchmark = entry.asBenchmark()
        guard AutotuneRecommendEngine.cachedBenchmarkAdmitted(
            benchmark,
            request: request,
            modelKey: modelKey
        ), Self.isDurableResumeCandidate(benchmark) else {
            return nil
        }
        var st = stat()
        guard benchmark.modelArtifactPath.hasPrefix("/"),
              lstat(benchmark.modelArtifactPath, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR
        else {
            return nil
        }
        return benchmark
    }

    /// Hard paid-path vetoes must not survive into the 7-day sidecar: installer
    /// #1269 retries are new processes and would otherwise reuse a cold/thermal
    /// first sample instead of re-measuring.
    static func isDurableResumeCandidate(_ benchmark: CandidateBenchmark) -> Bool {
        !benchmark.swapDetected && !benchmark.thermalThrottleDetected
    }

    func store(_ benchmark: CandidateBenchmark) {
        do {
            try storeThrowing(benchmark)
        } catch {
            FileHandle.standardError.write(
                Data("[warn] paid-yield probe cache not updated: \(error)\n".utf8)
            )
        }
    }

    func storeThrowing(_ benchmark: CandidateBenchmark) throws {
        guard Self.isDurableResumeCandidate(benchmark) else { return }
        let entry = AutotuneProbeCacheEntry(benchmark: benchmark)
        var entries = (try? read()) ?? []
        entries.removeAll { $0.modelKey == entry.modelKey }
        entries.append(entry)
        let cutoff = now().addingTimeInterval(-AutotuneRecommendEngine.maxBenchmarkAge)
        entries.removeAll { $0.generatedAt < cutoff }
        entries.sort { $0.generatedAt > $1.generatedAt }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        try write(entries)
    }

    private func read() throws -> [AutotuneProbeCacheEntry] {
        try Self.ensurePrivateParentDirectory(for: url, create: false)
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o022) == 0
        else {
            try? handle.close()
            return []
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == Self.schemaVersion else { return [] }
        return document.entries.map(\.entry)
    }

    private func write(_ entries: [AutotuneProbeCacheEntry]) throws {
        try Self.ensurePrivateParentDirectory(for: url, create: true)
        let document = Document(
            schemaVersion: Self.schemaVersion,
            entries: entries.map(WireEntry.init(entry:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try Self.writePrivateFile(data, to: url)
    }

    private static func ensurePrivateParentDirectory(for url: URL, create: Bool) throws {
        let parent = url.deletingLastPathComponent()
        var st = stat()
        if lstat(parent.path, &st) != 0 {
            guard create else { throw POSIXError(.ENOENT) }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            guard lstat(parent.path, &st) == 0 else { throw POSIXError(.EIO) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw POSIXError(.EPERM)
        }
        guard chmod(parent.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    }

    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == getuid() else {
                throw POSIXError(.EPERM)
            }
        } else if errno != ENOENT {
            throw POSIXError(.EIO)
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var closed = false
        defer {
            if !closed { close(fd) }
            _ = unlink(temporary.path)
        }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EPERM) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.EIO)
                }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        guard close(fd) == 0 else { throw POSIXError(.EIO) }
        closed = true
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    private struct Document: Codable {
        var schemaVersion: String
        var entries: [WireEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case entries
        }
    }

    private struct WireEntry: Codable {
        var modelKey: String
        var modelID: String
        var sustainedTPS: Double
        var ttftMS: Int
        var swapDetected: Bool
        var thermalThrottleDetected: Bool
        var artifactSHA256: String
        var modelArtifactPath: String
        var benchmarkID: String?
        var generatedAt: String
        var candidateCatalogSHA256: String
        var binaryVersion: String
        var hardwareIdentityHash: String
        var candidateRowIdentity: String

        enum CodingKeys: String, CodingKey {
            case modelKey = "model_key"
            case modelID = "model_id"
            case sustainedTPS = "sustained_tps"
            case ttftMS = "ttft_ms"
            case swapDetected = "swap_detected"
            case thermalThrottleDetected = "thermal_throttle_detected"
            case artifactSHA256 = "artifact_sha256"
            case modelArtifactPath = "model_artifact_path"
            case benchmarkID = "benchmark_id"
            case generatedAt = "generated_at"
            case candidateCatalogSHA256 = "candidate_catalog_sha256"
            case binaryVersion = "binary_version"
            case hardwareIdentityHash = "hardware_identity_hash"
            case candidateRowIdentity = "candidate_row_identity"
        }

        init(entry: AutotuneProbeCacheEntry) {
            modelKey = entry.modelKey
            modelID = entry.modelID
            sustainedTPS = entry.sustainedTPS
            ttftMS = entry.ttftMS
            swapDetected = entry.swapDetected
            thermalThrottleDetected = entry.thermalThrottleDetected
            artifactSHA256 = entry.artifactSHA256
            modelArtifactPath = entry.modelArtifactPath
            benchmarkID = entry.benchmarkID
            generatedAt = ISO8601DateFormatter.autotuneInternet.string(from: entry.generatedAt)
            candidateCatalogSHA256 = entry.candidateCatalogSHA256
            binaryVersion = entry.binaryVersion
            hardwareIdentityHash = entry.hardwareIdentityHash
            candidateRowIdentity = entry.candidateRowIdentity
        }

        var entry: AutotuneProbeCacheEntry {
            AutotuneProbeCacheEntry(
                modelKey: modelKey,
                modelID: modelID,
                sustainedTPS: sustainedTPS,
                ttftMS: ttftMS,
                swapDetected: swapDetected,
                thermalThrottleDetected: thermalThrottleDetected,
                artifactSHA256: artifactSHA256,
                modelArtifactPath: modelArtifactPath,
                benchmarkID: benchmarkID,
                generatedAt: ISO8601DateFormatter.autotuneInternet.date(from: generatedAt) ?? Date(timeIntervalSince1970: 0),
                candidateCatalogSHA256: candidateCatalogSHA256,
                binaryVersion: binaryVersion,
                hardwareIdentityHash: hardwareIdentityHash,
                candidateRowIdentity: candidateRowIdentity
            )
        }
    }
}

private extension AutotuneProbeCacheEntry {
    init(
        modelKey: String,
        modelID: String,
        sustainedTPS: Double,
        ttftMS: Int,
        swapDetected: Bool,
        thermalThrottleDetected: Bool,
        artifactSHA256: String,
        modelArtifactPath: String,
        benchmarkID: String?,
        generatedAt: Date,
        candidateCatalogSHA256: String,
        binaryVersion: String,
        hardwareIdentityHash: String,
        candidateRowIdentity: String
    ) {
        self.modelKey = modelKey
        self.modelID = modelID
        self.sustainedTPS = sustainedTPS
        self.ttftMS = ttftMS
        self.swapDetected = swapDetected
        self.thermalThrottleDetected = thermalThrottleDetected
        self.artifactSHA256 = artifactSHA256
        self.modelArtifactPath = modelArtifactPath
        self.benchmarkID = benchmarkID
        self.generatedAt = generatedAt
        self.candidateCatalogSHA256 = candidateCatalogSHA256
        self.binaryVersion = binaryVersion
        self.hardwareIdentityHash = hardwareIdentityHash
        self.candidateRowIdentity = candidateRowIdentity
    }
}
