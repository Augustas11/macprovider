# AUDIT SPEC — Wave 0a/0b SECURITY lane

You are auditing the current worktree diff for money-path security risks.

Scope:
- Wave 0a gateway settlement-from-usage changes in `phase5-gateway/internal/router/chat_proxy.go` and tests.
- Wave 0b coordinator rate-card key normalization in `phase4-coordinator/internal/billing/formula.go` and tests.

Required verdict:
- Return findings grouped by severity: CRITICAL, HIGH, MEDIUM, LOW.
- If there are no CRITICAL/HIGH/MEDIUM findings, say exactly that.
- Ground every finding in concrete file/line references.

Security audit requirements:
1. Enumerate every place the old clamp logic was reachable before this diff, and every place it is reachable after this diff.
2. Evaluate whether trusting provider usage on valid streaming usage chunks creates a buyer overbilling, provider underbilling, quota bypass, or settlement spoofing path.
3. Evaluate the remaining validation boundaries for streaming `usage`: non-negative counts, total consistency, max total bound, invalid usage fallback, and provider-reported over-max completion settling as `stream_output_exceeded`.
4. Evaluate the hard byte ceiling as a runaway-stream defense. Confirm the old soft byte estimate no longer creates false `stream_output_exceeded` on MoE streams before usage arrives.
5. Evaluate client disconnect, truncated stream, malformed SSE, no usage, and invalid usage settlement paths.
6. Evaluate coordinator normalization for rate-card mis-selection, default fallback abuse, nil/empty maps, exact-match precedence, and log leakage.
7. Enumerate every log-shape regression risk, especially required `event=rate_card_normalized requested=<verbatim> normalized=<normalized> matched=<which>` fields and existing gateway log shapes.
8. Enumerate every billing-arithmetic touch. Expected answer: zero arithmetic changes; this should be selection-only.

Validation evidence available:
- `( cd phase5-gateway && go vet ./... && go test ./... )`
- `( cd phase4-coordinator && go vet ./... && go test ./... )`

Do not inspect or rely on Layr-Labs/d-inference source. Do not propose schema, enum, shared-package, routing, or tokenizer-port changes for this PR.
