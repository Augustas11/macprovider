# BUILD prompt — Provider KV-cache hit detection (SPEC-024 payoff slice)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing a single line of code.**

Your job is to make the phase3 provider actually **detect KV-cache hits on sticky-routed multi-turn conversations** and report the reused prompt-token count in `usage.cached_prompt_tokens`, replacing the four hardcoded `0` emission sites shipped with SPEC-024. Until this ships, the SPEC-024 billing formula is technically correct but returns the same result as pre-SPEC-024 because every request reports `cached_prompt_tokens: 0`. This slice is where buyer economics start actually flowing.

**~1 week of provider Swift work + one codex audit round. Not directly money-path (SPEC-024's `CHECK(cached_prompt_tokens <= prompt_tokens)` constraint prevents any incorrect report from being credited), but wire-adjacent enough that a reasonable audit round earns its cost.**

## Pre-flight: confirm the gap

Verify against the current tree before touching code:

1. `grep -rn 'cached_prompt_tokens' phase3-binary/Sources` — should show exactly four hardcoded `: 0` emission sites at:
   - `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1103` (`usage()` helper for non-streaming completion)
   - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:854` (streaming `usage()` helper)
   - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:864` (`zeroUsage()` helper)
   - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:923` (`RelayRequestState.setUsage`)
   If any of these are already replaced with real detection logic, STOP and surface it.
2. `grep -rn 'X-MacProvider-Conversation\|X-MacProvider-Internal-Conv\|sticky\|KVCache' phase3-binary/Sources --include='*.swift'` — the provider currently sees NONE of the sticky-conversation identity. `X-MacProvider-Internal-Conv` reaches the coordinator (see [phase4-coordinator/internal/buyer/server.go:4878](phase4-coordinator/internal/buyer/server.go:4878), :4926) but is not forwarded to the provider WS. Confirm.
3. Read [phase3-binary/Sources/macprovider-cli/ModelRuntime.swift](phase3-binary/Sources/macprovider-cli/ModelRuntime.swift) around the three `generate(input: lmInput, ...)` sites (~lines 437, 521, and one more — confirm the current line numbers) and verify: `let input = UserInput(chat: request.messages.map { $0.mlxMessage })` rebuilds the input from scratch per call. No `cache: [KVCache]` parameter is passed and no cache persists across generate() calls today.
4. Read [phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift](phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift) end-to-end — cache-hit detection MUST run against canonicalized prompts, not raw text, or whitespace/formatting drift will make matches spuriously fail.
5. `find phase3-binary/.build/checkouts/mlx-swift-examples -name '*.swift' | xargs grep -l 'KVCache'` — confirm the mlx-swift-examples surface exposes `KVCache` and that the `Tools/llm-tool/Chat.swift` sample maintains `var cache: [KVCache]` across sequential generate() calls. That's the API pattern this slice uses.

If any of 1–5 is materially different from what this prompt assumes, STOP and surface the discrepancy.

## Why this specific design

Two paths were considered:

- **Path A (chosen):** Coordinator forwards the sticky conversation key to the provider on the WS request. Provider maintains a bounded LRU keyed by that opaque string. Simple, correct, no prompt-prefix guessing.
- **Path B (rejected):** Provider maintains a global LRU keyed by prompt-prefix hash, does longest-common-prefix search on every request. Works even without sticky routing but is O(N) per hit-check, memory-unbounded without careful tuning, and produces false positives when two unrelated conversations happen to share a canonical system prompt.

Path A pushes conversation identity through the layer that already owns it (coordinator sticky map at [phase4-coordinator/internal/routing/sticky/sticky.go](phase4-coordinator/internal/routing/sticky/sticky.go)) and keeps the provider dumb. Path A is roughly one week of clean Swift work; Path B is two weeks of edge-case whack-a-mole.

## What v1 MUST do

### 1. Coordinator forwards `X-MacProvider-Internal-Conv` to the provider WS request

Small [phase4-coordinator/internal/buyer/server.go](phase4-coordinator/internal/buyer/server.go) change: when a request routes via sticky-hit (`sticky_result: hit`), forward the already-known `X-MacProvider-Internal-Conv` header value to the provider on the WS request that carries `POST /v1/chat/completions`. Rename to `X-MacProvider-Provider-Conversation` on the provider-facing side so it's clear this is the provider's authority-of-record for conversation identity — the buyer never sees it, and the provider MUST NOT trust anything but this header for sticky-key state.

Never forward on non-hit routes (miss/disabled/no_key/evicted). Emit only when `sticky_result == "hit"`. If forwarded on non-hit routes, the provider might mistakenly try to reuse a stale cache — the SPEC-024 §3 wire contract makes that a quarantine event.

Expected coord diff: ~15 lines including a test.

### 2. Provider-side conversation-scoped KV-cache LRU

New Swift file `phase3-binary/Sources/macprovider-cli/ConversationCache.swift` (~150-250 lines):

- Actor-isolated store keyed by `X-MacProvider-Provider-Conversation` string
- Value: `(canonicalPromptTokens: [Int32], canonicalCompletionTokens: [Int32], kvCache: [KVCache], modelID: String, kvBits: Int?, storedAt: Date, tokenCount: Int)`
- Bounded LRU. Default cap: **8 conversations** OR **200,000 tokens total**, whichever hits first. Evict least-recently-USED (not stored). Config knobs via `MACPROVIDER_CONV_CACHE_MAX_CONVERSATIONS` and `MACPROVIDER_CONV_CACHE_MAX_TOKENS` env vars, defaults documented.
- Key invalidation triggers (MUST evict entry, MUST NOT report cache-hit):
  - `modelID` differs from stored (model swap between turns)
  - `kvBits` differs from stored (KV-cache quantization changed via config reload)
  - Any GenerateParameters affecting tokenization/prefill differ (tools list mutated, system message mutated — the canonical-token check in §3 catches these)
  - Entry age > 15 minutes (memory bound; conversations that idle out don't wedge memory)

### 3. Cache-hit detection = canonical-prompt-prefix match

On each request that arrives with `X-MacProvider-Provider-Conversation: <key>`:

1. Look up the stored entry in `ConversationCache` by key. If none → cache miss, `cached_prompt_tokens = 0`, proceed normally.
2. Canonicalize the incoming prompt to token IDs via the same path `PromptCanonicalizer.swift` uses, PLUS running through the model's chat template to produce the token sequence the model will actually see.
3. Verify the stored `canonicalPromptTokens + canonicalCompletionTokens` is a strict PREFIX of the new canonical token sequence. If not → cache miss (the buyer replayed a modified prior turn, or the assistant response was edited buyer-side).
4. If it IS a strict prefix, the cached KV state covers `len(canonicalPromptTokens) + len(canonicalCompletionTokens)` tokens. That's `cached_prompt_tokens` for this request.
5. Pass the stored `[KVCache]` to `generate()` alongside a `UserInput` built ONLY from the NEW tokens (the tokens after the shared prefix). Let mlx-swift's KVCache mechanism resume from the pinned state.
6. After generation completes, UPDATE the stored entry with the new turn's canonical tokens + KVCache (so turn N+2 can build on it), refresh `storedAt`, refresh `tokenCount`.

**Critical:** the mlx-swift `generate()` API takes the KVCache by reference and mutates it as it processes new tokens. You MUST snapshot the cache state BEFORE generation if you want to keep it available for concurrent turns on the same conversation. Realistically conversations are single-threaded per buyer, so serializing per-key with the actor lock is fine and probably the right first-order design.

### 4. Wire it into all four emission sites

Replace the four `cached_prompt_tokens: 0` hardcodes with the actual detected value. The value MUST equal what SPEC-024 §3 accepts:
- `0 <= cached_prompt_tokens <= prompt_tokens`
- MUST be `0` when the request did NOT arrive with `X-MacProvider-Provider-Conversation` (non-sticky-hit route)
- MAY be positive integer when the header IS present AND a cache-hit succeeded

Never emit a positive value on non-hit routes. The coordinator will quarantine per SPEC-024 §3 if you do.

### 5. Observability

Emit one structured log line per completed request with the cache decision:

```
event=conv_cache action=hit key_hash=<sha256_first_8> cached_prompt_tokens=1200 prompt_tokens=1500 conv_cache_entries=6 conv_cache_bytes=~24MiB
event=conv_cache action=miss key_hash=<sha256_first_8> reason=key_not_found
event=conv_cache action=miss key_hash=<sha256_first_8> reason=prefix_diverged
event=conv_cache action=miss key_hash=<sha256_first_8> reason=model_swap
event=conv_cache action=evict key_hash=<sha256_first_8> reason=lru
event=conv_cache action=evict key_hash=<sha256_first_8> reason=ttl_15min
```

`key_hash` is `sha256(key)[:8]` — enough for operator debugging without leaking buyer conversation identifiers to logs. Match the existing `event=` structured-log style already used across `phase4-coordinator/internal/routing/log.go`.

### 6. Metrics

Expose two new counters on the provider's `/metrics` (or wherever provider metrics live — check current surface):

- `macprovider_conv_cache_hits_total` — count of hits
- `macprovider_conv_cache_misses_total{reason="..."}` — count of misses tagged by reason (key_not_found | prefix_diverged | model_swap | kvbits_swap)
- `macprovider_conv_cache_entries` — current entry count
- `macprovider_conv_cache_tokens` — current cached token count

These let the operator watch cache-hit rate over time and validate the buyer-side economics are actually landing.

## What v1 MUST NOT do

- **No new SPEC.** The wire contract lives in SPEC-024 §3 (already locked). The coord-forwarding change is a SPEC-002 addendum candidate — file as follow-up if the reviewer insists, but the SPEC is thin (one header rename); don't bundle.
- **No prompt-prefix guessing.** Cache hits key on the coordinator-forwarded conversation string, NOT on prompt-prefix matching without an identity anchor. Path B was explicitly rejected above.
- **No cross-provider cache handoff.** If the sticky provider is down and coordinator routes to a fresh provider, that provider reports `cached_prompt_tokens: 0`. SPEC-024 §2 makes this explicit.
- **No cache reuse when tools/system-message differ.** The prompt-prefix check in §3 catches this — the token sequence changes when tools change, so the stored prefix won't match. Trust the canonical-token comparison; don't add a parallel tools-hash check.
- **No cache persistence to disk.** In-memory only. Provider restart evicts everything; conversations resume as fresh. Persistent KV-cache is a v2 optimization AFTER v1 proves cache-hit economics matter.
- **No cache for streaming that failed mid-response.** If generation is interrupted (buyer disconnect, provider error, thermal throttle mid-request), DO NOT update the stored entry — the model's KVCache state is now inconsistent with any completion the buyer might have received. Discard.
- **No coordinator-side cache** (that's a whole different design; SPEC-024 v0.2 territory).

## Files you'll likely touch

- `phase4-coordinator/internal/buyer/server.go` — forward sticky-hit header to provider WS (~15 lines + test)
- `phase3-binary/Sources/macprovider-cli/ConversationCache.swift` — NEW, ~150-250 lines
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — three generate() sites accept optional `[KVCache]`; on success, snapshot back into ConversationCache
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` + `InferenceRelay.swift` — four emission sites read `cached_prompt_tokens` from the runtime's cache-hit report instead of hardcoding 0
- `phase3-binary/Tests/macprovider-cliTests/ConversationCacheTests.swift` — NEW, unit tests
- `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift` + `InferenceRelayTests.swift` — add positive-cache-hit tests alongside the existing `cached_prompt_tokens == 0` expectations (both cases still valid)
- `beta/DECISION_CRITERIA.md` — Entry recording what shipped + the 8-conv / 200K-token default cap choice

## What you SHOULDN'T touch

- `phase5-gateway/**` — no gateway changes
- `phase4-coordinator/internal/billing/*` — SPEC-024 billing formula is already correct; do not re-derive
- `phase7-verify/**` — receipt canonicalization already stable; new usage field passes through the existing SPEC-015 v0.3 tuple untouched (receipts don't cover usage)
- `specs/SPEC-024-prefix-cache-billing.md` — locked; if you find a spec bug, file an issue and stop

## Test plan

1. **Unit test** — ConversationCache basic: insert, retrieve by same key returns match; retrieve by different key returns miss; retrieve after LRU eviction returns miss.
2. **Unit test** — canonical-prefix check: turn-N prompt+response stored; turn-(N+1) prompt that strict-prefixes it → hit with expected token count; turn-(N+1) prompt that DOESN'T strict-prefix (buyer edited turn N) → miss with reason `prefix_diverged`.
3. **Unit test** — invalidation: model swap → miss with reason `model_swap`; kvBits swap → miss with reason `kvbits_swap`; TTL exceeded → miss with reason `ttl_15min`.
4. **Unit test** — bounded LRU: insert 9 conversations at 8-cap → oldest evicted; insert conversations totaling > 200k tokens → LRU eviction keeps under cap.
5. **Integration test** — real 2-turn conversation through `phase3-binary` HTTP server: turn 1 emits `cached_prompt_tokens: 0`; turn 2 with matching key emits positive integer matching (turn-1 prompt_tokens + turn-1 completion_tokens); the numeric equality is exact, not approximate.
6. **Integration test** — same 2-turn shape without the conversation header: both turns emit `cached_prompt_tokens: 0` (rollout / non-sticky path unchanged).
7. **End-to-end smoke against `api.streamvc.live`** — 2-turn Python demo using the openai SDK with `X-MacProvider-Conversation` header; observe `usage.cached_prompt_tokens > 0` on turn 2. Add to `examples/` alongside the existing `tool_calling_demo.py`.
8. **Regression** — existing test suite stays green. All prior `cached_prompt_tokens == 0` assertions remain valid on non-hit routes.

## Audit-loop discipline

This is not directly money-path (SPEC-024's `CHECK(cached_prompt_tokens <= prompt_tokens)` constraint prevents any incorrect positive value from being credited; the worst-case bug quarantines the request rather than mis-crediting). But it IS wire-adjacent to the SPEC-024 money path.

Per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-build-audit-loop.md`: **one codex audit round on the diff is sufficient.** Fix any HIGH/CRIT, ship. The three most likely round-1 findings to pre-empt:

- **Concurrency race on ConversationCache** — two concurrent turns on the same key without proper actor isolation could interleave KVCache mutations. Design in an actor.
- **`cached_prompt_tokens > prompt_tokens` under prompt-prefix edge cases** — if the canonical token sequence has any encoding non-determinism, the comparison could over-count. Add an explicit clamp: `cached_prompt_tokens = min(computed_prefix_len, current_prompt_tokens)` before emission. Or better: assert-fail in debug builds so the underlying bug is fixed.
- **Cache leak on partial-response failure** — if generation starts to update the stored entry and then fails, the cache holds inconsistent state. Store-then-commit pattern: compute new entry, only replace on success.

## Deliverables

1. PR opened against `main` with branch `feat/kv-cache-hit-detection`. Use `GH_TOKEN=$(gh auth token -u Augustas11) gh pr create ...` per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/gh-pr-merge-augustas11-token-prefix.md`.
2. PR description MUST include:
   - Coord-side diff line count + provider-side diff line count separately
   - Chosen LRU cap defaults + rationale (8 convs / 200K tokens is a starting point; adjust with evidence)
   - The concurrency-safety analysis (which actor, what serialization guarantees)
   - Rollout safety statement: "Providers running old binary continue emitting `cached_prompt_tokens: 0`; new binary + old coordinator emits `0` (no header forwarded); new binary + new coordinator on sticky-hit route emits positive values. All three cases preserve SPEC-024 §3 wire correctness."
   - Screenshot or captured log of a real 2-turn conversation on `api.streamvc.live` showing positive `cached_prompt_tokens` on turn 2
3. `beta/DECISION_CRITERIA.md` entry recording what shipped + operator cache-cap knobs.
4. `examples/prefix_cache_reuse_demo.py` — 30-40 line 2-turn demo mirroring `tool_calling_demo.py` conventions.

## What "done" means economically

When this ships, a buyer running a 20-turn coding session with Cline (per the SPEC-018 v0.2 workload shape) sees:
- Turn 1: `cached_prompt_tokens: 0` (cold prefix)
- Turn 2–20: `cached_prompt_tokens: ~previous_turn_prompt_tokens + previous_turn_completion_tokens` on each successive turn
- Billing formula (SPEC-024) charges the cached fraction at the 25% discount default (`prompt_cache_hit_rate_per_mtok`)
- **Total buyer cost on a 20-turn session drops by roughly `(N-1)/N * 0.75 ≈ 71%`** on the prompt-token side (with completion tokens unchanged)

That's the economics landing. Until this ships, SPEC-024 saves buyers exactly zero dollars.

**You're done when:** PR merged, integration test proves positive `cached_prompt_tokens` on turn 2 of a real sticky-conversation flow, and the `examples/prefix_cache_reuse_demo.py` prints a non-zero value against `api.streamvc.live`. If you're past ~1 week of work, surface what's blocking.
