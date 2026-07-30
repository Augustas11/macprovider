# BUILD_SPEC_024_PREFIX_CACHE_BILLING_IMPL_PROMPT

You are starting a fresh implementation session in the macprovider repo. You
have no memory of prior conversations. Read this prompt end-to-end before
writing code.

Your job is to implement **SPEC-024 prefix-cache billing** after the normative
SPEC is locked:

- Normative spec: `specs/SPEC-024-prefix-cache-billing.md`
- Prompt status at authoring time: SPEC-024 v0.1 is a design-only draft.
- Repo rules: `AGENTS.md` and `CLAUDE.md`.

SPEC-024 is money-path work. Follow the repo PR workflow: do not develop on
local `main`; use a feature branch or isolated implementation worktree; do not
inspect clean-room `d-inference` source.

## 0. Workspace And Hard Gates

Before editing anything, verify:

```bash
pwd
git status -sb
git fetch origin
ls specs/SPEC-024-prefix-cache-billing.md
```

Work on a feature branch or isolated worktree, never local `main`.

Hard gates:

1. If `specs/SPEC-024-prefix-cache-billing.md` is not present at HEAD, STOP:
   the SPEC-024 design has not landed in your implementation base.
2. If SPEC-024 is still marked `Draft`, `design-only`, or says "no IMPL until
   v0.1 audit-clean lock", STOP before implementation. This prompt is the
   implementation plan artifact; code implementation requires the locked
   audit-clean SPEC text.
3. If the locked SPEC has changed materially after this prompt was written,
   re-read it first and treat the locked SPEC as authoritative. Do not silently
   prefer this prompt over the SPEC.
4. If code inspection reveals a true SPEC ambiguity, stop and surface it as a
   SPEC follow-up. Do not resolve billing semantics by implementation choice.
5. Same-actor buyer-provider abuse must be handled explicitly, but this prompt
   must not silently narrow the locked SPEC's billing economics. If the locked
   SPEC accepts discounted v0.1 cache billing while deferring coordinator-side
   cross-checks, implement that contract exactly and document the risk,
   mitigation/acceptance posture, metrics, and launch controls in the PR. If the
   locked SPEC changes to require a mitigation or launch gate, implement that
   gate exactly.

## 1. Controlling Contract

Implement exactly the locked SPEC-024 contract:

- Provider completion usage may include optional integer
  `cached_prompt_tokens`.
- Coordinator validates the raw provider value against `prompt_tokens`,
  sticky result, and attempt number.
- `ledger_request_credits` gains one additive nullable insert-only
  `cached_prompt_tokens` column.
- Rate-card config gains `prompt_cache_hit_credits_per_mtok`; billing snapshots
  and formula rows expose `prompt_cache_hit_rate_per_mtok`.
- Prompt billing splits uncached prompt tokens at the normal prompt rate and
  cached prompt tokens at the cache-hit rate.
- Buyer-visible usage gains a flat `cached_prompt_tokens` field present on
  every SPEC-024-aware response, sanitized to `0` when absent, invalid,
  quarantined, legacy, non-hit, or retry-only.

Do not re-litigate the product decisions. The implementation author encodes the
SPEC.

## 2. Explicit Non-Goals

Do not implement these in SPEC-024 v0.1:

- No Explorer UI or request-detail changes. SPEC-024 §9 is a SPEC-007
  follow-up.
- No buyer cache-hint headers or buyer-provided cache assertions.
- No cross-provider KV-cache handoff.
- No tool-call prefix-cache accounting.
- No coordinator-side cache-fraud algorithm beyond the locked SPEC-024 fraud
  model, validation, logging, and any locked launch controls. Do not invent a
  hidden mitigation or disable discounted billing by prompt interpretation; any
  same-actor abuse mitigation, launch gate, or risk acceptance must be explicit
  in the locked SPEC or PR evidence.
- No gateway-side rate-card pricing authority. SPEC-005 coordinator billing is
  the sole credit-denominated buyer-billing authority.
- No token-quota refund for cache hits. SPEC-006 daily quota remains
  token-count based.
- No new billing tables for cache accounting. Use the one new nullable ledger
  column and existing SPEC-005 quarantine machinery.
- No clean-room `d-inference` source inspection.

Provider KV-cache internals are implementation territory, but the wire field is
truthful only when actual provider-local prefix reuse occurred. If the current
Swift/MLX runtime cannot safely prove reuse in v0.1, the provider must report
absence or `0` and the rest of the billing rollout must remain byte-identical.

## 3. Required Reading Before Coding

Read these files before implementation:

1. `specs/SPEC-024-prefix-cache-billing.md` end-to-end.
2. The current SPEC-002 normative file named by the spec index and SPEC-024's
   dependency line.
3. The current SPEC-004 normative file named by the spec index and SPEC-024's
   dependency line.
4. `specs/SPEC-005-billing.md`.
5. `specs/SPEC-006-buyer-api.md`.
6. The current SPEC-018 normative file named by the spec index and SPEC-024's
   dependency line.
7. Coordinator billing code:
   - `phase4-coordinator/internal/billing/{formula,hotpath,snapshot,store,recovery,endpoints}.go`
   - `phase4-coordinator/internal/buyer/{billing_recorder,forward_with_failover,forward_state,server}.go`
   - `phase4-coordinator/internal/buyer/{rate_card.go,server_test.go}`
   - `phase4-coordinator/internal/routing/log.go`
   - `phase4-coordinator/internal/routing/sticky/sticky.go`
   - `phase4-coordinator/internal/config/config.go`
8. Gateway usage and quota code:
   - `phase5-gateway/internal/router/chat_proxy.go`
   - `phase5-gateway/internal/storage/{types.go,sqlite/store.go}`
9. Provider response and runtime code:
   - `phase3-binary/Sources/macprovider-cli/{HTTPServer,InferenceRelay,ModelRuntime,CoordinatorClient}.swift`
10. Existing tests around billing formula, hotpath, route snapshots, gateway
    usage parsing, streaming usage, and provider response usage.

## 4. Implementation Slices

Implement in the order below. Each slice must include focused tests before
moving on.

### Slice A - Schema, Config, Snapshot, Formula

Likely files:

- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/billing/{store,snapshot,formula,recovery,endpoints}.go`
- `phase4-coordinator/internal/buyer/{rate_card.go,server_test.go}`
- `phase4-coordinator/{coordinator.yaml.example,dist/coordinator.yaml.example}`
- coordinator billing migrations or schema bootstrap files
- billing tests under `phase4-coordinator/internal/billing`

Requirements:

1. Add `cached_prompt_tokens INTEGER NULL CHECK(cached_prompt_tokens IS NULL OR (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens))` to `ledger_request_credits`.
2. The migration must be additive, default `NULL`, and must not backfill
   historical rows.
3. Preserve insert-only semantics for the new ledger column. Do not create
   update paths that mutate it after the credit row is written.
4. Extend rate-card config with
   `prompt_cache_hit_credits_per_mtok`.
5. If a pre-SPEC-024 config omits the new config key, load with effective
   default equal to `prompt_credits_per_mtok`.
6. Reject config where `prompt_cache_hit_credits_per_mtok < 0` or
   `prompt_cache_hit_credits_per_mtok > prompt_credits_per_mtok`.
7. Extend the billing formula/rate snapshot field as
   `prompt_cache_hit_rate_per_mtok`.
8. Update credit arithmetic:

```text
cached = COALESCE(cached_prompt_tokens, 0)
uncached_prompt_tokens = prompt_tokens - cached
base_numerator = uncached_prompt_tokens * prompt_rate_per_mtok
              + cached * prompt_cache_hit_rate_per_mtok
              + effective_completion_tokens * completion_rate_per_mtok
```

9. Preserve the SPEC-005 `usage_source = 'null_error'` guard: no formula
   evaluation and all credit fields set to `0`.
10. Prove byte-identical gross/provider/operator arithmetic when
    `cached_prompt_tokens IS NULL`, `cached_prompt_tokens = 0`, or the config
    defaults cache-hit rate to prompt rate.
11. Update recovery/reconciliation code so recomputation uses the same cached /
    uncached split and compares the new snapshot field.
12. Update billing endpoints only where they expose rate-card excerpts or
    recomputed gross values. Do not add Explorer cache fields in this slice.
13. Update the buyer-facing `GET /v1/rate-card` recommendation projection so
    every row includes `prompt_cache_hit_rate_per_mtok`.
14. Include `prompt_cache_hit_rate_per_mtok` in the canonical `/v1/rate-card`
    version bytes so a change to only the cache-hit rate changes `version`.
15. Update coordinator YAML examples with `prompt_cache_hit_credits_per_mtok`
    and operator guidance that a discounted value such as 25% of
    `prompt_credits_per_mtok` is expected when the operator enables discounted
    cache billing.

Tests:

- Config load defaulting for omitted `prompt_cache_hit_credits_per_mtok`.
- Config validation rejects negative and above-prompt cache-hit rates.
- Snapshot round trip includes `prompt_cache_hit_rate_per_mtok`.
- Formula tests for null, zero, positive cached tokens, null-error, byte-
  estimated completion, overflow, and provider/operator split.
- Migration test proves additive `NULL` default and no historical backfill.
- Recovery/reconciliation test catches mismatch when the cached-token value or
  cache-hit rate is drifted.
- `/v1/rate-card` handler test proves rows include
  `prompt_cache_hit_rate_per_mtok`.
- `/v1/rate-card` version test proves `version` changes when only
  `prompt_cache_hit_rate_per_mtok` changes.
- Config-example review/test confirms both coordinator YAML examples carry the
  new key.

### Slice B - Coordinator Provider-Usage Validation And Ledger Write

Likely files:

- `phase4-coordinator/internal/buyer/{billing_recorder,server,forward_state,forward_with_failover}.go`
- `phase4-coordinator/internal/buyer/forward_loop_test.go`
- `phase4-coordinator/internal/billing/hotpath.go`
- `phase4-coordinator/internal/routing/log.go`
- coordinator buyer and billing tests

Requirements:

1. Parse optional provider usage field `cached_prompt_tokens` for both
   non-streaming and streaming provider completion paths.
2. Preserve provider-field absence as `ledger_cached_prompt_tokens = NULL`.
3. Derive `effective_cached_prompt_tokens = COALESCE(ledger_cached_prompt_tokens, 0)` after validation.
4. Validate raw provider value:
   - integer only;
   - `0 <= cached_prompt_tokens <= prompt_tokens`;
   - positive value allowed only when `sticky_result = "hit"`;
   - cache-hit billing allowed only for `attempt_n = 0`.
   The `sticky_result` used here must come from typed per-attempt route/forward
   state carried into billing. Do not infer sticky hit/miss from logs, candidate
   order, provider identity, or whether sticky reordering was a no-op.
5. For `cached_prompt_tokens > prompt_tokens`, negative, non-integer, or
   otherwise malformed values, write a quarantined ledger row with:
   - `quarantined = 1`;
   - `quarantine_reason = 'invalid_cached_prompt_tokens'`;
   - `cached_prompt_tokens = NULL`;
   - valid `usage_source` that would have applied absent the cache violation;
   - all payable credit fields set to `0`;
   - no provider-creditable credits.
6. For positive cached tokens on a non-hit route, write a quarantined ledger row
   with:
   - `quarantine_reason = 'ambiguous_cache'`;
   - `cached_prompt_tokens = NULL`;
   - valid `usage_source`;
   - all payable credit fields set to `0`;
   - no provider-creditable credits.
7. For retry/re-attempt rows (`attempt_n > 0`), price all prompt tokens at the
   normal prompt rate and store `cached_prompt_tokens` as `NULL` or `0` even if
   the provider reports a positive value. If the locked SPEC says quarantine
   retries instead, follow the SPEC; otherwise the implementation must not grant
   discounted billing on retries.
8. Emit an additional billing-time `routing_decision` log row after cache
   validation. Keep existing selection-time `routing_decision` rows unchanged.
   The billing-time row must carry at least:
   - `request_id`;
   - `sticky_result`;
   - `sticky_miss_reason` when applicable;
   - `attempt_n`;
   - `cached_prompt_tokens` equal to `effective_cached_prompt_tokens`.
9. Keep invalid raw cache values out of buyer responses and credit arithmetic.
10. Log invalid cache reports only with bounded sanitized metadata:
    `request_id`, `attempt_n`, validation reason, JSON type/class, and sanitized
    effective value. Do not log raw `usage`, raw `cached_prompt_tokens`, prompt
    text, output text, internal cache keys, or provider-supplied arbitrary JSON.
11. Ensure existing SPEC-015/SPEC-022 receipt and route-snapshot paths continue
    to bind usage consistently. If receipt schemas need a cache field, add it
    only if the locked receipt/spec contract requires it; otherwise preserve the
    existing receipt contract and document the gap as a SPEC follow-up.

Tests:

- Sticky-hit first attempt with positive cached tokens stores the positive
  ledger value and discounts only cached prompt tokens.
- Sticky state tests cover typed per-attempt sticky outcomes for sticky hit
  already first, sticky hit after reorder, miss, disabled/no-key, and
  retry/failover. Tests must fail if billing infers hit status from logs or
  candidate order.
- Sticky-hit first attempt with explicit `0` stores `0` and logs `0`.
- Absent provider field stores `NULL`, uses effective `0`, and preserves legacy
  arithmetic.
- Non-hit positive report quarantines with `ambiguous_cache`.
- Negative, greater-than-prompt, string/float/object/null-in-usage reports
  quarantine with `invalid_cached_prompt_tokens` as applicable.
- Retry/re-attempt positive report does not receive discounted prompt billing.
- Quarantined cache rows have zero payable credits and valid `usage_source`.
- Billing-time `routing_decision` log exists in addition to the selection-time
  row and contains the required fields.
- Invalid-value logging test proves raw malformed provider JSON is not emitted
  into coordinator or gateway logs.

### Slice C - Gateway Buyer-Visible Usage Shape

Likely files:

- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/storage/{types.go,sqlite/store.go}` only if existing
  storage structs need to tolerate/pass through the field
- gateway router and storage tests

Requirements:

1. Ensure every SPEC-024-aware completion response emitted by the gateway has
   flat `usage.cached_prompt_tokens`.
2. For valid coordinator/provider usage with cached tokens, forward the
   sanitized effective value.
3. For non-hit, legacy provider absence, invalid/quarantined reports,
   gateway-estimated fallback, upstream errors, timeouts, malformed streams,
   client disconnects, and any response without a usable cache report, surface
   `cached_prompt_tokens: 0`.
4. Preserve SPEC-006 daily quota settlement as token-count based:
   `prompt_tokens + completion_tokens` under the existing fallback matrix.
5. Do not add credit-denominated pricing to the gateway. Buyer invoices and
   paid credit debits must use coordinator ledger/rate snapshots.
6. Keep `usage_events` append-only token accounting compatible. Add storage
   fields only if required for buyer-visible replay or existing gateway
   architecture; do not make gateway storage a second billing authority.
7. Cover both non-streaming and streaming response paths. For streaming, handle
   usage-bearing chunks, `[DONE]`, truncation, provider errors, timeout, and
   client disconnect behavior according to existing gateway semantics.

Tests:

- Non-streaming success with cached tokens returns flat
  `usage.cached_prompt_tokens`.
- Non-streaming success without the field returns `cached_prompt_tokens: 0`.
- Streaming final usage chunk with cached tokens forwards the sanitized value.
- Streaming fallback/error paths return or settle with `cached_prompt_tokens: 0`
  where a buyer-visible usage object is emitted.
- Gateway `/v1/usage` quota totals remain unchanged for identical prompt and
  completion token counts with different cached-token values.
- Invalid cache values are never forwarded to buyers.

### Slice D - Provider Reporting

Likely files:

- `phase3-binary/Sources/macprovider-cli/{HTTPServer,InferenceRelay,ModelRuntime,CoordinatorClient}.swift`
- Swift tests under `phase3-binary/Tests/macprovider-cliTests`

Requirements:

1. Extend provider usage emission to include optional `cached_prompt_tokens`.
2. Report a positive value only when the provider has actually reused a
   provider-local KV prefix for the same canonical prompt prefix.
3. If actual reuse cannot be proven safely with the current runtime APIs, report
   absence or `0`; do not fake positive cache hits from message overlap alone.
4. The provider may use implementation-specific cache pinning, reuse, and
   eviction internals, but must not expose internal cache keys or prompt
   contents in logs.
5. Restrict v0.1 cache accounting to stable system/user/assistant message
   content prefixes. Do not claim cache reuse for tool-message content.
6. Verify the provider has enough request context to associate a reusable
   prefix with the same sticky conversation/provider path. If the current
   coordinator-provider request path does not carry sufficient context, either:
   - add a private authenticated coordinator-to-provider metadata field/header
     only if the locked SPEC and SPEC-002 allow it; or
   - keep provider reports at absence/`0` and document the internal metadata
     requirement as a follow-up.
7. Never accept buyer-supplied cache hints in v0.1.
8. Keep OpenAI-compatible response shape stable for clients that ignore unknown
   usage fields.

Tests:

- Provider response usage includes `cached_prompt_tokens: 0` or omits the field
  when no proven reuse occurred.
- Any positive-report test must prove actual cache reuse through a controlled
  runtime/cache abstraction, not by prompt string overlap alone.
- Tool-message content does not produce positive cached tokens.
- Response JSON remains valid for existing non-streaming and streaming provider
  response fixtures.

## 5. Acceptance Matrix

Before opening a PR, map each SPEC-024 section to tests or explicit
verification evidence:

- §3 Wire Contract: provider usage parsing, validation, quarantine, effective
  value, billing-time routing log.
- §4 Ledger Schema: additive nullable column, check constraint, insert-only
  behavior, no backfill.
- §5 Rate Card: config key, defaulting, validation, snapshot field.
- §6 Formula: cached/uncached split, null-error guard, retry rule, no gateway
  credit pricing, quota unchanged.
- §7 Fraud Model: zero logging on sticky-hit, non-hit quarantine, invalid raw
  values sanitized, and same-actor buyer-provider abuse risk documented with the
  locked SPEC's mitigation, launch-control, or risk-acceptance posture.
- §8 Buyer-Visible Usage: flat field, always present from SPEC-aware gateway,
  sanitized `0` in all fallback cases.
- §9 Explorer: explicitly not implemented.
- §10 Rollout Invariant: byte-identical legacy/non-hit arithmetic and startup
  compatibility.

Do not mark an acceptance item complete by prose alone when it can be tested.

## 6. Audit Gates

This is billing/security-sensitive work. After implementation and before merge,
run three independent audit lanes until each lane reports **0 CRITICAL, 0 HIGH,
0 MEDIUM** findings:

- CODE lane: implementation correctness, migrations, edge cases, tests.
- SECURITY lane: fraud/abuse, buyer/provider trust boundaries, invalid usage,
  logging privacy.
- ARCH lane: SPEC conformance, ownership boundaries, rollout compatibility,
  gateway/coordinator authority split.

If an audit returns a critical/high/medium finding, fix it and rerun the
affected lane. Low/info findings may be deferred only if they do not change the
locked SPEC-024 contract and are documented in the PR.

## 7. Verification Commands

Run focused tests as each slice lands, then finish with the broadest relevant
suite for touched modules:

```bash
cd phase4-coordinator && go test ./internal/config ./internal/billing ./internal/buyer ./internal/routing
cd phase5-gateway && go test ./internal/router ./internal/storage/...
cd phase3-binary && swift test --filter Usage
cd phase3-binary && swift test --filter InferenceRelay
```

If touched surfaces are broad or audit findings require it:

```bash
cd phase4-coordinator && go test ./...
cd phase5-gateway && go test ./...
cd phase3-binary && swift test
```

The final handoff must list:

- changed files;
- tests run;
- audit-lane outcomes;
- any low/info deferrals;
- explicit confirmation that there are 0 critical/high/medium findings left;
- any remaining SPEC follow-up candidates.
