# AUDIT — Gateway prompt-token headroom — R3 CODE re-audit

## Scope

Same as R2: 2 files. Read `git diff origin/main..HEAD`.

## R2 finding claimed FIXED

R2 was `0/1H/0/0/0`. Fix applied:

- **R2 HIGH (completionFromHeader unbounded)** — new
  `completionFromHeaderCapped(header, maxTokens)` wrapper clamps
  the X-MacProvider-Completion-Tokens header value to maxTokens.
  Two call sites in chat_proxy.go updated. New
  `TestCompletionFromHeaderCapsAtMaxTokens` regression.

## Your job (R3)

Final convergence. Confirm R2 HIGH is genuinely resolved. Surface
any OTHER call site I missed where untrusted provider/coordinator
data feeds completion tokens into settlement without a maxTokens
cap — specifically:

- `usageFromHeader` (if exists)
- Streaming path: `estimateStreamingCompletionTokens` uses
  byte-counted emitted bytes, which we DO cap at maxTokens via
  the new signature. Confirm.
- `settleAfterCommit` / `settleBeforeResponse` direct call sites
  that pass a completion value — do any of them use a
  provider-derived count without clamping?

Bar: **0 C/H/M** on R3 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
