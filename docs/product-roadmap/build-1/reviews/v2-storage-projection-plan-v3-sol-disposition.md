# Build 1 v2 storage projection plan v3 Sol review disposition

Reviewer: `/root/b1_v2_storage_plan_sol_r2` using `gpt-5.6-sol`, high reasoning.
Scope reviewed: plan/test v3, disposition, SPEC-044, current Swift code.

## Findings and resolutions

- High: v3 required `validateCleanupBinding` for every target, which contradicts protected targets because protected cleanup actions must be unavailable with null digest/bytes. Resolved in plan/test v4 by calling the helper only for reclaimable targets and by specifying protected-target invariants separately.
- Medium: v3 allowed caller-supplied budget values while labeling source `default` or `configured`. Resolved in v4 by supporting only computed default budget in this slice: `min(1TiB, floor(volume_capacity_bytes * 70 / 100))`, with no configured source emission.
- Medium: v3 required stale inventory failure without defining the stale signal. Resolved in v4 by removing stale detection from this slice and naming it as a future scanner/receipt-validation concern; this slice trusts only already decoded usable inventory.

Plan gate status after this disposition: not yet approved. Plan/test v4 require a fresh independent review.
