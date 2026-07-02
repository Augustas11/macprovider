# SPEC-024 - Prefix-cache billing

**Version:** 0.1 (2026-07-02, implementation lock)
**Status:** Locked for SPEC-024 implementation after v0.1 audit review.
**Depends on:** SPEC-002 v1.5.2 (coordinator-provider wire), SPEC-004 v0.3.1 (sticky affinity), SPEC-005 v0.4 (billing), SPEC-006 v0.9.4 (buyer API), SPEC-018 v0.2.4 (tool calling)

**Change log v0.1 (2026-07-02, prefix-cache billing design):**
- **Prefix-cache reuse meaning.** Prefix-cache reuse means the same provider that served conversation turn N also serves turn N+1 through SPEC-004 sticky affinity and can skip prefill work for an exact canonical prefix of the new prompt that was already materialized in provider-local KV cache.
- **Wire-shape delta.** The coordinator-provider completion usage object gains one optional integer field: `cached_prompt_tokens`.
- **Ledger schema delta.** `ledger_request_credits` gains one nullable insert-only integer column: `cached_prompt_tokens`.
- **Formula delta.** The rate-card row shape gains one integer field, `prompt_cache_hit_rate_per_mtok`, and prompt billing / buyer debit splits prompt tokens into uncached tokens at the normal prompt rate plus cached tokens at the cache-hit rate.
- **Buyer-visible delta.** The SPEC-006 response usage object gains one flat integer field: `cached_prompt_tokens`, sourced from the same effective value used for ledger arithmetic and credit-denominated buyer billing.

## 1. Scope

SPEC-024 specifies the billing treatment for provider-reported prefix-cache reuse on sticky-affinity conversations (SPEC-004 FR-SR-*). It defines a provider-reported `cached_prompt_tokens` field on the coordinator-provider usage report (SPEC-002), a new `cached_prompt_tokens` column on `ledger_request_credits` (SPEC-005), an additive rate-card row field `prompt_cache_hit_rate_per_mtok`, an updated billing / buyer-debit formula that prices the cached fraction at the discounted rate, and a mirror field in the buyer-visible OpenAI-shape usage object (SPEC-006).

## 2. Out of Scope

- KV-cache implementation details on the provider are out of scope. SPEC-024 defines reported `cached_prompt_tokens` semantics; mlx-swift cache pinning, reuse, and eviction between `generate()` calls are IMPL concerns. SPEC-024 MUST NOT prescribe internal mlx APIs.
- Cache-hit fraud detection algorithms are out of scope. Section 7 defines the v0.1 fraud model and defers cross-checked coordinator verification to v0.2.
- Cross-provider KV-cache handoff is out of scope. A request that does not route through a sticky hit MUST report `cached_prompt_tokens = 0` or omit the field.
- Prefix-cache reuse for tool-call replies is out of scope. Tool-message content is buyer-supplied and does not share a stable canonical form with previous turns; v0.1 accounting is restricted to system, user, and assistant message-content prefixes.
- Buyer-side cache-hint headers are out of scope. Buyers MUST NOT send `X-MacProvider-Expect-Cached-Prefix` or an equivalent v0.1 hint. Providers are the source of truth for actual cache reuse; buyers observe `usage.cached_prompt_tokens`.
- Rate-card hot reload for the new field is out of scope. SPEC-005 Wave 0/1 work continues to govern hot-reload semantics. v0.1 IMPL MAY require coordinator restart to activate `prompt_cache_hit_rate_per_mtok`.

## 3. Wire Contract (SPEC-002 Addendum)

Providers MAY report `cached_prompt_tokens` inside the standard completion-side usage object:

```json
"usage": {
  "prompt_tokens": 1500,
  "completion_tokens": 300,
  "total_tokens": 1800,
  "cached_prompt_tokens": 1200
}
```

`cached_prompt_tokens` MUST satisfy:

- `0 <= cached_prompt_tokens <= prompt_tokens`.
- Field absence is legal and has an effective cache value of `0` for arithmetic and buyer response shaping. Ledger storage still preserves absence as `NULL` per Section 4.
- When `sticky_result = "hit"`, `cached_prompt_tokens` MAY be positive.
- When `sticky_result != "hit"` (`miss`, `disabled`, `no_key`, `evicted`, or other non-hit values), `cached_prompt_tokens` MUST be `0` or absent.
- Positive `cached_prompt_tokens` on a non-hit route MUST quarantine the ledger write with `quarantined=1`, `quarantine_reason='ambiguous_cache'`, `cached_prompt_tokens=NULL`, and the `usage_source` value that would have applied absent the cache violation (`provider_reported` or `byte_estimated`). The row MUST set payable credit fields to 0 and MUST NOT produce provider-creditable credits.
- `cached_prompt_tokens > prompt_tokens`, negative `cached_prompt_tokens`, or non-integer `cached_prompt_tokens` MUST quarantine the ledger write with `quarantined=1`, `quarantine_reason='invalid_cached_prompt_tokens'`, `cached_prompt_tokens=NULL`, and the `usage_source` value that would have applied absent the cache violation (`provider_reported` or `byte_estimated`). The row MUST set payable credit fields to 0 and MUST NOT produce provider-creditable credits.

The coordinator MUST derive two values after validating the raw provider field against routing state:

- `ledger_cached_prompt_tokens`: nullable provenance stored in `ledger_request_credits.cached_prompt_tokens` per Section 4.
- `effective_cached_prompt_tokens`: `COALESCE(ledger_cached_prompt_tokens, 0)`, used for credit arithmetic, buyer-visible `usage.cached_prompt_tokens`, credit-denominated buyer billing, and cache observability.

Invalid raw provider values MAY be logged for operator debugging but MUST NOT be forwarded to buyers or used in credit arithmetic.

The coordinator MUST emit an additional billing-time `routing_decision` log row after cache validation, leaving the existing selection-time `routing_decision` row unchanged. The billing-time row MUST carry at least `request_id`, `sticky_result`, `sticky_miss_reason` when applicable, `attempt_n`, and `effective_cached_prompt_tokens` serialized as `cached_prompt_tokens`. This extends the SPEC-004 sticky observability surface instead of creating a parallel cache event stream.

## 4. Ledger Schema (SPEC-005 Addendum)

`ledger_request_credits` gains exactly one column:

```sql
cached_prompt_tokens INTEGER NULL CHECK(
  cached_prompt_tokens IS NULL OR
  (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens)
)
```

Rules:

- The column is insert-only.
- `NULL` means a legacy row written before SPEC-024 IMPL, an absent provider field during rollout, a non-hit route, a retry / re-attempt row, or a quarantined invalid cache report.
- `0` means a SPEC-024-aware sticky-hit first attempt was validated and reported no cached prompt tokens.
- A positive integer means a SPEC-024-aware sticky-hit first attempt reported that many cached prompt tokens.
- Migration MUST be additive with `NULL` default.
- Migration MUST NOT backfill historical rows.

## 5. Rate Card (SPEC-005 Addendum)

Each rate-card row gains exactly one field in the formula/rate snapshot:

```sql
prompt_cache_hit_rate_per_mtok INTEGER NOT NULL CHECK(
  prompt_cache_hit_rate_per_mtok >= 0 AND
  prompt_cache_hit_rate_per_mtok <= prompt_rate_per_mtok
)
```

`prompt_cache_hit_rate_per_mtok` MUST NOT exceed `prompt_rate_per_mtok`. A rate card violating this constraint MUST fail SPEC-005 config validation.

Coordinator YAML/config MUST expose this value as `prompt_cache_hit_credits_per_mtok`, mirroring SPEC-005's existing `prompt_credits_per_mtok` / `completion_credits_per_mtok` config names. The ledger/rate snapshot and formula name is `prompt_cache_hit_rate_per_mtok`, mirroring existing snapshot names such as `prompt_rate_per_mtok`.

Pre-SPEC-024 configs that omit `prompt_cache_hit_credits_per_mtok` MUST load with an effective default equal to `prompt_credits_per_mtok` until the operator explicitly configures a discounted value. This preserves startup compatibility and byte-identical arithmetic during rollout.

Operator guidance: configured `prompt_cache_hit_credits_per_mtok` SHOULD target 25% of `prompt_credits_per_mtok`. The concrete value is operator configuration, not a normative fixed price.

## 6. Formula (SPEC-005 Formula Addendum)

Current SPEC-005 v0.4 base numerator:

```text
base_numerator = prompt_tokens * prompt_rate_per_mtok + effective_completion_tokens * completion_rate_per_mtok
```

SPEC-024 base numerator:

```text
cached = COALESCE(cached_prompt_tokens, 0)
uncached_prompt_tokens = prompt_tokens - cached
base_numerator = uncached_prompt_tokens * prompt_rate_per_mtok
              + cached * prompt_cache_hit_rate_per_mtok
              + effective_completion_tokens * completion_rate_per_mtok
```

The result MUST be byte-identical to SPEC-005 v0.4 when `cached_prompt_tokens IS NULL` or `cached_prompt_tokens = 0`:

```text
cached = COALESCE(NULL, 0) = 0
uncached_prompt_tokens = prompt_tokens - 0 = prompt_tokens
base_numerator = prompt_tokens * prompt_rate_per_mtok
              + 0 * prompt_cache_hit_rate_per_mtok
              + effective_completion_tokens * completion_rate_per_mtok
base_numerator = prompt_tokens * prompt_rate_per_mtok
              + effective_completion_tokens * completion_rate_per_mtok
```

The SPEC-005 `usage_source = 'null_error'` NULL guard remains binding: when `usage_source = 'null_error'`, the formula MUST NOT evaluate and all credit fields MUST be set to 0. Valid `byte_estimated` rows with `completion_tokens IS NULL` and non-NULL `estimated_completion_tokens` remain creditable under SPEC-005's existing `effective_completion_tokens` rule. `cached_prompt_tokens IS NULL` is not a null-error case; it collapses to `0`.

Per-attempt rule: cache-hit billing applies only to `attempt_n = 0` for a conversation turn. Retry / re-attempt rows (`attempt_n > 0`) MUST set `cached_prompt_tokens` to `NULL` or `0` and MUST price all prompt tokens at `prompt_rate_per_mtok`, even if the same provider is retried.

SPEC-005 coordinator billing is the sole v0.1 authority for credit-denominated buyer billing. A SPEC-024 IMPL MUST NOT duplicate rate-card pricing authority in the SPEC-006 gateway. Buyer invoices, paid credit debits, or any credit-denominated export MUST use the coordinator ledger/rate snapshot and this cached / uncached prompt split:

```text
cached = effective_cached_prompt_tokens
uncached_prompt_tokens = prompt_tokens - cached
buyer_prompt_debit = uncached_prompt_tokens * prompt_rate_per_mtok
                   + cached * prompt_cache_hit_rate_per_mtok
```

plus the existing completion debit. SPEC-006 daily quota settlement remains token-count based in v0.1 and MUST continue to settle quota to nominal `prompt_tokens + completion_tokens` (or existing error/fallback matrix values). There is no token-quota refund for cache hits in v0.1; the buyer economic reward is the discounted credit/money calculation from SPEC-005.

## 7. Fraud Model

Provider over-reporting `cached_prompt_tokens` lowers provider revenue because:

```text
uncached * prompt_rate_per_mtok + cached * prompt_cache_hit_rate_per_mtok
```

is less than or equal to:

```text
(uncached + cached) * prompt_rate_per_mtok
```

when `prompt_cache_hit_rate_per_mtok <= prompt_rate_per_mtok`. Provider over-reporting therefore works against the provider and is not a provider-side fraud vector at this layer.

Provider under-reporting `cached_prompt_tokens` makes the buyer pay more than the actual cached-prefill economics justify. The gateway records buyer-visible prompt tokens, and buyers can estimate expected cache hits offline from prior-turn prompt and completion growth on sticky-hit conversations. v0.1 MUST log `cached_prompt_tokens = 0` explicitly on sticky-hit billing writes so buyer-side and operator analytics can flag providers with suspiciously low cache-hit rates. Coordinator-side cross-checking is deferred to v0.2.

Provider-reported cached tokens on a non-sticky-hit route are a wire-contract violation and MUST quarantine per Section 3. They are not a revenue-increasing fraud vector because the discounted rate reduces payable credits.

## 8. Buyer-Visible Usage Object (SPEC-006 Addendum)

The buyer-visible response usage object gains exactly one flat field:

```json
"usage": {
  "prompt_tokens": 1500,
  "completion_tokens": 300,
  "total_tokens": 1800,
  "cached_prompt_tokens": 1200
}
```

`cached_prompt_tokens` matches OpenAI `prompt_tokens_details.cached_tokens` semantics but remains flat because SPEC-006 usage is flat today. SPEC-024 v0.1 locks the flat shape.

The field MUST be present on every completion response emitted by a SPEC-024-aware gateway. Non-hit routes, legacy providers, absent provider fields, and quarantined cache reports MUST surface sanitized `cached_prompt_tokens: 0` to buyers.

## 9. Explorer Surface (SPEC-007 Follow-Up)

Explorer request-detail views SHOULD surface `cached_prompt_tokens` next to `prompt_tokens` for operator auditability. This is a SPEC-007 follow-up and MUST NOT be implemented as part of SPEC-024 v0.1.

## 10. Rollout Invariant

Rows written before SPEC-024 IMPL have `cached_prompt_tokens IS NULL`. Rows written after SPEC-024 IMPL against providers that do not report the field have `cached_prompt_tokens IS NULL`. Rows written after SPEC-024 IMPL against SPEC-024-aware providers on sticky-hit first attempts have `cached_prompt_tokens >= 0`.

For the first two cases, Section 6 reduces algebraically to the SPEC-005 v0.4 numerator because `COALESCE(cached_prompt_tokens, 0) = 0`. For pre-SPEC-024 configs, Section 5 also defaults `prompt_cache_hit_rate_per_mtok = prompt_rate_per_mtok`; even an explicit sanitized `0` therefore preserves startup and arithmetic compatibility. Rollout MUST preserve byte-identical gross numerator arithmetic for all legacy and non-hit rows.

Implementation deliverable: `BUILD_SPEC_024_PREFIX_CACHE_BILLING_IMPL_PROMPT.md` defines the implementation work for this locked SPEC.
