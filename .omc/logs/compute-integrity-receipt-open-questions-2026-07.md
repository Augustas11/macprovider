# Compute-Integrity Receipt Open Questions

**Date:** 2026-07-10
**Spec:** `specs/SPEC-030-compute-integrity-receipt.md`
**Research memo:** `docs/research/compute-integrity-receipt-2026-07.md`

Maintainer-input items before moving beyond v0.1-draft:

1. **Reference source:** Is trusted-reference-only acceptable for first enforce,
   or must every enforce deployment run hybrid trusted-reference plus N-provider
   consensus telemetry?

2. **Threshold floors:** Approve or revise the initial
   `tau_warn_median=0.015`, `tau_warn_position=0.030`,
   `tau_quarantine_median=0.060`, and `tau_quarantine_position=0.120` floors
   before warn-only calibration starts.

3. **Onboarding gate length:** Decide whether arbitrary new providers need the
   proposed 5 passes over 30 minutes, or a longer 24-hour pass window before
   covered paid routing.

4. **Enforce timeline:** Confirm the proposed minimum of 30 warn-only days,
   10,000 eligible canaries, 100 provider/model/hash keys, and 3 reference
   refresh or catalog/model rotation events before enforce activation.

5. **Funding model:** Choose v0.1 funding for consensus/reference costs:
   operator/network budget, provider credits, MALIBU rewards, or a later
   staker-funded quality budget. Buyer pass-through is rejected for v0.1 because
   probes are non-billable and SPEC-015 v0.4 `usage` is strict.
