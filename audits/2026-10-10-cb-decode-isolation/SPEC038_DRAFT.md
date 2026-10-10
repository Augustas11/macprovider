# SPEC-038 FR-CB2 draft: decode and verification row isolation

Draft text for `specs/SPEC-038-continuous-batching.md`. It is held here
because the release session is also editing SPEC-038; the operator decides
when it lands. The numbers assume v0.3.16 (#1953) is current. If another
SPEC-038 change lands first, renumber.

## Change log entry (insert above v0.3.16)

**Change log v0.3.17 (2026-10-11, decode and verification row isolation):**
FR-CB2: the kernel-route rule now also covers shared decode and packed MTP
verification. Rows of different lengths share one KV buffer padded to the
longest row. MLX's vector attention kernels pick one or two passes, the
two-pass partition count and a no-mask GQA variant from the key length of
the call, so through one padded call a row's reduction order could depend on
its neighbours. On the Studio, before this change, served-model decode rows
of 600 and 901 keys beside longer rows had logits up to 0.75 apart from
their lone runs. A padded row whose own key length selects another route
than the padded call now attends in its own call over exactly its own keys.
Rows on the padded call's route keep sharing it, because within one route
padding does not change a row's bits. A decode forward also carries fewer
rows than the device's smallest quantized-matmul vector limit, so every
projection stays on `qmv`; at 16 rows in one forward on the Studio, rows
differed from their lone runs in 255 of 256 steps. A ragged prefill forward
that attended outside the per-row path fails its rows before sampling.

## FR-CB2 body (insert after the v0.3.14 paragraph that ends "...once it observes it.")

**(v0.3.17)** Shared decode and packed native-MTP verification MUST NOT
change any row's attention route. Rows of different lengths are stored
left-aligned in one buffer padded to the longest row. In the pinned MLX core,
a call with at most 8 query tokens takes the vector attention kernels. They
choose one or two passes, the two-pass partition count and, without an
array mask, a GQA first-pass variant from the call's key length. Both
kernels deal key `i` to partition `i mod P` and skip masked keys, so a
padded row gets its lone bits exactly when its own key length selects the
same route as the padded call. When rows differ in key length, or a
verification row has fewer real columns than the call:
- one padded call MAY serve every row whose lone route equals the padded
  call's route. The implementation ports the core dispatch for this, cites
  the core file, lines and fork tag, and pins every route boundary in a
  test. A row whose route cannot be determined MUST NOT share the padded
  call;
- every other padded row MUST attend in its own call over exactly its own
  keys and query columns, with the mask its lone call takes: none for one
  decode token, its own slice of the packed verification mask, and the
  causal mask for a prompt chunk. Padded verification columns attend nothing
  and produce zeros;
- prompt chunks (more than 8 query tokens) take the unfused path, whose GEMM
  blocking follows the key length, so every padded prompt row attends in its
  own call.

Rows of one length, with full-width verification columns, keep the single
call. Every other operator stays batched. Rows whose layers present a
per-row trimmed sliding window keep the single call. These rules hold inside
a multi-step lockstep window: every step attends over each row's keys as of
that step.

A shared decode forward multiplies every quantized projection by `M`
rows, one token per row. MLX takes `qmv` while `M` is below the projection's
vector limit `get_qmv_batch_limit(K, N, device)`, and `qmm` at or above it.
So a decode forward MUST carry fewer rows than the device's smallest vector
limit over every K and N. In the pinned core that is 11 rows on Ultra
devices, 5 on M1/M2 non-Ultra and 12 on M3-or-later non-Ultra. When more
rows are active, the scheduler MUST decode them in consecutive forwards of
at most that many. This is a per-forward bound, not the slot count.

A ragged prefill forward in which the model attended outside the per-row
path (it called SDPA itself) MUST be rejected before any token is sampled
or any row state is committed. Its rows fail with
`continuous_batching_prefill_failed` and are released, not retried, because
each row's paged cache already holds the chunk. Later ragged groups for that
model MUST prefill serially.

Packed verification also multiplies each quantized projection by
`rows x width` tokens. Whether a shared verify forward keeps every row on
its lone kernel route is measured separately (see the PR evidence). If it
does not, the rule above applies to verification with `rows x width` in
place of `rows`.

## AC-16 addition (FR-CB2)

Append to AC-16:
- Backend-driven bitwise tests run rows with their own histories through
  the shared decode cache, the ragged prefill cache and the packed
  verification cache at served head dimensions, across route boundaries and
  across an 8-step lockstep window. Each row's attention output must match
  its lone call bit for bit, and each row cache must hold exactly its own
  history plus its new tokens.
- A table test pins the vector-attention route port at every boundary.
- A scheduler test requires every decode forward to carry at most the
  decode row bound.
- On the Studio, the served-model probe (16 unequal rows at the serve
  window) must be bit-identical to each row's lone run with the cap.

## CONFORMANCE mapping (SPEC-038-R002)

New tests to map:
- `PagedKVRuntimeBridgeTests.testSharedDecodeAndVerifyAttentionMatchLoneBitsAtServedHeadDims`
- `PagedKVRuntimeBridgeTests.testSharedDecodeWindowAttentionMatchesLoneBitsEveryStep`
- `PagedKVRuntimeBridgeTests.testVectorAttentionRouteMatchesTheCoreDispatchBoundaries`
- `PagedKVRuntimeBridgeTests.testOnlyRowsInThePaddedCallsRouteShareIt`
- `PagedKVRuntimeBridgeTests.testRowAttentionExtentsSplitOnlyPaddedRows`
- `PagedKVRuntimeMixedCacheTests.testRaggedPrefillThatBypassesPerRowAttentionFailsItsRowsAndLaterGroupsRunSerially`
- `ContinuousBatchSchedulerTests.testDecodeRouteBoundFollowsTheCoreVectorLimitPerDevice`
- `ContinuousBatchSchedulerTests.testDecodeForwardsNeverCarryMoreRowsThanTheDecodeRouteBound`

`PagedKVRuntimeBridgeTests.testRaggedPrefillAttentionMatchesLoneCausalAttentionBitwise`
keeps its existing mapping; it now drives the ragged batch cache.
