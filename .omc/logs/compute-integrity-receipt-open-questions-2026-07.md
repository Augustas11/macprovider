# Compute-Integrity Receipt Open Questions

**Date:** 2026-07-10
**Spec:** `specs/SPEC-030-compute-integrity-receipt.md`
**Research memo:** `docs/research/compute-integrity-receipt-2026-07.md`

Maintainer-input items before moving beyond v0.1-draft:

1. **Reference source:** Is trusted-reference-only with two active independent
   trusted-reference nodes acceptable for first enforce, or must every enforce
   deployment run hybrid trusted-reference plus N-provider consensus telemetry?

2. **Threshold floors:** Approve or revise the initial
   `tau_warn_median=0.015`, `tau_warn_position=0.030`,
   `tau_quarantine_median=0.060`, and `tau_quarantine_position=0.120` floors
   before warn-only calibration starts.

3. **Enforce onboarding gate length:** Decide whether arbitrary new providers
   need the proposed 5 passes over 30 minutes, or a longer 24-hour pass window
   before covered paid routing once enforce mode is active. Warn-only onboarding
   remains readiness telemetry only.

4. **Enforce timeline:** Confirm the proposed per-covered-key minimum of 30
   warn-only days, at least 100 eligible canaries, at least 10 distinct stable
   provider identities when available, and at least one relevant reference
   refresh after reference runtime/build, runtime-build provenance digest, signed
   golden-fixture validation digest, tokenizer, sampler-stage, corpus,
   threshold, or catalog changes before enforce activation. Fleet-wide totals
   must not substitute for missing per-key calibration; keys without approved
   per-key calibration stay observe/warn-only or outside enforce coverage.

5. **Consensus funding model:** V0.1 probe/reference costs are decided as
   operator/network funded. Choose whether consensus telemetry, if enabled, uses
   capped non-buyer credits with per-provider caps and anti-Sybil eligibility, or
   remains disabled until a later budget exists. Buyer pass-through and uncapped
   MALIBU rewards are rejected for v0.1 because probes are non-billable and
   SPEC-015 v0.4 `usage` is strict.
