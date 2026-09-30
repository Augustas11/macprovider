# code review — CB scheduler context cap + omitted max_tokens default (SPEC-038 v0.3.4)

Repo /Users/augstar/macprovider-cb-context-cap, branch fix/cb-context-cap (commit e78d1ebe1). Review FULL diff `git diff origin/main...HEAD` as code reviewer. Governing: SPEC-038 (continuous batching), SPEC-039 (paged KV, FR-PKV2, #1802), SPEC-001 FR-27 relay end statuses, SPEC-006 error contract, SPEC-005/SPEC-015 settlement for non-settling rejections.

Live defect fixed: production CB scheduler kept maxRequestTokens=131072 (ContinuousBatchScheduler.swift:181) while advertising 200k context; omitted max_tokens defaulted to context-prompt so EVERY no-max_tokens request (even 143 bytes) exceeded the cap -> continuous_batching_invalid_request -> relay error_internal -> coordinator 502 provider_error (retryable, can degrade provider) / stream_malformed.
Fix: maxRequestTokens = served maxContextTokens; omitted max_tokens -> min(ctx-prompt, 32768) (matches gateway limits.max_tokens_per_request / PR #1801); prompt+output > cap -> new contextLengthExceeded -> APIError 413 context_length_exceeded -> relay error_context_exceeded -> coordinator 413; stderr event=batching_rejected line.
Known behavior deltas (evaluate): explicit max_tokens over context now 413 on CB but not serial; implicit 32768 cap reports finish_reason stop not length; single-row reservation now prompt+32768.

Focus: correctness of cap wiring incl. warm-swap/rebuild paths, memory/paged-KV reservation implications of raising cap to 200k with 8 rows (pool exhaustion mid-decode, OOM), the omitted-default helper at both call sites, retained cache release on rejection, test adequacy (a key wiring test is metallib-gated/skipped locally), finish_reason semantics for OpenAI-compat clients.
Output: findings severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file:line, failure scenario, fix. End: VERDICT: C=<n> H=<n> M=<n> L=<n>.
