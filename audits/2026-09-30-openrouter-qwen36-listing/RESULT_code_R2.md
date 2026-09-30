
- **HIGH — Model-class aliases bypass the multi-turn tool gate**  
  File: [server.go:6821](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6821)

  The gate compares the requested model only against catalog IDs using `billing.ModelsEquivalent`. A native model-class alias such as `small-fast` therefore appears unresolved and passes the gate. Later, class resolution can select a catalogued non-§3.8 model such as Llama 3.2, and dispatch rewrites the alias to that concrete model.

  A request containing `role:"tool"` or assistant `tool_calls` then reaches an unsupported provider, recreating the provider error/502/degradation path the change is intended to prevent.

  Supporting paths: class resolution at [server.go:7546](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:7546), provider matching at [server.go:7694](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:7694), and dispatch rewriting at [server.go:6258](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6258).

  **Fix:** Resolve native model-class members before the pre-dispatch gate. Reject aliases capable of routing to any catalogued non-§3.8 model, or restrict selection to eligible members. Add a regression test using a class alias backed by Llama 3.2, asserting the specified 400 response and zero provider requests.

### Round-1 verification

The original R1 findings are addressed:

- Catalog/free/case/bare aliases use `ModelsEquivalent`.
- Empty `tool_calls: []` is rejected during validation.
- The probe requires the exact single OpenRouter listing.
- Feature descriptors are validated exactly.
- `response_format` uses the required object descriptor.
- Structured-output and tool-family predicates are separated.
- CONFORMANCE mappings cover the new gate and descriptors.
- Probe tests no longer assume the stale catalog version or 17 listed rows.

The accepted predicate-duplication LOW was not counted. The model-class issue above is a fresh bypass variant outside the aliases covered by the R1 fix.

Targeted coordinator, gateway, and all 98 probe unit tests passed. `git diff --check` and CONFORMANCE JSON parsing also passed. Repository-wide tests were not run due the MacProvider local resource boundary.

VERDICT: C=0 H=1 M=0 L=0.
