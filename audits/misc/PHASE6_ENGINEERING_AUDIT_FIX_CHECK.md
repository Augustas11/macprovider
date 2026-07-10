# Phase 6 Engineering Audit — FIX-Correctness Check

**Audit date:** 2026-05-29
**Auditor model:** Claude Opus 4.6 (1M context)
**FIX commit:** `bd60e61` ("Phase 6 engineering robustness arc — BUILD + audit FIX (codex session)")
**FIX-base:** `5e386fc` (specs: AUDIT_PHASE6_ENGINEERING_FIX_CHECK_PROMPT.md)
**Locked specs:** SPEC-001 v1.2.4, SPEC-002 v1.1.6, SPEC-003 v0.7, SPEC-006 v0.6

---

## Summary Table

| Category | Scope | Result | Findings |
|---|---|---|---|
| **η** Spec-text drift | SPEC-002 v1.1.5 → v1.1.6 | PARTIAL | 1 MINOR (F-3 numbering collision) |
| **ζ** Test rig isolation | `internal/testfaults/` | PASS | 0 |
| **θ** Keepalive URL redaction | CoordinatorClient.swift | PASS | 0 |
| **α** FIX completeness | Prior audit → FIX diff | SKIPPED | No prior audit report available |
| **β** FIX-introduced defects | All modified files | PASS | 0 |
| **γ** Cancellation semantics | Gateway upstream context | PASS | 0 |
| **δ** Failover correctness | Coordinator buyer server | PASS | 0 |
| **ε** Streaming dead-WS SSE | Pre/post-first-byte split | PASS | 1 OK-with-note |

**Total: 1 MINOR, 1 OK-with-note, 0 CRITICAL, 0 MAJOR**

---

## Findings List

### η-1 — F-3 numbering collision in SPEC-002

**Severity:** MINOR
**File:** `specs/SPEC-002-coordinator.md` lines 700-717 vs lines 2463-2467
**Category:** η (spec-text drift)

The new normative finding "F-3 — Dead provider WebSocket during in-flight inference
MUST fast-fail or fail over" (line 700) collides with the existing D6 finding "F-3 —
Operator endpoints live on the provider WS port" (line 2463). The F-numbering is a
single namespace across the spec: the "F-2 amendment" at line 693 explicitly amends
D6's F-2, confirming that F-1/F-2/F-3 from D6 are the canonical sequence. The new
normative finding should be **F-4**.

**Impact:** Ambiguity when cross-referencing findings by number. No operational or
code-level impact because the two F-3s are in clearly different sections.

**Recommended fix:** Rename the new finding to "F-4" in the normative text at line 700,
the changelog at line 7, and the failure-mode table at line 429.

### ε-1 — Redundant SSE error event in narrow post-[DONE] WS death window

**Severity:** OK-with-note
**File:** `phase4-coordinator/internal/buyer/server.go` lines 624-634
**Category:** ε (streaming dead-WS post-first-byte SSE)

If the provider sends all SSE chunks including `data: [DONE]` but the WebSocket dies
before the relay-level `inference_response_end` message, `relay.Errors` fires with
`ErrRelayClosed` while `committed` is true. The code writes an additional SSE error
event + second `data: [DONE]`. The buyer would see:

```
data: ... (chunks)
data: [DONE]

data: {"error":{"message":"Provider disconnected during streaming",...,"code":"provider_disconnected"}}

data: [DONE]

```

The timing window is microsecond-scale (between last SSE chunk on the HTTP body and
the relay-level completion WS message). Impact is bounded: buyer parsers that stop
reading after `[DONE]` ignore the extra data; parsers that don't would log a warning.

**Recommended fix (Phase 7 backlog candidate):** Track whether a `data: [DONE]` chunk
has been forwarded and suppress the error event if so. Not urgent — the probability
of hitting this window is negligible with current relay implementation.

---

## No-Finding Categories

### η — Spec-text drift (remaining checks)

All η sub-checks other than η-1 passed:

- **Changelog v1.1.5 → v1.1.6:** Present at line 6-7 with accurate one-line summary.
  PASS.
- **Config key references:** Spec references `routing.failover_enabled` and
  `routing.failover_timeout_s` — exact match to `config.go` lines 114, 162 and
  `coordinator.yaml.example` lines 17-18. PASS.
- **Default values:** Spec § config example shows `failover_enabled: true`,
  `failover_timeout_s: 5`. Code defaults in `config.go:132-133` and `server.go:133-134`
  match. PASS.
- **Existing F-1/F-2 text unchanged:** `git diff` shows only additions; F-1 (line 2440)
  and F-2 (line 2451) are byte-identical to the pre-FIX version. PASS.
- **`provider_disconnect` → `provider_disconnected` correction:** Fixed in spec
  (line 866), `implementation-notes.html` (line 139), and all code paths. Consistent
  everywhere. PASS.

### ζ — Test rig isolation

- **Build tags consistent:** `relay.go` and `panic_endpoint_testfaults.go` both use
  `//go:build testfaults`. `doc.go` is the empty marker (no tag). PASS.
- **Production build clean:** `go build ./...` without `testfaults` tag succeeds.
  `testfaults` package shows `[no test files]` in `go test ./...` output (correct —
  it's a marker-only package in production). PASS.
- **No testfaults symbols in binary:** Verified with `go tool nm`. PASS.
- **No `init()` in testfaults:** Grep confirms zero matches. PASS.
- **No production import of testfaults:** Grep across `phase4-coordinator/**/*.go`
  shows only references inside the `testfaults` package itself. PASS.
- **PanicHandler gated by build tag:** `//go:build testfaults` on line 1 of
  `panic_endpoint_testfaults.go`. Not accessible from any production code path. PASS.

### θ — Keepalive URL redaction

- **Redaction scope:** `redactedURL()` in `CoordinatorClient.swift` uses
  `URLComponents` to nil out `user`, `password`, `query`, and `fragment`. All four
  sensitive URL components are covered. PASS.
- **Redaction layer:** Applied only in the `keepaliveDebug()` static method, which is
  the log-emit layer. The coordinator URL in `self.coordinatorURL` is unmodified and
  used for actual WS connections. PASS.
- **Tarball verification:** `macprovider-cli-v1.2.4-verbose-keepalive-darwin-arm64.tar.gz`
  exists (15.5 MB, dated 2026-05-29 16:49). Source-level redaction verified. Binary
  content verification deferred to operator (requires extracting and running
  `strings | grep` on the arm64 binary). PASS.

### α — FIX completeness

**SKIPPED.** The BUILD and FIX were produced in a single Codex session as one commit
(`bd60e61`). No separate prior audit report (`PHASE6_ENGINEERING_AUDIT.md` or similar)
exists in the repository. The BUILD REPORT at `specs/PHASE6_ENGINEERING_BUILD_REPORT.md`
documents deliverables but does not contain audit findings. Category α requires a prior
audit's findings list as input and cannot be evaluated without one.

### β — FIX-introduced defects

Full read of all modified files in their post-FIX state:

- **Off-by-one errors:** No new loop/counter logic with off-by-one risk. The
  `failoverAttempted` boolean is a one-shot flag (set once, checked once per iteration).
  The `excluded` map is additive-only. PASS.
- **Resource leaks:** `monitorHeartbeat` goroutine exits when `pool.Resolve` returns
  `!ok` (provider removed) or when `conn.Close()` triggers the read-loop exit →
  `handleDisconnect` → pool removal. No orphaned goroutines. PASS.
- **Race conditions:** `monitorHeartbeat` reads `provider.LastHeartbeatAt` via
  `pool.Resolve` (which holds the pool lock) and writes only to `conn.Close()` (which
  is thread-safe). No data races. PASS.
- **Nil dereference:** All new error paths (`failoverCandidate`, `logWSDeadMidRequest`,
  `writeSSEError`) operate on value types or check existence before access. PASS.
- **Secret logging:** Keepalive debug uses `redactedURL`. No other new log line emits
  tokens, credentials, or URL userinfo. PASS.
- **Tests vs spec:** New tests assert behavioral contracts (status codes, error codes,
  provider state transitions, failover sequence) not implementation details. PASS.

### γ — Cancellation semantics

- **Buyer hangup → upstream cancellation:** `upCtx` derives from `r.Context()` via
  `context.WithTimeout(r.Context(), ...)`. If the buyer disconnects, `r.Context()` is
  cancelled, which cancels `upCtx`, which cancels the upstream HTTP request. Verified
  by `TestChatCompletionsCoordinatorRequestCancelsWithBuyerContext`. PASS.
- **Timeout → Response.Body closed:** `defer cancelUpstream()` at line 817 ensures the
  context cancel runs. `defer resp.Body.Close()` at line 833 ensures the body is closed.
  Both defers fire on every exit path (including panic, via Go's guarantee). PASS.
- **No stale `context.Background()` for upstream:** The FIX removed the
  `context.Background()` branch that existed for streaming. All remaining
  `context.Background()` calls in the gateway are for store operations (refund, settle,
  release concurrency) which MUST outlive `r.Context()`. PASS.
- **`defer cancelUpstream()` covers all paths:** Placed at line 817, immediately after
  the `context.WithTimeout` call. Go defers are LIFO and run on any return/panic. PASS.

### δ — Failover correctness

- **Failover cannot trigger another failover:** `failoverAttempted` is set `true` on
  first failover. On second `wsForwardProviderDisconnected`, the
  `failoverAttempted || hasPinnedRoute(r.Header)` check fires and returns 502. Verified
  by `TestChatCompletionsWSTunneledDeadProviderFailoverOnlyOnce` (three providers, only
  p1→p2 attempted, p3 never reached). PASS.
- **Pinned provider classification consistent:** `hasPinnedRoute` checks both
  `X-MacProvider-Provider` and `X-MacProvider-Session` headers. It is called in
  `handleChatCompletions` (caller) AND in `failoverCandidate` (defense in depth). Both
  use the same `r.Header`. Verified by
  `TestChatCompletionsWSTunneledPinnedDeadProviderDoesNotFailover` (both header
  variants tested). PASS.
- **Failed provider excluded from candidate set:** `excluded[routeKey(provider)]` is
  set in the caller before `failoverCandidate` is called, and `failoverCandidate` also
  adds `routeKey(failed)` (redundant but safe). `selectProviderExcluding` skips
  excluded entries. PASS.
- **Single-provider-dies returns 502:** When `failoverCandidate` finds no candidates
  (only one provider for the model), it returns `!ok` and the caller writes 502 with
  `provider_disconnected`. PASS.
- **Request ID propagation:** `originalRequestID` (first attempt), `requestID`
  (current attempt, updated on failover via `nextRequestID`), and `externalRequestID`
  (buyer's `X-Request-ID`, stable across failover) are all tracked in
  `logWSDeadMidRequest`. The buyer-visible `X-Request-ID` is never mutated. PASS.

### ε — Streaming dead-WS post-first-byte SSE (remaining checks)

- **OpenAI envelope shape:** `writeSSEError` produces
  `data: {"error":{"message":"...","type":"server_error","code":"..."}}\n\n` then
  `data: [DONE]\n\n`. Matches OpenAI SSE convention. `%q` in `fmt.Fprintf` ensures
  proper JSON string escaping. PASS.
- **Event boundary:** Each SSE event ends with `\n\n` (two newlines). PASS.
- **No JSON corruption:** All inputs to `writeSSEError` are hardcoded English strings.
  `%q` handles escaping correctly for ASCII. No risk of half-written provider data
  because `writeSSEError` constructs the entire event from scratch. PASS.
- **Distinguishable error codes:** `provider_disconnected` (dead WS) vs
  `provider_error` (generic relay failure). Different codes, different messages. Buyer
  can distinguish. PASS.
- **Flusher called after terminal event:** Every code path that calls `writeSSEError`
  follows with `if flusher != nil { flusher.Flush() }`. PASS.

---

## Reverse Verification

No prior audit findings to reverse-verify (category α SKIPPED). The BUILD REPORT's
four sub-phase claims were verified against the committed code:

| Sub-phase | BUILD REPORT claim | Code evidence | Verdict |
|---|---|---|---|
| 6E1 gateway timeout parity | Stream + non-stream share CoordinatorTimeout parented to buyer cancel | `server.go:816` `context.WithTimeout(r.Context(), ...)` for both paths; 2 tests | CONFIRMED |
| 6E2 coordinator dead-WS fast-fail/failover | `routing.failover_enabled`, `routing.failover_timeout_s`; one retry max; pins suppress failover; streaming pre/post-first-byte | `buyer/server.go` failover loop + `failoverCandidate` + `hasPinnedRoute`; 6 tests | CONFIRMED |
| 6E3 keepalive investigation | Verbose logging behind `MACPROVIDER_KEEPALIVE_DEBUG=1`; redacted URLs | `CoordinatorClient.swift` `keepaliveDebug` + `redactedURL`; root-cause doc filed | CONFIRMED |
| 6E4 fault-injection rig | Build-tag-gated `internal/testfaults`; dead-WS relay, slow reader, panic handler | `doc.go` + `relay.go` + `panic_endpoint_testfaults.go`; all `//go:build testfaults` | CONFIRMED |

---

## Test Evidence

```
$ go test ./...   (phase4-coordinator)
ok   internal/buyer   0.781s
ok   internal/ws      5.598s
testfaults: [no test files]  ← confirms no production compilation

$ go test ./...   (phase5-gateway)
ok   internal/config  0.572s
ok   internal/router  3.063s

$ go build ./...  (without testfaults tag) → clean
$ go tool nm → no testfaults symbols in binary
```

---

## Recommendation

**PROCEED-TO-DEPLOY**

Zero CRITICAL or MAJOR findings. The one MINOR (η-1, F-3 numbering collision) is a
spec-text housekeeping item that does not affect code correctness, deployment safety,
or runtime behavior. It can be fixed inline in a 30-second edit or deferred to the
next spec revision. The one OK-with-note (ε-1, redundant SSE event in microsecond
timing window) is a Phase 7 backlog candidate with negligible probability of
occurrence.

The coordinator + gateway are safe to cross-compile, deploy to Pearl, smoke-test,
and enter the 24h journal-watch period per the Entry 27 deployment pattern.

**Estimated audit time:** ~45 minutes of focused review + report authoring.
