# BUILD SPEC — Wave 0a/0b implementation: gateway settlement-from-usage + coordinator rate-card key normalization

Run as: `omc ask codex "$(cat specs/BUILD_SPEC_WAVE_0A_GATEWAY_USAGE_TRUST_IMPL_PROMPT.md)"` in a fresh worktree off `origin/main`.

This is an **implementation prompt**. You will write Go code, add Go tests, build, run tests, and produce a single PR-ready diff bundling Wave 0a (gateway) + Wave 0b (coordinator) per `beta/DECISION_CRITERIA.md` Entry 94.

**Money-path code. Do not propose patches that fail any of the regression fixtures below. Do not ship without all new tests green.**

---

## Background (read carefully — both entries are load-bearing)

- `beta/DECISION_CRITERIA.md` Entry 93 + Entry 94 establish what's being fixed and why.
- `.omc/artifacts/ask/codex-research-prompt-gateway-sse-tokenizer-completion-accounting--2026-06-30T16-11-02-978Z.md` is the read-only RESEARCH_228 diagnosis memo. Treat its Part 1 (file/line map), Part 2 (per-failure-mode analysis), and Part 3 (fix-shape verdict) as the design baseline.
- Three failure modes are empirically confirmed in production `pearl:/var/lib/macprovider/gateway.db::usage_events` (all settled with `token_source='gateway_estimated'`):
  - **(A)** MoE rows (gpt-oss-20b, Qwen3-Coder-30B-A3B) trip `stream_output_exceeded` mid-stream from `gateway-internal/router/chat_proxy.go:638-650` before provider `usage` chunk arrives.
  - **(B)** Qwen2.5-Coder-32B settles 12 tokens LOW (116 vs 128) via the issue #255 downclamp at `chat_proxy.go:565-580`.
  - **(C)** Llama-3.1-8B settles 24 tokens HIGH (93 vs 69) via the issue #278 trust-byte-estimate-when-overshoot-exceeds-ceiling path at `chat_proxy.go:522-550`.
- Active production impact: 15 fresh `stream_output_exceeded` rows for gpt-oss-20b at 14:54-15:00Z 2026-06-30 indicate live buyer traffic is being rejected on every gpt-oss-20b request.

## Scope

Wave 0a + Wave 0b are bundled in ONE PR per `[[feedback-bundle-spec-impl-one-pr]]`. They are independent fixes in different services that ship together because both are money-path 3-lane-audited changes. **Do NOT introduce a shared package or abstraction** — codex Part 3 verdict.

### Wave 0a — gateway: trust provider `usage.completion_tokens` on clean SSE streams

Edit `phase5-gateway/internal/router/chat_proxy.go` (and add tests under `phase5-gateway/internal/router/`).

**Design baseline:**

1. When the SSE stream completes cleanly (no malformed chunks, no client disconnect, no upstream error) AND the provider supplied a well-formed `usage` chunk, **settle from `usage.CompletionTokens` and `usage.PromptTokens` with `token_source="provider_reported"`**. Do not run the issue #255 downclamp or issue #278 trust-byte-estimate paths in this case.
2. Keep the byte-estimator path as fallback ONLY when:
   - No `usage` chunk arrived (`reported == nil`), OR
   - The `usage` chunk was invalid per `usageFromJSON` (`invalidReportedUsage == true`), OR
   - The stream was truncated (`settleTruncated` path), OR
   - The client disconnected mid-stream.
3. **Defer the mid-stream `stream_output_exceeded` guard to post-stream when possible.** The current `chat_proxy.go:638-650` byte-projection cap fires before the `usage` chunk arrives, mis-billing MoE outputs whose byte/token ratio exceeds 4. New behaviour: continue forwarding chunks even when `projectedCompletion > maxCompletion` by byte estimate, BUT enforce a hard byte ceiling at `maxCompletion * 8` (defense against runaway byte streams). If `usage` arrives showing real `completion_tokens > max_tokens`, settle `stream_output_exceeded` from `usage.CompletionTokens` (still cap-respecting outcome). If `usage` never arrives AND byte estimate exceeded the soft cap, settle `stream_output_exceeded` from byte estimate as the existing fallback.
4. Issue #255 (Qwen2.5-Coder-7B EOS/template over-report) and Issue #278 (gateway byte-estimator inflation) defences were correct responses to real signals but over-fitted. Remove the clamp branches in `settleReported` for the clean-stream path. Preserve their behaviour only when the stream is NOT clean (truncated / disconnect / malformed) AND a partial `usage` was still seen — in that case the byte estimate is the more reliable signal.

**Backwards-compatibility / regression guarantees:**

- Qwen3-32B legacy rows (the ~6,000 prior `usage_events` with `token_source='provider_reported'`/`outcome='ok'`) MUST still settle identically: `provider_reported`/`ok`/`usage.CompletionTokens`. Add a pinned regression test.
- All existing `clampFloorTokens` / `clampCeilingTokens` constants at `chat_proxy.go:1121` may be deleted ONLY if every prior test still passes; alternately keep them but unused. Codex audit lane will catch dead code.
- `outcome` values and `token_source` enum (`provider_reported | gateway_estimated | manual_fixture`) — do NOT add a new enum value. The fix changes *which path settles*, not *what gets recorded*.

### Wave 0b — coordinator: normalize rate-card model keys

Edit `phase4-coordinator/internal/billing/formula.go` (and add tests under `phase4-coordinator/internal/billing/`).

**Current bug:** `RateFor(rateCard, model)` at `formula.go:34` does exact-string lookup. Production buyer model strings like `mlx-community/Qwen3-32B-4bit` do not match Entry 92 rate-card keys like `qwen3-32b`, so every new rate-card row falls to `default` ($1.00/M silent overcharge) OR — if `default` row absent — to zero-rate `RateCardEntry{}` (silent under-bill).

**Design baseline:**

1. Add a `normalizeModelKey(model string) string` function (file-local — no exported package, no shared abstraction per codex Part 3).
2. Normalization rules (defensive minimum):
   - Lowercase
   - Strip leading namespace before `/` (e.g. `mlx-community/`, `openai/`, `google/`, `meta-llama/`, `nvidia/`, `qwen/`)
   - Strip trailing quantization variants: `-4bit`, `-8bit`, `-mxfp4-q8`, `-instruct-4bit`, `-instruct-8bit`
3. `RateFor` lookup order:
   - First try the model string verbatim (preserves any operator-set exact-key rows)
   - Then try `normalizeModelKey(model)`
   - Then try `default`
   - Then return `RateCardEntry{}` (existing zero-rate behaviour)
4. **Log** the chosen key path at INFO when normalization is applied (`event=rate_card_normalized requested=<verbatim> normalized=<normalized> matched=<which>`) so operator can audit drift between buyer strings and rate-card keys.

**Backwards-compatibility:**

- Operator-set exact-string rate-card rows must still match — verbatim lookup wins.
- Empty/nil `rateCard` returns `RateCardEntry{}` (unchanged).
- `default` row continues to act as catch-all.

## Tests (mandatory — at minimum)

### Gateway tests in `phase5-gateway/internal/router/chat_proxy_test.go` (or a new `chat_proxy_usage_trust_test.go`)

Each test simulates an SSE chunk stream + provider-reported usage and asserts `(outcome, token_source, completion_tokens, prompt_tokens)` written to `usage_events`:

| Test name | model | SSE deltas | usage chunk | max_tokens | Expected outcome | Expected token_source | Expected completion_tokens |
|---|---|---|---|---|---|---|---|
| `TestSettleFromUsage_Qwen3_32B_Legacy_Baseline` | `mlx-community/Qwen3-32B-4bit` | ~128 bytes content | `{prompt:12,completion:32}` | 128 | `ok` | `provider_reported` | 32 |
| `TestSettleFromUsage_Llama_31_8B_NoOverbill` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | ~372 bytes content (byte-estimate 93) | `{prompt:46,completion:69}` | 128 | `ok` | `provider_reported` | **69** (NOT 93) |
| `TestSettleFromUsage_Qwen25_Coder_32B_NoDownclamp` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | ~464 bytes content (byte-estimate 116) | `{prompt:42,completion:128}` | 128 | `ok` | `provider_reported` | **128** (NOT 116) |
| `TestSettleFromUsage_GptOss_20B_NoMidStreamByteCap` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | ~640 bytes content split across 5 chunks, usage arrives last | `{prompt:42,completion:128}` | 128 | `ok` | `provider_reported` | **128** (NOT 64 with `stream_output_exceeded`) |
| `TestSettleFromUsage_Qwen3Coder_30B_A3B_NoMidStreamByteCap` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | ~640 bytes content split across chunks, usage arrives last | `{prompt:52,completion:128}` | 128 | `ok` | `provider_reported` | **128** (NOT mid-stream-cap) |
| `TestSettleFromUsage_NoUsageChunk_FallsBackToByteEstimate` | any | ~120 bytes content | (no usage chunk) | 128 | `ok` | `gateway_estimated` | 30 (byte estimate) |
| `TestSettleFromUsage_InvalidUsageChunk_FallsBackToByteEstimate` | any | ~120 bytes content | `{prompt:0,completion:-5}` (or other malformed) | 128 | `ok` | `gateway_estimated` | 30 |
| `TestSettleFromUsage_TruncatedStream_WithPartialUsage` | any | ~120 bytes content then connection drop, usage arrived first | `{prompt:12,completion:42}` | 128 | `stream_truncated` | `provider_reported` | 42 |
| `TestSettleFromUsage_RealStreamOutputExceeded_ProviderReports` | any | byte stream genuinely runs over | `{prompt:12,completion:200}` | 128 | `stream_output_exceeded` | `provider_reported` | 200 |
| `TestSettleFromUsage_RunawayByteStream_HardCap` | any | byte stream exceeds `max_tokens * 8 * 4` bytes with no `usage` chunk | (no usage chunk) | 128 | `stream_output_exceeded` | `gateway_estimated` | `maxCompletion` |
| `TestSettleFromUsage_ClientDisconnect_WithUsage` | any | partial content then context cancel, usage arrived first | `{prompt:12,completion:42}` | 128 | `client_disconnect` | `provider_reported` | 42 |
| `TestSettleFromUsage_MalformedSSEChunk` | any | content then a malformed `data:` line | (n/a) | 128 | `stream_malformed` | `gateway_estimated` | byte estimate |

### Coordinator tests in `phase4-coordinator/internal/billing/formula_test.go`

| Test name | rateCard keys | input model | Expected match |
|---|---|---|---|
| `TestRateFor_ExactMatch_Wins` | `{"qwen3-32b": rateA, "default": rateD}` | `qwen3-32b` | `rateA` |
| `TestRateFor_VerbatimWinsOverNormalized` | `{"mlx-community/Qwen3-32B-4bit": rateExact, "qwen3-32b": rateNorm}` | `mlx-community/Qwen3-32B-4bit` | `rateExact` (NOT rateNorm) |
| `TestRateFor_NormalizesMLXCommunityNamespace` | `{"qwen3-32b": rateA}` | `mlx-community/Qwen3-32B-4bit` | `rateA` |
| `TestRateFor_NormalizesQuantizationSuffix` | `{"meta-llama/llama-3.1-8b-instruct": rateL}` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `rateL` |
| `TestRateFor_NormalizesMXFP4Suffix` | `{"openai/gpt-oss-20b": rateOss}` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | `rateOss` |
| `TestRateFor_FallsBackToDefault` | `{"default": rateD}` | `something-not-in-card` | `rateD` |
| `TestRateFor_NoDefault_ReturnsZero` | `{"qwen3-32b": rateA}` | `something-else` | `RateCardEntry{}` |
| `TestRateFor_EmptyCard_ReturnsZero` | `{}` | anything | `RateCardEntry{}` |
| `TestRateFor_NilCard_ReturnsZero` | `nil` | anything | `RateCardEntry{}` |

## Build + verify before push

Run (in the worktree root):

```bash
( cd phase5-gateway && go vet ./... && go test ./... )
( cd phase4-coordinator && go vet ./... && go test ./... )
```

Both must be green.

## Three-lane codex audit (mandatory before push)

Per `[[feedback-three-lane-codex-audits]]` + `[[feedback-audit-prompts-file-not-chat]]`, after IMPL converges:

1. Write three audit prompts to `specs/`:
   - `specs/AUDIT_SPEC_WAVE_0A_0B_CODE_PROMPT.md`
   - `specs/AUDIT_SPEC_WAVE_0A_0B_SECURITY_PROMPT.md`
   - `specs/AUDIT_SPEC_WAVE_0A_0B_ARCHITECT_PROMPT.md`
2. Fire each via `omc ask codex "$(cat specs/AUDIT_SPEC_WAVE_0A_0B_<LANE>_PROMPT.md)"`.
3. Audits must enumerate (a) every place the clamp logic was reachable before vs after, (b) every log-shape regression risk per `[[feedback-audit-prompts-log-shape-backcompat]]`, (c) every billing-arithmetic touch (should be zero — this is selection-only).
4. Converge to **0 CRITICAL / 0 HIGH / 0 MEDIUM** on all three lanes before push per `[[feedback-stop-iterating-on-low-audits]]`. LOWs may ship documented in PR body. Skip re-firing accepted lanes per `[[feedback-skip-accepted-audit-lanes]]`.
5. Record per-round findings in `specs/SPEC-WAVE-0A-0B-rN-audit.md` per `[[feedback-spec-audit-file-convention]]`.

## PR

Submit as Augustas11, approve as antfleet-ops, squash-merge as Augustas11 per `[[macprovider-no-required-reviewers-merge-pattern]]` + `[[gh-pr-merge-augustas11-token-prefix]]`. Use the per-repo helper for `git push`; use `GH_TOKEN=$(gh auth token -u Augustas11)` for `gh pr` commands.

PR body must include:
- Summary of the three failure modes fixed + the production-bug confirmation
- Table mapping each path A/B/C failure mode → which test pins it
- Reference to Entry 94 PR (this Entry 94 PR's URL or the squash-merge SHA on origin/main)
- LOWs surfaced by codex audits (documented, not iterated on)

After squash-merge, re-grep `origin/main` for a load-bearing fixture name (e.g. `TestSettleFromUsage_Llama_31_8B_NoOverbill`) per `[[feedback-verify-commit-content-not-just-message]]`.

## Out of scope

- Wave 0c (provider-side install/autotune defaults) — separate workstream.
- Per-model tokenizer porting / per-model byte-to-token ratio tables — codex explicitly rejected this as Wave 0a shape.
- SPEC-005 v0.3 class-aware lookup (regex/prefix) — Entry 92 mentions this as a future option; do NOT implement it here. Simple `normalizeModelKey` is enough for Wave 0b.
- Any changes to `usage_events` schema or `token_source` enum.
- Any changes to coordinator routing (`buyer/server.go::selectProviderExcluding` etc.) — admission gates are Wave 2 per Entry 92.
- Any inspection of `Layr-Labs/d-inference` source per CLAUDE.md clean-room rule.

## Estimated size

~80-160 LOC across `phase5-gateway/internal/router/chat_proxy.go` + ~30-60 LOC at `phase4-coordinator/internal/billing/formula.go` + ~300-500 LOC of new tests. Total diff ~500-700 LOC including tests.

## Success criteria

1. All 12 gateway tests + 9 coordinator tests green.
2. Full `go test ./...` green in both modules.
3. Three codex audit lanes converged to 0 C/H/M.
4. After deploy (out of scope for this PR — operator triggers separately), next live-traffic gpt-oss-20b request settles with `token_source='provider_reported'` and `outcome='ok'`, not `stream_output_exceeded`.
