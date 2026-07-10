# SPEC-020 v0.1.3 — Round 4 audit prompt (per-lane)

You are auditing **SPEC-020 v0.1.3 (2026-06-29, DRAFT)** post-r3 absorption.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Return `VERDICT: READY TO LOCK` if you find zero blocking findings; minor/Note observations under "Notes" are fine.**

## Trend

- r1: 0C + 4H + 13M (3 lanes)
- r2: 0C + 2H + 10M (3 lanes)
- r3: 0C + 1H + 8M (3 lanes)
- r4 target: 0/0/0

## What changed since r3 (v0.1.2 → v0.1.3)

- **Live trust-state predicate** with explicit 5 re-evaluation points (download / drain / marker / swap / launchctl-bootstrap) + `failure_class:"trust_state_lost"` enum value + partial-state cleanup invariant + AC coverage. T-1 absorption (A-r3-H-1 + C-r3-M-1).
- **`autoupdate_drain_extensions:true` capability gate** on the coordinator before providers emit `drain_status.phase:"timeout_skipped"`. Plus `state_update state:"ready"` after timeout-skipped swap. (A-r3-M-1).
- **Success-state cleanup**: atomically delete `pending.json` + rollback backup + release lock on post-start success. (B-r3-M-1).
- **`marker_deadline` semantics**: writer/basis/comparison/tolerance/missing-malformed-expired-future behavior all pinned. (B-r3-M-2).
- **`NORMALIZED_TARGET` definition** + downstream use in release lookup, marker, cooldown, drain reason. (B-r3-M-3).
- **Post-start failure_class split** into 3 explicit values. (B-r3-M-4).
- **Signed-policy monotonic persistence**: `persisted_signed_policy_minimum` / `persisted_signed_policy_revoked` as write-once-grow-only. (C-r3-M-2).
- **SHA-256 redaction**: full lowercase 64-hex in `recommended_binary_version_sha256` field; prefix truncation forbidden. (C-r3-M-3).

## Authoritative inputs

(Same as r3.)

## Lane-specific focus

### Lane A — Codex architect

- **Live trust-state predicate completeness**: are the 5 re-eval points complete? Could an irreversible mutation happen between two points where eligibility is not checked? Specifically check: between the `validateChecksumSignature` succeeding and the `applyValidatedUpdate` call — is there a gap?
- **Capability gate vs `recommended_binary_version` emission**: is `autoupdate_drain_extensions:true` actually a distinct signal from emitting `recommended_binary_version`? If so, does any v0.1.3 R-N.M require providers to verify this flag on EVERY coord session, or just initial connect? Mid-session capability degradation handling?
- **Cross-spec interaction with SPEC-018/SPEC-019 active products**: does the live-invariant re-evaluation conflict with any active inference request flow? E.g., a streaming SO request in flight when drain enters — what's the precedence?
- **Convergence boundary unchanged**: r3 didn't touch it. Confirm.
- **Overall design**: with all r1-r3 absorptions, is the SPEC implementable as a single PR's worth of work, or has it bloated past one PR? (Implementability check, not bloat finding.)

### Lane B — Codex code

- **Citations verify**: every cite in v0.1.3 resolves. New cites likely added for `autoupdate_drain_extensions`, `trust_state_lost`, `NORMALIZED_TARGET`, etc.
- **`NORMALIZED_TARGET` propagation**: grep every place the SPEC uses target / target_version / release tag. Does each call site use NORMALIZED_TARGET or could literal coord-sent value leak through?
- **`marker_deadline` tolerance interaction with retry**: if a marker is rejected as "future beyond tolerance" → orphaned-recovery path. Does the SPEC say whether autoupdate is then permanently disabled for the session or can retry?
- **Success-state cleanup atomicity**: "atomically mark success, delete pending.json, delete backup" — is the ORDER specified? What if the process crashes between delete-pending and delete-backup? Recovery semantics?
- **`failure_class` enum completeness**: every `failure_class:"X"` reference in body MUST appear in R-6.5 enum. Final check.
- **ACs**: AC count should be 22+ after r3. Verify the trust-state AC + post-start splits + success cleanup are all covered.

### Lane C — Codex security

- **Live trust-state predicate adversarial**: attacker who controls coord briefly opens a valid pinned + encrypted-leg session, watches provider initiate autoupdate, then immediately invalidates session — does v0.1.3's predicate catch the abort window between phases 4 and 5 (swap and launchctl bootstrap)?
- **Persisted monotonic signed-policy state**: where is `persisted_signed_policy_minimum` stored? Under `$HOME/.local/share/macprovider/`. Is its file/path mode/permission pinned in v0.1.3? Can a tampered persisted value erase prior revocations on next provider start?
- **`autoupdate_drain_extensions:true` capability**: is this a coord→provider field only, or also provider→coord? If provider→coord, can a malicious provider misadvertise to bypass coordinator-side admission?
- **Trust-state predicate failure → cleanup**: deleting partial state on `trust_state_lost` — is the deletion atomic? Could a race between cleanup and next-session-eligibility-evaluation cause double-execution of the autoupdate flow?
- **SHA-256 redaction**: redaction of oversized version is now full 64-hex. But is the redacted field still in the 4096-byte payload bound? 64 hex + JSON encoding is ~75 bytes — fine. But what about the original 32+ byte version being stored in marker for the abort path? Does the marker also enforce the bound, or could marker grow past 4096?

---

## Output format

`VERDICT: READY TO LOCK` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with C/H/M counts and ID-prefixed findings (A-r4-H-1, B-r4-M-1, C-r4-H-1, etc.).

Convergent findings still strongest signal.
