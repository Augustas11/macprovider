# Build 1 narrow MVP evidence-validator handoff v1

Status: implementation slice complete and locally verified. This handoff covers the redacted physical-staging evidence validator only.

## Implemented

- Added `scripts/validate-build1-narrow-mvp-evidence.py` for the approved Build 1 narrow MVP tuple.
- Added `scripts/tests/test_build1_narrow_mvp_evidence.py` with 57 unit tests.
- Preserved approved plan/test-spec v6 digests and marked superseded v1-v5 plan/test artifacts and v5 review history as non-authoritative.

## Verification status

- Local unit/compile/smoke/diff checks passed.
- Independent GPT-5.6 Sol code, security, and architecture lanes reported zero Critical/High/Medium findings on the final 57-test snapshot. Results are recorded in `docs/product-roadmap/build-1/reviews/narrow-mvp-validator-audit-v1.md`.
- Physical staging acceptance has not been run and is not claimed. The validator reports structural `schema-valid` status only; it is not a substitute for reviewing the referenced source captures or running the physical staging journey.

## Current qualification blockers

- PR #1510 remains an unmerged dependency for this branch.
- A measured artifact-bound staging release for the MVP tuple is still required before physical preparation/adoption can pass acceptance.
- Physical Apple Silicon staging run is still required to produce actual MLX request, provider receipt/audit correlation using the current emitted receipt-audit fields, and verified settlement evidence.
- Production economic activation, production enforcement, rewards, payout jobs, and payouts remain out of scope and not activated.

## Next slice

Continue Build 1 narrow MVP implementation with the executable provider path that creates the evidence bundle the validator now enforces: staging artifact-feed authority, preparation/adoption capture, runtime status capture, coordinator admission capture, non-streaming MLX request, provider receipt/audit correlation using the current emitted receipt-audit fields, and verified settlement retrieval.
