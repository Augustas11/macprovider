# RE-VERIFY — SPEC-037 observable unsupported-cache-class skip + serve-site test

Two MEDIUM findings were raised against a prior change and then fixed. Verify the
fixes resolve them AND that the fix introduced no new defect. Judge only the code.

## Context
SPEC-037 encrypted KV disk survival tier (residency-only, default-off,
synthetic-key-only). The tier only serializes `KVCacheSimple`. A prior fix made
serve build `KVCacheSimple` for tier-eligible requests via
`GenerateParameters.maxKVSize = nil`. Two MEDIUMs were then found:
- **MEDIUM-A:** some model families OVERRIDE mlx-swift-lm `newCache` and ignore
  `maxKVSize` (gpt-oss/gemma-4/nemotron), so eligible requests on those models
  still get a non-`KVCacheSimple` cache and `captureSnapshot` SILENTLY returned nil
  (silent no-op). Also the load-time seed silently didn't populate for them.
- **MEDIUM-B:** no test exercised the serve `newCache` site, so a regression
  reverting it would pass green; the MLX test's docstring falsely claimed it would
  catch the shipped no-op.

## The fix to verify
Read `audits/2026-07-27/OBSERVABLE_SKIP_DELTA.diff` and the full current text of
the touched files (`KVConversationColdTierAdapter.swift` captureSnapshot,
`KVDiskCacheStore.swift` noteUnsupportedCacheClassSkipped ~1588, `ModelRuntime.swift`
seedColdGeometry ~2148 + logColdTierUnsupportedCacheClass ~2175,
`KVDiskCacheFormat.swift` the new `.unsupportedCacheClass` reason, and the new/edited
tests in `KVConversationColdTierTests.swift`).

The fix: (1) captureSnapshot's `as? [KVCacheSimple]` cast-failure now fires
`Task { [store] in await store.noteUnsupportedCacheClassSkipped(...) }` emitting
`disk_write_skipped(detail=unsupported_cache_class, cache_class=<class>)` before
returning nil; (2) seedColdGeometry logs `event=kv_disk_tier_unsupported_model`
once at attach when its forced-simple warmup doesn't yield `[KVCacheSimple]`;
(3) new tests: `testEligibleServeNewCacheProducesKVCacheSimple` (a
`FakeDimensionModel: LanguageModel, KVCacheDimensionProvider` driving the stock
`newCache`, asserting maxKVSize=nil→[KVCacheSimple], set→RotatingKVCache) and
`testCaptureSnapshotEmitsObservableUnsupportedCacheClassSkip`.

## Verify (state resolved/not-resolved for each)
1. **MEDIUM-A resolved?** Does EVERY non-`KVCacheSimple` path through captureSnapshot
   now emit the observable skip (not silent nil)? Are there other silent `return nil`
   branches in captureSnapshot that should also be observable (identity, budget — those
   already have skips; confirm the cache-class one is complete)? Is the emitted event
   actually reachable by an operator (right sink, right reason/detail, class name
   populated)?
2. **MEDIUM-B resolved?** Does `testEligibleServeNewCacheProducesKVCacheSimple` truly
   pin the production invariant — i.e. does `FakeDimensionModel.newCache` run the SAME
   mlx-swift-lm class-selection code that Llama/Qwen3 inherit (RotatingKVCache iff
   maxKVSize != nil)? Would a regression reverting the serve site to
   `newCache(parameters: parameters)` now be caught by a test? Is the reworded docstring
   now accurate?
3. **New defects from the fix?** (a) The detached `Task { [store] in await ... }` in
   captureSnapshot — any lifetime/ordering/actor-reentrancy problem, lost emission, or
   retain issue? Compare to the existing `noteWriteBudgetSkipped` detached emission it
   mirrors. (b) The split guard in seedColdGeometry — does splitting the combined guard
   change any prior behavior (does the seed still skip cleanly, still best-effort, no
   crash when warmup fails)? (c) Does `logColdTierUnsupportedCacheClass` fire at most
   once and not spam per request? (d) Any FR-KVP1 (residency-only) impact?
4. **Test integrity:** do the new tests assert real behavior (not tautology)? Does the
   observable-skip test actually assert the emitted reason/detail/class, not just non-nil?

A clean verdict is expected if the fixes hold. Report per-item resolved/not + any new
finding (severity/file:line/defect/fix). End with exactly one line:
`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`
PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
