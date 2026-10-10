# Round 2 (three lanes) and fixes

Round 2 ran on `f3274fc53`. Verdicts: code 0 C / 0 H / 2 M / 0 L;
security 0 C / 0 H / 0 M / 0 L; architecture 0 C / 0 H / 2 M / 0 L. Every
lane confirmed round-1 #1-#8 closed (code: #1 closed for the foreign-array
case, completed below).

| # | Lane / severity | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Code MEDIUM | Provenance did not prove mask equivalence: a cache-built ragged mask with a window (`makeMask(windowSize:)` on full-history caches) was replaced by `.causal`, and a supplied `.none` became `.causal` for multi-token queries. | The cache records only plain masks (padding and causality; for decode, a presented suffix inside the window). Split rows synthesize lone masks only under those; under any other array mask each split row attends with its own slice of it. An unmasked multi-token padded call is not isolatable (#2). Tests: `testRaggedPromptKeepsAWindowedMaskForSplitRows`, the foreign-mask test now checks the split row keeps the mask's exclusion. |
| 2 | Arch MEDIUM | Unsupported masks and other ineligible padded calls silently fell back to the padded call without the bypass flag. | Every padded call is isolated or flagged: stored-key mismatches, malformed masks, unmasked multi-token calls and unsupported layouts set `attendedOutsideCachePath`, so the backend fails that forward and serializes rows. Sliding-window decode rows are now isolated over their presented suffix (`testSlidingWindowDecodeRowsMatchTheirLoneBits`) instead of falling back. |
| 3 | Code MEDIUM | A split verify round continued into later groups after backend cancellation. | Each group checks cancellation before touching row state and again before installing transactions. |
| 4 | Arch MEDIUM | Stored FR-CB10 self-check decisions were not invalidated by the new routing. | `ModelRuntime.continuousBatchingSelfCheckRuntimeBuild` appends `+cb-isolation-v1/decode<N>/verify<N>` to the key's runtime build (ContinuousBatchingSelfCheck is unchanged); a stored refusal re-runs and a stored grant carries the Mac through the re-run (`testSelfCheckKeyCarriesTheRowIsolationPolicy`). |

Studio tests after the fixes (debug, metallib `f42aef60…`): PagedKVRuntimeBridgeTests
84/0, PagedKVRuntimeMixedCacheTests 12/0, HybridDecodeWindowExactnessTests 6/0,
ContinuousBatchSchedulerTests 168/0, PagedKVSlidingWindowTests 7/0,
PagedKVCacheStorageTests 9/0, ContinuousBatchingSelfCheckTests 25/0,
NativeMTPAcceptanceTests 8/0, ServingKnobsConfigTests 115/0.
