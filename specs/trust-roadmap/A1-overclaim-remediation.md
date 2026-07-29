# A1 — Overclaim remediation (README + SDK doc)

**Type**: ship-now · **Size**: S (~2-3 operator hours) · **Dependencies**: none

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Status (2026-07-29)**: complete on `main` at `01e1585d` ("Clarify receipt
trust boundaries").

## Problem
`README.md:22` and `docs/using-macprovider-with-openai-sdk.md:202` present
provider-self-reported model identity as a shipping guarantee ("the verified
model hash … Verifiable inference"). The model hash is self-measured by the
provider; nothing binds it to the weights actually loaded. This violates the
repo's own normative rule `SPEC-006:343`, which forbids exactly this class of
claim, and `SPEC-006:3659` requires audit cycles to catch it.

## Change
Rewrite both strings to the `phase7-verify/README.md:129` pattern: state what
the signature proves, then enumerate what it does not (not model honesty, not
hardware attestation, not detection of a provider falsifying its own hash
measurement).

## Files
- `README.md`
- `docs/using-macprovider-with-openai-sdk.md`

## Tests / evidence
- Run `SPEC-006:3659`'s audit-cycle language check over the diff.

## Non-goals
No code, no API, no other doc surface. The transcript/stats-label fixes are A6.

## Why it is unconditional
Buyer-facing misrepresentation is independent of cohort size; it is a live
violation of a normative rule in the repo today.
