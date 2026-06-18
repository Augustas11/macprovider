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
        defer {
            runner.stop(graceSeconds: stopGraceSeconds)
        }

        try runner.start(model: model, port: port)
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

    private static func failureClass(for stderrTail: String) -> PreWarmResult.FailureClass {
        let lowercased = stderrTail.lowercased()
        if integrityMarkers.contains(where: { lowercased.contains($0) }) {
            return .integrity
        }
        return .transient
    }

    private static let integrityMarkers = [
        "signature mismatch",
        "hash mismatch",
        "manifest verification failed",
        "weight verification failed",
        "checksum mismatch",
        "signature verification failed",
        "checksum signature invalid",
        "missing tokenizer.json",
    ]
}
