I've completed a thorough read-only adversarial pass over the full SPEC-024 money-path surface. Here is the audit report.

---

# SPEC-024 Prefix-Cache Billing — Adversarial Verification Audit

## 1. HEAD audited
`41d800b` — "Reject quarantined and partial SPEC-024 audit surfaces" (branch `spec/024-prefix-cache-billing-impl-prompt`, repo `/Users/augstar/macprovider-poc`). Verified via `git log --oneline -1`. SPEC-024 impl spans commits `57969cc → 41d800b` on top of the handoff `b850b4d`.

## 2. Critical findings
None.

## 3. High findings
None.

## 4. Medium findings
None.

I attempted to construct concrete reachable failure paths for each in-scope hazard class and could refute all of them (see §6). No finding meets the "concrete reachable failure path" bar.

## 5. Low / notes (no gate impact)

- **N1 — Explicit JSON `null` cached is treated as invalid→quarantine, not as absence.** `cachedPromptTokensPointer` (server.go:5566) maps a present-but-`null` `cached_prompt_tokens` to the `-1` invalid sentinel, which drives an `invalid_cached_prompt_tokens` quarantine. SPEC-024 §3 says "field absence… has an effective cache value of 0." An explicit `null` is arguably absence, so this is stricter than the letter of the spec. **Impact is nil/fail-safe:** the effect is zeroed credits (provider-side loss on a malformed self-report, never a buyer overcharge or platform loss), and it is unreachable from the in-house provider, which always emits a valid integer `"cached_prompt_tokens": 0` (HTTPServer.swift:1035; InferenceRelay.swift:854/864/923). Not a defect; noted for spec-text alignment only.

- **N2 — Ledger does not persist `prompt_cache_hit_rate_per_mtok`.** `ledger_request_credits` stores `prompt_rate_per_mtok` / `completion_rate_per_mtok` but not the cache-hit rate actually applied (hotpath.go:296–304; schema store.go:57–90). This is **spec-compliant** — SPEC-024 §4 mandates "exactly one column" (`cached_prompt_tokens`) — and the effective rate remains recoverable by joining `ledger_config_snapshots.rate_card_json` or back-solving from `gross_credits`. Noted only as an auditability observation.

- **N3 — Provider currently always reports `cached_prompt_tokens = 0`.** The cache discount is therefore never actually applied in production yet; all rows are byte-identical to SPEC-005 v0.4. This matches the §10 rollout invariant and §2 (KV-cache reporting is deferred provider IMPL). The billing plumbing is correct forward-looking infrastructure.

## 6. Evidence (file:line) — hazards checked and why they don't fire

**Formula correctness (SPEC-024 §6).** `ComputeCreditsWithCache` splits `uncached*prompt_rate + cached*cache_rate + completion*completion_rate`, all overflow-guarded via `checkedMul`/`checkedAdd`; collapses byte-identically when `cached=COALESCE(NULL,0)=0` (formula.go:206–257, 307–328). Null-error / breaker-qualifying short-circuits preserved (formula.go:178–184).

**Quarantine semantics (§3).** `normalizeCachedPromptTokens` (hotpath.go:206–228) enforces ordered checks: invalid (`<0`, prompt nil, `cached>prompt`) → `invalid_cached_prompt_tokens`; `attempt_n>0` → discard to NULL; non-hit with `cached>0` → `ambiguous_cache`. Quarantine path zeroes credits, writes `cached_prompt_tokens=NULL`, preserves would-be `usage_source`, and skips operator-credit insertion (hotpath.go:179–190). Defense-in-depth re-validation in the formula layer (`cached>prompt`→null_error, formula.go:206–210).

**request_log ↔ ledger consistency.** Buyer-visible sanitizer `effectiveCachedPromptTokensForBuyer` (server.go:5654–5663) and recovery-field writer `requestLogCacheRecoveryFields` (server.go:5665–5684) apply validation identical to the ledger `normalizeCachedPromptTokens`, so the recovery field and the ledger agree on the genuine cache-billing case (`attempt_n==0 && sticky=="hit"`). The recorder passes the **raw** provider value to billing (billing_recorder.go:238) while injecting the **sanitized** value into the buyer body (server.go:2007/2419) — correct separation.

**attempt_n divergence (recorder pre-derivation vs COUNT-derived).** The hot path re-derives `attempt_n` via `COUNT(*)` after INSERT and quarantines on any downward mismatch (`ambiguous_attempt_n`, hotpath.go:88–124); `normalizeCachedPromptTokens` runs on the derived value (hotpath.go:131). Recovery independently guards the residual class `attempt_n==1 && retried==0` (recovery.go:170, 291–297). I could not construct a path where a positive `cached` survives to bill at `attempt_n>0`.

**Recovery / admin reconcile (§4, §7).** `RecoverLedger` replays `rl.cached_prompt_tokens` through `ComputeCreditsWithCache` and re-creates cache quarantines from `rl.cache_quarantine_reason` with correct byte-estimated provenance (recovery.go:98–206, 270); `reconcileExistingCreditTx` includes `!nullInt64MatchesPtr(cached, …)` in its mismatch predicate and quarantines settled-row mismatches rather than silently re-billing (recovery.go:448–467). Admin reconcile skips cache-quarantined rows (endpoints.go:534) and derives identical ordinals across all three sites (endpoints.go:502–507).

**Config default & validation (§5).** `EffectivePromptCacheHitCreditsPerMtok` defaults to the prompt rate when unset (config.go:402–407); explicit `0` is honored via `promptCacheHitRateSet` across YAML/JSON unmarshal (config.go:455–489); validation rejects `cache_rate > prompt_rate` and negatives (config.go:1132–1140). Snapshot round-trip freezes the effective rate via `MarshalJSON`/`UnmarshalJSON` (config.go:414–470).

**Streaming / WS / buffered (§8).** Latch on invalid-after-valid: `mergeStreamUsagePointers` sticks at `-1` once any usage frame is invalid (server.go:5582–5603; gateway chat_proxy.go:640–651), forcing gateway fallback to estimate and coordinator quarantine. Buyer-visible cached re-sanitized per SSE block (server.go:5763–5793) and per gateway line (chat_proxy.go:1546–1559). Buffered/WS terminal-usage merge preserves prior valid pointers (server.go:2651–2656). Quota settlement stays token-count based, ignoring cached (chat_proxy.go:408) per §6.

**Gateway usage validation.** `usageFromJSON` rejects malformed/negative/over-cap usage but sanitizes out-of-bounds `cached` to 0 without rejecting the response (chat_proxy.go:1480–1513) — matching §8 "surface sanitized `cached_prompt_tokens: 0`."

**Ledger schema (§4).** Additive `NULL`-default column with `CHECK(cached IS NULL OR (0 <= cached <= prompt_tokens))`, insert-only, no backfill (store.go:69, 328–354).

**routing_decision observability (§3).** Billing-time row emits `request_id`, `attempt_n`, `sticky_result`, `sticky_miss_reason` (when set), and effective `cached_prompt_tokens`, plus a `cache_validation_reason` on rejection, leaving selection-time rows untouched (hotpath.go:230–248; billing_recorder.go:109–127).

**Regression tests.** Money-path scenarios are covered: sticky-hit discount persistence, ambiguous/invalid quarantine + routing-decision emission, recovery replay and quarantine recreation (incl. byte-estimate provenance), partial-usage pointer merge, invalid-after-valid stream fallback, buyer-visible field presence, and gateway invalid-cached sanitization (store_test.go:121–302; formula_test.go:120–136; cache_recovery_internal_test.go:12–141; gateway server_test.go:2113, 3586, 3626). Build/test execution was blocked by the sandbox approval gate, so this is a static assessment of coverage, not a green test run.

## 7. Gate verdict
**ZERO C/H/M**

No Critical, High, or Medium findings. Only three fail-safe/informational Low notes (§5), none of which represent a reachable money-path defect — the strictest observed behaviors resolve to zeroed credits (provider-side, never buyer overcharge), and the provider currently reports `cached=0` making the discount path byte-identical to SPEC-005 today.

One caveat on completeness: I could not execute `go test`/`go build` (sandbox approval was denied for each attempt), so the verdict rests on static analysis plus test-coverage inspection rather than an observed passing suite. If you want, I can retry the build/test with sandbox disabled to convert that into positive evidence.
