# SPEC-020 v0.1.4 IMPL — Round 3 audit narrative

**Audited:** commits `8161aab` + `29443ab` on `impl/spec-020-provider-autoupdate`
**Round:** r3
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect | NEEDS REVISION | 0 | 1 | 0 |
| B code | NEEDS REVISION | 0 | 0 | 1 |
| C security | NEEDS REVISION | 0 | 2 | 1 |

**Totals: 0 CRITICAL, 3 HIGH, 2 MEDIUM.**

Trend r1→r2→r3: HIGH 12→4→3, MEDIUM 6→4→2.

## Convergent theme — sentinel/recovery integrity (A+C, both HIGH)

**A-r3-H-1**: startup recovery path deletes sentinel before `sendStateUpdate` is called. `CoordinatorClient.swift:1409-1419` runs startup recovery before reconnect; finalizes sentinel at `:1418`; records event in-memory at `:1419`. Coord-visible send happens later through `sendStateUpdate` at `:2035`. Crash between finalize and next `sendStateUpdate` → neither durable anchor NOR coord-visible event.

**C-r3-H-1**: pre-staged sentinel bypass. `CoordinatorClient.swift:1409` scans every `.macprovider-cli.success-*` before handshake; only checks `payload.binaryVersion == Self.binaryVersion`. Does NOT require sentinel's `update_id` to match the pending marker's `update_id`. Same-UID attacker / bad new binary can pre-stage a valid-version sentinel and force `completeSuccessfulUpdate(pending)` of a legitimate pending update — deleting backup before real coord-visible success.

**Combined absorption**: tighten startup recovery in `CoordinatorClient.swift:1409-1419`:

1. When scanning a sentinel, REQUIRE BOTH:
   - `sentinel.binaryVersion == Self.binaryVersion`, AND
   - A pending marker exists AND `pending.updateID == sentinel.updateID`.
2. If pending marker absent but sentinel claims success for current version: this is a delayed-publish-only state. Emit a `failure_class:"orphaned_success_sentinel"` event (already in enum) and delete just the sentinel — do NOT touch pending/backup.
3. If pending marker present and update_id matches: send the success state update FIRST (coord-visible), AWAIT delivery, THEN call `completeSuccessfulUpdate(pending)` + `finalizeSuccessfulUpdate(updateID:)`. The sentinel is durable until after coord sees the event.

This treats startup recovery exactly the same as the happy-path success: send-then-finalize, sentinel as anchor until coord confirms.

## Standalone HIGH

### C-r3-H-2: `marker_deadline` tolerance too wide

Swift validation accepts `now - 300s` to `now + 24h` at `AutoUpdateMarker.swift:401`. Watchdog accepts `now + 24h` at `watchdog.sh:249`. SPEC says future-beyond-tolerance is `marker_deadline > now + post_start_window + 30 min` (where post_start_window = 60s default), so the practical upper bound should be `now + ~31 min`, NOT 24h.

**Fix**: tighten both Swift and shell deadline upper bound to `now + post_start_window + 30 min` (i.e., `now + 90 * 60` seconds = 5400s). Anything beyond → reject as malformed → orphan-recovery + cooldown + autoupdate disabled for session.

## Standalone MEDIUMs

### C-r3-M-1: `try?` silent-swallow on signed-policy persist

`AutoUpdateMarker.swift:364` uses `try?` for encode/write of signed-policy state. If swap succeeds + policy persist fails → provider continues with no rollback, no event, no durable floor.

**Fix**: replace `try?` with `do/catch`. On failure: emit `failure_class:"signed_policy_persist_failed"` (add to R-6.5 enum), best-effort rollback of the just-applied update (restore prior binary from backup if still present), disable autoupdate for the session. If rollback also fails, structured-fatal log so operator can manually recover.

### B-r3-M-1: AC test assertion gaps

`AutoUpdateTests.swift` covers AC-17, AC-19, AC-20, sentinel persistence. Missing:
- **AC-10**: 3 post-start classifications (`post_start_crash`, `post_start_health_failed`, `post_start_rejoin_timeout`) implemented only in watchdog code, no test assertions.
- **AC-22**: trust-loss-after-auth — only notify-only-at-entry is tested, not the live demotion path between auth and swap.
- **AC-23**: production awaits `sendStateUpdate` before finalize (correct), but tests call marker-store cleanup directly without asserting coord send/finalize ordering.

**Fix**: add tests for each missing AC. For AC-10 watchdog tests, extend `Scripts/test-ac-19-20-watchdog-recovery.sh` to cover the 3 classifications (fake launchctl outputs + healthz responses + binary_version mismatch). For AC-22, add a test where `AutoUpdateTrustState.evaluate` returns eligible at entry but a subsequent re-evaluation (mid-pipeline) returns notify-only; assert no swap occurs and `trust_state_lost` emitted. For AC-23, mock the send pipeline and assert finalize is called only after send returns.

## Non-blocking confirmations

Lane A confirms: restore-before-cleanup validates marker + backup before restore/quarantine ✓; both watchdog + Swift respect `marker_deadline` ✓; notify-only pre-gate returns for all ineligible states ✓; signed-policy persistence is post-apply ✓.

Lane B confirms: production `sendStateUpdate` awaited before finalize on happy path ✓; watchdog integration test for AC-19/20 passes ✓.

Lane C confirms: restore-before-cleanup works on the validated path; `marker_deadline` parsing works (just tolerance is too wide).

## Next action

Absorb r3 → IMPL commit on top of `8161aab`. Then fire r4. If trend holds, r4 should land at 0/0/0.

## Raw artifacts

- Lane A architect: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-3-audit-prompt-per-lane-you-are-a-2026-06-29T17-13-51-147Z.md`
- Lane B code: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-3-audit-prompt-per-lane-you-are-a-2026-06-29T17-14-33-650Z.md`
- Lane C security: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-3-audit-prompt-per-lane-you-are-a-2026-06-29T17-14-16-793Z.md`
