# SPEC-020 v0.1.4 IMPL — Round 5 audit prompt (per-lane, DEFENSIVE)

You are auditing the IMPL of SPEC-020 v0.1.4 at HEAD of
`impl/spec-020-provider-autoupdate` (commit `17bd811`) in worktree
`/Users/augstar/macprovider-spec-020-impl`.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Return `VERDICT: READY TO MERGE`
if zero blocking findings. This is the final defensive round before
opening the IMPL PR.**

## Trend

- r1: 0C + 12H + 6M
- r2: 0C +  4H + 4M
- r3: 0C +  3H + 2M
- r4: 0C +  0H + 1M (Lane B + C already READY TO MERGE; Lane A 1M absorbed)
- r5 target: 0/0/0 across all three lanes → IMPL PR opens

## What changed since r4

Commit `17bd811` — "fix(020): remap two off-spec failure_class values
to 'other'" (5 files, 40 insertions, 13 deletions).

Removed `unsupported_install_topology` and `signed_policy_persist_failed`
from the IMPL's `AutoUpdateFailureClass` enum (both were absent from
LOCKED SPEC R-6.5). All emission sites remapped to `.other` with the
original semantic preserved in the structured `reason` field. Added
`testFailureClassEnumMatchesSpecR65` to lock IMPL enum at exactly 22
cases matching SPEC.

Behavior (restore-on-failure, session disable, cooldown) unchanged.

Counts: 663 swift tests pass, Go pass, watchdog scripts pass.

## Authoritative inputs

- IMPL at HEAD of `impl/spec-020-provider-autoupdate` (commit `17bd811`)
- SPEC at `specs/SPEC-020-provider-autoupdate.md` (LOCKED v0.1.4)
- Audit narratives in `specs/SPEC-020-IMPL-r{1,2,3,4}-audit.md`

## Lane-specific focus — defensive checks

Each lane: re-verify prior absorbed findings + spot-check for
anything missed.

### Lane A — Codex architect

- Confirm SPEC R-6.5 ↔ IMPL enum parity (22 cases, no drift).
- Confirm remap of the two removed values preserves operator-visible
  diagnostic capability via structured `reason`.
- No new architectural issues introduced by the remap.

### Lane B — Codex code

- IMPL enum has EXACTLY 22 cases — verified by `testFailureClassEnumMatchesSpecR65`.
- All emission sites use enum values that exist in the IMPL enum (no
  hardcoded strings).
- No regressions on the prior AC tests.
- `reason: "unsupported_install_topology"` and
  `reason: "signed_policy_persist_failed"` are now in structured `reason`
  field, NOT in `failure_class` — verify with grep.

### Lane C — Codex security

- Remap doesn't reduce the security posture: rollback-on-failure and
  session-disable behavior still triggers in the two affected paths.
- `failure_class:"other"` is broad — confirm coordinator-side logs can
  still differentiate via the structured `reason` field.
- No coordinator-visible payload growth that could trip 4096-byte bound.

---

## Output format

`VERDICT: READY TO MERGE` if 0/0/0. Else `VERDICT: NEEDS REVISION`
with counts + ID-prefixed findings.

Convergent cross-lane findings = strongest signal. This is defensive —
no new exploratory findings expected.
