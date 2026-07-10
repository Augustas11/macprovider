# AUDIT — Gateway prompt-token headroom — R1 CODE lane

## Scope

Branch `fix/gateway-prompt-headroom` (worktree
`/Users/augstar/macprovider-fix-prompt-est`). Read `git diff
origin/main..HEAD`.

Files:
- `phase5-gateway/internal/router/chat_proxy.go` (added
  `promptHeadroomTokens` constant + padded `estimatePromptTokens`)
- `phase5-gateway/internal/router/server_test.go` (new
  `TestEstimatePromptTokensHeadroomCoversAir5`)

## Context

During 2026-06-28 phase-A re-run we observed every chat completion
to `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` failing with
HTTP 502 `invalid_provider_usage` when `max_tokens` was small
(4-16). The same body to `Qwen3-32B` succeeded. Root cause:

- `estimatePromptTokens` returned `ceil(bytes/4)` with no headroom.
- For "hi" requests: body ~115 bytes → estimate 29.
- Qwen2.5-Coder tokenizes the body + chat template → 30 tokens.
- `maxUsageTokens = promptEstimate + maxTokens`. With max_tokens=4:
  cap=33. Provider reports 30+4=34. `usageFromJSON` rejects.
- Qwen3-32B happens to tokenize at ≤29 → passes.

The byte-heuristic cannot see the chat-template overhead that the
provider's tokenizer adds AFTER body parse (`im_start/role/im_end`
pairs, BOS token, etc.). That overhead is fixed-cost per request,
independent of body length.

This was a LIVE money-path bug: a buyer with a valid provider got
back 502 when their other provider would have returned 200.

## Fix

Add `promptHeadroomTokens = 64` fixed padding to
`estimatePromptTokens`. New regression test
`TestEstimatePromptTokensHeadroomCoversAir5` asserts:
- The air5 scenario (115-byte body, max_tokens=4,
  provider-reported prompt=30+completion=4=34) now accepts cleanly.
- A malicious provider reporting prompt=10000 for the same
  100-byte body STILL trips the cap (because 10000 ≫
  25+64+max_tokens).

Live-deployed to Pearl at `v1.6.1-37-gd82163d`; re-tested with
max_tokens=4/8/16/32/64 — all succeed against the previously-
broken provider. Phase-A scenario 01 now shows BOTH providers
serving traffic (pre-fix: 0 of 3 success-traffic went to the
Coder model; post-fix: 2 of 3).

## You are the CODE auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **0 C/H/M**.

Specifically check:

1. **Cap headroom adequacy.** 64 tokens covers the largest chat
   templates seen in the operator fleet with margin. Are there
   known templates that exceed this? Qwen, Llama-3, GPT-4
   wrappers all add ≤20 tokens per message in the formats I've
   surveyed. Could a multi-message conversation push the actual
   tokenization further off the byte-heuristic so that even +64
   is insufficient?
2. **Over-billing defense regression.** The new test asserts
   `prompt=10000` for a 100-byte body still trips the cap. Is
   that test sufficient, or are there other adversarial shapes
   (e.g. provider reporting completion much higher than asked)
   that need explicit assertions?
3. **Streaming path.** `maxUsageTokens` is also passed to
   `forwardStreamingChat` (cancelled-stream estimation,
   pre-commit settlement, etc.). Does adding +64 to
   `promptEstimate` impact streaming token accounting in
   surprising ways? Trace the calls in `forwardStreamingChat`.
4. **Reservation sizing.** `maxUsageTokens` is also used in the
   reservation step (`ReserveQuota`). Adding +64 means each
   request pre-reserves 64 extra tokens against the buyer's
   daily quota. For a small chat (e.g. max_tokens=10) this is a
   ~6x reservation inflation. Could this trip
   `quota_exhausted` early for a buyer near their daily cap?
   How does the existing `settleBeforeResponse` refund logic
   handle the over-reserved excess?
5. **Constant value choice.** Why 64 and not 32 or 128? Is the
   choice defensible / documented? The PR comment cites "chat
   template overhead ≤20 tokens per message"; 64 is 3x that
   for a single-message conversation. Is that headroom
   reasonable across multi-message conversations too?
6. **Test coverage shape.** Only one new test
   (`TestEstimatePromptTokensHeadroomCoversAir5`). Should we
   also add a test that fires through the full
   `forwardNonStreamingChat` path with a 200-response upstream
   to confirm the settlement-side numbers are still correct?

Out of scope: anything outside the two files in the diff.

## Output format

For each finding:

- **SEVERITY** (CRITICAL/HIGH/MEDIUM/LOW/NOTE)
- **Location** (file:line)
- **What** (one sentence)
- **Why it matters** (one sentence)
- **Suggested fix** (one or two lines)

End with `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
