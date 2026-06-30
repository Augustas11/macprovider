# AUDIT SPEC — Wave 0a/0b ARCHITECT lane

You are auditing the current worktree diff for architecture, boundaries, and maintainability.

Scope:
- Wave 0a gateway settlement-from-usage changes in `phase5-gateway/internal/router/chat_proxy.go` and tests.
- Wave 0b coordinator rate-card key normalization in `phase4-coordinator/internal/billing/formula.go` and tests.

Required verdict:
- Return findings grouped by severity: CRITICAL, HIGH, MEDIUM, LOW.
- If there are no CRITICAL/HIGH/MEDIUM findings, say exactly that.
- Ground every finding in concrete file/line references.

Architecture audit requirements:
1. Enumerate every place the old clamp logic was reachable before this diff, and every place it is reachable after this diff.
2. Verify the gateway fix is settlement-selection-only: no schema changes, no token_source enum changes, no per-model tokenizer registry, no shared package, no billing arithmetic changes.
3. Verify the coordinator fix is file-local normalization only: no shared abstraction, no class-aware regex/prefix system beyond the requested defensive minimum, no routing/admission changes.
4. Verify exact-match rate-card keys preserve operator override semantics before normalization.
5. Verify normalization behavior and suffix stripping match the Wave 0b requirements and tests.
6. Enumerate every log-shape regression risk, especially coordinator normalization logs and unchanged gateway chat-completion/stream logs.
7. Enumerate every billing-arithmetic touch. Expected answer: zero arithmetic changes; this should be selection-only.
8. Evaluate whether tests are appropriately scoped and not overfitted to helper internals.

Validation evidence available:
- `( cd phase5-gateway && go vet ./... && go test ./... )`
- `( cd phase4-coordinator && go vet ./... && go test ./... )`

Do not propose out-of-scope Wave 0c, SPEC-005 v0.3 class-aware lookup, tokenizer ports, schema changes, token_source enum changes, or coordinator routing changes.
