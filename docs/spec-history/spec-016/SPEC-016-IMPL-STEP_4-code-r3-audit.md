# SPEC-016 Step 4 — code-review lane, r3 audit

Codex run: `codex-impl-audit-prompt-spec-016-step-4-code-review-lane-round-3-m-2026-06-25T19-52-21-253Z.md`
HEAD: `fe6a699`
Branch: `impl/spec-016`

## Verdict

**REQUEST CHANGES** — 0 CRITICAL / 1 HIGH / 3 MEDIUM / 1 LOW.

Full coordinator test suite passes. The r2 BLOCK findings closed, but
r3 found a new HIGH defect on run-now correlation and §7.1 field-drift
sweep is broader than r2 fixed.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 1 |
| MEDIUM   | 3 |
| LOW      | 1 |

## R2 Closure Verification

| R2 finding | r3 status |
|------------|-----------|
| [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] convergent — run-now contract | PARTIAL — controller is in place but `payout_run_now_invoked` carries a different `run_id` than `payout_run_started/finished` (see [code:r3-1]) |
| [arch:r2-4.2] SPKI live read | PARTIAL — pin live-read at handshake works, but pool retention undocumented (see security r3) |
| [code:r2-2]/[sec:r2-2] AST forbidden set | CLOSED — exact identifiers |
| [code:r2-3] halt-race body | CLOSED in code but not actually tested (see [code:r3-4]) |
| [code:r2-4] §7.1 alert field names | CLOSED for alerts; broader §7.1 drift exists (see [code:r3-2] / [code:r3-3]) |

## Findings

### [code:r3-1] HIGH — `payout_run_now_invoked` uses a different `run_id` than the actual payout run

- Files: `phase4-coordinator/internal/payout/runnow.go:102`,
  `phase4-coordinator/internal/payout/runner.go:352`
- Confidence: HIGH

`ServeRunNow` creates a UUID for the response/event, but
`Runner.RunOnce` creates a SECOND UUID for
`payout_run_started` / `payout_run_finished`. The run-now response and
audit event therefore cannot correlate to the actual run lifecycle
events. This leaves r2 run-now closure incomplete — operators get a
PAGE event for `payout_run_now_invoked` with a UUID that doesn't
match any of the cycle events.

**Fix:** let run-now supply the run ID into the runner, OR have
`RunOnce` return the run ID it used. Emit/respond with the same ID
used by `payout_run_started` / `payout_run_finished`. Add a test
that asserts the response `run_id` matches `payout_run_started.run_id`.

### [code:r3-2] MEDIUM — Config reload events still drift from §7.1 fields

- Files: `phase4-coordinator/internal/payout/config_tuning.go:223`,
  `phase4-coordinator/internal/payout/config_tuning.go:268`,
  `phase4-coordinator/cmd/coordinator/main.go:1348`
- Confidence: HIGH

§7.1 requires `payout_config_reloaded` fields: `key, old_value,
new_value, actor, ts_utc`. Implementation emits `key, old, new,
ts_utc` with no `actor`.

§7.1 requires `payout_config_reload_rejected` fields: `key,
attempted_value, bound, actor, ts_utc`. Implementation emits only
error/severity/ts. The load-failure path emits neither the required
fields nor `ts_utc`.

**Fix:** rename `old/new` to `old_value/new_value`, pass an explicit
actor, and return structured bound errors so rejected reloads can
log `key`, `attempted_value`, and `bound`.

### [code:r3-3] MEDIUM — Chain-balance `payout_rpc_disagreement` does not match §7.1 schema

- File: `phase4-coordinator/internal/payout/reconcile.go:395`
- Confidence: HIGH

The chain-balance worker reuses `payout_rpc_disagreement` but emits
`primary_balance`, `secondary_balance`, and `tolerance`. §7.1
defines `payout_rpc_disagreement` as `payout_id, attempt_seq,
rpc_a_state, rpc_b_state, ts_utc`. Consumers expecting the table
schema will not parse this event consistently.

**Fix:** either emit a schema-compatible event shape OR introduce a
distinct chain-balance RPC disagreement event (e.g.
`payout_chain_balance_rpc_disagreement`). Coordinate with SPEC
update if introducing new event.

### [code:r3-4] MEDIUM — New run-now tests do not cover two claimed branches

- Files: `phase4-coordinator/internal/payout/runnow_test.go:169`,
  `phase4-coordinator/internal/payout/runnow_test.go:207`
- Confidence: HIGH

`TestRunNowController_InFlightReturns409` does not force `RunOnce`
to return the generic in-flight error; it halts the runner instead.
`TestRunNowController_ErrRunnerHaltedRaceReturnsHaltedBody` also
exercises the pre-halted branch, not the post-`RunOnce`
`errors.Is(err, ErrRunnerHalted)` race branch.

**Fix:** add an injectable runner interface (or test hook) so tests
can force `ErrRunnerHalted` after `IsHalted=false` AND a non-halt
`RunOnce` error.

### [code:r3-5] LOW — Whitespace check fails

- File: `phase4-coordinator/internal/payout/rpc_test.go:372`
- Confidence: HIGH

`git diff --check fe6a699^..fe6a699` reports a new blank line at EOF.

**Fix:** remove trailing blank line.

## Open Questions

- `payout_run_now_invoked` includes extra `outcome`. Since §7.1 says
  "minimum field set", treat this as an acceptable defensive
  extension, not a defect.
- SPKI live-read is per TLS handshake, not per request. The code
  comments document "next TLS handshake"; long-lived HTTP/2
  connections will keep the old verification until reconnect.
  (Security lane flags this as HIGH.)

## Positive observations

- r2 run-now routing is centralised through `RunNowController`, and
  Step2/3/4 mux constructors fail closed when `RunNow` is missing.
- The run-now rate-limit timestamp update is mutex-protected before
  releasing concurrent requests.
- SPKI pin lookup is live inside the verifier closure, and empty-pin
  bypass is preserved.
- AST forbidden identifier set now matches the current exported
  `PayoutSecurityConfig` fields.
- Low-balance and drift field renames for the r2 finding are closed.

## Validation

- `go test -race -count=1 ./internal/payout/...` passed.
- `go test -count=1 ./...` in `phase4-coordinator` passed.

## Recommendation

REQUEST CHANGES.
