
```text
1. **HIGH — `scripts/tests/test_openrouter_readiness_probe.py:224,232-234`**
   The probe test suite is not green. It currently fails on the stale expected catalog version; after correcting that, it will still assert that all 17 catalog models appear in `openrouter_models.go`, contradicting the new Qwen3.6-only listing.
   **Scenario:** CI runs `OpenRouterReadinessProbeTests` and fails; the second incompatibility is currently masked by the first assertion.
   **Fix:** Update the catalog version assertion and require only `OPENROUTER_LISTED_MODEL_IDS` to appear in the gateway listing source. Keep full catalog-to-slug validation separate.

2. **MEDIUM — `phase4-coordinator/internal/buyer/server.go:6822`**
   The multi-turn gate checks `tier2.Catalogued(req.Model)` using the raw model ID. Catalog lookup only trims/lowercases, while routing normalizes aliases such as `mlx-community/Llama-3.2-3B-Instruct-4bit-free`.
   **Scenario:** Multi-turn tool history sent to the retained Llama free alias is treated as uncatalogued, bypasses the pre-dispatch gate, reaches the provider, and can recreate the provider-400 → WS `error_internal` → 502/degradation failure.
   **Fix:** Perform alias-aware catalog lookup using the same normalization semantics as routing, while preserving the intended BYOM, pool, and external-engine exemptions. Add a `*-free` regression test.

3. **MEDIUM — `phase4-coordinator/internal/buyer/server.go:6840`**
   `hasMultiTurnToolData` treats `tool_calls: []` as multi-turn data, while coordinator validation accepts the empty array and the provider explicitly rejects it as `invalid_tools`.
   **Scenario:** For non-family models, an otherwise plain assistant message with `tool_calls: []` receives the misleading `unsupported_modelID_for_multi_turn`; for Qwen3.6, it passes this gate and can still trigger the provider-degradation path this change is intended to prevent.
   **Fix:** Reject empty `tool_calls` in coordinator request validation, matching the provider’s non-empty-array requirement. Base the gate on parsed non-empty calls, not raw non-null JSON.

4. **MEDIUM — `scripts/openrouter_readiness_probe.py:608`**
   Filing validation requires the Qwen3.6 row to be present but never rejects extra rows, despite SPEC-006 §5.3.2 requiring exactly the operator listing set. A Qwen3.6 document with an additional Llama row was accepted in direct validation.
   **Scenario:** A deployment accidentally republishes the old catalog and still produces a passing OpenRouter filing artifact.
   **Fix:** In filing/catalog mode, reject IDs outside `OPENROUTER_LISTED_MODEL_IDS` plus explicitly declared free aliases.

5. **MEDIUM — `scripts/openrouter_readiness_probe.py:414-433`**
   Feature-descriptor validation is optional and shape-only. It neither requires all four descriptors for supported families nor enforces the exact enum values. Direct checks accepted both a Qwen3.6 row with all four descriptors removed and one advertising `tool_choice:["required"]` plus `response_format:["xml"]`.
   **Scenario:** The readiness probe approves a document that violates SPEC-006 and overstates or omits SPEC-018/SPEC-019 capabilities.
   **Fix:** Mirror the family predicate, require the exact four descriptors for matching families, require their absence elsewhere, and enforce exact enum sets.

6. **LOW — `specs/CONFORMANCE.json:2189-2216`**
   The new SPEC-018 §3.8 coordinator gate and `TestUnsupportedMultiTurnToolModelGate` are absent from the SPEC-018 conformance mappings.
   **Scenario:** Future conformance audits do not identify the pre-dispatch gate or its regression coverage.
   **Fix:** Add the helper and test to the applicable SPEC-018 request-validation requirement mapping.

Targeted gateway/coordinator tests passed, but the probe-suite regression above was reproduced. Architecture status: **WATCH**. Recommendation: **REQUEST CHANGES**.

VERDICT: C=0 H=1 M=4 L=1.
