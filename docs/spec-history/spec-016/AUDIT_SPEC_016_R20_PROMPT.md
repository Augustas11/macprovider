# AUDIT — SPEC-016 v0.1.20 round-21 codex audit (Claude-round-20 absorption)

You are a SPEC auditor. SPEC-016 v0.1.19 was previously locked by codex
round 19 (CONVERGED 0/0/0 against v0.1.17 + v0.1.18 LOW sweep +
v0.1.19 audit-narrative split, ALL hygiene-only). Step 1 of the
IMPL has shipped (commit `1df0235` on branch `impl/spec-016`).

**Between Step 1 commit and Step 2 kickoff, a Claude-side adversarial
cross-check (round 20, two parallel subagents: critic + analyst lenses)
ran against the locked v0.1.19 and surfaced 3 criticals + 5 majors that
19 codex rounds with the same lens missed.** Round 20 absorbs 7 of the 8
into v0.1.20 (M3 deferred — see `specs/SPEC-016-r20-audit.md`).

This audit prompt is round 21 — a scoped codex verification of the seven
v0.1.20 deltas. You are NOT re-auditing the full SPEC body. You are
verifying:

1. The deltas are normatively coherent (no contradiction, dead reference,
   or undefined event/enum/field).
2. The closures actually close the cross-section attack class the round-20
   findings named (not merely a paraphrase of the finding).
3. No NEW class of defect was introduced by the deltas themselves (e.g. a
   tightened bound that contradicts an existing IMPL test).

## Inputs

- `specs/SPEC-016-payout-pipeline.md` at HEAD of branch `impl/spec-016`
  (v0.1.20).
- `specs/SPEC-016-r20-audit.md` (round-20 findings + closure narrative).
- `specs/SPEC-016-r19-audit.md` (last codex round for context — DO NOT
  re-litigate findings closed in r19).
- Step 1 IMPL commit `1df0235` on branch `impl/spec-016` — `internal/payout/`
  package, schema migrations 0001-0008, §3.3 handler, §3.2 EIP-712
  verifier, startup invariants. (DO NOT audit IMPL correctness — that's
  the next IMPL audit round. Just check that Step 1 is not invalidated by
  the v0.1.20 deltas.)

## The seven deltas to verify

For each, confirm (a) the closure is coherent end-to-end across the SPEC,
(b) the cross-section attack class is actually closed, (c) no contradiction
introduced.

**C1 — `Idempotency-Key` on `/admin/payout/record-funding` bound to `tx_hash`.**
§4.9 binds the header to equal the body's `tx_hash` field; mismatch → 422
`idempotency_key_mismatch`. Verify: does this actually eliminate the
positive-direction funding-inflation class? Is there any other endpoint
or path that writes to `payout_hot_wallet_funding` without the binding?
Is the case-insensitivity rule (`lower(0x-prefixed hex)`) well-defined?

**C2 — `from_address == hot_wallet` rejection + §7.4 query (E) + §3.2 deny-list framing.**
§4.9 400-response now lists `from_address == hot_wallet_address`. §7.4
query (E) is a defense-in-depth hand-edit detector. §3.2 deny-list prose
extended. Verify: is the symmetric ban consistent across all three sites?
Does any §4.9 path bypass the 400 check (e.g. via a future endpoint that
shares the same data shape)? Does query (E) handle the case-folding
correctly (`lower(...)`)?

**C3 — `amount_base_units == lpr.provider_credits` pre-INSERT invariant in §4.3 step 5.**
The invariant is asserted inside the `BEGIN IMMEDIATE` transaction
BEFORE the INSERT on `payout_attempts`. New `where='amount_credit_mismatch'`
enum value added to §7.1 `payout_invariant_violation`. Verify: is the
re-read of `lpr.provider_credits` actually inside the same txn (it
must be — outside-txn read can race)? Is the field-order between SPEC
and §7.1 enum consistent? Does the §4.3 step 2 prose still claim the
unit identity holds, or does it now over-promise something step 5's
invariant doesn't enforce?

**M1 — `payout.tuning.reorg_poll_window` mandated re-poll cadence in §4.7.**
New tuning key with bounds `[1h, 168h]`, default `24h`. Re-poll loop on
every cadence cycle. New `payout_reorg_poll_rpc_error` event. Existing
`payout_reorg_revert` event gains `observed_via` enum. Verify: are the
bounds defensible? Does the §4.4 two-RPC discipline accommodate the
extra RPC budget (≤ `max_rows_per_run × (reorg_poll_window / run_interval)`
reads per cycle)? Is `observed_via` exhaustively enumerated?

**M2 — `payout.tuning.confirmation_blocks` bounds widened to [5, 200] + finality model paragraph.**
Floor raised from 2 to 5; ceiling raised from 50 to 200. Finality model
prose explicit ("soft-finality threshold only"). Default UNCHANGED at 5.
Verify: does the v0.1.19→v0.1.20 floor bump break any existing IMPL test
that asserted `confirmation_blocks=2` was a valid setting? Is "operator
upgrading from default 5 MUST explicitly set to opt out of the new floor"
prose correct (5 is at the new floor, so no break — confirm)?

**M4 — Chain-nonce uniqueness load-bearing paragraph + new IMPL test (4) in §4.8b.**
Non-normative explanatory paragraph + a new test that the §4.8b semantics
section now lists. Verify: does the prose accurately describe the GC-stall
race? Is the IMPL test (4) actually different from existing test (3) in
what it asserts? Is the expected `nonce too low` / `already known` RPC
response well-defined across both pinned RPC vendors?

**M5 — §7.4 query (F) money-conservation aggregate invariant + weekly operational binding.**
Query (F) sums `consumed` ledger credits vs confirmed non-abandoned
non-cancel attempts. Operator MUST run weekly; non-zero is SEV-1. Verify:
does query (F) correctly EXCLUDE cancel rows (matching the existing query
(A) and the chain-balance reconciliation in §7.4)? Does it correctly
filter on `payout_currency = 'USDC-BASE'`? Is there a race between the
runner's in-flight cycle (consumed-but-not-yet-confirmed) that would
cause a transient non-zero `conservation_delta`? If so, is the operational
binding clear that the operator MUST drain in-flight before treating non-zero
as SEV-1, or is the query SQL itself correctly excluding in-flight?

## Step 1 IMPL invalidation check

For each delta, verify the Step 1 IMPL commit `1df0235` is NOT
invalidated:

- C1 — §4.9 handler is NOT in Step 1 (it's Step 3 per
  `BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md §2`). Schema for
  `payout_hot_wallet_funding` IS in Step 1 (migration 0008). The new
  C1 binding is handler-side only; schema unchanged. **No Step 1
  impact expected.**
- C2 — §4.9 handler is Step 3. Schema unchanged. §3.2 deny-list prose
  is normative against the §3.3 handler (already in Step 1) — verify
  Step 1's deny-list IMPL list includes the hot wallet address (it
  should, per v0.1.19 §3.2 item 4). **Confirm Step 1 deny-list
  includes hot wallet.**
- C3 — §4.3 step 5 runner is Step 2. Schema unchanged. **No Step 1
  impact.**
- M1 — §4.7 reorg runner is Step 2/3. New tuning key. **No Step 1
  impact** (config-parse code is shared but the new bound is additive).
- M2 — `confirmation_blocks` bounds widened. **Step 1 has no
  confirmation-block enforcement; no impact.** Verify nonetheless.
- M4 — §4.8b lease semantics. Schema IS in Step 1 (`payout_runner_lease`).
  The M4 paragraph is explanatory-only; new IMPL test (4) is for
  Step 2's broadcast path. **No Step 1 impact.**
- M5 — §7.4 query (F) is a checked-in SQL file. **No Step 1 impact**
  (`internal/payout/reconcile.sql` is created in Step 4 per BUILD_SPEC
  §2).

## Output format

```
ROUND 21 VERDICT: <CONVERGED 0/0/0 | NEEDS FIX PASS x/y/z/w>

DELTAS VERIFIED (7):
  C1: <pass | finding>
  C2: <pass | finding>
  C3: <pass | finding>
  M1: <pass | finding>
  M2: <pass | finding>
  M4: <pass | finding>
  M5: <pass | finding>

STEP 1 IMPL INVALIDATION:
  <none | <list>>

NEW CRITICALS / MAJORS / MEDIUMS / LOWS:
  <itemized findings if any, with line cites>

GO/NO-GO FOR STEP 2 IMPL START:
  <GO | NO-GO + rationale>
```

If CONVERGED, the user proceeds to Step 2 IMPL against v0.1.20. If
NEEDS FIX PASS, name the smallest set of edits that closes the
findings; loop until convergence.

Per [[feedback-codex-only-audits]] this is codex via `/ccg` or
`/ask codex`, NOT a Claude internal subagent. Per [[feedback-spec-audit-file-convention]]
findings + closure narrative for r21 go in `specs/SPEC-016-r21-audit.md`
(separate file).
