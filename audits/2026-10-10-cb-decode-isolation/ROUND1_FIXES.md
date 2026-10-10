# Round 1 (three lanes) and fixes

Verdicts: code 0 C / 0 H / 2 M / 0 L (+1 INFO); security 0 C / 0 H / 0 M / 1 L;
architecture 0 C / 0 H / 3 M / 2 L. Round 1 ran on `ae2b0da63`.

| # | Lane / severity | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Code MEDIUM | Split rows replaced any supplied array mask with `.none`/`.causal`, so a model-supplied mask could be dropped. | `PagedKVBatchLayerCache.makeMask` records the array masks it builds (weak table); `updateAndAttend` splits rows only when the supplied mask is one of them (or a mode), otherwise it keeps the single call with the mask as given. Test: `testPerRowAttentionKeepsTheSingleCallForForeignMasksAndMissingHistory`. |
| 2 | Code MEDIUM | Row extents came from logical offsets; a row at a positive offset with no stored keys would treat padding as history. | Eligibility also requires every row's `storedTokens` to equal its key extent (decode/prefill) or its pre-update offset (packed verify); otherwise one call. Same test. |
| 3 | Code INFO / Arch MEDIUM | A model that calls SDPA itself bypasses per-row attention in decode and verification; only ragged prefill was detected. | The base batch cache flags any padded update outside `updateAndAttend`. A flagged decode forward returns row failures before sampling, a flagged verify group throws (the scheduler aborts and fails the round), a flagged prefill fails its rows; then `serializesPaddedRows` makes the scheduler decode one row per forward and the backend verify one row per packed forward, and ragged groups stop. Test fakes now attend through the cache; the bypass test keeps a bypassing fake. |
| 4 | Arch MEDIUM | Route-table tests pin the Swift ports, not core; a core boundary change could pass. | `testCoreRoutingSourcesMatchThePortedDispatch` hashes the resolved core sources (`get_qmv_batch_limit`, the `sdpa_vector_2pass` partition and variant choice, the one/two-pass choice, `kernels/sdpa_vector.h`) and checks the vector-mode bound; the runbook says how to re-derive. |
| 5 | Arch MEDIUM | The verify-grouping probe bypassed production orchestration. | `testRealQwen35PackedNativeMTPRowsVerifiedInBoundedGroupsMatchSerialOrdinaryGreedy` runs the tiny real Qwen3.5 packed-MTP scheduler scenario (joins, early leave, depth-zero rows, cancel inside a committing round) with a 2-token verify bound and requires the serial greedy tokens and abort semantics. |
| 6 | Arch LOW | Runbook/draft trailed the verify bound. | Runbook and `SPEC038_DRAFT.md` describe the verify token bound, groups, the oversized-row exception and the tests; draft mapping lists the new tests. |
| 7 | Arch LOW | Provider-layer vs core-fork decision not recorded. | Recorded in the runbook routing exceptions. |
| 8 | Security LOW | New `*ForTest` hooks compiled into release. | Wrapped in `#if DEBUG || MACPROVIDER_LAB_HARNESS`. |

Studio tests after the fixes (debug, metallib `f42aef60…`): PagedKVRuntimeBridgeTests
82/0, PagedKVRuntimeMixedCacheTests 12/0, HybridDecodeWindowExactnessTests 6/0,
ContinuousBatchSchedulerTests 167/0, PagedKVSlidingWindowTests 7/0,
PagedKVCacheStorageTests 9/0, ContinuousBatchingSelfCheckTests 25/0,
NativeMTPAcceptanceTests 8/0.
