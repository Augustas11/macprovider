# M2-1b Design — `transportResult` Unification + Forward-State Sketch

**Status:** PROPOSAL. Draft PR is open implementing transportResult; this doc explains the shape and the 1c forwardState sketch. Review before un-drafting.

**Audit refs:** `audits/2026-06-10/REPO_AUDIT.md` §3.1 item 3 (ARCH-1), §5 sketch (M2-1).

**Predecessors:** M2-1a (#48, merged) extracted `advanceToNextProvider` from 4 of 5 audit-identified callsites. M2-1b unifies the three transport-specific return shapes behind one type, without collapsing the three transport loops. M2-1c will collapse them.

## Recommendation

Two related types, introduced in two PRs (1b + 1c) — not bundled:

| Type | PR | Lifetime | Owns |
|---|---|---|---|
| `transportResult` | **M2-1b (this PR)** | per attempt | "what just happened in one forward call" — billing payload, retry semantics, behaviour flags |
| `forwardState` | **M2-1c (next sub-PR)** | per request | "what's accumulated across all attempts" — routingDone, explicitRetries, faultedProviders, faultedRoutes, current provider |

The codex architect auditor asked us to lock the forwardState shape **before 1b opens**. I'm presenting the proposed shape in this design doc for review, but the PR itself implements only `transportResult` — that's faithful to the audit's original M2-1 sketch which split 1b (classification) and 1c (loop collapse) into separate steps. The three transport loops at server.go:1085-1170 / 1172-1257 / 1264-1356 remain untouched in this PR; M2-1c will route them through the classifiers and collapse them into the unified failover skeleton.

## `transportResult` (this PR)

```go
// transportResult is the transport-agnostic shape every forward call
// produces. M2-1b unifies the three return tuples
// (wsForwardResult+attempt, wsForwardResult+status+attempt,
// *http.Response+error+attempt) behind this type. The three transport
// loops in handleChatCompletions continue to exist in this PR; they
// each call through a classifier to convert their native return into
// transportResult and then drive retry decisions off the flags.
type transportResult struct {
    // Native kind, preserved so transport-specific renderers
    // (writeStreamForwardError, etc.) can still dispatch on it where
    // necessary. The unified loop in 1c will minimise dependence on
    // this field; for 1b it lets the existing dispatch shape survive.
    kind wsForwardResult

    // Canonical HTTP status. WS forwards map their forwardResult to a
    // status here so attempt logging is uniform.
    status int

    // The existing billing/log payload. Untouched — preserves byte-
    // identical attempt-row format the ledger keys off.
    attempt requestLogAttempt

    // Network/dispatch error, where applicable.
    err error

    // Behaviour flags — the AUDIT-CONFIRMED intentional per-transport
    // differences, encoded as data on this struct so the unified loop
    // in 1c can branch on flags rather than transport-specific if/else.
    //
    // retryable: caller should advance to the next provider.
    // failoverEligible: WS "failoverCandidate" path is in play. Set by
    //   both non-streaming WS disconnect and streaming pre-first-chunk
    //   disconnect; the two diverge on `retryable` instead.
    // markBusy: caller should call s.pool.MarkState(StateBusy) for the
    //   current provider before deciding retry.
    // committed: streaming first-chunk has been received — the attempt
    //   is committed to this provider; never retry, just finalize.
    // cancelled: buyer cancelled the request (ctx.Done). Skip attempt
    //   logging unless the attempt has otherwise-loggable content.
    retryable        bool
    failoverEligible bool
    markBusy         bool
    committed        bool
    cancelled        bool
}
```

### Three classifiers

```go
// classifyHTTPResult converts the HTTP-forward dispatch tuple into the
// unified transportResult. Encodes HTTP-only invariants: per-attempt
// context timeout maps to status=504; readLimitedBody failure maps to
// 502; nil-response normalizes to status=502 (matches
// server.go:1335-1341).
func classifyHTTPResult(resp *http.Response, err error, attempt requestLogAttempt) transportResult

// classifyWSResult converts forwardWS's return into transportResult
// for the WS-tunneled NON-STREAMING loop. Encodes the
// failoverCandidate path as failoverEligible=true on
// wsForwardProviderDisconnected. Critically, sets retryable=FALSE on
// disconnect — the WS-non-streaming loop fast-fails with 502 when
// failover misses (server.go:1217-1228); it does NOT fall through to
// shouldRetry/advanceToNextProvider.
func classifyWSResult(result wsForwardResult, attempt requestLogAttempt) transportResult

// classifyStreamResult converts forwardStreaming's return into
// transportResult. Encodes the first-chunk-received commit semantics
// as committed=true on wsForwardProviderDisconnectedCommitted +
// wsForwardCancelled. ALSO sets failoverEligible=true on
// wsForwardProviderDisconnected (pre-first-chunk) — the streaming
// loop runs the same failoverCandidate code at server.go:1120 as
// WS-non-streaming — AND retryable=true, since the streaming loop
// falls through to shouldRetry at server.go:1130 if failover misses.
// This per-transport divergence on the same wsForwardResult is what
// kept the three failover loops drifting; encoding it as two flags
// lets the M2-1c unified loop branch correctly.
func classifyStreamResult(result wsForwardResult, status int, attempt requestLogAttempt) transportResult
```

### Audit-flagged invariants preserved

The audit-verifier was explicit that these are *intentional* per-transport differences and **must not be flattened** at any point in the strangler:

1. **HTTP per-attempt context timeout** (`buyer/server.go:1262` pre-1a) — stays HTTP-only. Encoded as a separate code path inside `classifyHTTPResult`; not visible as a flag because no other transport has it.
2. **WS failoverCandidate** — encoded as `failoverEligible`. Set by BOTH `classifyWSResult` (non-streaming disconnect) AND `classifyStreamResult` (streaming pre-first-chunk disconnect) — they share the same `failoverCandidate` code at `server.go:1120` / `:1223`. Never set by `classifyHTTPResult`. The cross-transport divergence on the same `wsForwardResult` lives in the `retryable` flag instead: WS-non-streaming sets `retryable=false` (fast-fail when failover misses), streaming pre-chunk sets `retryable=true` (falls through to `shouldRetry`).
3. **Streaming first-chunk-received commits the attempt** — encoded as `committed`. Only `classifyStreamResult` ever sets it to true.

## `forwardState` (sketch — for M2-1c, NOT this PR)

```go
// forwardState collects the per-request state that the three transport
// loops mutate as they advance through retry attempts. M2-1c will
// thread this through the single failover skeleton (replacing the three
// loops with one driven by transportResult + forwardState). The shape
// is locked here so that M2-1b's transportResult fits cleanly when
// the unified loop arrives.
//
// Per-loop scratch (excluded, failoverAttempted) is intentionally NOT
// in here — that's per-transport in M2-1b's world and gets folded in
// only at 1c when the loops collapse.
type forwardState struct {
    routingDone      time.Time
    explicitRetries  int
    faultedProviders int
    faultedRoutes    map[string]struct{}  // already shared across loops pre-1a
    provider         pool.Provider         // mutates each advance
}
```

**Why these 5 fields:** they're the per-request state currently declared at the top of `handleChatCompletions` and threaded by pointer through `advanceToNextProvider`. The 1c work is mechanical — replace the pointer parameters with a `*forwardState` receiver, and the per-loop `excluded`/`failoverAttempted` locals migrate into the unified loop.

## What this PR does NOT change

- The three transport loops at lines 1069 / 1156 / 1245. They survive 1b unchanged in shape.
- `advanceToNextProvider` from M2-1a. It still takes pointers; 1c rewrites it.
- The billing ledger format. `requestLogAttempt` is embedded in `transportResult`, not replaced.
- `forwardState` is not introduced. That's M2-1c.

## Critical invariants (audit-cited)

`attempt_n` numbering and `logAttempt` ordering MUST be byte-identical to pre-refactor behavior; the billing ledger keys off them. Two regression checks gate this PR:

1. The full coordinator suite (`go test ./...`) stays green, including the M1-2 divergence tests that pinned the streaming-WS queue-full handling.
2. A new test (will land in the implementing commit) captures the sequence of logged attempts in a known retry+failover scenario and asserts the row sequence is exactly the M1-2-fixed shape. This is the audit's stated 1c requirement, but adding it in 1b is cheap insurance.

## Open questions

1. **Where to put the classifiers?** Two options:
   - **a)** New file `phase4-coordinator/internal/buyer/transport_result.go`. Cleaner separation but spreads the buyer-server logic across files.
   - **b)** Same `server.go` as a new section. Keeps everything together while 1c lands.
   - **Recommendation: (a)** — by the end of 1c the buyer-server is gaining `forwardState`, the unified loop, and the classifiers. Splitting transport_result.go early keeps the cognitive load on each file lower. Option (b) is reasonable if you'd rather defer the file split to a separate PR after 1c lands.

2. **Should `cancelled` be a separate flag or rolled into `committed`?** Streaming has both wsForwardCancelled (buyer ctx cancel) and wsForwardProviderDisconnectedCommitted (first chunk received, then disconnected). The audit treats them differently — `committed` becomes a success-with-truncation, `cancelled` becomes a no-op attempt log. Keeping them separate matches existing behaviour. Will revisit at 1c.
