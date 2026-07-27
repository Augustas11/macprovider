# BLIND AUDIT — SPEC-037 serve cache-type selection (hot path)

You are an independent auditor with NO prior context and no knowledge of any
earlier review. Judge only what the code does.

## Feature
`macprovider-cli` (Swift, phase3-binary/) has an encrypted provider-local KV disk
survival tier behind the in-RAM ConversationCache. Residency-only (no buyer wire /
receipt / billing / cached_prompt_tokens change), default-off, synthetic-key-only.
The disk tier can only serialize `KVCacheSimple` (allowlist `["KVCacheSimple"]`,
KVDiskCacheFormat.swift:43); `captureSnapshot` (KVConversationColdTierAdapter.swift)
casts `layers.layers as? [KVCacheSimple]` and returns nil (no persist) otherwise.

## The change under audit (on the inference HOT PATH)
Read `audits/2026-07-27/CACHETYPE_DELTA.diff` and the FULL current text of
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (all `newCache` call
sites + `speculativeRoute` + `coldContext`), and
`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
(`allowsSpeculativeDecoding`). Background: mlx-swift-lm `LanguageModel.newCache`
builds `RotatingKVCache` when `GenerateParameters.maxKVSize != nil`, else
`KVCacheSimple`. serve historically always set `maxKVSize = maxContextTokens`, so
every request built RotatingKVCache and the disk tier silently persisted nothing.

The change adds `cacheParameters(_:forceSimpleKV:)` (ModelRuntime.swift:491) which
drops `maxKVSize` when forced, and applies it at the non-streaming (1399) and
streaming (1860) serve `newCache` sites with `forceSimpleKV: coldContext?.eligible
== true`, and at the seed warmup (2139) with `forceSimpleKV: true`. Other newCache
sites (1236, 1601, 2388) were left unchanged.

## What to hunt (the two symmetric hot-path risks)
1. **Eligible-reachable no-op:** is there ANY request path that IS tier-eligible
   (synthetic `conv:kvs-synth:` key + `.directHTTP` provenance → `coldContext.eligible`)
   yet reaches a `newCache` site that still builds RotatingKVCache (i.e. an eligible
   path through 1236 / 1601 / 2388, or any site not given the eligible treatment)?
   If so the tier silently persists nothing for that path — the exact shipped bug.
   Enumerate which request shapes reach EACH newCache site and confirm every
   eligible-reachable one forces KVCacheSimple.
2. **Buyer-path regression:** can `coldContext?.eligible` EVER be true for ordinary
   buyer traffic (non-synthetic key, relay/tier2 provenance)? If so, buyer requests
   would switch to unbounded `KVCacheSimple` — a memory/behavior regression on the
   money path. Trace how `eligible` is computed (the FR-KVP11 gate + provenance +
   key prefix) and confirm buyer traffic can never set it.
3. **Speculative exclusion:** confirm eligible requests can never route to
   speculative decoding (the draft/target caches at 1601/2388 assume the buyer
   params). Anchor to `allowsSpeculativeDecoding` (false when conversationKey != nil).
4. **Seed-warmup consistency:** the F1 geometry seed (2139) forces KVCacheSimple so
   its seeded geometry matches what eligible requests produce. Confirm no path makes
   the seed geometry diverge from the eligible-request cache geometry.
5. **cacheParameters correctness:** does it mutate only maxKVSize and leave every
   other GenerateParameters field intact? Any aliasing/shared-state issue (value vs
   reference semantics)?
6. **Residency-only / FR-KVP1:** the delta must not touch buyer wire, receipts,
   billing, or cached_prompt_tokens.
7. **Test integrity:** do the new tests (`testCacheParametersDropsMaxKVSizeOnlyForEligibleRequests`,
   the MLX-gated persist test, the `(0..<8)` shape fix) assert the real invariant,
   not a tautology?

A clean delta is the expected outcome — do not manufacture findings. Report a
numbered list (severity / file:line / defect / failing scenario / fix) and note
which attacks you tried and could not land. End with exactly one line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
