codex
## Findings

1. **LOW — Accepted carried risk: family predicates remain duplicated**  
   [openrouter_models.go:386](/Users/augstar/macprovider-or-features/phase5-gateway/internal/router/openrouter_models.go:386), [server.go:6844](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6844), [openrouter_readiness_probe.py:138](/Users/augstar/macprovider-or-features/scripts/openrouter_readiness_probe.py:138), [ToolPromptRenderer.swift:41](/Users/augstar/macprovider-or-features/phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift:41)

   Failure scenario: a future family addition updates Swift rendering but misses gateway advertising, coordinator admission, or probe validation, causing false capability advertising or late provider-side failures.

   Fix: accepted for this round. Eventually generate parity fixtures from one spec-owned capability table.

No new CRITICAL, HIGH, or MEDIUM findings.

## Round-1 verification

All R1 findings are fixed:

- Alias bypass: coordinator resolves catalog aliases through `billing.ModelsEquivalent` and gates before dispatch/idempotency reservation. Tests cover free, OpenRouter-slug, bare-key, and case aliases.
- Empty `assistant.tool_calls: []`: rejected as `invalid_tools` before the family gate.
- `response_format`: now a valid schema-2.4 `object` descriptor with nested `type` enum and `json_schema: unknown`.
- SPEC-018/SPEC-019 coupling: tool and structured-output predicates are separate.
- Probe gaps: extra rows are rejected and descriptor presence, absence, and exact shapes are enforced.
- CONFORMANCE: `SPEC-018-R005` maps the coordinator gate and tests; `SPEC-006-R010` maps the Qwen-only listing and descriptor behavior.
- Stale probe expectations: catalog and gateway-listing assertions now reflect the single Qwen3.6 row.

The descriptor shapes conform to OpenRouter’s current [provider schema 2.4](https://openrouter.ai/docs/assets/provider-monitor-schema-v2.openapi.json) and [capability descriptor grammar](https://openrouter.ai/docs/guides/community/for-providers).

Deploy ordering is safe: gateway-first advertises only Qwen3.6, which has the required profiles; coordinator-first merely converts unsupported catalogued multi-turn histories into pre-dispatch HTTP 400 responses.

Validation passed: `git diff --check`, CONFORMANCE JSON parsing, targeted gateway tests, coordinator gate tests, and readiness-probe regressions.

**Architectural status: WATCH**, solely for the accepted LOW duplication risk.

VERDICT: C=0 H=0 M=0 L=1.
