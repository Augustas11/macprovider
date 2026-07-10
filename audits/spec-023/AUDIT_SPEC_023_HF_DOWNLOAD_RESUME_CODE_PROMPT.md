# AUDIT (CODE lane) — SPEC-023 HuggingFaceSnapshotDownloader retry-with-resume

## Context

macprovider-cli's SPEC-023 installer-integrated autotune-recommend downloads HuggingFace model shards during install. Every 2026-07-02 v1.7.3 install attempt on operator's M5 (real production QA) failed at `AutotuneCommand.swift::run_autotune_recommend_apply` when a large safetensors shard download dropped with `NSURLErrorDomain -1005 "The network connection was lost."` mid-transfer.

Root cause discovered via `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:1361-1394`:
1. The `download` closure used `URLSession.download(for:delegate:)` and did NOT catch the URLError to extract `NSURLSessionDownloadTaskResumeData` from `userInfo`.
2. On any error inside the per-sibling loop, the entire staging directory (potentially with 10+ GB of already-downloaded shards) got wiped.
3. Zero retry: one shard drop = complete install failure.

Verification B (empirical Swift test at scratchpad/verify-resume.swift) confirmed:
- HF CDN returns `HTTP/2 206 Partial Content` with `Content-Range: bytes N-M/TOTAL` on Range requests
- URLSession's resume-data blob (11-12 KB opaque bytes) correctly encodes byte offset
- `URLSession.download(resumeFrom:delegate:)` async API resumes from that offset, produces a byte-identical complete file (4,517,488,999 bytes == expected total)

## The change

New static function `downloadWithResume` on `HuggingFaceSnapshotDownloader`. Retries transient network errors (7 specific `URLError.Code` values), extracts resume data from `error.userInfo[NSURLSessionDownloadTaskResumeData]`, calls `URLSession.download(resumeFrom:)` on next attempt. Backoff exponential 5s/20s. Max 3 attempts. Non-transient errors or non-URLError bubble immediately.

New unit tests (9) cover:
- Success on first attempt (no retry, no backoff)
- Resume-data captured on transient → next attempt uses resume path
- No resume-data captured on transient → next attempt is fresh
- All attempts fail → last error thrown
- Non-transient URLError (.cancelled) → immediate rethrow, no backoff
- Non-URLError → immediate rethrow, no backoff
- `isTransientDownloadError` covers 7 codes, excludes 6 sample non-transient codes
- `extractResumeData` returns nil when absent, bytes when present

Version bump: 1.7.3 → 1.7.4. Test assertions updated to match.

## Files changed (repo-relative)

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` (+99 / -6, retry-with-resume logic on `HuggingFaceSnapshotDownloader`)
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` (+1 / -1, `binaryVersion = "1.7.4"`)
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift` (+233, 9 new tests)
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift` (+4 / -4, `"1.7.4"` assertions)

## Your instructions (CODE lane, this file)

You are the CODE lens. Focus exclusively on:
- Correctness of the retry state machine (attempt counting, resume-data lifecycle, error propagation)
- Loop invariants (does `attempt + 1 < maxAttempts` guard sleep correctly on the last iteration?)
- Edge cases: `maxAttempts = 0` (does `max(1, ...)` prevent zero-attempt exit?); `maxAttempts = 1` (should skip sleep entirely — verify); simultaneous URLError with BOTH transient code AND missing resume-data
- Thread safety: closures marked `@Sendable`, no shared mutable state? Actor usage in tests (`SleepCounter`)?
- Task cancellation: does `Task.sleep` cooperate with `Task.cancel()`? Does cancellation during a retry loop bubble correctly?
- Dead code / unused parameters
- Test coverage completeness for the invariants named in the spec
- Any place where Swift compiler warnings should exist but don't (Sendable, strict concurrency)

Do NOT critique architectural placement or security surface — those go to sibling audit lanes.

Return findings as a structured list. For each finding: **file:line, severity (CRITICAL/HIGH/MEDIUM/LOW), one-sentence summary, why it matters, minimal fix.** If a finding is speculative or "I'd write it slightly differently" style, mark it LOW.

Bar for STOP: 0 CRITICAL, 0 HIGH, 0 MEDIUM in your final response. Iterate the actual codebase and re-audit only after fixes if invited. Absent an invitation, single pass.

## Excerpted code under audit (both source + tests)

### phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift (relevant excerpt around lines 1344-1470)

```swift
struct HuggingFaceSnapshotDownloader {
    struct ModelInfo: Decodable {
        var siblings: [Sibling]
    }

    struct Sibling: Decodable {
        var rfilename: String
    }

    private static let guardedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        return URLSession(configuration: config)
    }()

    struct DownloadRetryPolicy {
        var maxAttempts: Int
        var baseDelaySeconds: Double
        var backoffMultiplier: Double
        var sleep: @Sendable (UInt64) async throws -> Void

        static let production = DownloadRetryPolicy(
            maxAttempts: 3,
            baseDelaySeconds: 5.0,
            backoffMultiplier: 4.0,
            sleep: { ns in try await Task.sleep(nanoseconds: ns) }
        )
    }

    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await HuggingFaceSnapshotDownloader.guardedSession.data(for: request, delegate: HFRedirectGuard())
    }
    var download: (URLRequest) async throws -> (URL, URLResponse) = { request in
        try await HuggingFaceSnapshotDownloader.downloadWithResume(
            request: request,
            policy: .production,
            initialDownload: { req in
                try await HuggingFaceSnapshotDownloader.guardedSession.download(
                    for: req, delegate: HFAssetRedirectGuard()
                )
            },
            resumeDownload: { data in
                try await HuggingFaceSnapshotDownloader.guardedSession.download(
                    resumeFrom: data, delegate: HFAssetRedirectGuard()
                )
            }
        )
    }

    static func downloadWithResume(
        request: URLRequest,
        policy: DownloadRetryPolicy,
        initialDownload: @Sendable (URLRequest) async throws -> (URL, URLResponse),
        resumeDownload: @Sendable (Data) async throws -> (URL, URLResponse)
    ) async throws -> (URL, URLResponse) {
        var lastError: Error?
        var resumeData: Data?
        for attempt in 0..<max(1, policy.maxAttempts) {
            do {
                if let data = resumeData {
                    return try await resumeDownload(data)
                }
                return try await initialDownload(request)
            } catch let error as URLError where isTransientDownloadError(error) {
                lastError = error
                if let extracted = extractResumeData(from: error) {
                    resumeData = extracted
                }
                if attempt + 1 < policy.maxAttempts {
                    let delaySeconds = policy.baseDelaySeconds
                        * pow(policy.backoffMultiplier, Double(attempt))
                    let delayNanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
                    try await policy.sleep(delayNanoseconds)
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    static func isTransientDownloadError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func extractResumeData(from error: URLError) -> Data? {
        error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }

    func downloadSnapshot(modelID: String, revision: String, to snapshot: URL) async throws {
        // ... unchanged in this PR; still wipes staging dir on error ...
    }
}
```

### phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift (new tests block, ~233 lines)

See git diff — 9 tests + 2 helpers (`SleepCounter` actor and `makeDownloadRetryPolicyNoDelay`). Tests marked at the top of the block with `// MARK: - downloadWithResume`.
