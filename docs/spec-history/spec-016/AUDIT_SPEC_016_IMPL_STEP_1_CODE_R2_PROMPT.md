# IMPL audit prompt — SPEC-016 Step 1, **CODE REVIEW lane, round 2**

Round 2 of the code-review lane against the Step 1 r1 fix-pass.
Branch `impl/spec-016` HEAD after fix-pass: `fc3bf56`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the **code-reviewer** lane (1 of 3) auditing SPEC-016
Step 1 IMPL — round 2. Round 1 returned 1 CRITICAL + 1 MEDIUM
(see `specs/SPEC-016-IMPL-STEP_1-code-r1-audit.md`). The fix-pass
landed in commit `fc3bf56` on branch `impl/spec-016`. Your round
2 job: verify the r1 findings are properly closed AND scan for
regressions or new defects introduced by the fix-pass.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md` for the full
shared context preamble. Same SPEC version (v0.1.21 LOCKED at
`f0152c0`). Same Step 1 scope.

Branch HEAD: `fc3bf56`. Recent commit chain:

- `fc3bf56` impl(016): Step 1 r1 fix-pass — close 1 CRITICAL + 3 MEDIUMs
- `2ca290a` spec(016): Step 1 audit r1 findings — 3 parallel codex lanes
- `85ec22a` spec(016): Step 1 audit — split into 3 parallel codex lanes
- `6b7a73f` spec(016): Step 1 audit prompt — rebase onto SPEC v0.1.21
- `f0152c0` spec(016): v0.1.20→v0.1.21 — Claude r20 cross-check + codex r21/r22
- `1df0235` impl(016): Step 1 — schema + §3 address registration + §3.2 EIP-712

## Your r2 verification scope

### r1 findings to verify CLOSED

**[code:1.1] CRITICAL — rotation re-enables payout_allowed=0**

Verify the fix at `phase4-coordinator/internal/payout/addresses.go`:

- The SELECT inside the BEGIN IMMEDIATE txn now reads BOTH
  `address` AND `payout_allowed` from `provider_payout_addresses`.
- The rotation branch checks `existingPayoutAllowed.Int64 == 0`
  and returns 409 `payout_not_allowed` BEFORE the UPDATE.
- The UPDATE preserves `existingPayoutAllowed.Int64` (no longer
  hardcoded to `1`).
- The 409 path returns via the `committed=false` defer, so the
  nonce-replay INSERT performed earlier in the txn is rolled back
  (probe: a 409'd request MUST NOT register the nonce as "seen"
  — otherwise a follow-up legitimate retry would 400
  `nonce_replayed` against itself; verify by re-attempt against
  the same `(canonical_address, nonce)` after a 409).
- Regression tests
  `TestServePayoutAddress_RotationPreservesPayoutAllowed_Zero` +
  `TestServePayoutAddress_RotationPreservesPayoutAllowed_One`
  exist and pass.

**[code:1.2] MEDIUM — 0X vs 0x nonce splits anti-replay**

Verify the fix at the same file:

- The `nonceLowerHex` derivation is now
  `"0x" + hex.EncodeToString(nonce32[:])` (from decoded bytes).
- `DecodeNonce32` still accepts both 0x/0X (for input laxity)
  but the STORAGE key is invariant.
- Regression test
  `TestServePayoutAddress_NonceCanonicalisation_0XReplayDefeated`
  exists and submits the 0X-prefix replay → 400
  `nonce_replayed`, plus asserts the anti-replay table holds
  exactly one row for the canonical nonce key.

### Regression sweep

Probe for code-side defects the fix-pass MAY have introduced:

1. The new `existingPayoutAllowed sql.NullInt64` scan order:
   verify the SELECT column ordering matches the Scan target
   ordering (`address, payout_allowed` ↔ `&existingAddress,
   &existingPayoutAllowed`). A swapped order would silently
   parse `0` / `1` into the address NullString.

2. The 409 short-circuit MUST run AFTER the BEGIN IMMEDIATE + the
   nonce-replay INSERT. Confirm the ordering by reading
   `ServePayoutAddress` top-to-bottom. A 409 issued BEFORE the
   nonce INSERT would let an attacker probe-rotate without
   advancing the nonce table (DoS-ish, not money-out).

3. `preservedPayoutAllowed` defaults to `1` when
   `existingPayoutAllowed.Valid == false`. That branch is
   unreachable in practice (the row exists at this point because
   `existingAddress.Valid == true`), but confirm the default
   matches the SPEC §3.1 schema default. Flag if a future schema
   bump changes the default.

4. New `encoding/hex` import — confirm no shadow of an existing
   `hex` symbol.

5. The `topology.go` runtime-OS check (`runtime.GOOS != "linux"`)
   is currently gated by `LinuxRequired=false` at Step 1. Confirm
   the gate skips correctly on darwin (Mac dev hosts).

### NEW focus areas (only if you spot something)

Do not re-audit the entire Dimension 1 focus area list from r1 —
the r1 codex lane was thorough. ONLY flag if you observe a NEW
defect in the diff between `1df0235` and `fc3bf56`. Skim the diff
via `git show fc3bf56`.

### Output

Write findings to `specs/SPEC-016-IMPL-STEP_1-code-r2-audit.md`
with the same structure as r1:

```
# SPEC-016 IMPL Step 1 — codex CODE REVIEW lane, round 2

## Verdict (code review lane only)

<one-line summary: CLEAN | FIX-THEN-PROCEED | BLOCK>

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| <N>      | <N>   | <N>    | <N> |

## r1 findings verification

| r1 ID    | Status   | Notes |
|----------|----------|-------|
| code:1.1 | CLOSED / NOT_CLOSED / PARTIAL | <one-line> |
| code:1.2 | CLOSED / NOT_CLOSED / PARTIAL | <one-line> |

## New findings (if any)

[code:2.1] [SEVERITY] ...

## Tests run

<list of go test invocations + pass/fail>

## Cross-cutting code observations

<anything spanning multiple files>

## Note on sibling lanes

You are the code-review lane only. Defer security / arch verdicts
to sibling lanes.
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- A CLEAN verdict requires r1 findings VERIFIED closed AND zero
  new findings.
- BLOCK only if you find a new CRITICAL or if r1 closures are
  themselves wrong.
- You may run shell commands (git log, git show, grep, go vet,
  go test). You MUST NOT modify any file.

You may take up to 25 minutes wall-clock. Clean reports are
shorter — don't pad.

=== END PROMPT ===
```

---

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-016 v0.1.21 IMPL Step 1 round 2.
