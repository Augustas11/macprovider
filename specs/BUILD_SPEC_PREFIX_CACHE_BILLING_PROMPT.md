# BUILD_SPEC — Prefix-cache billing (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing anything.**

Your job is to author a NEW SPEC (next available number — SPEC-024 as of this writing, verify against `ls specs/SPEC-*.md`) at **v0.1 design-only** that closes the billing-side half of Cluster C #5 "Conversation prefix-cache reuse" from `audits/2026-06-22/CLUSTER_HANDOFF.md`.

**The routing-side half already shipped** in PR #302 as part of SPEC-004 Pillar A: `X-MacProvider-Conversation` (buyer) → gateway HMACs with `account_id` → `X-MacProvider-Internal-Conv` (coord) → bounded TTL + LRU sticky map at [phase4-coordinator/internal/routing/sticky/sticky.go](phase4-coordinator/internal/routing/sticky/sticky.go) pins conversation N+1 to the same provider that served turn N. That's the prerequisite. What's missing is the buyer-visible economic reward: when the sticky provider actually reuses its warm KV-cache, the buyer's request should be billed at a REDUCED prefill rate for the cached-prompt-tokens fraction.

**This is money-path.** SPEC-005 rate-card + ledger schema + coordinator-provider wire + buyer-visible usage object all get touched. Three-lane codex audit discipline applies (see §"Audit-loop discipline" below). SPEC v0.1 is design-only; IMPL is a separate follow-up.

## Pre-flight: verify the gap before writing anything

Before writing a single line of SPEC, confirm these against the current tree:

1. `grep -rn 'cached_prompt_tokens\|prompt_cache\|cache_hit\|prefill.*discount\|cached_tokens' phase3-binary phase4-coordinator phase5-gateway --include='*.swift' --include='*.go'` → should return zero substantive matches. If any prior prefix-cache billing work exists, surface it.
2. Read `specs/SPEC-005-billing.md` line 3 (current locked version — was v0.4 as of last sweep) and note the exact version. Read §"D10 attempt_n" (~line 456) and the formula at line 779 — that's the base you're extending.
3. Read `specs/SPEC-004-smart-router.md` line 3 (current locked version). Note the sticky-affinity contract (`internal/routing/sticky/sticky.go` package doc at line 1 cites SPEC-004 §FR-SR-2 through §FR-SR-6).
4. Read `phase4-coordinator/internal/routing/log.go:32-129` — the sticky observability event fields (`sticky_result: hit|miss|updated|evicted|disabled|no_key`, `sticky_miss_reason`). SPEC-024 MUST extend this event with `cached_prompt_tokens` at billing-write time, not invent a parallel observability surface.
5. Read `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` around the two `generate(input: lmInput, ...)` sites (~lines 437/521) and confirm today's flow: `let input = UserInput(chat: request.messages.map { $0.mlxMessage })` — nothing preserves KV-cache state across successive generate() calls. That's the provider-side work the IMPL will unblock; SPEC v0.1 defines the contract.
6. Verify `specs/SPEC-002-coordinator.md` and `specs/SPEC-006-buyer-api.md` locked versions (both need dependency bumps in SPEC-024's `Depends on:` line).

If any of #1–#6 is materially different from what this prompt assumes, STOP and surface the discrepancy.

## Repo conventions you MUST honour

- **House file:** `specs/SPEC-024-prefix-cache-billing.md` (or the next available integer). Line 3: `**Version:** 0.1 (YYYY-MM-DD, design-only draft)`. Line 4: `**Status:** Draft (design-only — no IMPL until v0.1 audit-clean lock).` Line 5: `**Depends on:**` SPEC-002 vX.Y (wire), SPEC-004 vX.Y (sticky), SPEC-005 vX.Y (billing), SPEC-006 vX.Y (buyer API), SPEC-018 vX.Y (tool calling — tool-call arguments make the prefix stable across turns, so mention).
- **Change log** at the top, newest first. v0.1 entry MUST include: what prefix-cache reuse means precisely (a normative sentence), the wire-shape delta (one new field), the ledger schema delta (one new column), the formula delta (rate-card row + arithmetic), and the buyer-visible delta (one new usage field).
- **Voice:** terse, normative, MUST / SHOULD / MAY per RFC 2119. No filler.
- **Naming:** `BUILD_SPEC_024_PREFIX_CACHE_BILLING_IMPL_PROMPT.md` is the IMPL prompt you will REFERENCE (do NOT create it).
- **One file only.** Do NOT bundle SPEC-002/004/005/006 amendments — file each cross-SPEC addendum as a separate follow-up.

## What v0.1 MUST normatively specify

### §1 Scope

One paragraph, roughly: "SPEC-024 specifies the billing treatment for provider-reported prefix-cache reuse on sticky-affinity conversations (SPEC-004 §FR-SR-*). It defines a provider-reported `cached_prompt_tokens` field on the coordinator-provider usage report (SPEC-002), a new `cached_prompt_tokens` column on `ledger_request_credits` (SPEC-005), an additive rate-card row `prompt_cache_hit_rate_per_mtok`, an updated billing formula that credits the cached fraction at the discounted rate, and a mirror field in the buyer-visible OpenAI-shape usage object (SPEC-006)."

### §2 Out of scope (call this out explicitly)

- **KV-cache implementation details on the provider.** SPEC-024 defines the reported `cached_prompt_tokens` semantics; how mlx-swift pins / reuses / evicts KV-cache blocks between successive `generate()` calls is an IMPL concern. The SPEC MUST NOT prescribe internal mlx APIs.
- **Cache-hit fraud detection.** See §7 (fraud model) — SPEC-024 v0.1 documents the perverse-incentive analysis (provider gets paid LESS when reporting more cached tokens, so no provider-side fraud vector exists at this layer) and defers cross-checked verification to v0.2.
- **Cross-provider KV-cache handoff.** A conversation that STICKY-MISSES to a new provider MUST report `cached_prompt_tokens = 0` for that request. No inter-provider cache migration in v0.1.
- **Prefix-cache reuse for tool-call REPLIES.** Tool-message content is buyer-supplied and doesn't share a stable canonical form with previous turns; v0.1 restricts cache-hit accounting to system + user + assistant message-content prefixes.
- **Buyer-side cache-hint headers.** No `X-MacProvider-Expect-Cached-Prefix` or similar. The provider is the source of truth for what it cached; buyers observe the reported cache-hit in `usage.cached_prompt_tokens` and adjust their own economic modelling from there.
- **Rate-card hot-reload for the new row.** SPEC-024 additively defines the rate-card field; hot-reload semantics remain governed by the SPEC-005 Wave 0/1 work in flight (Entries 93–97). v0.1 IMPL MAY require a coordinator restart to activate the new row.

### §3 Wire contract (SPEC-002 addendum)

The provider reports `cached_prompt_tokens: <integer>` inside the standard usage object on the completion-side WS message. Constraints:

- `0 <= cached_prompt_tokens <= prompt_tokens` (MUST reject at coordinator if violated; classify as `usage_source = 'ambiguous_cache'` or similar and quarantine per SPEC-005 quarantine machinery).
- When the request routed via sticky-hit (`sticky_result: hit`), `cached_prompt_tokens` MAY be positive.
- When `sticky_result != hit` (miss / disabled / no_key / evicted), `cached_prompt_tokens` MUST be `0` OR absent (treat absent as 0). Positive value on non-hit routes is a quarantine trigger.
- Field absence is legal and equivalent to 0 (v0.1 rollout: pre-IMPL providers won't send it; treat missing as no-cache-hit rather than error).

### §4 Ledger schema (SPEC-005 addendum)

Add exactly one column to `ledger_request_credits`:

```
cached_prompt_tokens INTEGER NULL CHECK(cached_prompt_tokens IS NULL OR (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens))
```

Insert-only. NULL means either legacy row (pre-v0.1) or non-hit route. Positive integer means sticky-hit route with N cached prompt tokens. Migration: additive column with NULL default. NO backfill.

### §5 Rate-card (SPEC-005 addendum)

Add exactly one field to the rate-card row shape:

```
prompt_cache_hit_rate_per_mtok INTEGER NOT NULL CHECK(prompt_cache_hit_rate_per_mtok >= 0 AND prompt_cache_hit_rate_per_mtok <= prompt_rate_per_mtok)
```

Constraint: MUST NOT exceed `prompt_rate_per_mtok`. A rate card that violates this constraint MUST fail the SPEC-005 config-validation gate.

**Default operator guidance:** target 25% of `prompt_rate_per_mtok` (mirrors OpenAI's cache-hit discount of ~50% shifted for the smaller Mac-native prefill savings). Document as guidance in the SPEC — the concrete rate is operator config, not normative.

### §6 Formula (SPEC-005 §D formula addendum)

Current (v0.4 line 779):
```
base_numerator = prompt_tokens * prompt_rate_per_mtok + effective_completion_tokens * completion_rate_per_mtok
```

New (v0.1):
```
uncached_prompt_tokens = prompt_tokens - COALESCE(cached_prompt_tokens, 0)
base_numerator = uncached_prompt_tokens * prompt_rate_per_mtok
              + COALESCE(cached_prompt_tokens, 0) * prompt_cache_hit_rate_per_mtok
              + effective_completion_tokens * completion_rate_per_mtok
```

MUST be byte-identical to the v0.4 result when `cached_prompt_tokens IS NULL` OR `cached_prompt_tokens = 0`. Prove this in the SPEC by algebraic reduction — this is what makes the rollout safe.

The `usage_source = 'null_error'` NULL-guard from SPEC-005 v0.3.3 remains binding: if either `prompt_tokens` OR `completion_tokens` is NULL, formula MUST NOT evaluate (set all credit fields to 0). `cached_prompt_tokens` NULL is NOT the null-error case — it collapses to 0 in the new formula.

### §7 Fraud model (normative)

Analyze both directions honestly in the SPEC body:

- **Provider over-reports `cached_prompt_tokens`** → provider gets paid LESS (revenue = uncached × prompt_rate + cached × cache_hit_rate, where cache_hit_rate < prompt_rate). Perverse incentive works against the provider. **No provider-side fraud vector.**
- **Provider under-reports `cached_prompt_tokens`** (reports 0 despite genuine cache hit) → buyer pays MORE. Buyer's request routes through gateway with recorded prompt_tokens; buyer can compute expected cache-hit offline (previous turn's prompt_tokens + completion_tokens ≈ this turn's prompt prefix) and detect anomalies over time. v0.1 documents the observability path (log `cached_prompt_tokens=0` events explicitly so buyer-side analytics can flag providers with suspiciously low cache-hit rates on sticky-hit routes). Cross-checked coordinator-side verification deferred to v0.2 as an explicit follow-up.
- **Provider reports cached tokens on a non-sticky-hit route** → quarantine per §3. Not a fraud vector; a wire-contract violation.

### §8 Buyer-visible usage object (SPEC-006 addendum)

Add exactly one field to the response usage object per SPEC-006:

```json
"usage": {
  "prompt_tokens": 1500,
  "completion_tokens": 300,
  "total_tokens": 1800,
  "cached_prompt_tokens": 1200
}
```

Field name: `cached_prompt_tokens` (matches OpenAI's `prompt_tokens_details.cached_tokens` semantics but flattened, since SPEC-006 usage is flat today — flat vs nested is a v0.1 decision worth locking here rather than mirroring OpenAI structurally).

MUST be present on every completion response (even value 0) for buyer-side determinism, OR MUST be absent-equivalent-to-0 for rollout compatibility — pick ONE and document. Recommend: PRESENT with 0 on non-hit routes for buyer-side analytics friendliness.

### §9 Explorer surface (SPEC-007 addendum note)

The Explorer `/admin/explorer/sessions/*` views SHOULD surface `cached_prompt_tokens` next to `prompt_tokens` on request-detail rows for operator auditability. File as SPEC-007 v0.6 follow-up rather than inlining.

### §10 Rollout invariant

State explicitly: rows written pre-v0.1-IMPL have `cached_prompt_tokens IS NULL`; rows written post-v0.1-IMPL against pre-v0.1 providers have `cached_prompt_tokens IS NULL`; rows written post-v0.1-IMPL against v0.1-IMPL providers on sticky-hit routes have `cached_prompt_tokens >= 0`. The formula (§6) MUST produce v0.4-byte-identical numerator in the first two cases. This is the safe-rollout gate.

## What v0.1 MUST NOT do

- **No code.** This is design.
- **No new accounting primitives** beyond the one column + one rate-card field + one usage field. Do NOT introduce a parallel `ledger_cache_events` table or similar.
- **No cross-provider cache handoff design.** Explicitly out of scope per §2.
- **No hot-reload / rate-card migration mechanism.** Governed by the Wave 0/1 work.
- **No fraud-detection algorithm** beyond the analytical fraud-model in §7. v0.2 territory.
- **No SPEC bundling.** SPEC-002/004/005/006 addenda referenced in the change-log MUST be filed as separate follow-ups (issue stubs or short vX.Y+1 prompts).
- **No mlx-swift internals.** Provider-side KV-cache pinning is IMPL, not SPEC.

## Audit-loop discipline (money-path — three-lane, multi-round)

Per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-three-lane-codex-audits.md` and `feedback-spec-audit-loop-before-pr.md`: money-path SPEC. Every audit round is THREE independent codex invocations (code, security, architect). Converge until all three return 0 CRITICAL / HIGH / MEDIUM. LOW-only ships with PR-body documentation.

Expected first-round findings to pre-empt:

- Rollout invariant not proven algebraically (§10)
- Fraud model missing the under-reporting analytical path (§7)
- Wire-contract ambiguity: "field absent = 0" vs "field explicitly 0" — must pick one and pin
- Explorer surface not scoped as follow-up (SPEC-007 owns it, not SPEC-024)
- `cached_prompt_tokens > prompt_tokens` violation classification unclear (§3)
- Interaction with per-attempt credit (SPEC-005 v0.3.1 D-decision): does a re-attempt on the same conversation get cache-hit? SPEC MUST answer explicitly (recommend: NO — re-attempt routes fresh, cache-hit only on the FIRST successful attempt of a conversation turn)

Address each. This is what earns the money-path v0.1 lock.

## Deliverables

1. `specs/SPEC-024-prefix-cache-billing.md` at v0.1, audit-clean across all three lanes.
2. `beta/DECISION_CRITERIA.md` new Entry recording: SPEC-024 v0.1 locked, rate-card default (25% guidance) documented as operator config, rollout invariant proven, per-attempt no-cache-hit decision recorded.
3. PR opened against `main` with branch `spec/024-prefix-cache-billing-v0.1`. Use `GH_TOKEN=$(gh auth token -u Augustas11) gh pr create ...` per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/gh-pr-merge-augustas11-token-prefix.md`. Follow the antfleet-ops-approve → Augustas11-squash-merge pattern per `macprovider-no-required-reviewers-merge-pattern`.
4. A separate IMPL write-prompt is NOT bundled here. Name it `BUILD_SPEC_024_PREFIX_CACHE_BILLING_IMPL_PROMPT.md` as the documented next-step deliverable; do NOT write it in this session.

## Scope sanity check

If your SPEC draft exceeds ~500 lines you are over-designing. This is a single-column ledger addition + a single-field wire addition + a two-line formula update. The SPEC's job is to lock those three deltas with rollout safety proven, not to redesign the billing surface. Kill scope if you find yourself writing new sections beyond §1–§10 above.

**You are done when:** SPEC-024 v0.1 is merged on `main`, Decision-Criteria entry is in, and the IMPL prompt is named (not written) as the documented next step.
