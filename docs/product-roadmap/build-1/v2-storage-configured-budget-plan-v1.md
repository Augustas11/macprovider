# Build 1 next slice: v2 configured storage budget foundation

Plan revision: v1.
Base revision: `origin/main` at `ab181787` (`Guard Build 1 MVP evidence from overclaiming (#1512)`).
Depends on: `v2-storage-projection-plan-v5.md` and `v2-storage-projection-acceptance-v1.md`.

## Goal

Advance SPEC-044 managed-v3 storage accounting by allowing the internal v2 private-storage snapshot loader to accept one already-selected configured budget value and project `managed_budget_source: "configured"` when it is valid. Invalid selected configured values fail closed and do not fall through to the default volume budget. This remains internal test-only projection groundwork.

## Boundary

- No public v2 local-status advertisement.
- No public `models catalog-economics` run or cancel activation.
- No env/YAML config parser wiring in this slice.
- No preparation, transfer, publication, cleanup execution, admission, settlement, rewards, payout, release packaging, or production activation.
- No private paths, root locators, operator secrets, feed bodies, or credentials are projected.

## Implementation

1. Extend `ModelCatalogEconomicsBuilder.PrivateStorageBudget` with a configured constructor that accepts only `1...1099511627776`.
2. Extend `loadPrivateStorageSnapshot` with an optional already-selected `configuredBudgetBytes` argument.
3. Use the configured budget when supplied and valid, with `managedBudgetSource == "configured"`.
4. Return unavailable storage when the supplied configured value is zero, negative, or above the SPEC-044 maximum, even when a valid default volume capacity is available.
5. Preserve existing default-budget behavior when no configured value is supplied.

## Acceptance

- Valid configured budget projects configured source and exact configured global budget.
- Configured budgets smaller than current published bytes keep truthful charge and clamp available budget to zero.
- Invalid configured values fail closed with unavailable storage and empty cleanup targets.
- Existing default-budget storage projection tests remain green.
- Public v1 CLI behavior is unchanged.
