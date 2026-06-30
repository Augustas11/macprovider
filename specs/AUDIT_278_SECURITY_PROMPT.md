# AUDIT 278 SECURITY PROMPT — Gateway upward-correction symmetric clamp

You are auditing the current branch for issue #278. This is a security and abuse-resistance audit.

Target result: determine whether the symmetric upward clamp creates an exploitable under-billing path while preserving the #262 risk model.

Files in scope:
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/router/server_test.go`
- `specs/BUILD_GATEWAY_UPWARD_CLAMP_PROMPT.md`
- existing spec text may be read only if needed to validate the billing contract

Threat model:
- A hostile provider may deliberately report `usage.completion_tokens = ceil(bytes/4) - k` on every streaming request.
- The most important case is `k` inside `(2, 20]`, where the new upward clamp would settle at the lower provider-reported value.
- The audit should compare this risk against the symmetric #262 downward-clamp attack surface, where a provider could over-report by a small bounded amount but the gateway clamps inside the same absolute window.

Checks:
- Is the `(2, 20]` upward clamp small and bounded enough to ship as a symmetric correction?
- Does the above-ceiling behavior still protect against zero-report fraud and stream-truncation underreports?
- Does the floor behavior avoid churn from benign 1-2 token noise without opening material abuse?
- Does the patch preserve settlement bounds enforced by parsed usage and reservation limits?
- Does `token_source = "provider_reported"` remain truthful for in-window upward clamps?
- Are there missing tests for hostile-provider cases just above the ceiling or large underreports?
- Are there logs sufficient to audit clamp fires post-deploy?

Output format:
- Start with `AUDIT_278_SECURITY: PASS` if there are 0 CRITICAL/HIGH/MEDIUM findings, otherwise `AUDIT_278_SECURITY: FAIL`.
- Then list counts as `CRITICAL: n`, `HIGH: n`, `MEDIUM: n`, `LOW: n`.
- For every finding, include severity, file:line, evidence, exploit or impact, and concrete fix.
- LOW findings may be documentation-only; CRITICAL/HIGH/MEDIUM must be actionable before merge.
