# IMPL audit prompt — SPEC-016 Step 1, **SECURITY REVIEW lane, round 2**

Round 2 of the security-review lane against the Step 1 r1
fix-pass. Branch `impl/spec-016` HEAD after fix-pass: `fc3bf56`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the **security-reviewer** lane (2 of 3) auditing SPEC-016
Step 1 IMPL — round 2. Round 1 returned 0/0/0 + 1 LOW (see
`specs/SPEC-016-IMPL-STEP_1-security-r1-audit.md`); your prior
adversarial probe matrix found NO Step 1 money-path defense
cracking. The fix-pass commit `fc3bf56` addresses 1 CRITICAL + 3
MEDIUMs from the code + architecture lanes. Your round 2 job:
verify the fix-pass does NOT introduce a NEW security defect AND
that the CRITICAL closure ([code:1.1] payout_allowed rotation
gate) actually defangs the money-out gate-bypass class.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md` for the shared
context preamble. Same SPEC version (v0.1.21 LOCKED at
`f0152c0`). Same threat models (Adversary A / B / C / D).

Branch HEAD: `fc3bf56`. Fix-pass diff: `git show fc3bf56`.

## Your r2 verification scope

### Verify [code:1.1] CRITICAL closure from a security lens

The fix is at `addresses.go` — rotation now reads existing
`payout_allowed` inside the txn and rejects 409 on 0. Probe:

1. **Adversary A re-attempt:** stolen `provider_token`, victim's
   row at `payout_allowed=0` (operator-disabled). Can the
   attacker bypass the gate via any cred path? Confirm the
   compliance-disabled row stays untouched on the 409.

2. **Race against the §6.4.1 compliance-gate path** (Step 3
   territory but the lock semantics are testable now): the read
   of `payout_allowed` is inside BEGIN IMMEDIATE — confirm no
   alternate code path can flip the row between the read and the
   UPDATE. (At Step 1 there is no Step 3 endpoint yet so the
   race is hypothetical, but the lock posture should hold.)

3. **Nonce-table side-channel:** a 409 path rolls back the txn,
   which rolls back the nonce-replay INSERT. Verify by attempting
   the same `(canonical_address, nonce)` after a 409 — does the
   second attempt succeed (showing the nonce was rolled back) or
   400-replay (showing the rollback didn't happen)? Either is
   defensible architecturally but the security implication
   differs:
   - If rolled back: an attacker who guesses a victim's
     `payout_allowed=0` state can probe-retry the same nonce
     indefinitely (still gated by §3.3 rate-limit which Step 1
     does not implement).
   - If NOT rolled back: a legitimate retry by the same provider
     would 400 against itself, breaking liveness.
   Document which behavior the IMPL exhibits and whether the
   SPEC §3.3 wording mandates one or the other.

### Verify [code:1.2] MEDIUM closure from a security lens

`nonceLowerHex = "0x" + hex.EncodeToString(nonce32[:])` is the
canonical form derived from decoded bytes. Probe:

1. Adversary B (replay attacker) attempts every prefix variant
   (`0x`, `0X`, no prefix elsewhere in the spec — but only `0x` /
   `0X` are accepted by `DecodeNonce32`). Confirm all variants
   collapse to the same anti-replay key.

2. Confirm `hex.EncodeToString` always emits LOWERCASE — there
   is no environment-dependent path that could emit uppercase.

### Verify [arch:1.3] MEDIUM closure from a security lens

The new `AssertPayoutRuntimeTopology` hook in `topology.go`
rejects empty / malformed hot-wallet pin at startup. Probe:

1. **Empty pin path:** an operator whose
   `payout.security.hot_wallet_address` is the empty string
   triggers `setupPayout` to fail before the listener mounts. No
   §3.3 traffic can reach a handler that would silently EIP-712
   verify against `verifyingContract=""` (which would short-circuit
   the proof-of-possession contract).

2. **Malformed pin path:** garbled hex / wrong length triggers
   the EIP-55 check inside `AssertPayoutRuntimeTopology`. Confirm
   no path bypasses this.

### Regression sweep — re-run a subset of the r1 probes

Re-fire (from your r1 round) the highest-leverage adversarial
probes against the fix-pass tip to confirm no regression:

- Independent ethers.js EIP-712 vector still accepted by the Go
  verifier (same digest).
- 8-conn `PRAGMA synchronous = 2` (FULL) probe still holds.
- TOCTOU pause re-check still 503's on the in-txn flip race.
- Hot-wallet self-payment denial via `denylist` still 400's.
- v=0/1 signature still rejected.
- `0X`-prefix replay defeated (this is also the [code:1.2]
  closure test — running the test twice from two angles is fine).

Document each probe's pass / fail outcome in the report.

### Output

Write findings to
`specs/SPEC-016-IMPL-STEP_1-security-r2-audit.md` with the same
structure as r1:

```
# SPEC-016 IMPL Step 1 — codex SECURITY REVIEW lane, round 2

## Verdict (security review lane only)

<one-line summary: CLEAN | FIX-THEN-PROCEED | BLOCK>

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| <N>      | <N>   | <N>    | <N> |

## r1 closures verified from security lens

| r1 ID    | Lane     | Closure verdict | Notes |
|----------|----------|-----------------|-------|
| code:1.1 | code     | CLOSED / PARTIAL / NOT_CLOSED | <one-line> |
| code:1.2 | code     | CLOSED / PARTIAL / NOT_CLOSED | <one-line> |
| arch:1.3 | arch     | CLOSED / PARTIAL / NOT_CLOSED | <one-line> |

## Regression probe matrix

<table of each probe + verdict>

## New findings (if any)

[sec:2.1] [SEVERITY] ...

## Tests run

<list of `go test -race`, fuzzing, manual probes>

## Cross-cutting security observations

<patterns spanning multiple findings>
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Model the attacker explicitly. Without an attacker model, a
  finding is a smell, not a security defect.
- CLEAN requires r1 closures VERIFIED + zero new CRITICAL /
  MAJOR / MEDIUM.
- Reference the threat-model adversary (A / B / C / D) for every
  finding.

You may run shell commands (`go vet`, `go test -race -count=1`,
fuzzing). You MUST NOT modify any file.

You may take up to 35 minutes wall-clock.

=== END PROMPT ===
```

---

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-016 v0.1.21 IMPL Step 1 round 2.
