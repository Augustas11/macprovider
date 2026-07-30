## Summary

Step 2’s internal payout primitives are mostly shaped for Step 3/4, but the coordinator boundary is not: `setupPayout` acquires a lease and asserts runner co-residency without constructing or starting the runner, and the Step 2 admin mux would be unreachable under the current `/providers/` mount. The main recommendation is to make Step 3 start by fixing lifecycle ownership and mux mounting before adding more admin endpoints.

Fresh validation passed:

```text
go test -count=1 ./internal/payout ./cmd/coordinator
```

## Analysis

[arch:3.1] [MAJOR] Lease/topology is half-wired when `payout.enabled=true`  
What: `setupPayout` asserts `HandlerEnabled=true` and `RunnerCoResident=true`, then acquires the runner lease, but it never constructs a `Runner`: `RunnerOptions.Claimer` is `nil`, `runnerOpts` is discarded, `NewRunner` is not called, and `main.go` discards `payoutS2`. Shutdown never invokes `payoutS2.stopFn`, so a process that starts with payout enabled can hold a fresh lease without heartbeat or clean release. This contradicts the SPEC expectation that the runner starts from `main.go` when `payout.enabled=true`.  
Trade-off: Step 2 kept billing wiring deferred, but it turned a documented follow-up into a false co-residency invariant and stale-lease risk.  
Suggestion: Move `Acquire` into the same lifecycle branch that constructs `NewRunner` with a real `billing.Store` claimer and calls `runner.Start`; on shutdown call `runner.Stop` then `Release`, matching `Runner.Stop`’s own contract.

[arch:3.2] [MAJOR] `/admin/payout/*` routes are not reachable through current mounting  
What: `NewMuxStep2` registers `/admin/payout/abandon-attempt` and `/admin/payout/run-now`, but `main.go` mounts the payout handler only at `/providers/`. A request to `/admin/payout/...` will not be dispatched to that handler by `http.ServeMux`. Current `setupPayout` also still returns `NewMux`, not `NewMuxStep2`. Step 3’s `record-orphan`, `record-funding`, and pause/resume routes will fight the same composition bug.  
Trade-off: Keeping provider payout-address and billing fallback under one mux preserved Step 1 behavior, but mixing root-level admin routes into a handler mounted at `/providers/` makes route-table parity insufficient.  
Suggestion: Split provider and admin payout muxes, or mount the same Step 2/3 payout mux at both `/providers/` and `/admin/payout/`; add coordinator-level tests against the outer `providerMux`, not just chi-internal route parity.

[arch:3.3] [MEDIUM] Step 4 hot-reload and RPC pinning seams need a runtime owner  
What: Config declares SPKI pins and validates them, but `main.go` constructs both RPC clients with `NewHTTPRPCClient(url, label, 20*time.Second)`, and that constructor does not install a pinned transport. Payout tuning is also read into value fields at startup, while SIGHUP currently reloads Tier2/rewards/settlement only. Step 4 will need to replace these value captures with an atomic payout tuning snapshot and a pinned RPC transport factory.  
Trade-off: Simple startup-only config is easy to audit in Step 2, but Step 4’s SIGHUP-only tuning reload becomes a refactor across `main.go`, `RunnerOptions`, and `ReorgPoller`.  
Suggestion: Introduce a `PayoutRuntime` or `PayoutTuningProvider` owned by `main.go`: immutable security and signer at startup; atomic tuning snapshot for reloadable values; RPC clients built through a per-endpoint config that includes timeout, label, URL, and SPKI pin.

[arch:3.4] [MEDIUM] §7.1 event emission is incomplete and snowflake-shaped  
What: Several events are emitted inline with fields that do not match the §7.1 table: `payout_paid` omits `block_number`, `nonce`, and `ts_utc`; `payout_failed` omits `attempt_seq`, `provider_id`, `error_text`, and `ts_utc`; `payout_run_finished` omits `skipped_funds` and `error_text`; `payout_signer_unavailable` omits `error_class` and `ts_utc`; one `payout_capped` path omits `provider_id` and `ts_utc`.  
Trade-off: Inline zerolog calls are quick, but Step 3/4 will add more operator events and make drift easier.  
Suggestion: Add typed event helpers or table-driven tests that assert every emitted event contains the §7.1 field set before Step 3 adds more admin surfaces.

[arch:3.5] [LOW] §4.7 drift is contained but should be resolved before Step 3 hardens the API  
What: `reorg.go` correctly avoids nonexistent `payout_attempts.id` / `payout_external_id` columns and uses `(payout_id, attempt_seq, tx_hash)`. The orphan table has the right snapshot columns, and Step 3 can join `ledger_payout_ready` and `payout_attempts` by `(payout_id, attempt_seq)`. The remaining issue is SPEC drift: §4.7 still names impossible columns and also says insert an orphan row, while the current plan moves recording to `/admin/payout/record-orphan`.  
Trade-off: Deferring the SPEC edit avoided churn during Step 2, but Step 3 will otherwise encode the de facto semantics in code first.  
Suggestion: Treat this as a SPEC v0.1.22 pre-Step-3 cleanup: define the endpoint input and join explicitly, with `orphan_tx_hash = payout_attempts.tx_hash`.

## Step 2 → Step 3 Readiness

| Row | Status | Reason |
|---|---|---|
| `record-orphan` endpoint | FRICTION | Schema and reorg evidence are usable, but §4.7 drift must be clarified and admin mux mounting must be fixed. |
| `record-funding` endpoint | FRICTION | Admin route composition is not ready; funding can be added after mux/lifecycle ownership is repaired. |
| pause/resume | FRICTION | Runtime flag foundation exists, but the admin route surface is currently not reachable. |
| chi mux composition | BLOCKED | Current outer `providerMux` mounting cannot serve root-level `/admin/payout/*` routes. |

## Root Cause

Step 2 introduced payout internals as usable components, but `main.go` does not yet have a real payout runtime owner. Lifecycle, lease, runner construction, admin routing, and reloadable tuning are split across placeholders and comments rather than one executable coordinator boundary.

## Recommendations

1. Fix coordinator payout lifecycle first - medium effort - high impact. Construct runner with `billing.Store`, acquire lease only immediately before `Start`, and release after `Stop`.
2. Split or correctly mount provider/admin payout muxes - low/medium effort - high impact. Add outer `providerMux` integration tests for `/providers/...` and `/admin/payout/...`.
3. Add typed payout event emitters/tests - medium effort - medium impact. Lock §7.1 field sets before Step 3 expands events.
4. Add Step 4 runtime seams now - medium effort - medium impact. Atomic tuning provider plus SPKI-aware RPC constructor.

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| Patch `main.go` directly in Step 3 | Fastest path to unblock endpoints | Risks repeating lifecycle coupling in one large function |
| Introduce `PayoutRuntime` owner | Clean lifecycle, shutdown, reload, and mux ownership | More upfront structure |
| Keep current placeholders until Step 4 | Smaller Step 3 diff | Step 3 tests will fight stale lease and unreachable admin routes |

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-2-architecture-review-lane-l-2026-06-25T16-13-37-549Z.md._
