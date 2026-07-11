# SPEC-024 - Prefix-cache billing and provider-local cache isolation

**Version:** 0.2 (2026-07-12, provider-local cache-isolation reconciliation)
**Status:** v0.1 billing sections locked; v0.2 adds the isolation baseline (§11–§16) reconciled to shipped code.
**Depends on:** SPEC-002 v1.5.2 (coordinator-provider wire), SPEC-004 v0.3.1 (sticky affinity), SPEC-005 v0.5 (billing), SPEC-006 v0.9.7 (buyer API; §1.3 conversation-key derivation), SPEC-008 v0.3 (Tier-2 trust; Pillar B conversation-key survivability — see the §12 provider-visibility reconciliation note), SPEC-018 v0.2.4 (tool calling)

**Change log v0.2 (2026-07-12, provider-local cache-isolation baseline — spec-only, reconciled to shipped code):**
v0.1 specified the *accounting* of a provider-reported `cached_prompt_tokens` but left the number's *provenance safety* unspecified: the entire provider-local KV/conversation cache keying, the cross-account isolation invariant, and coordinator cross-checking were deferred (§2/§7). v0.2 writes that missing normative baseline, matching the shipped Swift provider + Go coordinator + gateway.
- **§11 (cache-key / isolation invariant):** the provider-local cache is partitioned **solely by the coordinator-supplied `conversation_key`**, and reuse additionally requires an exact token-level longest-common-prefix (LCP ≥ 32) with matching `model_id` and quantization (`kvBits`) — codifying the shipped guards. The provider cache has **no account/buyer dimension of its own**.
- **§12 (account-namespacing — the load-bearing cross-component invariant):** cross-account isolation is inherited entirely from the requirement that `conversation_key` be **unforgeable and account-scoped before it reaches the provider or the coordinator sticky map** — shipped via the gateway's keyed HMAC derivation (`conv:` + unpadded-base64url(HMAC-SHA256(secret, scope‖`\n`‖account_id‖`\n`‖tag)), already normative in **SPEC-006 §1.3 / SPEC-008 §1.1**), public-ingress stripping of the `X-MacProvider-Internal-*` namespace, **and** the coordinator's operator/service-bearer gate on internal routing headers (which adds replay-resistance HMAC alone does not). v0.2's contribution is connecting this existing derivation to the cache-**isolation** property and reconciling the provider-visibility tension (next bullet) — not re-owning the derivation.
- **§12 provider-visibility reconciliation (cross-spec — DECISION NEEDED):** the shipped prefix-cache design **sends the derived `conv:` key to the provider** (cleartext relay and inside the Tier-2 encrypted plaintext), because provider-local KV caching needs a stable per-conversation key. That **contradicts** the current SPEC-004 FR-SR-2 / SPEC-006 / SPEC-008 invariant that the provider cannot read/derive `conv:`. The outer network frames still conceal the key + raw account/tag (Pillar B survivability holds at the wire), but the provider **runtime** learns a stable per-conversation identifier (the same cross-turn correlation sticky affinity already grants). Reconciling the corpus — amend SPEC-004/006/008 to permit a provider-visible *derived* conversation identifier with an explicit privacy disclosure, **or** treat the shipped behavior as a privacy regression to fix in code — is a **cross-spec design decision carried out of v0.2**; §12 documents the tension.
- **§13 (non-leakage threat model):** cache reuse MUST NOT cross a `conversation_key` boundary, and `cached_prompt_tokens` (buyer-visible, §8) plus TTFT MUST NOT become a cross-account prefix-content/timing oracle.
- **§14 (coordinator cross-check — the deferred §7 item):** resolves the v0.1 deferral; ties trust of a positive `cached_prompt_tokens` to `sticky_result == "hit"` and flags the shipped sticky-Lookup account-scope gap (account compared only on write, not on the routing read path).
- **§15 (ingest paths without a fronting gateway):** direct/Tier-2/cleartext ingest trust `conversation_key` verbatim with no provider-side account binding; v0.2 states the deployment invariant these paths must preserve.
- **§16 (acceptance criteria):** adds the missing **non-interference** test requirement (no shipped test drives two distinct keys/accounts against one cache).

**Change log v0.1 (2026-07-02, prefix-cache billing design):**
- **Prefix-cache reuse meaning.** Prefix-cache reuse means the same provider that served conversation turn N also serves turn N+1 through SPEC-004 sticky affinity and can skip prefill work for an exact canonical prefix of the new prompt that was already materialized in provider-local KV cache.
- **Wire-shape delta.** The coordinator-provider completion usage object gains one optional integer field: `cached_prompt_tokens`.
- **Ledger schema delta.** `ledger_request_credits` gains one nullable insert-only integer column: `cached_prompt_tokens`.
- **Formula delta.** The rate-card row shape gains one integer field, `prompt_cache_hit_rate_per_mtok`, and prompt billing / buyer debit splits prompt tokens into uncached tokens at the normal prompt rate plus cached tokens at the cache-hit rate.
- **Buyer-visible delta.** The SPEC-006 response usage object gains one flat integer field: `cached_prompt_tokens`, sourced from the same effective value used for ledger arithmetic and credit-denominated buyer billing.

## 1. Scope

SPEC-024 specifies the billing treatment for provider-reported prefix-cache reuse on sticky-affinity conversations (SPEC-004 FR-SR-*). It defines a provider-reported `cached_prompt_tokens` field on the coordinator-provider usage report (SPEC-002), a new `cached_prompt_tokens` column on `ledger_request_credits` (SPEC-005), an additive rate-card row field `prompt_cache_hit_rate_per_mtok`, an updated billing / buyer-debit formula that prices the cached fraction at the discounted rate, and a mirror field in the buyer-visible OpenAI-shape usage object (SPEC-006).

**v0.2 adds the provider-local cache **isolation** baseline (§11–§16):** the normative cache-key/reuse invariant, the cross-account `conversation_key` unforgeability/namespacing invariant that isolation depends on, the non-leakage threat model, the coordinator cross-check of `cached_prompt_tokens`, and the acceptance criteria — because the discounted cache-hit price and the buyer-visible `cached_prompt_tokens` are only sound if cache reuse cannot cross a buyer/conversation boundary. v0.2 is spec-only and reconciled to shipped code; it specifies the isolation *invariant*, not the provider KV-cache implementation (still §2).

## 2. Out of Scope

- KV-cache implementation **internals** on the provider are out of scope. SPEC-024 defines the reported `cached_prompt_tokens` semantics and (v0.2, §11) the **observable cache-key/reuse invariant**; the mlx-swift cache pinning, materialization, and eviction *mechanism* between `generate()` calls remain IMPL concerns and SPEC-024 MUST NOT prescribe internal mlx APIs. (v0.2 pins the *behavior* — what may be reused for which key — not the mechanism.)
- ~~Cache-hit fraud detection algorithms are out of scope. Section 7 defines the v0.1 fraud model and defers cross-checked coordinator verification to v0.2.~~ **(v0.2: resolved.)** Coordinator cross-checking of `cached_prompt_tokens` is now in scope — §14. Specific ML-based anomaly-scoring *algorithms* remain out of scope; §14 pins only the deterministic route/attribution gates the coordinator already applies.
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

Final-provider provenance rule: `sticky_result = "hit"` is a statement about the provider that actually receives the attempt, not only the pre-tiebreak candidate. A SPEC-024-aware coordinator MUST NOT let random tiebreaking or retry/failover relabel a different final provider as a sticky hit for cache-billing purposes. Implementations MAY skip random tiebreaking after a sticky-hit swap; if they keep random tiebreaking enabled after sticky lookup, they MUST recompute cache-billing eligibility from the final selected provider before accepting positive `cached_prompt_tokens`.

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

Provider under-reporting `cached_prompt_tokens` makes the buyer pay more than the actual cached-prefill economics justify. The gateway records buyer-visible prompt tokens, and buyers can estimate expected cache hits offline from prior-turn prompt and completion growth on sticky-hit conversations. v0.1 MUST log `cached_prompt_tokens = 0` explicitly on sticky-hit billing writes so buyer-side and operator analytics can flag providers with suspiciously low cache-hit rates. **Coordinator-side cross-checking is specified in §14 (v0.2, resolving the v0.1 deferral).**

Provider-reported cached tokens on a non-sticky-hit route are a wire-contract violation and MUST quarantine per Section 3. They are not a revenue-increasing fraud vector because the discounted rate reduces payable credits.

**Cross-account cache collision (v0.2, §11–§13).** The provider-local cache is keyed only on `conversation_key` (§11); it has no account dimension. If two distinct buyers could ever present the **same** `conversation_key` to the same provider process, buyer B would obtain KV reuse — and a positive, buyer-visible `cached_prompt_tokens` — against buyer A's cached prefix. That is simultaneously (a) a **confidentiality** leak (a prefix-content + TTFT oracle, §13) and (b) a **billing-attribution** fault (a cache-hit discount priced against another account's work). This vector is closed **not at the provider** but by the §12 invariant that `conversation_key` is unforgeable and account-scoped before it reaches the provider or the coordinator sticky map; §7's provider-report analysis assumes that invariant holds.

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

---

## 11. Provider-local cache-key and reuse invariant (v0.2)

The provider-local conversation/KV cache (`phase3-binary/.../ConversationCache.swift`) is an
in-process, per-provider-process store. Its **isolation boundary is the `conversation_key`
namespace and nothing else** — entries are held in a dictionary keyed by the trimmed
`conversation_key` string, with **no account, buyer, or provider-identity component**.

**FR-CI1 (partition).** A provider MUST partition cached prefixes strictly by
`conversation_key`. A lookup for key K MUST NOT return, reuse, or measure any prefix stored
under a different key K′. `conversation_key` MUST satisfy the SPEC-004 shape (`conv:` prefix,
≤ 256 UTF-8 bytes, printable ASCII); the provider treats it as an opaque, already-scoped
token (§12) — it MUST NOT parse or attribute it.

**FR-CI2 (reuse predicate).** Even on a key hit, a provider MUST reuse cached KV only for the
**exact token-level longest common prefix** of the stored canonical prompt tokens and the
incoming prompt tokens, and MUST require: LCP ≥ a fixed minimum (shipped `lcpThreshold = 32`
tokens), LCP `<` the incoming prompt length (a full-prompt match is not a reuse event),
identical `model_id`, and identical quantization (`kvBits`). A mismatch on model or `kvBits`
MUST yield a cache **miss**, not a partial reuse. Additionally (shipped guards): every KV
layer MUST be *trimmable* and each `trim` MUST remove exactly the requested token count, else
the request is a **miss** (regression-tested). Because reused KV corresponds to *identical
tokens*, reuse preserves **model semantics conditional on identical sampler/RNG state** — the
per-position logits/KV are equivalent to a cold prefill. It does **not** guarantee
bit-for-bit identical *sampled output*: the shipped default is stochastic sampling
(`temperature = 1.0`, and the parsed `seed` is not wired into generation), so warm and cold
runs of a stochastic request will differ. Reuse is a performance optimization with no effect
on the *distribution* of output, not a determinism guarantee.

**FR-CI3 (canonical prefix).** The stored canonical prefix is the provider's canonicalized
prompt token IDs (system/user/assistant content per §2), optionally extended by the
generated token IDs of the served turn. `cached_prompt_tokens` reported per §3 MUST equal
`min(LCP, incoming_prompt_tokens)` for the reused turn (see §5–§6 for pricing); it is a
**token count**, never a byte count.

**FR-CI4 (lifecycle bounds).** The cache MUST bound retention (shipped: a TTL sweep, default
900 s, and LRU eviction on a per-provider conversation-count cap and total-token cap). These
bounds are IMPL-tunable; the *invariant* is that no prefix outlives its `conversation_key`
entry, and eviction never moves a prefix across keys.

This section pins observable behavior, not the mlx mechanism (§2).

## 12. Cross-account namespacing invariant (v0.2) — load-bearing

Because §11's cache has no account dimension, **all** cross-account isolation rests on a
single upstream invariant, which v0.2 makes normative:

**FR-CI5 (unforgeable, account-scoped key).** By the time a `conversation_key` reaches a
provider or the coordinator sticky map, it MUST be **account-scoped and unforgeable** — a
value that no buyer can choose or collide with another account's value. This derivation is
**already normative in SPEC-006 §1.3 / SPEC-008 §1.1**; SPEC-024 references it and does not
re-own it. For clarity, the **byte-exact** shipped algorithm
(`phase5-gateway/internal/router/chat_proxy.go` `deriveConversationKey`) is:

```
scope = "spec006-v0.8-sticky-conversation-v1"
conversation_key = "conv:" + base64url_unpadded( HMAC-SHA256(secret, scope + "\n" + account_id + "\n" + tag) )
```

Note the **newline (`\n`) field separators** and **unpadded base64url** (`base64.RawURLEncoding`).
Two accounts using the same buyer-facing tag therefore receive **different** internal keys, and a
buyer cannot forge another account's key without the secret.

**FR-CI6 (ingress non-injection + coordinator origin gate).** Buyer-controlled ingress MUST
NOT be able to set the internal conversation key directly, and the coordinator MUST NOT
accept internal routing headers from untrusted origins. Two shipped controls, both
load-bearing: (a) the gateway strips any inbound `X-MacProvider-Internal-*` header (the whole
namespace, including `X-MacProvider-Internal-Conv`) at public ingress; (b) the **coordinator**
itself rejects internal routing headers unless the request carries the operator/service
bearer (`internal/buyer/server.go`), so a party that *observes* a valid `conv:` key still
cannot **replay** it to the coordinator without gateway-origin authorization (HMAC gives
unforgeability, not replay-resistance — SPEC-006 §… states the coordinator gate). A
deployment MUST preserve both: the account-scoped key is set exclusively by trusted
infrastructure and honored only on authenticated gateway-origin traffic.

**FR-CI7 (wire survivability, with a provider-runtime caveat).** The account-scoping input
(`account_id`) MUST remain in the key derivation and MUST NOT be strippable downstream. At the
**wire** level this preserves SPEC-008 Pillar B survivability: captured provider-leg frames
contain no raw `account_id` or raw buyer tag. **But** — and this is the §12 provider-visibility
tension — the provider **runtime** does receive the derived `conv:` key in cleartext (relay
path) or inside the decrypted Tier-2 plaintext (`Tier2ProviderSession.swift`), so it learns a
stable per-conversation identifier. This **contradicts** the current SPEC-004 FR-SR-2 /
SPEC-006 / SPEC-008 invariant (b) that the provider cannot read/derive `conv:`. FR-CI7 does
**not** claim consistency with that invariant; it records the contradiction and defers its
resolution to the cross-spec decision below.

**Provider-visibility reconciliation (DECISION NEEDED — carried out of v0.2).** Provider-local
prefix caching (SPEC-024's entire premise) requires a stable per-conversation key at the
provider; the shipped design supplies the derived `conv:` key. This is inconsistent with the
provider-nonvisibility invariant in SPEC-004/006/008. The corpus MUST resolve it one of two
ways, which is an operator/architecture decision, not a v0.2 spec-text choice:
(a) **amend** SPEC-004 FR-SR-2, SPEC-006, and SPEC-008 invariant (b) to permit a
provider-visible *derived, account-scoped, opaque* conversation identifier, with an explicit
privacy disclosure that the provider can correlate a conversation's turns (the same
correlation sticky affinity already grants) but cannot recover the account/tag; **or**
(b) treat the shipped provider-visible key as a **privacy regression** — in which case
provider-local prefix caching as designed cannot stand and SPEC-024's reuse model must change.
Until this is decided, §11–§16's isolation guarantees hold **only at the wire/account-scoping
layer** and assume the provider is trusted to hold (not exfiltrate) the derived key.

If FR-CI5/6 hold, §11's key-only partition is sufficient for cross-account **isolation**
(no cross-buyer *reuse*); if either fails (a derivation bug, a stripped account input, or a
topology where buyers reach the provider/coordinator without the deriving gateway — §15),
cross-account isolation collapses to whatever the buyer can name.

## 13. Non-leakage threat model (v0.2)

**Threats.** (a) *Confidentiality*: a buyer learning any portion of another buyer's prompt or
its cache state. (b) *Timing*: a buyer inferring another buyer's cached prefix from reduced
TTFT (skipped prefill). (c) *Billing attribution*: a cache-hit discount or a positive
`cached_prompt_tokens` computed against another account's work.

**FR-CI8 (no cross-key KV *reuse* or prefix measurement).** For any two distinct
`conversation_key`s, a provider MUST NOT reuse KV, measure a prefix, or attribute
`cached_prompt_tokens` from one key against the other; a lookup for key K′ returns a cold-cache
result regardless of what is stored under K. **Scope caveat (shipped, capacity contention):**
this is a *content/reuse* non-interference guarantee, **not** a full side-channel guarantee.
The shipped cache is one process-wide store with global conversation-count and total-token
caps, so committing one key can **LRU-evict** another key's warm entry
(`ConversationCache.swift` eviction; regression-tested). A buyer priming its own keys can
therefore observe, via its own later `cached_prompt_tokens`/TTFT, aggregate cache *pressure*
from other keys, or deliberately evict another key's warmth (a latency/discount denial). This
capacity-contention channel reveals **no prefix content** and enables **no cross-key reuse**,
but it is real cross-key cache-*state* interference; mitigating it (per-key or per-account
capacity partitioning) is a forward hardening item, not a v0.2 guarantee.

**FR-CI9 (`cached_prompt_tokens` is not a cross-account oracle).** Given FR-CI5/6, a positive
`cached_prompt_tokens` on key K reflects only prior turns *of that same account's key K*.
Operators and buyers MUST NOT treat `cached_prompt_tokens` as evidence about any other
account. Should FR-CI5/6 fail, `cached_prompt_tokens` and TTFT become an LCP-granularity
prefix-match oracle — which is precisely why §12 is load-bearing.

**FR-CI10 (telemetry locality).** The provider's `kv_cache_request_completed` observability
event (`KVCacheTelemetry.swift`) is a **local operator signal** (default stderr) and MUST NOT
be exposed to buyers; only the §8 buyer-visible `cached_prompt_tokens` count crosses to the
buyer, and only for the buyer's own account.

## 14. Coordinator cross-check of `cached_prompt_tokens` (v0.2)

This section resolves the v0.1 §7 deferral with the **deterministic** gates the coordinator
already applies (`phase4-coordinator/internal/billing/hotpath.go`, `normalizeCachedPromptTokens`);
ML-based anomaly scoring remains out of scope (§2).

**FR-CI11 (route gate).** A positive `cached_prompt_tokens` MUST be accepted for the
discounted price only when the request was served on a **sticky hit** (`sticky_result ==
"hit"`). A positive value on any non-hit route MUST be quarantined (`ambiguous_cache`) and
priced as if `cached_prompt_tokens = 0` (§3).

**FR-CI12 (range + retry gates).** The coordinator MUST null and flag (`invalid_cached_prompt_tokens`)
any value `< 0` or `> prompt_tokens`, and MUST null `cached_prompt_tokens` on any retry
attempt (`attempt_n > 0`) — cache reuse is only trusted on the first, sticky-routed attempt.

**FR-CI13 (attribution — known shipped gap, MUST close).** The sticky affinity that gates
FR-CI11 is keyed on the same `conversation_key` as the provider cache, but the shipped sticky
**Lookup/read path compares only the key and provider candidacy — it does NOT compare
`account_id`** (account is validated only on the sticky *write* path;
`internal/routing/sticky/sticky.go`, `internal/buyer/server.go` `applySticky`). This is
defense-in-depth-only and relies entirely on the §12 key-unforgeability invariant. v0.2
requires that a coordinator serving requests **without** the FR-CI5 guarantee (e.g. a
direct-buyer or non-HMAC topology, §15) MUST additionally compare the sticky entry's
`account_id` on the read path before honoring a cache-hit discount; under the shipped
gateway-HMAC topology the key already encodes the account, so the read-path account check is
redundant but MUST NOT be relied upon as the *primary* isolation control.

## 15. Ingest paths without a fronting gateway (v0.2)

The provider accepts `conversation_key` on multiple ingest paths — the cleartext HTTP/relay
path and the Tier-2 encrypted-envelope path — and trusts the value **verbatim**, with no
provider-side account binding (`InferenceRelay.swift`, `Tier2ProviderSession.swift`). This is
safe **only** while every buyer request passes through the FR-CI5 deriving gateway first.

**FR-CI14 (deployment invariant).** Any deployment topology in which buyers can reach the
coordinator or provider **without** the gateway HMAC derivation (direct coordinator access, a
future direct-buyer Tier-2 leg, or a self-hosted provider exposed to untrusted buyers) MUST
supply an equivalent account-scoped, unforgeable `conversation_key` derivation, or MUST
disable prefix-cache reuse and the `cached_prompt_tokens` discount entirely for that path.
Prefix-cache reuse MUST NOT be enabled on a path where the conversation key is buyer-chosen.

## 16. Acceptance criteria (v0.2)

- **AC-CI-1 (partition).** Two distinct `conversation_key`s driven against one provider cache
  produce independent results: key K′ gets a cold-cache result and `cached_prompt_tokens = 0`
  even when key K has a warm, longer-prefix entry. *(No shipped test asserts this cross-key
  non-interference today — see the coverage note below; v0.2 IMPL MUST add it.)*
- **AC-CI-2 (reuse predicate).** A key hit with a changed `model_id` or `kvBits`, or with LCP
  `< 32`, yields a miss and `cached_prompt_tokens = 0`; a hit with LCP ≥ 32 (and `< prompt`)
  reports `cached_prompt_tokens = LCP`.
- **AC-CI-3 (namespacing).** Two accounts using an identical buyer-facing conversation tag
  receive different internal `conversation_key`s from the gateway (distinct HMAC outputs), and
  therefore never share a cache entry or a sticky route.
- **AC-CI-4 (ingress non-injection).** A buyer-supplied `X-MacProvider-Internal-Conv` header is
  stripped at ingress and never reaches the coordinator sticky map or the provider.
- **AC-CI-5 (route/retry/range gates).** A positive `cached_prompt_tokens` on a non-hit route,
  on a retry, or out of `[0, prompt_tokens]` is quarantined/nulled per §14 and priced as 0.
- **AC-CI-6 (reuse-equivalence, deterministic).** With **deterministic decoding** (fixed
  sampler + pinned RNG state, e.g. `temperature = 0` or a wired seed), a conversation produces
  identical completion output whether or not prefix-cache reuse occurred; equivalently, per-position
  logits/KV are equal with and without reuse. Under stochastic sampling the AC MUST assert
  *distributional* equivalence, not byte equality (FR-CI2).

**Coverage note (v0.2).** The shipped provider tests lock reuse *correctness* (LCP,
model/`kvBits` swap → miss, non-trimmable → miss, TTL/LRU/token-cap eviction, cached-token
clamping — the LRU test drives three keys through one cache). But **no test asserts
cross-key/cross-account non-interference (AC-CI-1)**, exercises the sub-32 LCP / full-prompt
miss paths (AC-CI-2), the coordinator route/retry/range normalization (AC-CI-5), or
cold-vs-warm reuse-equivalence (AC-CI-6). Also un-tested here: FR-CI4 lifecycle, FR-CI8's
full non-interference claim, FR-CI10 buyer non-exposure, FR-CI13 read-path account compare on
a non-FR-CI5 topology, and FR-CI14 reuse-disable on buyer-chosen-key paths. Closing these is a
v0.2 IMPL deliverable.
