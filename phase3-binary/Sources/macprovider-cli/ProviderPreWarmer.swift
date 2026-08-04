import Foundation

enum PreWarmResult: Equatable {
    enum CacheState: Equatable {
        case alreadyCached
        case fetchedDuringLoad
    }

    enum FailureClass: Equatable {
        case transient
        case integrity
    }

    case warmed(cacheState: CacheState, loadDurationSec: Double)
    case failed(failureClass: FailureClass, reason: String)
}

struct HuggingFaceCacheChecker {
    private let cacheRoot: URL
    private let fileManager: FileManager

    init(
        cacheRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.cacheRoot = cacheRoot
        self.fileManager = fileManager
    }

    func isModelCached(modelID: String) -> Bool {
        guard let repoDirectory = repositoryDirectory(for: modelID) else {
            return false
        }

        let snapshotsDirectory = repoDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotURLs = try? fileManager.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return snapshotURLs.contains { snapshotURL in
            isDirectory(snapshotURL) && containsAnyFile(snapshotURL)
        }
    }

    private func repositoryDirectory(for modelID: String) -> URL? {
        let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        return cacheRoot.appendingPathComponent("models--\(parts[0])--\(parts[1])", isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func containsAnyFile(_ snapshotURL: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                continue
            }
            if values.isRegularFile == true || values.isSymbolicLink == true {
                return true
            }
        }
        return false
    }
}

struct ProviderPreWarmer {
    private let cacheChecker: HuggingFaceCacheChecker
    private let stopGraceSeconds: Double
    private let now: () -> Date

    init(
        cacheChecker: HuggingFaceCacheChecker = HuggingFaceCacheChecker(),
        stopGraceSeconds: Double = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.cacheChecker = cacheChecker
        self.stopGraceSeconds = stopGraceSeconds
        self.now = now
    }

    func prewarmAndProbe(
        model: String,
        port: Int,
        runner: CandidateProviderRunner,
        readyTimeoutSec: TimeInterval
    ) async throws -> PreWarmResult {
        let cacheState: PreWarmResult.CacheState = cacheChecker.isModelCached(modelID: model)
            ? .alreadyCached
            : .fetchedDuringLoad
        let started = now()
        try runner.start(model: model, port: port)
        return try await withCandidateProviderCleanup(runner, graceSeconds: stopGraceSeconds) {
        let readyStatus = try await runner.waitForReady(timeout: readyTimeoutSec)

        switch readyStatus {
        case .ready:
            return .warmed(cacheState: cacheState, loadDurationSec: max(0, now().timeIntervalSince(started)))
        case .processExited(let rc, let stderrTail):
            let reason = "provider exited rc=\(rc): \(stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))"
            return .failed(
                failureClass: Self.failureClass(for: stderrTail),
                reason: reason
            )
        case .timeout(let lastError):
            return .failed(failureClass: .transient, reason: "load timeout: \(lastError)")
        }
        }
    }

    private static func failureClass(for stderrTail: String) -> PreWarmResult.FailureClass {
        let lowercased = stderrTail.lowercased()
        if integrityMarkers.contains(where: { lowercased.contains($0) }) {
            return .integrity
        }
        return .transient
    }

    /// Integrity-class markers: substrings whose presence in
    /// `stderrTail` (case-insensitively lower-cased) classifies a
    /// pre-warm failure as repository-shape / tampering / corruption
    /// rather than transient (network / disk).
    ///
    /// SPEC-013 §5.4 FR-D.2 lists these examples: signature mismatch,
    /// weight hash mismatch, repository contents inconsistent with
    /// expected shape (e.g. missing tokenizer.json), or any
    /// tampering signal.
    ///
    /// Round-1 audit B.1 (CRITICAL) closure: the prior `"missing
    /// tokenizer.json"` marker did NOT match the actual
    /// swift-transformers Hub error string `"Required configuration
    /// file missing: tokenizer.json"` (colon breaks the substring
    /// match), so the SPEC-named integrity case was silently
    /// advancing as transient. We now keep BOTH the colon-bearing
    /// variants (the real dependency strings, found in
    /// .build/checkouts/swift-transformers/Sources/Hub/Hub.swift)
    /// AND the original marker as a fallback for variant phrasings.
    ///
    /// Round-1 audit B.2 (MAJOR) closure: added safetensors loader
    /// corruption markers from
    /// .build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/io/safetensors.cpp
    /// and the MLX load path. These signal corrupted or tampered
    /// repository content (asymmetric FR-D.2 risk model biases
    /// toward integrity here).
    private static let integrityMarkers = [
        // Signature / hash / checksum markers (round-0 set)
        "signature mismatch",
        "hash mismatch",
        "manifest verification failed",
        "weight verification failed",
        "checksum mismatch",
        "signature verification failed",
        "checksum signature invalid",

        // Missing-tokenizer markers (B.1 closure):
        // the actual swift-transformers error string is
        // "Required configuration file missing: tokenizer.json"
        // — lowercased, it doesn't contain the bare phrase
        // "missing tokenizer.json" because of the colon.
        "missing tokenizer.json",
        "configuration file missing: tokenizer.json",
        "missing: tokenizer.json",
        "missing required tokenizer files",

        // Malformed safetensors / loader markers (B.2 closure):
        // mlx-swift's safetensors reader throws strings like
        // "[load_safetensors] Invalid json header length ..." and
        // "[load_safetensors] Invalid json metadata ..." when the
        // weight file is corrupted or tampered. These two phrases
        // are anchored to the safetensors loader's actual output
        // and are unlikely to appear in transient/network/cache
        // contexts.
        //
        // Round-2 audit N.1 (MAJOR) closure: the prior list also
        // included "incomplete metadata" and "invalid or
        // corrupted" — both too vague. A benign transient line
        // like "Download failed: incomplete metadata in
        // Hugging Face API response; retry later" or "cache index
        // invalid or corrupted; rebuild cache and retry" would
        // match and over-abort an advanceable transient failure.
        // Asymmetric FR-D.2 still biases toward integrity, but
        // not so broad as to misclassify HF API metadata errors or
        // cache rebuild prompts. The two markers below stay because
        // they're anchored to the safetensors loader's actual
        // output context.
        "invalid json header",
        "invalid json metadata",
    ]
}
