# AUDIT 278 CODE PROMPT — Gateway upward-correction symmetric clamp

You are auditing the current branch for issue #278. This is a code-implementation audit, not a research task.

Target result: verify the implementation matches `specs/BUILD_GATEWAY_UPWARD_CLAMP_PROMPT.md` and is a direct symmetric twin of the landed #262 downward clamp.

Files in scope:
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/router/server_test.go`
- this audit may read `specs/BUILD_GATEWAY_UPWARD_CLAMP_PROMPT.md` for acceptance criteria

Checks:
- In `settleReported`, the upward branch (`observedCompletion > usage.CompletionTokens`) computes `overshoot := observedCompletion - usage.CompletionTokens`.
- It reuses `clampFloorTokens` and `clampCeilingTokens`; no duplicate or new constants.
- It clamps only when `clampFloorTokens < overshoot && overshoot <= clampCeilingTokens`.
- In-window upward clamp settles to `usage.PromptTokens` and `usage.CompletionTokens` with `token_source = "provider_reported"`.
- Outside-window upward cases preserve the old behavior: gateway prompt estimate, observed completion estimate, `token_source = "gateway_estimated"`.
- The existing downward clamp behavior and other `estimateStreamingCompletionTokens` call sites are untouched.
- The new log line mirrors the downward clamp log shape and includes `request_id`, `account_id`, `reported`, `observed`, `overshoot`, `window_floor`, `window_ceiling`, and `outcome`, with a direction-specific message.
- Tests cover exact match, floor boundary, in-window values, ceiling boundary, above-ceiling, large overshoot, the four v0.4 scenario-07 fixtures, and a symmetry pin for the shared window.
- Regression tests still preserve the #262 downward-clamp behavior.

Output format:
- Start with `AUDIT_278_CODE: PASS` if there are 0 CRITICAL/HIGH/MEDIUM findings, otherwise `AUDIT_278_CODE: FAIL`.
- Then list counts as `CRITICAL: n`, `HIGH: n`, `MEDIUM: n`, `LOW: n`.
- For every finding, include severity, file:line, evidence, impact, and concrete fix.
- Do not propose scope expansion unless the current patch violates the prompt or introduces a correctness risk.
