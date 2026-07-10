# AUDIT — Gateway prompt-token headroom — R2 CODE re-audit

## Scope

Branch `fix/gateway-prompt-headroom` (worktree
`/Users/augstar/macprovider-fix-prompt-est`). Read `git diff origin/main..HEAD`.

## R1 CODE findings claimed FIXED

R1 was `0/2H/0/0/1N`. Fixes applied:

1. **R1 HIGH #1 (over-billing via inflated completion)** — added
   explicit `maxCompletion` parameter to `usageFromJSON` and a
   `completion_tokens > maxCompletion` rejection. New regression
   asserts a provider reporting `completion=68` for `max_tokens=4`
   (well under the `maxUsageTokens=97` headroom cap) is rejected.

2. **R1 HIGH #2 (settlement debit on fallback paths)** — split
   `estimatePromptTokens` (bare `bytes/4`, used as the billable
   prompt count) from `promptCapTokens` (`bytes/4 + 64`, used
   only in `maxUsageTokens` for validation). Streaming helpers
   (`estimateStreamingCompletionTokens`, `maxStreamingCompletionTokens`,
   `settleCancelledStream`) now take `maxTokens` directly so the
   completion-side cap doesn't silently inflate with the prompt-cap
   headroom.

3. **R1 NOTE (misleading comment)** — updated.

Full gateway test suite passes (`go test ./... -count=1`). Live
deploy is at `v1.6.1-38-g363e0e5-dirty-forced` on Pearl;
verified air5 returns HTTP 200 for `max_tokens=4`.

## Your job (R2)

Confirm R1 findings are genuinely resolved. Surface any NEW defect
introduced by the split:

- `forwardStreamingChat` now threads `maxTokens` through every
  settlement variant. Is the value the same `maxTokens` the buyer
  set (the buyer-controllable cap), or could a code path
  accidentally pass `maxAllowed` or `maxUsageTokens`?
- The streaming SSE-parser path at the inline `usageFromJSON(...,
  maxTokens)` (around line 474): when usage arrives inline in a
  streaming chunk, the cap is `maxUsageTokens` and the
  completion-side cap is `maxTokens`. Is that correct for the
  case where the buyer's max_tokens was hit exactly?
- `settleCancelledStream` got a new `maxTokens` param. All four
  call sites in `chat_proxy.go` pass it. Confirm no other call
  site (test file, etc.) lost a param.

Bar: **0 C/H/M** on R2 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
