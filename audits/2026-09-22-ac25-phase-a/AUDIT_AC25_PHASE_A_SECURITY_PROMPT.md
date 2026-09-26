# Shared context — AC-25 Phase A: make lifecycle outcomes API-visible

Repo: macprovider. Worktree `/Users/augstar/macprovider-ac25-m2`, branch
`campaign/ac25-m2-api-lifecycle`, based on `origin/main` @ `b9b20fe4`.

Review the FULL combined diff as it will land: `git diff origin/main..HEAD`
(2 commits, ~1032 insertions / 17 deletions across 9 files, plus a plan doc).
This is the complete fix, not a follow-up slice.

## Why

SPEC-038 `:607` requires the scheduler and its HTTP/relay integration to map
every batched request to exactly one API-visible terminal outcome. The overlay
table `:614-624` enumerates the lifecycle points; AC-25 (`:840-846`) requires
they be proven **through the real HTTP/relay serving surface**.

Six outcomes were not API-visible, so AC-25 could not be evidenced at all:

- `backpressure` was mapped only on the **streaming** path; non-streaming bare
  rethrew and surfaced as generic `model_not_loaded`/`internal_error`.
- `duplicateRequestMismatch`, `idempotencyWindowExpired`,
  `idempotencyAuthorityUnavailable`, `unsupported(code)`, `requestFailed(code)`
  had no APIError mapping at all on the serve path.
- There was **no admission-wait deadline** — only drain (30 s) and token
  delivery (5 s) timeouts. A queued request could wait forever.
- Direct HTTP passed `shouldCancel: { false }`, so a disconnected client left
  the request running and burned a slot. Only `InferenceRelay` had cancellation.

## What changed

1. One `ContinuousBatchSchedulerError.asAPIError()` called from both serve
   paths, so they cannot drift again. Mapping table is in the commit message.
   409 for duplicate/idempotency matches the existing buyer-surface convention
   (`chat_proxy.go:532`, `relay_blind.go:628`, `wallet_sessions.go:1204`).
2. `.drained` / `.drainTimedOut` deliberately left unmapped: only reachable via
   `ContinuousBatchScheduler.drain()`, whose sole `Sources/` caller is
   `MSBThroughputCommand` (a harness). Mapping them would ship unreachable code.
3. New `queueWaitTimeoutNanoseconds`, default 30 s, configurable via
   `continuous_batch_queue_wait_timeout_ms` / env / flag. Clock starts on
   enqueue; absolute deadline so a `capacityExceeded` bounce resumes rather
   than restarts. On expiry: no terminal result cached, so never replayable or
   settlement-eligible.
4. `ClientDisconnectState` in `HTTPServer.swift`, armed on the event loop
   before inference starts, read by `shouldCancel`. Mirrors
   `InferenceRelay`'s `RelayRequestState`. Holds no channel/handler reference.

## Two deliberate behaviour changes on the money path

- **`backpressure` now reports `inference_ran: false`** (was `true`). A
  pre-admission rejection runs no inference; the overlay calls queue-full
  non-settling. Claimed basis: the flag is only ever *written* into the error
  envelope and nothing in provider/coordinator/gateway reads it back to drive
  retry, settlement, or receipts. **Verify that claim.**
- **Queue-pressure 503s now serialize `retryable: true`.** Claimed basis:
  nothing branches on `retryable` for routing, failover, sanctions, or
  settlement; its one production read sets the gateway `Retry-After` header.
  **Verify that claim too** — it is a buyer-visible contract field.

## Known gap, deliberately not addressed

`retryable: true` reaches the buyer on direct HTTP only. `InferenceRelay`
forwards it for four codes; `buyer/server.go` nulls overrides outside
`isSpec019RetryableOverrideCode`; `gatewayRetryableByCode` lacks both codes.
Three Go/Swift forwarding gates must widen before `:614` closes end to end.

## Verification already run

- `cd phase3-binary && swift build` → exit 0.
- `swift test --filter 'macprovider_cliTests'` → 3072 tests, 37 skipped,
  30 failures — all pre-existing local-env noise (22 `CoordinatorClientTests`,
  1 `DoctorCommandTests`, 1 `EndToEndAcceptanceTests`). No new failures.

## Output format

Findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line, a
concrete failure scenario, and a suggested fix. Gate: **0 CRITICAL, 0 HIGH,
0 MEDIUM**. State explicitly if you find none. Do not propose SPEC edits.

## Your lane: SECURITY REVIEW

- The two money-path behaviour changes: verify the claims independently.
  Does anything read `inference_ran` or `retryable` to drive settlement,
  receipts, retry, failover, sanctions, or payout?
- Can the new cancellation path cause a request to be settled twice, settled
  after cancellation, or produce a receipt for partial output?
- Can a client induce resource exhaustion or premature cancellation of
  **another** request via the disconnect flag (cross-request contamination)?
- Does the queue-wait deadline create a denial-of-service lever, or leak
  state on expiry? Can an attacker use it to evict others' queued work?
- Do any new error codes or messages disclose model SHAs, hardware identity,
  config paths, or internal state to a buyer over HTTP?
- Does `retryable: true` on queue pressure enable an amplification loop
  (client retries immediately, worsening the queue-full condition)?
- Confirm no receipt, usage, billing, model-identity, or settlement field
  changes shape.
