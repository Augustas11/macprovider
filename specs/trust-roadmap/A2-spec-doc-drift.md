# A2 — Spec/doc drift reconciliation

**Type**: ship-now · **Size**: S · **Dependencies**: none (shares SPEC-023 with A4/A8)

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **REDUCED — SPEC-032 item done by #769**.

## Problem (roadmap §4.10)
- ~~`SPEC-032` posture inverted~~ — **DONE by PR #769**: the spec now records the 2026-07-11 posture as "superseded" and the gate as `false` (`SPEC-032:557,568`). No longer in scope.
- `SPEC-033`'s migration roster omits migration 019 (operator dual-control approval).
- `SPEC-013` NFR-4 ("nothing leaves the machine") contradicts three live egress
  paths: the hardware-evidence POST, `/v1/rate-card`, and signed static-feed fetches.
  (The HuggingFace pre-warm carve-out is already at `SPEC-013:1280-1281`.)
- `SPEC-023` has no "what the catalog signature does not prove" section (unlike the
  `SPEC-015` receipts negative-list).

## Change
Correct each drift; add the signature-does-not-prove section to SPEC-023
(mirror the SPEC-015 pattern); amend SPEC-013 NFR-4 to enumerate the three
egress paths it omits.

## Files
`specs/SPEC-033` (add migration 019 to the roster at `:17`), `SPEC-013`
(NFR-4 egress list at `:1279`), `SPEC-008-tier2.md`, and the SPEC-023
signature-caveat section. SPEC-032 no longer in scope (#769).

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
