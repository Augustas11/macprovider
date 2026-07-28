# A8 — Reconcile SPEC-023 v0.8 against the live signed catalog

**Type**: ship-now · **Size**: S (~3-5 operator hours) · **Dependencies**: none (shares SPEC-023 with A2/A4)

## Problem (roadmap §4.13, F13)
`SPEC-023 v0.8` is `status: LOCKED`, yet its normative row table disagrees with
the **live signed** catalog on 6 of 7 shared rows. Most starkly
`google-gemma-4-26b-a4b-it`: the spec lists it `blocked` (`SPEC-023:259-267`) and
says "blocked rows are never … recommended by default" (`:269`), while
`phase3-binary/dist/static/autotune-candidates.json` serves it
`runtime_status: "recommendable"`. §7 rule 2 is already violated against the
normative spec. This is exactly the governance-correctness gap the document's
thesis targets — a signed artifact contradicting a locked spec.

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
