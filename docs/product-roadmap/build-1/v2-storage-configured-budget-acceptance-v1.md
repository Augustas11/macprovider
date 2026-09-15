# Build 1 acceptance: v2 configured storage budget foundation

Acceptance revision: v1.
Plan: `v2-storage-configured-budget-plan-v1.md`.
Test spec: `v2-storage-configured-budget-test-spec-v1.md`.

## Result

Accepted for internal Build 1 groundwork. The v2 private-storage snapshot loader can now carry an already-selected configured managed budget into the internal v2 projection. Valid configured values emit `managed_budget_source: "configured"` and invalid selected values fail closed without falling back to the default volume budget.

## Evidence

- `swift test --filter ModelCatalogEconomicsTests`
- Result: 26 tests, 0 failures.
- `swift test --filter 'ProviderStatusTests|ModelsSubcommandTests'`
- Result: 92 tests, 0 failures.

New tests:

- `testV2ProjectionUsesConfiguredBudgetWhenSelected`
- `testV2ProjectionAcceptsMaximumConfiguredBudget`
- `testV2ProjectionRejectsInvalidConfiguredBudgetWithoutFallingBackToDefault`
- `testV2ProjectionConfiguredBudgetSaturatesAvailableBudgetAtZero`

## Boundary Preserved

- Public `models catalog-economics --json` remains v1.
- No v2 status capability was advertised.
- No env/YAML parser was wired.
- No preparation, cleanup execution, admission, settlement, payout, release, or production activation was added or claimed.
