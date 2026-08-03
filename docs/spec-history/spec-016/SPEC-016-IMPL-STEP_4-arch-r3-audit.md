# SPEC-016 Step 4 — architecture-review lane, r3 audit

Codex run: architect lane, round 3
HEAD: `fe6a699`
Branch: `impl/spec-016`

## Verdict

**BLOCK** — 0 CRITICAL / 1 MAJOR / 1 MEDIUM / 0 LOW.

The r2 fixes are architecturally closed for the new `RunNowController`
and SPKI live-read primitive. But r3 found a new `TuningSnapshot`
exhaustiveness gap: the runner stale-cancel producer still uses
startup `RunInterval` for the `3 × run_interval` stale threshold while
the r2 contract says stale-age checks should live-read. Same authority
bug class as r1/r2.

Validation: `go test ./... -count=1` passed in `phase4-coordinator`.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| MAJOR    | 1 |
| MEDIUM   | 1 |
| LOW      | 0 |

## R2 Closure Verification

| R2 finding | Verdict |
|------------|---------|
| [arch:r2-4.1] run-now contract | **CLOSED**. One controller built at main.go:935 passed into nested Step2/3/4 mux options at main.go:946. Mux levels require/use the same controller. Mutex update before release; RunOnce outside the lock. |
| [arch:r2-4.2] SPKI live read | **CLOSED for the primitive**, with new operational doc gap (see [arch:r3-4.2]). |

## TuningSnapshot Exhaustiveness Enumeration

| Field | Status |
|-------|--------|
| `AddressCoolingOffPeriod` | OK — live read at write time via `currentCoolingOff()`; documented non-recompute semantics (addresses.go:87, :441) |
| `RunInterval` | **BLOCK** — ticker cadence restart-only documented, but stale producer still uses startup value at runner.go:383 |
| `RunNowMinInterval` | OK — `RunNowController.currentInterval()` reads live tuning (runnow.go:62) |
| `ConfirmationBlocks` | OK — runner captures snapshot per cycle (runner.go:343); receipt depth uses `r.snap().ConfirmationBlocks` (runner.go:646) |
| `MaxRowsPerRun` | OK — ready selection uses per-cycle snapshot (runner.go:404) |
| `ReorgPollWindow` | OK — reorg poller reads live window (reorg.go:74, :92) |
| `LowBalanceThreshold` | OK — balance probes use per-cycle snapshot (runner.go:1367) |
| `LowNativeThreshold` | OK — native probe uses per-cycle snapshot (runner.go:1394) |
| `RPCURLPrimaryPinSPKI` | OK primitive — closure in main reads provider snapshot (main.go:728); verifier calls pinFn() (rpc.go:175) |
| `RPCURLSecondaryPinSPKI` | OK primitive — closure in main reads provider snapshot (main.go:733); verifier calls pinFn() (rpc.go:175) |

## Findings

### [arch:r3-4.1] MAJOR — `RunInterval` is not exhaustive across stale-cancel production

- `phase4-coordinator/internal/payout/runner.go:383` — stale producer
  gets startup `r.opts.RunInterval`.
- `phase4-coordinator/internal/payout/orphans.go:396` — stale cutoff
  computed from passed interval.
- `phase4-coordinator/internal/payout/reaper.go:58` — reaper correctly
  live-reads `RunInterval`.
- `specs/SPEC-016-payout-pipeline.md:2033` — stale threshold is
  `3 × run_interval`.
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r2.md:48` — r2 contract
  separates ticker restart-only from live stale-age checks.

`TuningSnapshot` includes `RunInterval`. Runner documents restart-only
semantics for ticker cadence (runner.go:86), and tickers do capture
startup value. But `RunInterval` is ALSO the stale-cancel threshold
input. The reaper follows the r2 design with
`3 * r.tuning.Snapshot().RunInterval`. The synchronous runner producer
still calls `ProduceStaleOutboxRows(..., r.opts.RunInterval)`.

An accepted SIGHUP `run_interval` change updates reaper stale-age but
NOT the runner-owned stale producer. Same authority leak class as
r1/r2: reload accepted, one runtime consumer keeps the startup value.

**Fix:** in `Runner.RunOnce`, pass `snap.RunInterval` to
`ProduceStaleOutboxRows` instead of `r.opts.RunInterval`. Add a test
proving a tuning reload changes the stale cutoff without restart.

### [arch:r3-4.2] MEDIUM — SPKI live-read is real, but pooled TLS limitation is undocumented

- `phase4-coordinator/internal/payout/rpc.go:139` — `NewHTTPRPCClient`
  takes `func() string`.
- `phase4-coordinator/internal/payout/rpc.go:149` — installs
  pinFn-driven verifier.
- `phase4-coordinator/internal/payout/rpc.go:175` — verifier calls
  pinFn() per TLS handshake.
- `phase4-coordinator/internal/payout/rpc.go:143` — pooled transport
  with `IdleConnTimeout: 90 * time.Second`.
- `phase4-coordinator/dist/payout-runbook.md:125` — runbook covers
  alert checks + reload events, but repository search found no
  SPKI/TLS/pin reload section.

The live-read fix closes the captured-value bug at the verifier level,
but `http.Transport` pools established TLS connections. A SIGHUP
updates pins for FUTURE handshakes but does NOT re-verify
already-established pooled connections. Acceptable only if documented
OR if reload closes idle RPC connections.

Converges with [sec:r3-1] (security puts at HIGH for the integrity
implications).

**Fix (two options, pick one):**
1. Operational: add a payout-runbook section explaining pin changes
   apply on the next TLS handshake; document that idle pooled
   connections persist for ≤90s.
2. Programmatic: give RPC clients a `CloseIdleConnections()` hook
   and call after accepted SPKI pin reloads.

Recommend (2) per [sec:r3-1] BLOCK.

## Root Cause

The architecture now has a mostly correct `TuningProvider`, but
`RunInterval` has two meanings: scheduler cadence (restart-only) AND
stale-age threshold (should be live). The implementation documented
restart-only semantics for cadence, then accidentally let that
documentation cover a non-cadence threshold path that should live-read.

`payout_run_now_invoked` adds `outcome`; SPEC §7.1 says the listed
fields are a "minimum field set" (specs/SPEC-016-payout-pipeline.md:3707),
so this is an acceptable extension, not a drift.

## Recommendations

1. **Fix `RunInterval` stale-producer authority** — low effort, high
   impact. Pass `snap.RunInterval` to `ProduceStaleOutboxRows`. Add
   a test proving a tuning reload changes the stale cutoff without
   restart.

2. **Document or close pooled SPKI connections on reload** —
   low/medium effort, medium impact. Programmatic close is preferred
   per the security lane verdict.

## Trade-offs

| Option | Pros | Cons |
|--------|------|------|
| Live stale threshold via `snap.RunInterval` | Matches r2 contract and reaper behavior; closes hot-reload authority gap | A SIGHUP can change stale-page timing before process restart |
| Declare all `RunInterval` effects restart-only | Simpler lifecycle model | Contradicts existing reaper design and accepted SIGHUP semantics |
| Document SPKI pool limitation | Small, low-risk ops fix | Does not force immediate distrust of existing pooled TLS sessions |
| Close idle RPC connections on reload | Stronger operational semantics | Requires a small lifecycle/API addition around RPC clients |

## Step 4 PR Readiness Matrix

| Row | Verdict |
|-----|---------|
| §6.5 dual-namespace loader split | OK |
| §7.4 reconciliation queries verbatim | OK |
| §7.4 chain-balance worker drift detection | OK |
| §7.4 negative-drift halt | OK |
| §6.2 balance monitoring emits | OK |
| §7.3 provider-scoped read endpoint | OK |
| §4.2 admin run-now contract | OK |
| §7.1 event field-name compliance | OK for alerts; **WATCH** for config_reloaded + payout_rpc_disagreement (see code r3) |
| TuningProvider authoritative across consumers | **BLOCK** |
| Halt primitive authoritative across entry points | OK |
| Ops bundle | WATCH — SPKI pool limitation missing |
| Construction ordering correctness | OK |
| Step 3 advisories addressed or deferred | DEFERRED |

## Recommendation

BLOCK on [arch:r3-4.1] MAJOR. The MEDIUM is fix-then-proceed (or
defer via runbook update).
