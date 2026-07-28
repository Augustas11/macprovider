# A8 — Reconcile SPEC-023 v0.8 against the live signed catalog

**Type**: ship-now · **Size**: S (~3-5 operator hours) · **Dependencies**: none (shares SPEC-023 with A2/A4)

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **SHAPE — now 3 disagreeing rows**.

## Problem (roadmap §4.13, F13)
`SPEC-023` is now `v0.8.1`, `status: LOCKED`, and its normative row table still
disagrees with the **live signed** catalog on **3 rows** (all live rows are
`recommendable`):
- `google-gemma-4-26b-a4b-it` — spec **blocked** (`SPEC-023:271`), and "blocked
  rows are never … recommended by default";
- `qwen3-32b` — spec **listed** (`:268`);
- `qwen2.5-coder-32b-instruct` — spec **listed** (`:270`).
Two live rows (`llama-3.2-3b`, `qwen3-8b`) have no spec-table counterpart. §7
rule 2 is violated against the normative spec — a signed artifact contradicting
a locked spec, the exact governance gap the document's thesis targets. The
v0.8.1 amendment did not reconcile it.

## Change
Reconcile the two. The signed, serving catalog is the operational reality; bring
SPEC-023's row table into agreement with it (spec-follows-catalog) under a
version bump, or document each divergence with its justification. Record which is
authoritative per row.

## Files
`specs/SPEC-023-installer-autotune-recommend.md` (+ version bump); cross-check
against `phase3-binary/dist/static/autotune-candidates.json` and the baked copy.

## Non-goals
Does **not** change any served catalog row (that is a signed-catalog release).
It makes the spec tell the truth about what is served.

## Coordination
A2, A4, A8 all edit the LOCKED `SPEC-023` — share one unlock/version bump.
