# SPEC-020 v0.1.4 IMPL — Round 4 audit narrative

**Audited:** commit `6774559` (r3 absorption)
**Round:** r4 (post-r3 absorption defensive)
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect | NEEDS REVISION | 0 | 0 | 1 |
| B code | **READY TO MERGE** | 0 | 0 | 0 |
| C security | **READY TO MERGE** | 0 | 0 | 0 |

**Totals: 0 CRITICAL, 0 HIGH, 1 MEDIUM.**

Trend r1→r2→r3→r4: HIGH 12→4→3→**0**, MEDIUM 6→4→2→**1**.

## Lane A finding

**A-r4-M-1**: `signed_policy_persist_failed` is emitted in the IMPL enum but the LOCKED SPEC R-6.5 enum doesn't list it. Implementation has drifted from the spec.

Investigation revealed TWO drifts (Lane A flagged one):
1. `signed_policy_persist_failed` (added during r3 absorption for C-r3-M-1)
2. `unsupported_install_topology` (added during r1 absorption for A-r1-H-4)

Both were added without realizing SPEC v0.1.4 was LOCKED.

## Absorption — commit `17bd811`

Per [[feedback-bundle-spec-impl-one-pr]] SPEC-020 is net-new so the SPEC cannot be amended in this IMPL PR. Instead:

- Removed both enum cases from `AutoUpdateFailureClass` in
  `phase3-binary/Sources/macprovider-cli/AutoUpdateEvent.swift`.
- Remapped all emissions to `AutoUpdateFailureClass.other` with the
  original semantic preserved in the structured `reason` field.
- Updated watchdog rollback classification accordingly.
- Added `testFailureClassEnumMatchesSpecR65` asserting the IMPL enum
  has exactly 22 cases matching SPEC R-6.5.

Behavior (restore-on-failure, session disable, cooldown) unchanged. Only
the wire-visible `failure_class` string changes.

Counts: 663 swift tests pass (was 662; +1 for new enum-conformance test), Go pass, watchdog scripts pass.

## Lane B + C READY TO MERGE confirmations

**Lane B** confirmed (Lane C also confirmed independently):
- `update_id` validation strict lowercase UUIDv4.
- `marker_deadline` upper bound 1860s consistent Swift + shell.
- `signed_policy_persist_failed` was handled as terminal-for-session before remap (now folded into `other`).
- AC-10 watchdog tests cover all 3 classifications.
- AC-22 / AC-23 Swift tests exercise production paths.

**Lane C** further confirmed (security):
- Pre-staged sentinel rejection (`update_id_mismatch`, `binary_version_mismatch`, `no_matching_pending`).
- `marker_deadline` tightened to spec tolerance.
- No `TEST_MODE` production bypass.
- Cross-process recovery idempotent.

## Next action

Fire IMPL r5 (defensive) across all three lanes against `17bd811`. If
all three return READY TO MERGE → open IMPL PR and proceed to v1.7.0
release tag.

## Raw artifacts

- Lane A architect: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-4-audit-prompt-per-lane-you-are-a-2026-06-29T17-33-11-423Z.md`
- Lane B code: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-4-audit-prompt-per-lane-you-are-a-2026-06-29T17-33-14-686Z.md`
- Lane C security: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-4-audit-prompt-per-lane-you-are-a-2026-06-29T17-34-10-583Z.md`
