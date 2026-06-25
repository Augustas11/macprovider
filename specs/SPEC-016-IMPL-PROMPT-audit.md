# SPEC-016 IMPL prompt — codex round-1 audit

**Audit subject:** [`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md)
at commit `1ea20a3` on branch `spec/016-payout-impl-prompt`
([PR #162](https://github.com/Augustas11/macprovider/pull/162)).
**Controlling SPEC:** [`specs/SPEC-016-payout-pipeline.md`](SPEC-016-payout-pipeline.md)
at v0.1.19, commit `5c034a0` on `main`.
**Auditor:** codex (`gpt-5.5`, reasoning effort high).
**Date:** 2026-06-25.
**Verdict:** NEEDS FIX PASS.
**Counts:** CRITICAL 4 / MAJOR 2 / MEDIUM 3 / LOW 1.
**Diff scope:** clean — PR diff only adds the audited prompt file.

## CRITICAL findings

### C1 — §9 prerequisite gate is relaxed contrary to SPEC

[Prompt L45-49](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:45) allows
code to land with `payout.enabled: false`, and
[L162-166](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:162) say
Steps 1-3 can proceed without §9.1/§9.2/§9.5b. SPEC-016 §9
says "IMPL MUST NOT begin until ALL EIGHT prerequisites are
discharged" at SPEC L3828-3829. The prompt gives the IMPL
author permission to start the exact work the SPEC blocks.

**Fix:** restate the §9 gate verbatim; remove the "Steps 1-3
can proceed without …" carve-out; keep the cutover-vs-IMPL
distinction only where the SPEC itself draws it.

### C2 — §9 item citations are wrong after §9.5b

[Prompt L122](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:122)
labels Nginx as `[§9.6]`; SPEC §9 item 6 is BetterStack.
[Prompt L128](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:128)
labels BetterStack as `[§9.7]`; SPEC §9 item 7 is Nginx.
Exact wrong-§-reference class the audit prompt called out as
highest-cost.

**Fix:** swap the two labels — BetterStack is item 6, Nginx
is item 7.

### C3 — §3.2 EIP-712 timestamp skew requirement is missing

Prompt §3.2 block at
[L257-276](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:257) covers
domain/struct equality, EIP-55, deny-list, 10-minute nonce
pruning — but never requires `ts_utc` within ±5 minutes.
SPEC §3.2 requires reject `signature_skew` at SPEC L475-477.
A SPEC-aligned IMPL following this prompt could ship a
stale-signature replay gap.

**Fix:** add an explicit `ts_utc` ±5 minute skew check bullet
to the §3.2 block.

### C4 — §4.9 manual funding omits the intra-txn bootstrap-trigger presence check

Step 3 `record-funding` instructions at
[L603-617](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:603) mention
the bootstrap triggers but do not require the §4.8a
same-transaction `sqlite_master` check for
`trg_prs_bootstrap_one_way`, `trg_pa_bootstrap_flip`, and
`trg_pa_bootstrap_flip_insert`. SPEC L2514-2538 makes that
check normative for `source='manual'` acceptance — it's the
defense against the DROP-trigger + reset-flag + CREATE-trigger
attack class.

**Fix:** add the intra-transaction trigger-presence assertion
to the Step 3 §4.9 instructions; reject `422
bootstrap_trigger_missing` on count != 3.

## MAJOR findings

### M1 — §6.3.1 Signer contract is under-specified

[Prompt L342-347](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:342)
name `FromAddress`/`SignTx` and ban `SignMessage`, but omit:
unsignedTxBytes format (EIP-2718 type-prefixed RLP, txType
`0x02`), caller-does-not-pre-hash rule (KMS impls keccak256
themselves), determinism guidance (RFC 6979 not load-bearing
for idempotency), cancellation behavior (`ctx.Err()` transient),
typed error semantics (`payout_signer_unavailable`). SPEC
§6.3.1 at L3153-3203 carries all of this.

**Fix:** expand the §6.3 / §6.3.1 block in Step 2 to surface
each of those bullets.

### M2 — §9.5b.1 SPEC-005 handoff is incomplete

[Prompt L100-119](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:100)
list only part of the required SPEC-005 vX.Y+1 endpoint
contract. Missing: `Idempotency-Key` HTTP header byte-equality
with the JSON body `idempotency_key` field,
`min_payout_credits_override=0` honored at INSERT,
"MUST NOT trigger a fresh settlement run", emit
`ledger_payout_ready_admin_inserted` event,
same-SQLite-DB requirement for the `payout_reorg_orphans`
join. SPEC §9.5b.1 at L3927-3936 and L3973-4089.

**Fix:** expand the §9.5b handoff bullet to cover all six
missing items.

## MEDIUM findings

### Med1 — Step 1 adds a global same-DB rule SPEC defers to v0.2

[Prompt L235-239](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:235)
say "All SPEC-016 tables MUST live in the same SQLite
database file as SPEC-005's `ledger_payout_ready`". SPEC has
table-level same-DB pins (in §3.1, §4.7, §4.8a, §4.8b, §4.9)
but explicitly defers the comprehensive all-table pin to v0.2
at SPEC L2456-2457 and L2738-2739. The prompt is creating a
stronger normative requirement than SPEC currently locks.

**Fix:** weaken to the per-table pins SPEC actually locks;
note the v0.2 candidate exists.

### Med2 — §7.4 query labels collide with SPEC labels

[Prompt L776-784](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:776)
calls the per-provider-sum query "(A)" and the NULL-currency
detector "(B)". SPEC §7.4 reserves (A) for stale-orphan,
(B) for compensation-forgery, (C) for orphan-mismatch, (D)
for cancel-observability at SPEC L3722-3789.

**Fix:** rename the prompt's labels to descriptive names; do
not reuse (A)/(B).

### Med3 — §4.5 index count internally inconsistent

[Prompt L209-215](BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:209)
says "FIVE partial UNIQUE / non-UNIQUE indexes" but the bullet
list enumerates seven. SPEC §4.5 has seven indexes at SPEC
L1408-1434 with the two partial UNIQUE indexes called out
separately at L1445-1463.

**Fix:** correct "FIVE" → "seven".

## LOW findings

### L1 — Missing explicit `feedback-spec-audit-loop-before-pr` reference

The prompt wires `feedback-codex-only-audits`,
`feedback-spec-audit-file-convention`,
`feedback-build-audit-loop`,
`feedback-bundle-spec-impl-one-pr`, and the PR-merge
memories — but never references
`feedback-spec-audit-loop-before-pr`. Traceability-only; the
audit prompt explicitly asked for it.

**Fix:** add the memory reference inline where the audit-loop
discipline is described.

## Closing notes

The IMPL prompt is structurally sound: house-style audit
pattern, scoped step boundaries, citations of existing
primitives. The defects above are transcription / omission
errors against a 4312-line SPEC — exactly the failure mode
the audit pass exists to catch. None of the findings indicate
the IMPL decomposition itself is wrong; all are addressable
by editing the prompt without re-architecting the 4 steps.

The merge gate for [PR #162](https://github.com/Augustas11/macprovider/pull/162)
is **0 CRITICAL + 0 MAJOR**. Once CRITICAL 1-4 + MAJOR 1-2
are absorbed, a round-2 audit verifies closure. MEDIUM + LOW
are operator-judgment; rolling them into the same fix pass
keeps the merge atomic.

---

## Round 2 — closure verification

**Auditor:** codex (`gpt-5.5`, reasoning effort high).
**Date:** 2026-06-25.
**Audit prompt:** [`specs/AUDIT_SPEC_016_IMPL_PROMPT_R2_PROMPT.md`](AUDIT_SPEC_016_IMPL_PROMPT_R2_PROMPT.md).
**Closure verdict:** READY. All 10 round-1 findings closed.
**New fix-pass findings:** CRITICAL 0 / MAJOR 0 / MEDIUM 0 / LOW 1.
**Merge gate:** PASS (0 open round-1 CRITICAL/MAJOR; 0 new
CRITICAL/MAJOR).

### Closure evidence (verbatim from codex)

- **C1 closed:** §1 now says IMPL must not begin until all
  eight prerequisites are discharged, and explicitly removes
  the old carve-outs (prompt L45-58); closing paragraph
  blocks IMPL kickoff first (L222-225).
- **C2 closed:** BetterStack is now "§9 item 6", Nginx is
  "§9 item 7" (L182-210); list still covers §9.1, §9.2,
  §9.3, §9.4, §9.5/5a/5b, item 6, item 7, §9.8 (L60-219).
- **C3 closed:** §3.2 requires `ts_utc` within ±5 min and
  rejects 400 `signature_skew` (L335-341).
- **C4 closed:** Step 3 requires the same-transaction
  `sqlite_master` count check for all three bootstrap
  triggers and names `422 bootstrap_trigger_missing`
  (L723-737).
- **M1 closed:** Signer contract now covers no
  `SignMessage`, unsigned EIP-1559 tx bytes,
  caller-does-not-pre-hash, determinism, cancellation, and
  typed error semantics (L419-455).
- **M2 closed:** §9.5b now includes header/body
  `Idempotency-Key` equality, `min_payout_credits_override:
  0`, no fresh settlement run,
  `ledger_payout_ready_admin_inserted`, and same-SQLite-DB
  handling (L117-179).
- **Med1 closed:** Step 1 lists per-table same-DB pins only;
  no global all-table claim (L295-309).
- **Med2 closed:** Step 4 reserves SPEC labels (A)-(D) for
  stale-orphan, compensation-forgery, orphan-mismatch,
  cancel-observability; uses descriptive names for unlabeled
  queries (L909-929).
- **Med3 closed:** §4.5 says "seven partial indexes"
  consistent with seven listed index names (L268-275).
- **L1 closed:** §3 cites `feedback-spec-audit-loop-before-pr`
  (L1031).

### New LOW from round-2 fix-pass

**L2 (round-2):** Step 4 §7.4 wording said "two un-labeled
regression queries" but listed three (per-provider delta,
NULL-currency detector, chain-balance recon). Wording-only;
all required queries still named. **Absorbed in the same
fix-pass commit** by changing "two" → "three".

---

## Final state

- All round-1 CRITICAL + MAJOR + MEDIUM + LOW findings:
  CLOSED.
- Round-2 LOW: CLOSED in the same fix-pass commit.
- Merge gate: PASS.
- PR [#162](https://github.com/Augustas11/macprovider/pull/162)
  is READY for merge once CI clears.
