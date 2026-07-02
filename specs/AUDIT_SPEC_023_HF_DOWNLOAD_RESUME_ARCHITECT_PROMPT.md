# AUDIT (ARCHITECT lane) — SPEC-023 HuggingFaceSnapshotDownloader retry-with-resume

## Context

macprovider-cli's SPEC-023 installer-integrated autotune-recommend downloads HuggingFace model shards during install. On operator's M5, every 2026-07-02 v1.7.3 install failed at real-network `NSURLErrorDomain -1005 "The network connection was lost."` mid-transfer.

Root cause: `HuggingFaceSnapshotDownloader.download` closure at `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:1361-1394` treats any URLSession download failure as fatal. No retry, no resume-data extraction, no partial-progress preservation. Entire staging directory (potentially 10+ GB of previously-completed shards) wiped on any error.

## The change

- New `DownloadRetryPolicy` struct (injectable production defaults: 3 attempts, 5s base delay, 4x backoff, `Task.sleep`)
- New `HuggingFaceSnapshotDownloader.downloadWithResume` static function taking `initialDownload` + `resumeDownload` as `@Sendable` closures
- The instance-level `download` closure now delegates to `downloadWithResume` with production defaults
- Bump binaryVersion 1.7.3 → 1.7.4

Related surrounding code (unchanged):
- `HuggingFaceSnapshotDownloader.downloadSnapshot(modelID:revision:to:)` iterates siblings sequentially, wraps in try/catch that wipes staging on error. **Still wipes on terminal failure after all retries exhausted.**
- `HFAssetRedirectGuard` delegate rejects redirects to non-HF hosts, strips Authorization header
- `guardedSession` is a static `.ephemeral` URLSession
- `addTokenHeader` reads HF_TOKEN env var, sets `Authorization: Bearer ...` on request

## Files changed (repo-relative)

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` (+99 / -6)
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` (+1 / -1)
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift` (+233)
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift` (+4 / -4)

## Your instructions (ARCHITECT lane, this file)

You are the ARCHITECT lens. Focus exclusively on:

- **Placement of retry.** Is `downloadWithResume` at the right layer? Should retry live at the per-sibling level (inside the for-loop in `downloadSnapshot`) versus per-request (inside the closure)? Trade-off: sibling-level catches per-file failures but misses cross-sibling patterns; request-level (current) doesn't preserve completed siblings on terminal failure.
- **Staging-dir wipe on terminal failure.** After `downloadWithResume` exhausts retries and throws, `downloadSnapshot`'s catch still wipes the whole staging dir (line ~1392). Should this PR ALSO fix that so partial progress across siblings survives to the next `autotune --recommend` invocation? Or is that out of scope, with a follow-up PR?
- **Sequential vs parallel sibling downloads.** Line 1374 loops siblings serially. On a 4-shard model (~22 GB total), that means 4 sequential downloads. Parallelism could halve wall-clock but adds concurrent-connection cost, HF rate-limit risk, and memory pressure. Trade-off — is the current serial approach still the right choice given retries now handle transient drops? Any latent bug from concurrent-safe assumption vs actual serial invariant?
- **Backoff schedule sanity.** 5s → 20s → cap at 80s (but only 3 attempts total so only 5s + 20s = 25s wall-clock added). Reasonable for install-time UX? For headless CI/scripting?
- **Configuration surface.** The `DownloadRetryPolicy` struct is public/internal-scoped. Should operators be able to override via env var (`MACPROVIDER_HF_MAX_ATTEMPTS`, `MACPROVIDER_HF_BASE_DELAY`) for degraded environments? Or is that YAGNI?
- **Test injection design.** `downloadWithResume` accepts closures for `initialDownload` + `resumeDownload`. Alternative: accept a session + delegate factory. Trade-off in test overhead vs production directness.
- **Layering vs mlx-swift-examples.** The mlx-swift-examples package (2.29.1) has its own HF download machinery via MLXLLM/MLXLMCommon. SPEC-023 uses its own downloader instead to enforce hash+revision provenance. Given this PR adds retry logic that mlx-swift-examples' downloader may already have (or may not), any risk of duplicated / conflicting behavior when both hit HF for the same model?
- **Task cancellation semantics.** Structured concurrency: does a `Task.cancel()` propagate correctly through `policy.sleep` + the retry loop? Should it? What's the UX contract during a Ctrl-C mid-install?
- **Version bump appropriateness.** 1.7.3 → 1.7.4 (patch). Change is behavior-affecting (users who previously failed will now succeed). Is patch correct or should this be a minor bump (1.8.0)?
- **Observability.** No new log line emitted on retry. Should the retry emit a stderr line so users see "retrying download after 5s (attempt 2/3)…"? SPEC-023 already emits "Running paid-yield recommendation before service start." from install.sh — should the retries be visible?

Do NOT critique code correctness (state machine, edge cases) or security surface — those go to sibling audit lanes.

Return findings as a structured list. For each finding: **file:line, severity (CRITICAL/HIGH/MEDIUM/LOW), one-sentence summary, architectural concern, minimal fix.**

Bar for STOP: 0 CRITICAL, 0 HIGH, 0 MEDIUM in your final response. Iterate the actual codebase and re-audit only after fixes if invited. Absent an invitation, single pass.

## Excerpted code under audit

### phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift (relevant excerpt)

Same excerpts as CODE + SECURITY lanes; see those files. Key architectural context:

```swift
// UNCHANGED — caller of the (now retrying) download closure:
func downloadSnapshot(modelID: String, revision: String, to snapshot: URL) async throws {
    let siblings = try await modelSiblings(modelID: modelID, revision: revision)
    guard !siblings.isEmpty else {
        throw AutotuneRecommendError.invalidArtifact("empty HuggingFace snapshot \(modelID)@\(revision)")
    }
    let staging = snapshot.deletingLastPathComponent()
        .appendingPathComponent(".download-\(revision)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    do {
        for sibling in siblings {
            try validateRelativeHFPath(sibling.rfilename)
            let destination = staging.appendingPathComponent(sibling.rfilename, isDirectory: false)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            var request = URLRequest(url: resolveURL(modelID: modelID, revision: revision, filename: sibling.rfilename))
            addTokenHeader(&request)
            let (temporary, response) = try await download(request)  // <-- NOW retries under the hood
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                throw AutotuneRecommendError.invalidArtifact("download failed \(sibling.rfilename)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            _ = chmod(destination.path, 0o600)
        }
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: snapshot)
        try FileManager.default.moveItem(at: staging, to: snapshot)
    } catch {
        try? FileManager.default.removeItem(at: staging)  // <-- STILL wipes on terminal failure
        throw error
    }
}
```
