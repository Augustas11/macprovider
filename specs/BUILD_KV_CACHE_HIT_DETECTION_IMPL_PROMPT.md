# BUILD IMPL prompt — KV-cache hit detection production (continues from spike)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing a single line of code.**

Your job is to promote the working **spike** on branch `spike/kv-cache-hit-detection` into the production version of provider-side KV-cache hit detection, then merge to `main` via PR. The spike (single-conversation static cache, no LRU/TTL/actor, no bilingual WS protocol) is a **proven reference** — the mechanism works end-to-end with correct multi-turn output. Your job is production polish, not design.

**Estimated: half-day to a day of focused Swift + Go work + one codex audit round + integration smoke against `api.streamvc.live`.**

## Read these BEFORE touching code

Two files carry all the design context you need. Read both end-to-end:

1. `specs/BUILD_KV_CACHE_HIT_DETECTION_PROMPT.md` — the design prompt on the spike branch (v2 with the LCP + trim algorithm baked in). §"Spike findings" documents the tokenizer trap and the `prompt_tokens` correctness gotcha the spike surfaced. §3 has the LCP + trim algorithm. Read all of it.
2. `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` on the spike branch — search for `SpikeConvCache` and read every line it touches. That IS your reference implementation of the mechanism. Do NOT rewrite the LCP logic from scratch — it works.

Then:

3. `specs/SPEC-024-prefix-cache-billing.md` — the billing contract this IMPL makes real. §3 is the wire contract; the ledger `CHECK(cached_prompt_tokens <= prompt_tokens)` at `phase4-coordinator/internal/billing/store.go:69` is the money-path invariant you cannot violate.
4. `phase4-coordinator/internal/routing/sticky/sticky.go` and `phase4-coordinator/internal/buyer/server.go` search for `X-MacProvider-Internal-Conv` — this is where the coord already receives the conversation key from the gateway. You will forward this same key to the provider on sticky-hit routes only.
5. `phase4-coordinator/internal/ws/messages.go` — search for `InferenceRequest`. This is the struct you extend with `ConversationKey`.
6. Memory: `~/.claude/projects/-Users-augstar-macprovider-poc/memory/gh-pr-merge-augustas11-token-prefix.md`, `feedback-build-audit-loop.md`, `feedback-verify-commit-content-not-just-message.md`.

## Starting state

- Base branch: `main` at commit c24ba6f or later
- Reference branch: `spike/kv-cache-hit-detection` at commit 84e50c9 — pushed but NOT merged. Working code, single-conversation static cache, proves LCP + trim produces correct output on turn 2 of a 2-turn conversation.
- Model used for spike validation: `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` at temperature=0.

**Your working branch:** create `feat/kv-cache-hit-detection` off `origin/main` in a fresh worktree per `feedback-always-fresh-worktree-for-code-work`:

```bash
git worktree add ../macprovider-kv-cache-impl -b feat/kv-cache-hit-detection origin/main
cd ../macprovider-kv-cache-impl
```

You will consult the spike branch as a reference but implement on your own feature branch. Copy the LCP + trim + suffix-input pattern; the store-side needs the `prompt_tokens` fix documented in the design prompt §"Spike findings" second correctness trap.

## What the spike already proved (trust this — do not re-verify)

- `TokenIterator(input:model:cache:parameters:)` accepts a pre-populated cache. Correct API.
- `[KVCache]` retains state across successive `generate()` calls; `KVCacheSimple` supports `trim(_ n: Int)`.
- `didGenerate: ([Int]) -> GenerateDisposition` callback receives ACCUMULATED tokens per tick, not delta. Use `generatedTokens = tokens.map { … }` (assign), never `append(contentsOf:)`.
- Naïve token-ID strict-prefix match FAILS due to tokenizer non-canonicity (whitespace tokens after chat-template headers). LCP + trim + suffix input is the correct approach.
- LCP + trim + suffix produces semantically correct multi-turn output (spike turn 2: "Io is the most well-known moon of Jupiter" — correctly references turn 1's context).
- The `prompt_tokens` field in the OpenAI response MUST be the full buyer prompt length, NOT `GenerateResult.promptTokenCount` (which reports the SUFFIX length after cache reuse).
- `cache.offset` lags actual token count by 1 due to mlx-swift `prepare()` step() priming. Design tolerance ±1; don't assert exact equality.

## What v1 production MUST do (concrete diff list)

### 1. Coord: extend `InferenceRequest` with `ConversationKey`

File: `phase4-coordinator/internal/ws/messages.go`

```go
type InferenceRequest struct {
    Type            string                     `json:"type"`
    RequestID       string                     `json:"request_id"`
    Stream          bool                       `json:"stream"`
    Body            string                     `json:"body"`
    Settlement      *SettlementReceiptMetadata `json:"settlement,omitempty"`
    ConversationKey string                     `json:"conversation_key,omitempty"` // NEW
}
```

Additive, omitempty — safe rollout (old providers ignore the field).

### 2. Coord: populate `ConversationKey` on sticky-hit routes only

File: `phase4-coordinator/internal/buyer/server.go`

At the site where `InferenceRequest` is constructed for the WS forward, populate `ConversationKey` ONLY when the routing result was a sticky hit. Use the existing `X-MacProvider-Internal-Conv` header value from the request (already validated by the sticky-hit path). On non-hit routes (miss, disabled, no_key, evicted), leave `ConversationKey` empty — the spec (§3 of design prompt) requires this.

Add a unit test in `server_test.go`: verify that a sticky-hit route populates `ConversationKey` and a sticky-miss route does not. There are existing patterns for this — grep for `stickyResult` in the test file.

### 3. Provider Swift: deserialize `conversation_key` from `InferenceRequest`

File: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` (or wherever the WS message decoder for `InferenceRequest` lives — grep for `RequestID` and `Body`).

Add optional `conversationKey: String?` to the Swift `InferenceRequest` struct/decoder. Optional so old-coord + new-provider still works.

### 4. Provider Swift: `ConversationCache` actor replaces `SpikeConvCache`

File: `phase3-binary/Sources/macprovider-cli/ConversationCache.swift` (NEW)

Actor-isolated bounded LRU. Copy the LCP + trim logic from `SpikeConvCache.maybeReuse` verbatim — it's proven. Add:

- Key: the conversation key string (from step 3)
- Value: `(canonicalPromptTokens: [Int32], kvCache: [KVCache], modelID: String, kvBits: Int?, storedAt: Date, tokenCount: Int)`
- LRU cap: **8 conversations** OR **200,000 tokens total**, whichever hits first. Evict least-recently-USED.
- TTL: **15 minutes**. Sweep on access (lazy) rather than a background task.
- Invalidation triggers: modelID differs from stored, kvBits differs from stored, prefix-LCP < 32 tokens (below threshold, treat as miss), cache layers not trimmable (`isTrimmable == false` on any layer).
- Config knobs via env vars: `MACPROVIDER_CONV_CACHE_MAX_CONVERSATIONS`, `MACPROVIDER_CONV_CACHE_MAX_TOKENS`, `MACPROVIDER_CONV_CACHE_TTL_MINUTES`. Documented; defaults reasonable.

**Concurrency:** `TokenIterator` mutates the passed `KVCache` in place. Serialize per-key via the actor to prevent concurrent turns on the same key from corrupting each other's state. First-order design; production may need more nuance later.

### 5. Provider Swift: wire `ConversationCache` into ModelRuntime

File: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`

Replace the spike's `SpikeConvCache` calls with real ConversationCache lookups keyed on `conversationKey`. If the request has no `conversationKey` (non-sticky-hit route, or an older gateway that doesn't set it), skip the cache entirely — always report `cached_prompt_tokens: 0`. Do NOT try to key on prompt-prefix; the spike explicitly rejected that path.

**Wire it into both `completeWithServedSnapshot()` (non-streaming, ~line 656) AND `stream(...)` (streaming, ~line 750).** The spike only touched non-streaming. Streaming path uses the same `generate()` primitive with the same `TokenIterator(cache:)` pattern — mirror the design.

### 6. Provider Swift: fix the `prompt_tokens` correctness bug

The spike currently returns `promptTokens: result.promptTokenCount` in the `CompletionResult`. When LCP+trim path was taken, `result.promptTokenCount` is the SUFFIX length (e.g. 29), not the buyer's full prompt (86). This VIOLATES SPEC-024's `CHECK(cached_prompt_tokens <= prompt_tokens)` constraint if reported to the coord.

Fix: change to `promptTokens: promptTokenIds.count` (the FULL prompt length as tokenized before trim). Add a unit test that asserts `completion.cachedPromptTokens <= completion.promptTokens` at every emission site.

### 7. Provider Swift: structured observability

Emit one structured log line per completed request. Match existing `event=` conventions from `phase4-coordinator/internal/routing/log.go`:

```
event=conv_cache action=hit key_hash=<sha256_first_8> cached_prompt_tokens=57 prompt_tokens=86 lcp=57 trim_by=12 conv_cache_entries=3 conv_cache_tokens=42500
event=conv_cache action=miss key_hash=<sha256_first_8> reason=cold_start
event=conv_cache action=miss key_hash=<sha256_first_8> reason=prefix_diverged lcp=15 threshold=32
event=conv_cache action=miss key_hash=<sha256_first_8> reason=model_swap stored_model=X incoming_model=Y
event=conv_cache action=miss key_hash=<sha256_first_8> reason=cache_not_trimmable
event=conv_cache action=evict key_hash=<sha256_first_8> reason=lru
event=conv_cache action=evict key_hash=<sha256_first_8> reason=ttl_15min
```

`key_hash = sha256(conversationKey)[:8]` — enough for operator debugging without leaking buyer conversation identifiers.

### 8. Metrics (optional for v1 — decide based on effort budget)

If time permits, expose four Prometheus counters on `/metrics` (or wherever provider metrics live — grep for existing metrics surface):

- `macprovider_conv_cache_hits_total`
- `macprovider_conv_cache_misses_total{reason="..."}`
- `macprovider_conv_cache_entries` (gauge)
- `macprovider_conv_cache_tokens` (gauge)

If skipping for v1, note this as a v1.1 follow-up in the PR description.

### 9. Tests

- **Unit tests** in `phase3-binary/Tests/macprovider-cliTests/ConversationCacheTests.swift` (NEW):
  - LCP computation: empty vs empty, identical, partial match, full match of shorter, disjoint
  - Trim: verify cache offset after trim equals LCP (±1 for mlx priming tolerance)
  - Invalidation: model swap, kvBits swap, TTL exceeded, cache-not-trimmable
  - LRU: eviction order under 9 inserts at cap=8; token-cap eviction
  - `cachedPromptTokens <= promptTokens` invariant at all emission sites
- **Coord unit test** in `phase4-coordinator/internal/buyer/server_test.go`: sticky-hit sets `ConversationKey`, sticky-miss does not.
- **Integration test** in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift` (or a new file): 2-turn HTTP request against the local server (test-fixture model or the mock ModelRuntime), assert turn 2 has `cached_prompt_tokens > 0` when the conversation key is set.
- **Regression sweep:** existing `swift test` MUST stay green.

### 10. Verification against production

The definition-of-done gate: hand-run a 2-turn conversation via `openai-python` against `api.streamvc.live` after your PR merges and Pearl is redeployed. Assert turn 2 shows `usage.cached_prompt_tokens > 0` in the response. Capture the response and paste it into the PR description.

Do NOT skip this. The docs/using-macprovider-with-openai-sdk.md cookbook already tells buyers to observe this on turn 2 — this IMPL is what makes that statement true.

## What v1 MUST NOT do

- **No new SPEC.** SPEC-024 §3 already normalizes the wire; SPEC-002 addendum for `conversation_key` is small enough to inline in the PR body as "SPEC-002 vX.Y addendum ships in this PR." If a reviewer insists, file a follow-up.
- **No prompt-prefix guessing without conversation identity anchor.** Only cache-key on the coordinator-forwarded conversation string. Explicitly rejected in the design prompt Path B section.
- **No cross-provider cache handoff.** If sticky routes to a fresh provider, that provider reports 0 — done.
- **No cache persistence to disk.** In-memory only. Process restart evicts everything.
- **No cache update on partial-response failure.** Store-then-commit: update the stored entry only on successful generation completion. If interrupted (buyer disconnect, error, thermal throttle mid-request), discard the mutated cache state — it's inconsistent with any buyer-observed output.
- **No coordinator-side cache.** Different design, out of scope.
- **No streaming-tool-call cache reuse across turn boundaries** if it's complicated. The spike didn't exercise this; add tests but keep the behavior conservative (miss if tool_calls in the assistant history is unusual).

## Decisions the fresh session must make (with recommendations)

1. **LRU cap defaults.** Recommend 8 conversations / 200K tokens / 15min TTL. Justify or override in the PR description with rationale. Config knobs are env vars; not YAML for v1.
2. **Metrics for v1 or v1.1?** Recommend v1 if you finish steps 1-7 with budget remaining; otherwise defer to v1.1 explicitly in the PR body.
3. **How to canonically key the conversation on the coord.** The gateway HMACs the buyer-supplied tag as `conv:<base64url_hmac>`. Recommend passing this canonical form through to the provider unchanged — no re-derivation. Provider uses opaque-key semantics.
4. **SPEC-002 addendum: inline PR body or separate follow-up PR?** Recommend inline PR body since it's a single optional field. If reviewer prefers separate, split.
5. **Should streaming path invalidate cache on interruption?** Recommend YES — store-then-commit at final success only, discard on any error/cancel/drain. This preserves the invariant that stored KV state matches the tokens the buyer observed.
6. **What to do if `X-MacProvider-Internal-Conv` header is present but sticky routed to a MISS (fresh provider)?** Recommend do NOT populate `ConversationKey` on the WS request — this preserves the invariant that new provider reports 0.

## Audit-loop discipline

Per `feedback-build-audit-loop`: this is wire-adjacent to the SPEC-024 money path (via the `CHECK` constraint). One codex round on the diff, three-lane if the diff exceeds ~600 lines of Swift + Go. Pre-empt the three most likely round-1 findings:

- Concurrency race on ConversationCache (verify actor isolation properly serializes per-key operations, especially trim+generate+store on the same key)
- `cached_prompt_tokens > prompt_tokens` under encoding non-determinism (unit test at every emission site enforces the invariant)
- Cache leak on partial-response failure (verify store-then-commit; failure paths do not mutate stored entry)

## Deliverables

1. PR opened against `main` with branch `feat/kv-cache-hit-detection`. Use `GH_TOKEN=$(gh auth token -u Augustas11) gh pr create ...`.
2. PR description MUST include:
   - Coord Go diff line count + Provider Swift diff line count separately
   - Chosen LRU cap defaults + rationale
   - Concurrency-safety analysis (actor, per-key serialization guarantee)
   - Rollout matrix: (old binary + new coord), (new binary + old coord), (new binary + new coord + sticky-hit route), (new binary + new coord + non-hit route). All 4 preserve SPEC-024 §3 wire correctness.
   - Captured example from `api.streamvc.live` showing `cached_prompt_tokens > 0` on turn 2 of a real 2-turn conversation
   - Whether metrics are v1 or v1.1
   - Whether SPEC-002 addendum is inline or follow-up
3. `beta/DECISION_CRITERIA.md` entry recording what shipped + operator cache-cap knobs.
4. Optional: `examples/prefix_cache_reuse_demo.py` mirroring `examples/tool_calling_demo.py` conventions.

## Definition of done

- PR merged to `main`
- After Pearl redeploy: 2-turn `openai-python` demo against `api.streamvc.live` shows `usage.cached_prompt_tokens > 0` on turn 2
- The cookbook claim at `docs/using-macprovider-with-openai-sdk.md` ("observe cached_prompt_tokens > 0 on turn 2") is TRUE end-to-end for the first time
- Beta economics ("~71% prompt-token discount on multi-turn sessions at 25% cache-hit rate") starts flowing for real buyers

If you're past a day of work, surface what's blocking. The spike proved the mechanism; production polish should be linear from here.
