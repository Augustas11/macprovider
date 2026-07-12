# SPEC-024 - Prefix-cache billing and provider-local cache isolation

**Version:** 0.2.1 (2026-07-12, billing arithmetic superseded by SPEC-005 v0.6)
**Status:** **Billing arithmetic (§4 ledger / §5 rate card / §6 formula) MOVED to SPEC-005 v0.6** (canonical). SPEC-024 **retains** the `cached_prompt_tokens` **wire field** (§3, a SPEC-002 addendum), the **buyer-visible** mirror field (§8, a SPEC-006 addendum), the fraud model (§7), and the provider-local cache-**isolation** baseline (§11–§16) — none of which SPEC-005 **re-owns** (SPEC-005 §5.3.1 does fold in the §14 coordinator cross-check *gates* as billing-eligibility rules, but SPEC-024 remains their canonical home).
**Depends on:** SPEC-002 v1.5.2 (coordinator-provider wire), SPEC-004 v0.3.2 (sticky affinity; FR-SR-2 provider-visibility carve-out), SPEC-005 v0.6 (billing — the canonical owner of prefix-cache billing arithmetic, formula, ledger columns, and rate-card keys), SPEC-006 v0.9.8 (buyer API; §1.3 conversation-key derivation + survivability (b) carve-out), SPEC-008 v0.4.1 (Tier-2 trust; §2.2 invariant (b) carve-out permitting the provider-visible derived conversation_key), SPEC-018 v0.2.4 (tool calling)

**Change log v0.2.1 (2026-07-12, billing ownership handoff to SPEC-005 v0.6):**
- **SPEC-024 §4 (ledger schema), §5 (rate card), and §6 (formula) — the billing ARITHMETIC — are
  SUPERSEDED by SPEC-005 v0.6** and retained here only as historical/reference text. SPEC-005 v0.6 is
  now the **canonical** owner of prefix-cache billing: the `cached_prompt_tokens` ledger column
  (§4.3), the `uncached@prompt-rate + cached@cache-hit-rate` formula split with the unset-rate ⇒
  full-prompt-rate default and the `0 <= cache_hit_rate <= prompt_rate` ceiling (§5.3 / §5.3.1), the
  eligibility gates (sticky-hit / first-attempt / `ambiguous_cache` / `invalid_cached_prompt_tokens`
  quarantine, §5.3.1), and the `prompt_cache_hit_credits_per_mtok` rate-card key (§13). Where §4–§6
  below and SPEC-005 v0.6 differ, **SPEC-005 v0.6 governs.**
- **SPEC-024 RETAINS ownership** of the surfaces SPEC-005 does not restate: the provider **wire
  field** `cached_prompt_tokens` (§3, the SPEC-002 usage-object addendum), the **buyer-visible**
  `cached_prompt_tokens` mirror (§8, the SPEC-006 response addendum), and the fraud model (§7). These
  are wire/API contracts, not coordinator-ledger arithmetic; SPEC-005 v0.6 consumes the wire field
  and prices it but does not define it.
- SPEC-024 continues to **own** the provider-local cache-**isolation** invariant (§11–§16): cache
  keying, cross-account non-leakage, the coordinator cross-check semantics that the SPEC-005
  eligibility gates implement, and the ingest/deployment invariants.
- Dependency on SPEC-005 bumped v0.5 → v0.6.

**Change log v0.2 (2026-07-12, provider-local cache-isolation baseline — spec-only, reconciled to shipped code):**
v0.1 specified the *accounting* of a provider-reported `cached_prompt_tokens` but left the number's *provenance safety* unspecified: the entire provider-local KV/conversation cache keying, the cross-account isolation invariant, and coordinator cross-checking were deferred (§2/§7). v0.2 writes that missing normative baseline, matching the shipped Swift provider + Go coordinator + gateway.
- **§11 (cache-key / isolation invariant):** the provider-local cache is partitioned **solely by the coordinator-supplied `conversation_key`**, and reuse additionally requires an exact token-level longest-common-prefix (LCP ≥ 32) with matching `model_id` and quantization (`kvBits`) — codifying the shipped guards. The provider cache has **no account/buyer dimension of its own**.
- **§12 (account-namespacing — the load-bearing cross-component invariant):** cross-account isolation is inherited entirely from the requirement that `conversation_key` be **unforgeable and account-scoped before it reaches the provider or the coordinator sticky map** — shipped via the gateway's keyed HMAC derivation (`conv:` + unpadded-base64url(HMAC-SHA256(secret, scope‖`\n`‖account_id‖`\n`‖tag)), already normative in **SPEC-006 §1.3 / SPEC-008 §2.1**), public-ingress stripping of the `X-MacProvider-Internal-*` namespace, **and** the coordinator's operator/service-bearer gate on internal routing headers (which adds replay-resistance HMAC alone does not). v0.2's contribution is connecting this existing derivation to the cache-**isolation** property and reconciling the provider-visibility tension (next bullet) — not re-owning the derivation.
- **§12 provider-visibility reconciliation (cross-spec — RESOLVED via option (a)):** the shipped prefix-cache design **sends the derived `conv:` key to the provider** (cleartext relay and inside the Tier-2 encrypted plaintext), because provider-local KV caching needs a stable per-conversation key. This tensioned the prior SPEC-004 FR-SR-2 / SPEC-006 / SPEC-008 invariant that the provider cannot see `conv:`. **Resolution (operator decision, 2026-07-12): option (a) — ratify the shipped design.** The corpus is amended in this same change — **SPEC-004 v0.3.2** (FR-SR-2 provider-visibility carve-out), **SPEC-006 v0.9.8** (survivability invariant (b) narrowed), **SPEC-008 v0.4.1** (§2.2 invariant (b) narrowed) — now permitting the coordinator to provide the **derived, opaque, account-scoped** `conv:` key to the provider for prefix caching, under an explicit privacy disclosure: the provider learns a stable per-conversation identifier (the same cross-turn correlation sticky affinity already grants) but MUST NOT be able to recover the raw buyer tag or `account_id` (the HMAC is one-way), and captured network frames still contain no raw account/tag (Pillar B survivability, unchanged).
- **§13 (non-leakage threat model):** cache reuse MUST NOT cross a `conversation_key` boundary, and `cached_prompt_tokens` (buyer-visible, §8) plus TTFT MUST NOT become a cross-account prefix-content/timing oracle.
- **§14 (coordinator cross-check — the deferred §7 item):** resolves the v0.1 deferral; ties trust of a positive `cached_prompt_tokens` to `sticky_result == "hit"` and flags two shipped gaps the coordinator MUST close: the sticky-Lookup account-scope gap (account compared only on write, not on the routing read path — FR-CI13) and the **queued-routing final-provider provenance** gap (the slot-queue `enterBest` path can carry a stale `sticky_result == "hit"` after admitting a different provider — FR-CI11a).
- **§15 (ingest paths without a fronting gateway):** direct/Tier-2/cleartext ingest accept `conversation_key` with **no provider-side account binding** (the value is trimmed and FR-CI1-validated — an invalid key becomes *absent* and disables caching — so it is not blindly *verbatim*, but no **account** dimension is added); v0.2 states the deployment invariant these paths must preserve.
- **§16 (acceptance criteria):** adds the missing **non-interference** test requirement (no shipped test drives two distinct keys/accounts against one cache).
- **R2-audit reconciliation (2026-07-12, spec-only).** Second codex 3-lane pass (code/security/architect) confirmed option (a) resolved but flagged incomplete carve-out reconciliation and new fidelity gaps; all C/H/M addressed: **§14 FR-CI11a** documents the queued-routing final-provider provenance gap (`slot_queue.go enterBest`); **§13 FR-CI10a** records the provider-receipt/retention + cross-provider-linkability **disclosure-completeness** items; **§15** distinguishes the three shipped ingest transport shapes (relay top-level field / Tier-2 envelope field / direct-HTTP `X-MacProvider-Provider-Conversation` header); citations corrected (SPEC-008 §2.1 for the derivation, SPEC-006 §5.4/§5.4.1 for the coordinator origin gate); FR-CI1/CI2 and the §16 coverage inventory reconciled to the actual shipped tests (Unicode/grapheme trim semantics; LRU/route/range **are** tested but shallowly; partial-trim + queued-provenance untested).
- **R3-audit reconciliation (2026-07-12, spec-only).** Third 3-lane pass verified every R2 fix against code (code lane 0 C/H/M) and caught residual stale-text occurrences the R2 sweep missed, all fixed: **SPEC-008 §2.2** normative-preservation rule (ciphertext "carries only the body" → now includes the authorized `conversation_key` envelope, closing the shared byte-fidelity HIGH at its last location); **SPEC-004 §1 mission + §2 scope** (top-level "no provider-wire-change / no provider-managed cache" carved out to match FR-SR-2/§6); **SPEC-006 §5.4.1** ASCII→Unicode trim (matching § 1.3); **SPEC-006 §1.3** buyer-deletion lifecycle addressed for the not-directly-purgeable provider KV (the R3 wording "indirect: sever routing + TTL" **was itself an overstatement, superseded by R4** — see the R4 bullet below and current FR-CI10a); **§2 tool-billing** corrected to shipped reality (the discount applies to the whole `cached_prompt_tokens` aggregate **including** rendered tool history — no role segmentation, `formula.go` — v0.1's "tool-call replies out of scope" retired); **§12** trust-delta no longer understated (provider receipt/retention is genuinely new under (a)); FR-CI10a disclosure citation §5.4→§5.3.1; §16 retry-gate coverage overclaim corrected.
- **R4/R5-audit corrections (2026-07-12, spec-only).** R4: FR-CI10a rewritten to the honest buyer-deletion position (deterministic key + post-delete same-provider re-population ⇒ deletion is neither a direct nor reliable indirect provider-cache purge; only bound is provider TTL/LRU). R5: made the **provider-report vs billing-eligibility layering** explicit in **§3 / FR-CI3 / FR-CI11** — `cached_prompt_tokens` is the provider's report of *actual reuse* (it never sees `sticky_result`), so a positive value on a non-sticky-hit route (e.g. the FR-CI10a same-provider return) is **legitimate but non-creditable**, and the coordinator's `ambiguous_cache` quarantine is a billing-eligibility decision, **not** a provider wire violation. SPEC-006 §1.3 terminal ship-guard carved for the ratified option-(a) residual.
- **R6-audit correction (2026-07-12, spec-only).** Swept the report/eligibility layering into its sibling locations: **§2** (cross-provider-handoff bullet) and **§7** (fraud model) still framed a positive non-hit provider report as a provider obligation to report 0 / a "wire-contract violation"; both reworded to the coordinator-normalization framing (legitimate actual reuse, non-creditable via `ambiguous_cache`, not a provider violation). The malformed-value quarantine (negative / >prompt_tokens / non-integer) is kept distinct as a genuine invalid-value case.

**Change log v0.1 (2026-07-02, prefix-cache billing design):**
- **Prefix-cache reuse meaning.** Prefix-cache reuse means the same provider that served conversation turn N also serves turn N+1 through SPEC-004 sticky affinity and can skip prefill work for an exact canonical prefix of the new prompt that was already materialized in provider-local KV cache.
- **Wire-shape delta.** The coordinator-provider completion usage object gains one optional integer field: `cached_prompt_tokens`.
- **Ledger schema delta.** `ledger_request_credits` gains one nullable insert-only integer column: `cached_prompt_tokens`.
- **Formula delta.** The rate-card row shape gains one integer field, `prompt_cache_hit_rate_per_mtok`, and prompt billing / buyer debit splits prompt tokens into uncached tokens at the normal prompt rate plus cached tokens at the cache-hit rate.
- **Buyer-visible delta.** The SPEC-006 response usage object gains one flat integer field: `cached_prompt_tokens`, sourced from the same effective value used for ledger arithmetic and credit-denominated buyer billing.

## 1. Scope

> **⚠ Billing ARITHMETIC moved to SPEC-005 v0.6 (v0.2.1).** The prefix-cache billing **arithmetic**
> below — the `cached_prompt_tokens` ledger column, the rate-card `prompt_cache_hit_credits_per_mtok`
> key, the cache-split formula, and the eligibility gates — is **canonically owned by SPEC-005 v0.6**
> (§4.3 / §5.3 / §5.3.1 / §13). SPEC-024 still **owns** the `cached_prompt_tokens` **provider wire
> field** (§3, SPEC-002 addendum) and the **buyer-visible** mirror field (§8, SPEC-006 addendum),
> plus the fraud model (§7) and the cache-**isolation** baseline (§11–§16). The billing-arithmetic
> descriptions in §4–§6 are retained for history; where they differ from SPEC-005 v0.6,
> **SPEC-005 v0.6 governs.**

SPEC-024 (v0.1) specified the billing treatment for provider-reported prefix-cache reuse on sticky-affinity conversations (SPEC-004 FR-SR-*): a provider-reported `cached_prompt_tokens` field on the coordinator-provider usage report (SPEC-002, §3), a `cached_prompt_tokens` column on `ledger_request_credits` (§4), an additive rate-card row field (§5), a cache-split billing / buyer-debit formula (§6), and a mirror field in the buyer-visible OpenAI-shape usage object (SPEC-006, §8). **The ledger/rate/formula arithmetic (§4–§6) is now specified by SPEC-005 v0.6** (see banner above); the **provider wire field (§3)** and **buyer-visible mirror (§8)** remain SPEC-024's canonical SPEC-002/006 addenda. The §4–§6 descriptions here are historical.

**v0.2 adds the provider-local cache **isolation** baseline (§11–§16):** the normative cache-key/reuse invariant, the cross-account `conversation_key` unforgeability/namespacing invariant that isolation depends on, the non-leakage threat model, the coordinator cross-check of `cached_prompt_tokens`, and the acceptance criteria — because the discounted cache-hit price and the buyer-visible `cached_prompt_tokens` are only sound if cache reuse cannot cross a buyer/conversation boundary. v0.2 is spec-only and reconciled to shipped code; it specifies the isolation *invariant*, not the provider KV-cache implementation (still §2).

## 2. Out of Scope

- KV-cache implementation **internals** on the provider are out of scope. SPEC-024 defines the reported `cached_prompt_tokens` semantics and (v0.2, §11) the **observable cache-key/reuse invariant**; the mlx-swift cache pinning, materialization, and eviction *mechanism* between `generate()` calls remain IMPL concerns and SPEC-024 MUST NOT prescribe internal mlx APIs. (v0.2 pins the *behavior* — what may be reused for which key — not the mechanism.)
- ~~Cache-hit fraud detection algorithms are out of scope. Section 7 defines the v0.1 fraud model and defers cross-checked coordinator verification to v0.2.~~ **(v0.2: resolved.)** Coordinator cross-checking of `cached_prompt_tokens` is now in scope — §14. Specific ML-based anomaly-scoring *algorithms* remain out of scope; §14 pins only the deterministic route/attribution gates the coordinator already applies.
- Cross-provider KV-cache handoff is out of scope. A request that does not route through a sticky hit earns **no** cache discount — but this is the **coordinator's** billing-eligibility decision, **not** a provider wire obligation: the provider reports its *actual* reuse (FR-CI3) without seeing `sticky_result`, so a positive non-hit report is legitimate-but-non-creditable and is **quarantined** `ambiguous_cache` (shipped credit effect — whole-row-zero or recovery flag-only — is canonical in SPEC-005 §2.7 / §5.3.1), not a wire violation (§3 layering / FR-CI11).
- **Tool-call replies (reconciled to shipped billing, v0.2).** The v0.1 draft said prefix-cache reuse for tool-call replies was "out of scope" and that accounting was "restricted to system, user, and assistant message-content prefixes." **That is NOT what shipped, and v0.2 supersedes it.** The provider renders tool messages and assistant tool-call content into the prompt (`ToolPromptRenderer`, `ModelRuntime.swift`), that full rendered prompt (`prompt_token_ids ‖ generated_token_ids`) is tokenized and cached (§11 FR-CI3), and the coordinator prices the **entire undifferentiated `cached_prompt_tokens` aggregate at the cache-hit rate with no message-type/role segmentation** (`phase4-coordinator/internal/billing/formula.go`). So tool-history tokens **do** participate in the cache LCP **and do** receive the discount. There is no shipped role filter; v0.1's "tool-call replies out of scope" is retired. (Out-of-scope items below are the ones that remain genuinely excluded.)
- Buyer-side cache-hint headers are out of scope. Buyers MUST NOT send `X-MacProvider-Expect-Cached-Prefix` or an equivalent v0.1 hint. Providers are the source of truth for actual cache reuse; buyers observe `usage.cached_prompt_tokens`.
- Rate-card hot reload for the new field is out of scope. SPEC-005 Wave 0/1 work continues to govern hot-reload semantics. v0.1 IMPL MAY require coordinator restart to activate `prompt_cache_hit_rate_per_mtok`.

> **⚠ SUPERSEDED (v0.2.1): the billing ARITHMETIC in §4 (ledger) / §5 (rate card) / §6 (formula) is
> now owned by SPEC-005 v0.6.** That text is retained for history; where it differs from SPEC-005 v0.6,
> **SPEC-005 v0.6 governs**. **§3 (the provider wire field) and §8 (the buyer-visible mirror) are NOT
> superseded** — they remain SPEC-024's canonical SPEC-002 / SPEC-006 addenda for `cached_prompt_tokens`,
> which SPEC-005 consumes but does not define. §7 (fraud model) and §11–§16 (cache isolation) also
> remain live SPEC-024 scope.

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
- **Layering (v0.2, explicit).** `cached_prompt_tokens` is a **provider-reported** count of the KV reuse the provider actually performed (FR-CI3); the provider reports it **without** knowledge of the coordinator-internal `sticky_result` (SPEC-004 exposes only `conversation_key` to the provider, not the sticky outcome). `sticky_result` is **coordinator** routing state. The two rules below are therefore **coordinator-side billing-eligibility normalization**, not provider wire obligations — a positive provider report on a non-hit route is **legitimate** (see FR-CI10a: post-deletion normal selection can return to the same provider under the deterministic key and genuinely reuse KV), just **non-creditable**.
- When `sticky_result = "hit"`, a positive provider-reported `cached_prompt_tokens` is **creditable** (discounted).
- When `sticky_result != "hit"` (`miss`, `disabled`, `no_key`, `evicted`, or other non-hit values), the coordinator MUST treat `cached_prompt_tokens` as `0` for **all** credit/billing/buyer-visible purposes, **regardless of any positive raw value the provider reported** — the reuse is non-creditable because its provenance is not sticky-attributable.
- A positive provider-reported `cached_prompt_tokens` on a non-hit route MUST quarantine the ledger write with `quarantined=1`, `quarantine_reason='ambiguous_cache'`, `cached_prompt_tokens=NULL`, and the `usage_source` value that would have applied absent the ambiguous-provenance normalization (`provider_reported` or `byte_estimated`). The row MUST set payable credit fields to 0 and MUST NOT produce provider-creditable credits. **This quarantine is a billing-eligibility decision (ambiguous provenance), not an assertion that the provider misreported** — the provider correctly reported actual reuse it could not attribute to a sticky outcome.
- `cached_prompt_tokens > prompt_tokens`, negative `cached_prompt_tokens`, or non-integer `cached_prompt_tokens` is a genuinely **malformed** value (unlike the non-hit case above, which is legitimate-but-non-creditable) and MUST quarantine the ledger write with `quarantined=1`, `quarantine_reason='invalid_cached_prompt_tokens'`, `cached_prompt_tokens=NULL`, and the `usage_source` value that would have applied absent the invalid-value quarantine (`provider_reported` or `byte_estimated`). The row MUST set payable credit fields to 0 and MUST NOT produce provider-creditable credits.

**(Shipped-behavior caveat, v0.2.1 — applies to BOTH quarantine bullets above.)** The "MUST set
payable credit fields to 0" rule is the *intended* invariant, but the coordinator's **recovery
flag-only** quarantine subpath (applied to a **pre-existing** ledger row for *either*
`ambiguous_cache` *or* `invalid_cached_prompt_tokens`, and also for the `invalid_usage_tokens`
out-of-range case) changes only the quarantine marker/reason/timestamp and **preserves all existing
money and cache fields** — it does **not** zero a pre-existing row's stored credits. So the zero-payable
rule is not uniformly enforced across all shipped write shapes. The canonical accounting of the four
write shapes, this deviation, and its carried fix live in **SPEC-005 §2.7**.

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

Current SPEC-005 v0.5 base numerator (formula unchanged from v0.4):

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

Provider-reported cached tokens on a non-sticky-hit route are **non-creditable** and MUST be quarantined (`ambiguous_cache`) per Section 3. This is **not** a provider wire-contract violation: the provider reports the actual reuse it performed (FR-CI3) and cannot see the coordinator-internal `sticky_result`, so a positive non-hit report (e.g. the FR-CI10a post-deletion same-provider return under the deterministic key) is legitimate but non-creditable. The shipped coordinator **quarantines** such a row (`ambiguous_cache`; whole-row-zero on the hot-path/receipt paths, flag-only on recovery — canonical: SPEC-005 §2.7 / §5.3.1), rather than merely re-pricing it with `cached = 0`. Either way it is not a revenue-increasing fraud vector, because the cache discount only ever **reduces** payable credits (§5 ceiling `0 <= cache_hit_rate <= prompt_rate`).

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
under a different key K′. `conversation_key` uses the SPEC-004 `conv:<opaque-id>` namespace; the shipped provider
validator (`ChatCompletionRequest.validConversationKey`) additionally requires the `conv:`
prefix, length > 5 (Swift `String.count`, i.e. **extended grapheme clusters**, measured after
trimming Foundation `.whitespacesAndNewlines` — not a byte or scalar count, so a reimplementation
counting bytes/scalars or trimming only ASCII whitespace can diverge on non-ASCII input),
≤ 256 UTF-8 bytes, and every Unicode scalar ≥ U+0020 **except U+007F**
(i.e. it rejects C0 controls and DEL but **does not** restrict to printable ASCII — non-ASCII
Unicode ≥ U+0020 is accepted). Note the provider dictionary compares keys by Swift **string
canonical equivalence**, so canonically-equivalent Unicode (e.g. composed vs decomposed `é`)
collapses to one entry despite differing UTF-8 bytes — irrelevant under the ASCII gateway-HMAC
keys, but load-bearing on non-FR-CI5 ingest (§15). The provider treats the key as an opaque,
already-scoped token (§12) — it MUST NOT parse or attribute it.

**FR-CI2 (reuse predicate).** Even on a key hit, a provider MUST reuse cached KV only for the
**exact token-level longest common prefix** of the stored canonical prompt tokens and the
incoming prompt tokens, and MUST require: LCP ≥ a fixed minimum (shipped `lcpThreshold = 32`
tokens), LCP `<` the incoming prompt length (a full-prompt match is not a reuse event),
identical `model_id`, and identical quantization (`kvBits`). A mismatch on model or `kvBits`
MUST yield a cache **miss**, not a partial reuse. Additionally (shipped guards): every KV
layer MUST be *trimmable* and each `trim` MUST remove exactly the requested token count, else
the request is a **miss** (enforced at runtime in `ConversationCache.swift`; the current
`ConversationCacheTests` cover the fully-**non-trimmable** rejection path, **not** a
partial/incorrect trim-count case — see the §16 coverage note; a partial-trim regression test
is a MUST-add). Because reused KV corresponds to *identical
tokens*, reuse preserves **model semantics conditional on identical sampler/RNG state** — the
per-position logits/KV are equivalent to a cold prefill. It does **not** guarantee
bit-for-bit identical *sampled output*: the shipped default is stochastic sampling
(`temperature = 1.0`, and the parsed `seed` is not wired into generation), so warm and cold
runs of a stochastic request will differ. Reuse is a performance optimization with no effect
on the *distribution* of output, not a determinism guarantee.

**FR-CI3 (canonical prefix).** On a served turn the provider commits the canonical prefix as
`prompt_token_ids ‖ generated_token_ids` (shipped: always both, not an optional extension).
The prompt token IDs are the provider's rendered prompt **including any tool messages and
assistant tool-call content** — the shipped tokenizer renders tool history into the prompt and
caches it (**a drift from v0.1 §2's "tool-call replies out of scope"; v0.2 records the shipped
reality**). `cached_prompt_tokens` reported per §3 MUST equal `min(LCP, incoming_prompt_tokens)`
for the reused turn (see §5–§6 for pricing); it is a **token count**, never a byte count. This
is the provider's report of the **actual reuse it performed**, independent of routing
provenance — the provider does not see `sticky_result`; whether that reuse is *creditable* is a
separate coordinator-side decision (§3 layering / FR-CI11).

**FR-CI4 (lifecycle bounds).** The cache MUST bound reuse-**eligibility** (shipped: a TTL,
default 900 s, and LRU eviction on a per-provider conversation-count cap and total-token cap).
The shipped TTL sweep is **lazy** — it runs only on the next `begin()`, so an idle process MAY
physically retain expired KV in memory beyond the TTL until the next request; *eligibility* is
TTL-bounded even though *physical retention* is not. These bounds are IMPL-tunable; the
*invariant* is that no prefix is reused past its `conversation_key` entry's eligibility, and
eviction never moves a prefix across keys.

**FR-CI4a (same-key serialization).** Overlapping operations on a single `conversation_key`
MUST be serialized — a provider MUST NOT concurrently mutate or reuse one key's cache entry
(shipped: an exclusive per-key lease held from `begin()` until `commit`/`abort`,
`ConversationCache.swift`). This pins the observable ordering rule; it does not prescribe the
Swift `actor`/lease mechanism (§2).

This section pins observable behavior, not the mlx mechanism (§2).

## 12. Cross-account namespacing invariant (v0.2) — load-bearing

Because §11's cache has no account dimension, **all** cross-account isolation rests on a
single upstream invariant, which v0.2 makes normative:

**FR-CI5 (unforgeable, account-scoped key).** By the time a `conversation_key` reaches a
provider or the coordinator sticky map, it MUST be **account-scoped and unforgeable** — a
value that no buyer can choose or collide with another account's value. This derivation is
**already normative in SPEC-006 §1.3 / SPEC-008 §2.1**; SPEC-024 references it and does not
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
unforgeability, not replay-resistance — SPEC-006 §5.4 / §5.4.1 states the coordinator
gate: `X-MacProvider-Internal-Conv` is honored only on authenticated/network-restricted
gateway-originated traffic and never from direct buyer traffic). A
deployment MUST preserve both: the account-scoped key is set exclusively by trusted
infrastructure and honored only on authenticated gateway-origin traffic.

**FR-CI7 (wire survivability, with a provider-runtime caveat).** The account-scoping input
(`account_id`) MUST remain in the key derivation and MUST NOT be strippable downstream. At the
**wire** level this preserves SPEC-008 Pillar B survivability: captured provider-leg frames
contain no raw `account_id` or raw buyer tag. The provider **runtime** does receive the
**derived** `conv:` key in cleartext (relay path) or inside the decrypted Tier-2 plaintext
(`Tier2ProviderSession.swift`), so it learns a stable per-conversation identifier. As of the
option-(a) resolution (§12), this is **explicitly permitted** by the amended SPEC-004 v0.3.2
FR-SR-2 / SPEC-006 v0.9.8 / SPEC-008 v0.4.1 §2.2 invariant (b): the derived opaque key MAY be
provider-visible for prefix caching, provided the raw tag/`account_id` remain unrecoverable
(one-way HMAC) — which FR-CI5/CI7 guarantee.

**Provider-visibility reconciliation (RESOLVED — option (a), 2026-07-12).** Provider-local
prefix caching (SPEC-024's entire premise) requires a stable per-conversation key at the
provider; the shipped design supplies the derived `conv:` key. This tensioned the prior
provider-nonvisibility invariant in SPEC-004/006/008. The operator chose **option (a): ratify
the shipped design**, and the corpus is amended in this same change:
- **SPEC-004 v0.3.2** FR-SR-2 — provider-visibility carve-out: the coordinator MAY forward the
  derived, opaque, account-scoped `conversation_key` to the provider for prefix caching.
- **SPEC-006 v0.9.8** — survivability invariant (b) narrowed to "raw tag/`account_id`
  unrecoverable + not side-channel-derivable" while permitting the derived key in the
  inference request.
- **SPEC-008 v0.4.1** §2.2 invariant (b) — same narrowing; the inference `conversation_key`
  field is the single authorized provider-visible channel for the derived value; error/close/
  preflight/attestation paths still MUST NOT reveal it.

The disclosed privacy trade-off: the provider learns a **stable per-conversation identifier**
and can correlate that conversation's turns (the correlation SPEC-004 sticky affinity
already grants by pinning the conversation to one provider), but **cannot** recover the raw
buyer tag or `account_id` (one-way HMAC), and captured network frames still carry no raw
account/tag. **Cross-provider linkability caveat:** the derived key is forwarded on cache
**misses** and **re-routes** too, not only on sticky hits, so over a conversation's life the
**same** identifier MAY reach **more than one** provider — slightly broader than the
single-provider correlation sticky affinity alone grants. This is the SPEC-006 §5.3.1
disclosure-completeness item (§13). §11–§16's isolation guarantees therefore hold at the wire/account-scoping layer,
and the residual trust assumption is: the provider is trusted to **hold (not exfiltrate)** the
opaque derived key. Note this **is a genuinely new trust delta** under option (a): pre-carve-out
sticky affinity kept the `conv:` value **coordinator-internal** (SPEC-004 §1 / prior SPEC-008
§2.2), so the provider did *not* previously receive or retain it — provider **receipt and
local retention are new consequences of (a)**, as FR-CI10a records. What is *not* new is the
cross-turn **correlation** capability (sticky affinity already let a provider correlate a
conversation's turns by serving them); (a) newly hands the provider a durable, stable
*identifier* for that correlation and a broader (cross-provider) surface.

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

**FR-CI10a (disclosure-completeness — MUST close).** The option-(a) carve-out gives the
provider a durable artifact and a broader correlation surface than the shipped buyer-facing
disclosure describes. Two consequences are **not yet disclosed** to buyers and MUST be added
to the SPEC-006 §5.3.1 `sticky_affinity` disclosure, `/v1/models tier1_disclosure`, and
`disclosure.go`:
- **(i) Provider receipt + independent, non-buyer-purgeable retention.** The provider
  **receives** the derived opaque conversation identifier and **retains** it in a provider-local
  KV cache under its own TTL/LRU (§11 FR-CI4). `DELETE /v1/sticky` purges only the **coordinator
  sticky map**, not this provider-local entry. Deletion is **not** even a reliable *indirect*
  purge: the derived key is **deterministic** (same account+tag ⇒ same `conv:`), and post-delete
  **normal** selection (SPEC-004 FR-SR-3) MAY still route to the same provider, which then
  reuses and **re-populates** the entry under the same key — so the provider entry's only
  dependable bound is its own TTL/LRU, and no buyer-triggered provider-side purge primitive
  exists (SPEC-006 §1.3 lifecycle residual gap; closing it needs a provider-side conv-key purge,
  not shipped). Note this bound is on reuse **eligibility**, not guaranteed **physical**
  deletion: the shipped TTL sweep is lazy (FR-CI4), so expired KV MAY physically persist in
  process memory past its TTL until the next `begin()`. Buyer-facing disclosure copy MUST NOT
  imply guaranteed physical erasure at TTL.
- **(ii) Cross-provider linkability.** Because the derived key is forwarded on cache **misses**
  and **re-routes**, the same stable identifier MAY reach **more than one** provider across a
  conversation's life — broader than the single-provider correlation sticky affinity alone
  grants (§12 cross-provider linkability caveat).
The current disclosure (preferential routing + single-provider correlation) is accurate but
**incomplete** for (i)–(ii). v0.2 records this as a tracked completeness gap, not a silent
omission; extending the disclosure copy is a follow-up (buyer-facing string + `disclosure.go`).

## 14. Coordinator cross-check of `cached_prompt_tokens` (v0.2)

This section resolves the v0.1 §7 deferral with the **deterministic** gates the coordinator
already applies (`phase4-coordinator/internal/billing/hotpath.go`, `normalizeCachedPromptTokens`);
ML-based anomaly scoring remains out of scope (§2).

**FR-CI11 (route gate — a billing-eligibility gate, not a wire rule).** A positive
`cached_prompt_tokens` MUST be accepted for the discounted price only when the request was
served on a **sticky hit** (`sticky_result == "hit"`). A positive value on any non-hit route
MUST be quarantined (`ambiguous_cache`). This gate operates on the **coordinator** side: the
provider reports the actual reuse it performed (FR-CI3) without seeing `sticky_result`, so a
positive report on a non-hit route (e.g. the FR-CI10a post-deletion same-provider return under
the deterministic key) is a **legitimate, non-creditable** reuse — not a provider violation.
**Shipped credit effect (canonical: SPEC-005 §2.7 / §5.3.1):** the coordinator does **not**
merely re-price the row with `cached = 0` (keeping the uncached-prompt + completion credit); the
`ambiguous_cache` quarantine **zeroes the whole row** on the hot-path / receipt-time paths (a
recovery-path flag-only quarantine instead leaves stored credits intact — SPEC-005 §2.7). Whether
to withhold only the **discount** rather than the whole row is a carried SPEC-005 money-path
follow-up. FR-CI11's soundness depends on `sticky_result` describing the provider **actually
dispatched to** — see FR-CI11a.

**FR-CI11a (final-provider provenance — known shipped gap, MUST close).** `sticky_result`
MUST reflect the provider that ultimately served the request, not the provider sticky ordering
initially preferred. The **normal** selection path enforces this (it corrects a stale
sticky hit when preflight selects another provider,
`internal/buyer/server.go` `selectProviderExcluding`). The **slot-queue** path does **not**:
it computes sticky ordering, then `enterBest` (`internal/buyer/slot_queue.go`) MAY admit a
**different** provider with a shorter queue while the original `stickyResult == "hit"` is
carried unchanged (`internal/buyer/server.go`), and billing then trusts that stale state
(`internal/buyer/billing_recorder.go`). A positive `cached_prompt_tokens` can therefore be
discounted after a **non-sticky final selection** on the queued path. The account-scoped HMAC
keeps this from becoming a *cross-account* oracle (the different provider still only has its
own account-scoped keys), so it is a **billing-attribution** defect, not an isolation breach.
v0.2 records it as a shipped gap the coordinator MUST close by re-deriving `sticky_result`
against the **final** admitted provider on the slot-queue path before honoring the discount.

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

The provider accepts `conversation_key` on **three distinct transport shapes**, all with **no
provider-side account binding** — a reimplementation that reads the wrong shape silently
disables caching:

1. **Cleartext WebSocket relay** — a **top-level JSON field** `conversation_key` on the
   `inference_request` message (`InferenceRelay.swift`; coordinator seals it at
   `relay.go` `sealInferenceRequest`).
2. **Tier-2 encrypted leg** — inside the decrypted `inference_request_plaintext` **envelope**
   `conversation_key` field, never in AAD/outer metadata (`Tier2ProviderSession.swift`;
   SPEC-008 v0.4.1 §6.6).
3. **Direct HTTP** (`POST /v1/chat/completions` straight to the provider) — the
   `X-MacProvider-Provider-Conversation` **request header** (`HTTPServer.swift`); the request
   **JSON body** parser does **not** carry the key (it initializes as absent,
   `ChatCompletionRequest.swift`), so on this path the header is the only channel.

On all three the value is trimmed and passed through the FR-CI1 prefix/length/scalar
validation — an invalid key becomes *absent* and disables caching, so it is not blindly
*verbatim* — but no **account** dimension is added. This is safe **only** while every buyer
request passes through the FR-CI5 deriving gateway first.

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
- **AC-CI-5 (route/retry/range gates).** Three distinct outcomes per §14 / SPEC-005 §5.3.1:
  (1) a positive `cached_prompt_tokens` on a **non-hit route** is **quarantined** `ambiguous_cache`;
  (2) a value **out of `[0, prompt_tokens]`** is **quarantined** `invalid_cached_prompt_tokens`;
  (3) a positive value on a **retry** (`attempt_n > 0`) is **NOT quarantined** — it is **nulled and the
  row is priced at the full prompt rate** (`hotpath.go`). In all three the cache discount is never
  applied; for the two quarantine cases the shipped credit effect is path-dependent (canonical:
  SPEC-005 §2.7).
- **AC-CI-6 (reuse-equivalence, deterministic).** With **deterministic decoding** (fixed
  sampler + pinned RNG state, e.g. `temperature = 0` or a wired seed), a conversation produces
  identical completion output whether or not prefix-cache reuse occurred; equivalently, per-position
  logits/KV are equal with and without reuse. Under stochastic sampling the AC MUST assert
  *distributional* equivalence, not byte equality (FR-CI2).

**Coverage note (v0.2 — reconciled to the actual shipped test suite).** *What is tested:* the
shipped provider tests (`ConversationCacheTests`) lock reuse *correctness* — LCP,
model/`kvBits` swap → miss, fully-non-trimmable → miss, TTL expiry, LRU and token-cap
eviction, and cached-token clamping — and the coordinator Go tests exercise the
`normalizeCachedPromptTokens` **route** (sticky-hit / non-hit) and **range** gates (FR-CI11/CI12)
on the normal (non-queued) path (`internal/billing/store_test.go`). The **retry** gate
(FR-CI12 `attempt_n > 0` → null) is only partially covered: the shipped attempt-one test
inherits a `testHotPathInput` whose cached-token field is nil, so **no test combines a
*positive* `cached_prompt_tokens` with `attempt_n > 0`** — the retry-null path with a non-nil
value is a MUST-add. *What is NOT tested (the real gaps, MUST-add):* (1) cross-key/cross-account
non-interference (AC-CI-1) — the LRU test drives three keys through one cache but asserts only
**aggregate** entry/token counts, **not which specific LRU key was evicted** nor that key K′
returns a cold result while key K is warm; (2) the sub-32 LCP / full-prompt miss paths
(AC-CI-2); (3) the **partial/incorrect trim-count** rejection (only the fully-non-trimmable
case is covered — FR-CI2); (4) cold-vs-warm reuse-equivalence (AC-CI-6); (5) the
**queued-routing final-provider provenance** gap (FR-CI11a — no test drives a slot-queue
re-selection with a carried `sticky_result == "hit"`); (6) FR-CI13 read-path account compare
on a non-FR-CI5 topology; (7) FR-CI14 reuse-disable on buyer-chosen-key paths. Closing these is
a v0.2 IMPL deliverable. (The earlier draft mislabeled TTL/LRU/token-cap and coordinator
route/range normalization as untested; they exist — the accurate gap is *depth* of the LRU/trim
assertions and the queued-provenance + cross-key cases above.)
