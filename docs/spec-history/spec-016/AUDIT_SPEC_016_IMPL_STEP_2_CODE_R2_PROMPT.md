# IMPL audit prompt — SPEC-016 Step 2, **CODE REVIEW lane, round 2**

Round 2 of the code-review lane against the Step 2 r1 fix-pass.
Branch `impl/spec-016` HEAD: `3653516`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 2
IMPL — round 2. Round 1 returned 0/2/2/1 (REQUEST CHANGES).
The fix-pass landed in commit `3653516` on branch `impl/spec-016`.
Your round-2 job: verify the r1 findings are properly closed AND
scan for regressions introduced by the fix-pass.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md` for the master
context preamble. Same SPEC v0.1.21 LOCKED at `f0152c0`.

Branch HEAD: `3653516`. Recent commit chain:

- `3653516` impl(016): Step 2 r1 fix-pass — close 7 MAJOR/HIGH + 4 MEDIUM
- `8a8a110` spec(016): Step 2 audit r1 findings — 3 parallel codex lanes
- `b49ac4d` spec(016): Step 2 audit prompts — 3 parallel codex lanes (r1)
- `db5c9ba` impl(016): Step 2 wiring + topology tighten
- … (Step 2 commits) …
- `a1fe3b1` spec(016): Step 1 audit CONVERGED — r2 across all 3 lanes 0/0/0/0

## Your r2 verification scope

### r1 findings to verify CLOSED

**[code:1.1] MAJOR — persisted bytes never retried**

Verify `runner.processRow` at the persisted-but-unbroadcast
branch: when an attempt has `raw_signed_tx IS NOT NULL AND
broadcast_at_utc IS NULL AND abandoned_at_utc IS NULL`, the new
`rebroadcastAndPoll` method:

- runs a standalone SelfFence BEFORE broadcasting
- BroadcastBoth on both RPCs
- IsNonceTooLow handling: stamp broadcast_at_utc and proceed to
  poll (chain-serialized race)
- both-RPCs-reject: leave broadcast_at_utc NULL; retry next cycle
- accept: StampBroadcastAt + pollAndConfirm

Probe: write a test that mocks the persisted-bytes state and
verifies the new branch runs without re-signing.

**[code:1.2] MAJOR — cancel pre-check halts forever**

Verify the 3-branch state machine:
- unbroadcast: `r.rebroadcastCancel` called; `cancelsBlockFresh=true`
- broadcast-unconfirmed: `r.pollCancelOnce` called; if confirmed
  during the cycle (returns `rowOutcomePaid`), `continue` (don't
  block); else `cancelsBlockFresh=true`
- confirmed: do nothing — proceed to fresh non-cancel allocation

Verify pollCancelOnce performs cancel-specific verification (tx.to
== hot wallet, NO Transfer log, confirmation depth, status=1)
and emits the transition INFO event with the §7.1 field set.

**[code:1.3] / [sec:2.2] BOTH-RPC chain verification**

Verify the new verifyChainSideTransfer signature accepts (ctx,
attempt, recA, recB) and asserts on BOTH:
- both receipt.To == USDC
- both tx.input byte-equal to expected calldata
- both tx.from == hot_wallet AND tx.from agree
- exactly-one Transfer log on BOTH receipt log arrays via
  countMatchingTransferLog helper

**[code:1.4] MEDIUM — strict RLP decode**

Verify:
- `rlpDecodeListWithKinds` exists alongside the legacy
  `rlpDecodeList` and returns parallel kinds slice
- DecodeSignedEIP1559 asserts consumed == len(body)
- access-list slot is rejected when kinds[8] != rlpKindList
- `TestEIP1559_DecodeRejectsTrailingBytes` regression test exists

### Regression sweep

Probe the fix-pass diff for new defects:

1. The runner's pollAndConfirm now threads block_number into the
   freshAttempt struct — confirm no shadow of attempt.BlockNumber
   that could carry a stale value from the parent caller.
2. The Migrate function now tracks applied migrations in
   payout_schema_applied. Verify the table CREATE precedes any
   `SELECT name FROM payout_schema_applied` so a fresh DB doesn't
   query a missing table.
3. The `cancelsBlockFresh` flag inside the cancel loop: confirm
   the `continue` for confirmed-during-cycle doesn't accidentally
   leak the flag from a prior iteration that set it true.
4. `gas_reserved_native_wei` column added via ALTER TABLE
   doesn't break the existing CASPersistSignedTx UPDATE (the
   UPDATE doesn't touch the new column).

### NEW focus areas (only flag if you spot something)

Do not re-audit the full Step 2 surface — only flag NEW defects
in the diff `f0152c0..3653516`.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-code-r2-audit.md`
with the same structure as r1:

```
# SPEC-016 IMPL Step 2 — codex CODE REVIEW lane, round 2

## Verdict (code review lane only)

<one-line: CLEAN | FIX-THEN-PROCEED | BLOCK>

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| <N>      | <N>   | <N>    | <N> |

## r1 findings verification

| r1 ID    | Status   | Notes |
|----------|----------|-------|
| code:1.1 | CLOSED / NOT_CLOSED / PARTIAL | <one-line> |
| code:1.2 | CLOSED / NOT_CLOSED / PARTIAL | <one-line> |
| code:1.3 | CLOSED / NOT_CLOSED / PARTIAL | <one-line> |
| code:1.4 | CLOSED / NOT_CLOSED / PARTIAL | <one-line> |
| code:1.5 | CLOSED / NOT_CLOSED / PARTIAL | <one-line> |

## New findings (if any)

[code:2.1] [SEVERITY] ...

## Tests run

<list>

## Note on sibling lanes

Code-review only. Defer security/arch verdicts.
```

## Discipline

- BLOCK only on new CRITICAL OR if r1 closures are wrong.
- Cite `<file>:<line>` for every finding.

You may take up to 30 min wall-clock.

=== END PROMPT ===
```
