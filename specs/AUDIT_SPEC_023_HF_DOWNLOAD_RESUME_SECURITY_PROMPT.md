# AUDIT (SECURITY lane) — SPEC-023 HuggingFaceSnapshotDownloader retry-with-resume

## Context

macprovider-cli's SPEC-023 installer-integrated autotune-recommend downloads HuggingFace model shards during install. Every 2026-07-02 v1.7.3 install attempt failed at real-network `NSURLErrorDomain -1005 "The network connection was lost."` mid-transfer of a multi-GB `model-*-of-*.safetensors` shard. Root cause: no retry, no resume-data extraction from `URLSession.download(for:)`'s userInfo, whole-model staging directory wiped on any error.

This PR (v1.7.4) adds `HuggingFaceSnapshotDownloader.downloadWithResume` that catches transient URLError codes, extracts `error.userInfo[NSURLSessionDownloadTaskResumeData]`, retries via `URLSession.download(resumeFrom:delegate:)`.

## The change (security-facing summary)

- Adds retry-with-resume behavior inside the existing `HuggingFaceSnapshotDownloader.guardedSession` (an `.ephemeral` URLSession)
- Preserves the existing `HFAssetRedirectGuard` delegate on both initial AND resumed downloads
- Does NOT change `addTokenHeader` (HF_TOKEN handling), the redirect-guard implementation, the artifact SHA256 verification post-download, or the caller (`downloadSnapshot`) semantics
- Max 3 attempts, exponential backoff 5s → 20s → cap. Ceiling on total wall-clock ~25s of sleep across retries.
- No new files opened, no new secrets read, no new network hosts contacted

## Files changed (repo-relative)

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` (+99 / -6)
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` (+1 / -1)
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift` (+233 unit tests)
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift` (+4 / -4)

## Your instructions (SECURITY lane, this file)

You are the SECURITY lens. Focus exclusively on:

- **Auth token exposure through retry.** The initial request carries `HF_TOKEN` via `Authorization: Bearer ...` header if the env var is set (added at line 1424 of AutotuneRecommend.swift). Does the resume path preserve or re-expose that token? Does resume-data serialization include the header, and if so is that persisted in a place attacker-controllable?
- **Redirect guard on resumed downloads.** The initial download uses `HFAssetRedirectGuard()` as the delegate. The resume path *also* uses `HFAssetRedirectGuard()`. Are both codepaths equally protected against redirect to malicious host? Is the resume data an opaque URLSession blob or does it contain a URL that could bypass the guard?
- **Sig-verification / SHA post-download.** After download completes, is the artifact still SHA-256-checked against the signed catalog value? Nothing in this PR touches that check but confirm the retry doesn't skip it.
- **Bypass of catalog-bound provenance.** SPEC-023 pins model_revision + model_sha256. If a resume completes a download from a partial that started from a different revision (e.g., HF changed the revision mid-attempt), does the post-download verification still catch it, or could a modified file get accepted?
- **Info leak via error propagation.** URL and Authorization header can appear in error `userInfo`. If the retry logic surfaces error content anywhere (logs, error messages, telemetry), does it redact Authorization? Note existing error strings look opaque ("download failed <filename>") — verify no new leak surface.
- **DoS / retry storm.** 3 attempts × 25s backoff ceiling. What if downloadSnapshot() has 4 siblings? Could this multiply into visible resource pressure? Reasonable ceiling?
- **Race on shared state.** The class-level `guardedSession` is `.ephemeral`. Does retry-with-resume touch any URLSession-cached state (cookies, credentials cache) that could persist across attempts inappropriately? An ephemeral session shouldn't but confirm.
- **Cancellation-vs-retry semantics.** User Ctrl-C during a retry sleep — does the loop honor cancellation (bubble URLError.cancelled) or does it swallow it and continue retrying?
- **Test injection surface as attack surface.** The `downloadWithResume` static function takes `initialDownload` and `resumeDownload` as @Sendable closures. Production code passes closures that call the real URLSession. Test code passes closures that return synthetic data. If an attacker could somehow reach `downloadWithResume` with custom closures, would that be exploitable? (This is really a check that the entry point is private/internal-scoped correctly.)

Do NOT critique code style, dead vars, or architectural placement — those go to sibling audit lanes.

Return findings as a structured list. For each finding: **file:line, severity (CRITICAL/HIGH/MEDIUM/LOW), one-sentence summary, attack scenario or exposure vector, minimal fix.**

Bar for STOP: 0 CRITICAL, 0 HIGH, 0 MEDIUM in your final response. Iterate the actual codebase and re-audit only after fixes if invited. Absent an invitation, single pass.

## Excerpted code under audit

### phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift (relevant excerpt)

Full source at path above. Key context for security:

```swift
// Existing token handling — UNCHANGED in this PR:
private func addTokenHeader(_ request: inout URLRequest) {
    guard let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty else { return }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
}

// Existing redirect guard — UNCHANGED:
final class HFAssetRedirectGuard: NSObject, URLSessionTaskDelegate {
    // Rejects redirects to hosts not in the HF allowlist,
    // strips Authorization header on cross-origin redirects
    // (see phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift around line 1439)
}

// NEW in this PR:
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
```
