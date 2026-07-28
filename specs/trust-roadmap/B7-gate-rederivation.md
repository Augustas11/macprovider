# B7 — Catalog gate re-derivation tooling

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Gated on**: ≥3 verified providers existing / #584 hardware. Deferred by physics, not choice.

## Problem / shape
Stage-4 promotion arithmetic (roadmap §7 rule 4, #687): recompute each gate from
≥N verified providers' post-#745 measurements on ≥M hardware classes (N≥3, M≥2),
cross-checked against observed serving data; drop the oMLX seed at promotion.
**Unbuildable at current fleet size**, and the >32 GB rows remain unmeasurable
pending #584. Only after a gate reaches `trusted_provider_matrix` may it gain
enforcement power, and then under a new field name (`hard_min_sustained_tps`) so
the advisory wire field never silently changes meaning.
