## Findings

- HIGH — Alias-based bypass enables provider degradation. [server.go:6822](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6822) checks `tier2.Catalogued(req.Model)` using exact normalized catalog keys, while downstream routing accepts aliases through `billing.ModelsEquivalent`. A buyer can submit a catalog alias such as `meta-llama/llama-3.2-3b-instruct` with multi-turn tool history. The gate misses it, routing rewrites it to the provider’s canonical model, and the provider rejects it as `unsupported_modelID_for_multi_turn`. That error becomes a coordinator 502 and immediately degrades the provider at [server.go:10152](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:10152). Repeating this against matching providers creates an authenticated fleet-availability DoS. Fix: canonicalize or resolve the model through the same alias-equivalence mechanism used by routing before applying the gate. Add regression coverage for catalog aliases, free aliases, quantized/HF IDs, and case variants, asserting no dispatch or idempotency reservation occurs.

- LOW — The readiness probe does not detect unintended extra public model rows. [openrouter_readiness_probe.py:608](/Users/augstar/macprovider-or-features/scripts/openrouter_readiness_probe.py:608) verifies that required model IDs are present but never rejects additional IDs. An accidental regression exposing Llama or other fleet models alongside Qwen3.6 would therefore pass the filing probe, contrary to SPEC-006’s Qwen3.6-only requirement. Fix: in filing/`require_catalog` mode, require the returned ID set to equal `OPENROUTER_LISTED_MODEL_IDS` plus explicitly permitted aliases, and add an extra-row rejection test.

No CRITICAL or MEDIUM findings. The pre-dispatch 400 occurs before provider dispatch and idempotency reservation; the inspected gateway refund and request-log paths did not show settlement, receipt, or provider-credit side effects.

Targeted Go gate and model-document tests passed, as did `git diff --check`. The probe test suite had one unrelated pre-existing stale catalog-version assertion failure.

VERDICT: C=0 H=1 M=0 L=1.
