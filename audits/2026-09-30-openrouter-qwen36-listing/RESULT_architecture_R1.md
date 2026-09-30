## Findings

1. **HIGH — Catalog aliases bypass the coordinator’s pre-dispatch gate**
   [server.go:6822](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6822), [catalog.go:368](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/tier2/catalog.go:368)

   `tier2.Catalogued` performs only lowercase exact matching, while routing accepts aliases through `billing.NormalizeModelKey`. A multi-turn request using the normative `mlx-community/Llama-3.2-3B-Instruct-4bit-free` alias therefore bypasses this gate but still routes to the Llama 3.2 provider.

   Failure scenario: the provider rejects the unsupported history; its 400 is collapsed into a 502 and can degrade the provider—the failure this change intends to prevent.

   Fix: resolve catalog membership using the same alias-equivalence rules as routing, or gate on the resolved provider/catalog identity. Add real-catalog tests for `-free` and canonical catalog-key aliases; the current fake predicate at [multi_turn_test.go:239](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/multi_turn_test.go:239) masks this mismatch.

2. **MEDIUM — `response_format` is advertised as a scalar enum although the request value is an object**
   [openrouter_models.go:368](/Users/augstar/macprovider-or-features/phase5-gateway/internal/router/openrouter_models.go:368), [SPEC-006:1591](/Users/augstar/macprovider-or-features/specs/SPEC-006-buyer-api.md:1591)

   OpenRouter defines an enum descriptor as the accepted values themselves, while an object descriptor represents a nested request object. SPEC-019 requires values such as `{"type":"json_schema","json_schema":{...}}`, not the strings `"json_schema"` or `"json_object"`. See [OpenRouter capability descriptors](https://openrouter.ai/docs/guides/community/for-providers) and [structured-output request shape](https://openrouter.ai/docs/guides/features/structured-outputs).

   Failure scenario: OpenRouter can classify a valid structured-output request as outside the endpoint’s declared value domain and route it elsewhere or reject filing validation.

   Fix: advertise `response_format` as an `object` descriptor with nested `type` information, or as `unknown` if the conditional union cannot be described accurately. Update SPEC-006, the runbook, gateway tests, and probe assertions together.

3. **MEDIUM — SPEC-006 incorrectly couples structured outputs to SPEC-018 multi-turn families**
   [SPEC-006:1620](/Users/augstar/macprovider-or-features/specs/SPEC-006-buyer-api.md:1620), [openrouter_models.go:363](/Users/augstar/macprovider-or-features/phase5-gateway/internal/router/openrouter_models.go:363)

   `tools` and `tool_choice` appropriately depend on a SPEC-018 §3.8 prompt profile. `response_format` and `structured_outputs` are governed independently by locked SPEC-019. The provider already renders a generic structured-output instruction for non-Qwen/Llama models at [StructuredOutputRenderer.swift:65](/Users/augstar/macprovider-or-features/phase3-binary/Sources/macprovider-cli/StructuredOutputRenderer.swift:65).

   Failure scenario: a future listed non-tool-family model supports SPEC-019 structured output but omits the capability because it lacks a SPEC-018 multi-turn profile.

   Fix: split the predicates: gate tool descriptors on SPEC-018 §3.8 and structured-output descriptors on SPEC-019 support.

4. **MEDIUM — CONFORMANCE does not map the new SPEC-018 gate**
   [CONFORMANCE.json:2207](/Users/augstar/macprovider-or-features/specs/CONFORMANCE.json:2207), [CONFORMANCE.json:5796](/Users/augstar/macprovider-or-features/specs/CONFORMANCE.json:5796)

   Neither the SPEC-018 mappings nor SPEC-006-R010 list `unsupportedMultiTurnToolModel` or `TestUnsupportedMultiTurnToolModelGate`, although R010’s rationale claims new coordinator coverage.

   Failure scenario: conformance tooling can continue reporting the requirement as mapped after the pre-dispatch protection or its regression test disappears.

   Fix: add a dedicated SPEC-018 §3.8 requirement mapping—or extend the correct existing requirement—with the helper and test. Keep SPEC-006-R010 limited to the OpenRouter ingest contract.

5. **LOW — The family predicate has several manually synchronized sources of truth**
   [openrouter_models.go:378](/Users/augstar/macprovider-or-features/phase5-gateway/internal/router/openrouter_models.go:378), [server.go:6830](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6830), [ToolPromptRenderer.swift:41](/Users/augstar/macprovider-or-features/phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift:41)

   The copies currently agree, but a future SPEC-018 family addition can update provider rendering without updating gateway advertising or coordinator admission.

   Fix: introduce a checked-in, spec-owned family fixture consumed by Go and Swift parity tests, or generate the predicates from one capability table.

**INFO — Deploy ordering:** no gateway/coordinator ordering blocker was found. Gateway-first exposes only Qwen3.6, which already matches the provider family predicate; coordinator-first only moves unsupported catalogued histories to an earlier 400.

Validation: `git diff --check`, focused gateway tests, focused coordinator tests, and the three new Qwen3.6 probe tests passed. The full probe suite has one pre-existing catalog-version pin failure at `test_openrouter_readiness_probe.py:224`; that assertion is unchanged from `origin/main`.

VERDICT: C=0 H=1 M=3 L=1
