# AUDIT SPEC — Wave 0a/0b CODE lane

You are auditing the current worktree diff for the macprovider repo.

Scope:
- Wave 0a gateway: `phase5-gateway/internal/router/chat_proxy.go` plus tests under `phase5-gateway/internal/router/`.
- Wave 0b coordinator: `phase4-coordinator/internal/billing/formula.go` plus tests under `phase4-coordinator/internal/billing/`.

Required verdict:
- Return findings grouped by severity: CRITICAL, HIGH, MEDIUM, LOW.
- If there are no CRITICAL/HIGH/MEDIUM findings, say exactly that.
- Ground every finding in concrete file/line references.

Audit requirements:
1. Enumerate every place the old streaming completion clamp logic was reachable before this diff, and every place it is reachable after this diff.
2. Verify clean SSE streams with valid provider usage settle `provider_reported` using `usage.prompt_tokens` and `usage.completion_tokens`.
3. Verify no-usage and invalid-usage streaming paths still fall back to `gateway_estimated`.
4. Verify the mid-stream byte guard no longer rejects MoE-like 640-byte/128-token streams before usage arrives, while a hard runaway byte ceiling remains.
5. Verify provider-reported `completion_tokens > max_tokens` on streaming settles `stream_output_exceeded` from provider usage rather than invalid usage.
6. Verify coordinator `RateFor` lookup order is exact string, normalized key, default, zero.
7. Enumerate every billing-arithmetic touch. Expected answer: zero arithmetic changes; this should be selection-only.
8. Check tests pin the Wave 0a/0b regression matrix from `specs/BUILD_SPEC_WAVE_0A_GATEWAY_USAGE_TRUST_IMPL_PROMPT.md`.

Validation evidence available:
- `( cd phase5-gateway && go vet ./... && go test ./... )`
- `( cd phase4-coordinator && go vet ./... && go test ./... )`

Do not suggest out-of-scope work such as provider tokenizer ports, shared packages, schema changes, token_source enum changes, coordinator routing changes, or SPEC-005 class-aware matching.
