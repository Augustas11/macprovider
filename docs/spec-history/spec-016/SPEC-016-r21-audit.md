# SPEC-016 round 21 — codex fix-pass audit on v0.1.20

**Date:** 2026-06-25
**Auditor:** codex (via `omc ask codex` per [[feedback-codex-only-audits]])
**Audit target:** SPEC-016 v0.1.20 at HEAD of branch `impl/spec-016`
**Prompt:** `specs/AUDIT_SPEC_016_R20_PROMPT.md`
**Verdict:** NEEDS FIX PASS 0/1/1/1 (0 CRIT / 1 MAJOR / 1 MED / 1 LOW)
**Fix-pass commit:** v0.1.21 (this round's closure)

## Codex verdict block (verbatim)

```
ROUND 21 VERDICT: NEEDS FIX PASS 0/1/1/1

DELTAS VERIFIED (7):
  C1: pass
  C2: pass
  C3: pass
  M1: finding — LOW: §4.7 mandates two-RPC re-polling but states the
      default cost is 200 receipt reads "across both RPCs"; with two
      RPCs that is 200 row re-polls / 400 RPC calls unless "read" is
      explicitly defined as a two-RPC pair. Smallest edit: clarify
      row-read pairs vs RPC calls at SPEC-016 line 1871 and line 1889.
  M2: finding — MAJOR: v0.1.20 says `confirmation_blocks` bounds are
      [5, 200] at SPEC-016 line 3568, but §4.3 step 7 still says default
      5, minimum 2, maximum 50 at SPEC-016 line 1295. The upgrade prose
      is also wrong: operators upgrading from default 5 do not need to
      "opt out" of the new floor because 5 is valid at the new floor
      (SPEC-016 line 3585). Smallest edit: update §4.3 step 7 to
      [5, 200], rewrite the upgrade sentence to say only operators using
      values below 5 must raise them, and update stale BUILD prompt
      bounds at BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md line 81 and line
      885 before Step 2 uses it.
  M4: finding — MEDIUM: the new IMPL test (4) is distinct from test (3),
      and the nonce-collision response set is directionally valid, but
      the test demands mutually exclusive outcomes. If the injected
      sleep is before the post-COMMIT lease re-read, the first process
      must emit `payout_runner_lease_lost` and not broadcast; if it is
      after that read, the first process can receive `nonce too low` /
      `already known`, but that loss is not "per the §4.3 step 6
      post-COMMIT lease re-read" as stated. Smallest edit: split test
      (4) into two cases or pin the injection point after the post-COMMIT
      re-read and remove the impossible lease-re-read assertion.
  M5: pass

STEP 1 IMPL INVALIDATION:
  none. Step 1 deny-list includes configured hot wallet in
  `phase4-coordinator/internal/payout/deny.go:41`, with test coverage
  at `phase4-coordinator/internal/payout/addresses_test.go:341`.
  `go test ./internal/payout` passes.

NEW CRITICALS / MAJORS / MEDIUMS / LOWS:
  MAJOR-1 (M2): stale [2,50] bound contradicts v0.1.20 [5,200] at SPEC
      line 1295; stale Step 2 BUILD prompt copies at lines 81 + 885.
  MEDIUM-1 (M4): impossible stall-test assertion across SPEC lines
      1272 + 2793.
  LOW-1 (M1): two-RPC re-poll budget wording undercounts or mislabels
      RPC calls at SPEC line 1889.

GO/NO-GO FOR STEP 2 IMPL START:
  NO-GO — fix M2 before Step 2 to avoid implementing stale confirmation
  bounds; fix M4 test wording so the required Step 2 broadcast-race
  test is executable; clarify M1 budget wording in the same fix pass.
  External sanity check: Base and QuickNode document nonce-too-low
  semantics, and Alchemy documents already-known semantics for
  duplicate/pending raw transactions.
```

## Fix-pass closure (v0.1.21)

### MAJOR-1 (M2 fix-out) — `confirmation_blocks` bound contradiction

The v0.1.20 closure widened §payout.tuning bounds to `[5, 200]` but
missed two downstream copies:

1. **§4.3 step 7 line 1295** — inline restatement of the bound while
   defining the receipt-agreement cadence. Replaced `default 5; minimum 2;
   maximum 50` with `default 5; bounds [5, 200] per §payout.tuning hard
   floors`.
2. **`BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` line 82 and line 885** —
   Step 2 IMPL prompt's tuning-bounds cheat sheet, used by codex during
   IMPL audit. Both updated to `[5, 200]` with `was [2, 50]` annotation
   so the next IMPL audit doesn't drift back to the old bound.

The "MUST explicitly set to opt out" prose in §payout.tuning hard floors
section was rewritten to: "operators with config values in `[2, 4]`
MUST raise to ≥5 before upgrading. The v0.1.19 default `5` is at the
new floor, so operators on default config need no action." The original
prose was directionally wrong because `5` is at the new floor — no
opt-out required.

### MEDIUM-1 (M4 fix-out) — IMPL test (4) mutually-exclusive outcomes

The v0.1.20 test (4) mixed two contradictory scenarios: if the injected
sleep is BEFORE the post-COMMIT lease re-read, the first process must
self-halt on the lease re-read and NOT broadcast (test trivially passes
because no race exists). If the sleep is AFTER the lease re-read, the
race does exist and chain-nonce-uniqueness is the only guard — but the
test as worded asserts `payout_runner_lease_lost` is emitted "per the
§4.3 step 6 post-COMMIT lease re-read", which is impossible because
the re-read already passed.

The fix pins the injection point AFTER the post-COMMIT lease re-read
returned OK and BEFORE `eth_sendRawTransaction`. The first process is
allowed to receive `nonce too low` or `already known` from the RPC.
The test FAILS if both processes' broadcasts return `successful` (the
nonce-uniqueness guard failed) OR if the first process emits
`payout_invariant_violation` on the nonce-collision response (the
runner should treat the RPC's nonce-already-used response as a
benign-but-noteworthy outcome, not an invariant violation). The
`payout_runner_lease_lost` emit is moved to the NEXT cadence cycle's
self-fencing check — that's where the lease-token mismatch is
actually observed.

### LOW-1 (M1 fix-out) — two-RPC re-poll budget undercount

The v0.1.20 closure wrote "200 receipt reads per cycle across both
RPCs" — ambiguous between 200 row-reads (where each row = 1 read per
RPC = 2 RPC calls) and 200 total RPC calls. The §4.7 re-poll path
uses the §4.4 two-RPC discipline, so each row re-poll is 2 RPC calls.
At default values: 50 rows × (24h / 6h) = 200 row re-polls = 400 RPC
calls per cycle (200 per RPC). The §4.4 RPC budget assumes ~10 req/s
sustained per provider, so 200 calls per RPC per cycle (every 6h) is
well within budget. Paragraph rewritten with explicit budget
accounting.

## Convergence-ready check for round 22

The three v0.1.21 edits are scoped and additive:

- Two `[2, 50] → [5, 200]` substitutions + one prose sentence rewrite
- One IMPL test rewrite (~15 lines)
- One budget-accounting paragraph rewrite (~10 lines)

No new cross-section attack class introduced. No Step 1 IMPL impact
(M2's BUILD prompt update is the only file Step 2 will read, and the
change is a tightening of valid range, not a Step 1 schema or handler
change). Round 22 should converge.

## Cross-reference

- Raw codex CLI artifact:
  `.omc/artifacts/ask/codex-run-the-spec-016-round-21-audit-per-specs-audit-spec-016-r20-2026-06-25T14-30-36-528Z.md`
- Round 20 narrative: `specs/SPEC-016-r20-audit.md`
- Audit prompt: `specs/AUDIT_SPEC_016_R20_PROMPT.md` (re-used for round 22)
