I have completed a thorough independent trace. I was unable to run ad-hoc SQLite/Go probes (sandbox denied writes and the heredoc/`-c` commands), but I verified the migration ALTER against SQLite documentation and confirmed both module test suites pass uncached. Here is the audit.

---

# SPEC-024 Prefix-Cache Billing — Adversarial Verification Audit

**Target:** local HEAD `71e3fc6` on `spec/024-prefix-cache-billing-impl-prompt`
**Scope:** money-path correctness across coordinator billing/ledger/recovery, gateway usage shaping, provider reporting.
**Baseline:** `go test ./internal/config ./internal/billing ./internal/buyer ./internal/routing` and gateway `./internal/router ./internal/storage/...` all **PASS** (re-run uncached). Provider (`InferenceRelay.swift`, `HTTPServer.swift`) hardcodes `cached_prompt_tokens: 0` on every usage object — SPEC-024 §2/Slice-D compliant (no unproven positive reports), so the discount path is dormant-but-correct in production today.

## Traced conformance (independently confirmed)

- **Formula split & overflow** (`formula.go`): `ComputeCreditsWithCache` computes `uncached = prompt − cached`, prices `uncached·prompt_rate + cached·cache_hit_rate + completion` with `checkedMul`/`checkedAdd` guards. Byte-identical to SPEC-005 v0.4 when `cached∈{NULL,0}`. `null_error` guard preserved; `zeroCredits` now also nils `CachedPromptTokens`.
- **Wire validation & quarantine** (`hotpath.go normalizeCachedPromptTokens`): ordering is invalid→retry→ambiguous. `cached<0 | prompt==nil | cached>prompt` → `invalid_cached_prompt_tokens`; non-hit + positive → `ambiguous_cache`; both null the value, zero payable credits, preserve `usage_source`. Matches §3 exactly.
- **Typed sticky provenance** (`server.go selectProviderExcluding`): random tiebreak is **skipped** on sticky hit; after preflight, if the finally-selected provider ≠ `candidates[0]` the result is downgraded to `miss/provider_not_candidate`. Satisfies §6 final-provider rule (no relabeling via tiebreak/failover). `sticky_result` is carried in typed `forwardState`, not inferred from logs/order.
- **Ledger/request_log consistency**: `requestLogCacheRecoveryFields` (request_log) and `normalizeCachedPromptTokens` (ledger) apply identical validation from identical inputs, so provenance stored in both agrees. `request_log` gains `cached_prompt_tokens` + `cache_quarantine_reason`; both have additive `ensureColumns` ALTERs.
- **Recovery/reconcile** (`recovery.go`): reads `rl.cached_prompt_tokens` + `rl.cache_quarantine_reason`; cache-quarantine rows short-circuit before reconcile; `reconcileExistingCreditTx` mismatch predicate now includes `!nullInt64MatchesPtr(cached, input.CachedPromptTokens)`; recompute threads cached. `insertQuarantineTx` now also persists `estimated_completion_tokens` (prior gap fixed).
- **Config/rate-card** (`config.go`): `EffectivePromptCacheHitCreditsPerMtok` defaults omitted config to `prompt_credits_per_mtok` (SPEC §5) while honoring explicit `0` via `promptCacheHitRateSet`; `Validate` rejects negative and `> prompt_rate`; YAML/JSON both handled. `billing.RateCardEntry = config.RateCardEntry` (type alias) — no lossy conversion. Snapshot JSON round-trips the effective rate and it participates in `/v1/rate-card` version bytes.
- **Gateway** (`chat_proxy.go`): flat `cached_prompt_tokens` added; `sanitizedCachedPromptTokens` clamps null/non-int/negative/`>prompt`→0 (defense-in-depth); invalid stream usage frames dropped (`line=nil; return true`) with fallback to gateway estimate; quota settlement remains `prompt+completion` (no cache discount); no rate-card pricing authority added.
- **Invalid-then-valid streaming**: `mergeStreamUsagePointers` latches an out-of-range cached to sentinel `-1` across the stream (commit "Latch SPEC-024 streaming cache violations"), so a later valid frame cannot rescue a violated request → ledger quarantines. Correct.
- **Buyer-visible sanitation**: `effectiveCachedPromptTokensForBuyer` gates on hit + attempt 0 + range; non-hit/absent/invalid/retry all surface `0`.

## Findings

### Critical — none
### High — none
### Medium — none

### Low
1. **Incomplete-usage rewrite zeroes real prompt tokens (buyer-visible only).** `server.go:2008-2016` / `forwardWSNonStreaming:2411`: when a provider returns a usage object present-but-missing any of `prompt/completion/total`, `chatResponseWithCompleteUsage(body, 0, effectiveCached, estimate)` rewrites buyer-visible usage to `prompt_tokens=0`, `completion=byte-estimate`, and can emit `cached_prompt_tokens>0` with `prompt_tokens=0` (violating `cached≤prompt`). **Ledger is unaffected** (it uses the original `promptTok/completionTok` pointers), and the SPEC-006 gateway re-clamps `cached>prompt→0`. Not reachable via the trusted provider (always emits complete usage). Unpinned by tests. *Prior-round audits flagged the same and rated it below C/H/M; concur.*
2. **Migration ALTER path untested.** `ensureCachedPromptTokensColumn` (the production rollout path: `ALTER TABLE … ADD COLUMN … CHECK(… ≤ prompt_tokens)` on an existing ledger) is not exercised by `TestBillingMigration`, which only validates the fresh `CREATE TABLE` (inline column). The cross-column CHECK in ADD COLUMN is valid SQLite and existing rows default to NULL (satisfying the `IS NULL` disjunct), so I assess this as a coverage gap, not a defect — but it is the one load-bearing rollout path with no direct test.
3. **Explicit JSON `null` diverges coordinator vs gateway.** Coordinator maps `"cached_prompt_tokens": null` → sentinel `-1` → `invalid_cached_prompt_tokens` quarantine (intentional per IMPL Slice-B test list); gateway maps null→0. A hypothetical provider that emits explicit `null` every response would quarantine all its sticky-hit billing. Current provider omits/zeroes the field, so not triggered.

### Info
- `RateCardEntry` built as a struct literal with explicit `PromptCacheHitCreditsPerMtok: 0` (bypassing YAML/JSON unmarshal or `SetPromptCacheHitCreditsPerMtok`) is treated as "unset" and defaults to prompt rate. Config-load paths set `promptCacheHitRateSet` correctly; only affects programmatic construction.
- Retry (`attempt_n>0`) + non-hit + positive cached is **dropped and billed at full rate**, not quarantined as `ambiguous_cache` (retry check precedes sticky check). Matches IMPL Slice-B item 7; economically safe (provider-adverse, no buyer harm).
- `endpoints.go byteEstimatedLedgerGross` refactor now reads stored `gross_credits` rather than recomputing — consistent with the ledger and correctly avoids a recompute that would have ignored the cached split.

## Gate verdict

**PASS — ZERO Critical / High / Medium findings.**

The SPEC-024 money path is conformant: correct cached/uncached formula split with byte-identical legacy/non-hit/absent arithmetic, sound wire-contract validation and quarantine (invalid, ambiguous-cache, retry, negative/over-prompt/non-integer/null), typed per-attempt sticky provenance with final-provider re-checking, consistent request_log↔ledger provenance, recovery/reconcile drift detection on the cached column, gateway-side sanitation with token-count quota preserved, and privacy-safe billing-time routing logs. The 3 Low items (buyer-visible incomplete-usage rewrite, untested migration-ALTER path, coordinator/gateway null divergence) are documentable and do not alter the locked contract; none is reachable via the current trusted provider, which reports `cached_prompt_tokens: 0`.
