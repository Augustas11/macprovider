# Build 1 test spec: v2 configured storage budget foundation

Test spec revision: v1.
Plan: `v2-storage-configured-budget-plan-v1.md`.

## Scope

Unit-test only the internal v2 storage snapshot/projection path. Do not test or imply public v2 command activation, env/YAML config parsing, or production model preparation.

## Required tests

- Valid configured budget:
  - create a root-validated private `published_inventory`;
  - call `loadPrivateStorageSnapshot(... configuredBudgetBytes:)`;
  - assert `managed_budget_source == "configured"`;
  - assert `global_managed_budget_bytes` equals the configured value, not the default volume-derived value;
  - assert charge, available budget, and cleanup target publication stay intact.
- Maximum configured budget:
  - pass the exact SPEC-044 upper bound `1099511627776`;
  - assert it remains valid, emits `managed_budget_source == "configured"`, and reports exact remaining budget after the published-byte charge.
- Invalid configured budget:
  - cover zero, negative, and above-maximum values;
  - use a valid volume capacity so fallback would be observable;
  - assert unavailable storage, `global_managed_budget_bytes == 0`, and empty cleanup targets.
- Saturated configured budget:
  - choose a valid configured value smaller than published bytes;
  - assert truthful charge and `available_managed_budget_bytes == 0`.
- Regression:
  - keep the existing default-budget tests passing when no configured value is supplied.

## Non-goals

- No environment-variable parser test.
- No YAML configuration test.
- No physical disk free-space test.
- No public CLI status or Malibu UI test.
