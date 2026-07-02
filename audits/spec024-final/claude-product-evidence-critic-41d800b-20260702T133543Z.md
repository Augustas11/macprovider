# SPEC-024 Prefix-Cache Billing — Second Claude Design-Critic Audit

## 1. HEAD audited
`41d800b Reject quarantined and partial SPEC-024 audit surfaces`

Scope reviewed from the evidence pack: admin ledger reconcile quarantine exclusion (`endpoints.go` 488–538 + regression test), streaming buyer-visible cache-token sanitizer (`server.go` pre-commit loop 2984–3092), SSE strip/rewrite helpers (`server.go` 5740–5848), and the streaming/recovery internal tests (`cache_recovery_internal_test.go`).

## 2. Critical findings
None.

## 3. High findings
None.

## 4. Medium findings
None.

I looked specifically for reachable product/accounting-contract breaks and could not substantiate one from this pack:

- **Reconcile drift symmetry (checked, clean).** Quarantined and 503 rows are excluded from *both* `buyer_equivalent_credits` and `provider_gross_credits` (endpoints.go 531–536), so the reconciliation *delta* stays 0 for those rows rather than manufacturing a phantom one-sided drift. `TestReconcileEndpoint_CacheQuarantineDoesNotCreateBuyerEquivalentDelta` locks buyer=0, provider=0, delta=0, rows_quarantined=1. No asymmetry that would misfire the drift alarm.
- **Billing-vs-display divergence (checked, by-design, not reachable as harm today).** The pre-commit and post-commit loops retain the raw merged `cachedPromptTok` for billing while the buyer-visible line is rewritten to `effectiveCachedPromptTokensForBuyer(...)` (server.go 2992–2993, 3086–3088). During rollout the provider reports cached=0, so there is no live raw value being hidden from the buyer, and any future divergence is buyer-favorable-or-neutral in the discount direction. This is the documented rollout design, not a contract break.
- **Partial-usage handling (checked, fail-safe).** `streamingJSONWithCachedPromptTokens` strips an incomplete/ambiguous `usage` object entirely rather than forwarding an unsanitized or half-rewritten one, and `streamingUsageObjectComplete` additionally rejects any usage where `total ≠ prompt + completion` — pushing malformed totals down the strip path. Tests `TestSSELineWithCachedPromptTokensStripsIncompleteUsage` / `...RewritesCompleteUsage` confirm choices content is preserved while usage is neutralized. Failure direction is "hide, don't leak," which is the safe direction for a billing surface.
- **Attempt_n derivation under quarantine reconcile (checked, consistent).** The `COALESCE(rl.attempt_n, …id-ASC count…, 0)` fallback uses the same `(account_id, request_id)` IS-clustering as hotpath/recovery, so the three sites cannot diverge on ordinal, and legacy NULL-account rows cluster among themselves preserving pre-v1.5.0 behavior.

## 5. Low / notes
- **L1 (agrees with prior lane):** Explicit-null `cached_prompt_tokens` is mapped to the `-1` invalid sentinel and quarantined (`TestCachedPromptTokensPointerTreatsExplicitNullAsInvalid`), a fail-safe reject rather than silently billing 0. Correct, but worth a one-line SPEC note that "provider omission" and "provider explicit null" take different paths (drop vs quarantine).
- **L2:** `effectiveCachedPromptTokensForBuyer`, `chatJSONWithCachedPromptTokens`, and the downstream billing computation are not present in this pack; my verdict is bounded to the sanitizer/reconcile surfaces shown. The dual computation of `effectiveCachedPromptTokensForBuyer` at three call sites (2993, 3088, 5773) is a duplication worth a shared-helper note but is not a defect.
- **L3:** Cache-hit rate is not persisted (by design per prior lanes); acceptable but limits post-hoc audit of the display-vs-bill gap once providers begin reporting nonzero cached tokens. Revisit before the rollout flips.

## 6. Evidence references from this pack
- `endpoints.go` 497–538 — reconcile query + 503/quarantine exclusion loop.
- `endpoints_test.go` 177–215 — quarantine-zero-delta regression.
- `server.go` 2984–2998, 3083–3092 — pre/post-commit token-line sanitize + drop-on-nil.
- `server.go` 5740–5840 — `sseLineWithCachedPromptTokens`, `streamingJSONWithCachedPromptTokens`, `streamingUsageObjectComplete` strip/complete gating.
- `cache_recovery_internal_test.go` 12–89 — sticky-hit-zero preservation, non-hit drop, null-sentinel, partial-usage merge, strip/rewrite assertions.

## 7. Gate verdict
**ZERO C/H/M**

Concurs with the three codex lanes and the prior Claude adversarial lane at this HEAD. No Critical/High/Medium product-contract risk with a concrete reachable failure path is substantiable from the evidence pack; Lows are documentation/observability nits only and ship with PR-body notes.

---

Note: I did not enter the plan workflow or write a plan file — this was an audit deliverable (read-only, no tools, fixed output format) with no implementation to execute, so producing the verdict inline is the correct terminal action rather than `ExitPlanMode`.
