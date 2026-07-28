# A2 — Spec/doc drift reconciliation

**Type**: ship-now · **Size**: S · **Dependencies**: none (shares SPEC-023 with A4/A8)

## Problem (roadmap §4.10)
- `SPEC-032:553` states the hello gate is on in prod; it is **off** (verified 2026-07-22).
- `SPEC-033`'s migration roster omits migration 019 (operator dual-control approval).
- `SPEC-013` NFR-4 ("nothing leaves the machine") contradicts three live egress
  paths: the hardware-evidence POST, `/v1/rate-card`, and signed static-feed fetches.
  (The HuggingFace pre-warm carve-out is already at `SPEC-013:1280-1281`.)
- `ops/runbooks/spec-drift-remediation.md:130` contradicts the live overlay read.
- `SPEC-023` has no "what the catalog signature does not prove" section (unlike the
  `SPEC-015` receipts negative-list).

## Change
Correct each drift; add the signature-does-not-prove section to SPEC-023
(mirror the SPEC-015 pattern); amend SPEC-013 NFR-4 to enumerate the three
egress paths it omits.

## Files
`specs/SPEC-032`, `SPEC-033`, `SPEC-013`, `SPEC-023`, `SPEC-008-tier2.md`,
`ops/runbooks/spec-drift-remediation.md`.

## PR-declaration note
The SPEC edits are governance-only, but `ops/runbooks/` is **not** in the repo's
`GOVERNANCE_ONLY_PATHS` (`scripts/check_spec_pr_declaration.py:45-56`), so a
whole-PR `behavior_change: "none"` would be rejected. Either declare `"yes"`, or
split the one-line runbook fix into a separate mini-PR and keep the spec edits
`"none"`.

## Non-goals
No code. Does not touch the SPEC-023 row table — that contradiction is A8.

## Coordination
A2, A4, A8 all edit the LOCKED `SPEC-023`. Sequence the PRs or combine the
SPEC-023 edits into one to avoid a collision + redundant re-locks.
