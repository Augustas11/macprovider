# SPEC-038 FR-CB2 draft: decode and verification row isolation

This is draft text for `specs/SPEC-038-continuous-batching.md`, held here
because the release session (`cli/auto-cb-slots`) is also editing SPEC-038.
The operator coordinates when it lands. Version numbers assume v0.3.14 is
still the current version. If another SPEC-038 change lands first, renumber.

## Change log entry (insert above v0.3.14)

**Change log v0.3.15 (2026-10-10, decode and verification row isolation):**
FR-CB2: the kernel-route rule now also covers shared decode and packed MTP
verification. Rows of different lengths share one KV buffer padded to the
longest row. One attention call over that buffer masks the padding, but MLX's
vector attention kernels choose one or two passes, and the two-pass partition
count, from the padded key length. A row's reduction order therefore depended
on its neighbours (Studio, bfloat16, head dim 256: a 600-key or 901-key row
padded to 9000 keys was up to 2e-3 apart from its lone result). Each padded
row now attends in its own call over exactly its own keys. A decode forward
also carries no more rows than the device's quantized-matmul vector limit
allows, and a ragged prefill forward that attended outside the per-row path
fails its rows before sampling.

## FR-CB2 body (insert after the v0.3.14 paragraph that ends "...once it observes it.")

**(v0.3.15)** Shared decode and packed native-MTP verification MUST NOT
change any row's attention route. Rows of different lengths are stored
left-aligned in one buffer padded to the longest row. In the pinned MLX core
the vector attention kernels (query length at most 8) choose one or two
passes, and the two-pass partition count, from the key length of the call.
Over the padded buffer that is the longest row's length, so a single call
gives a shorter row a different floating-point reduction order than its lone
call. When the rows of a shared decode or verification forward differ in
key length, or a verification row has fewer real columns than the call
width, each row MUST attend in its own call over exactly its own keys and
query columns. That call MUST use the mask the row's lone call takes: none
for one decode token, the causal mask for a prompt chunk, and the row's own
slice of the packed verification mask. Padded verification columns attend
nothing and produce zeros. Rows of one length, with full-width verification
columns, keep the single call, which is already exact. Every other operator
stays batched. Rows whose layers present a per-row trimmed sliding window
keep the single call.

A shared decode forward multiplies every quantized projection by `M` rows,
one token per row. MLX takes `qmv` while `M` is below the projection's
vector limit `get_qmv_batch_limit(K, N, device)` and `qmm` at or above it,
so a decode forward MUST carry fewer rows than the smallest vector limit of
the device over every K and N. Measured on the pinned core, that allows 11
rows on Ultra devices, 5 on M1/M2 non-Ultra and 12 on M3-or-later non-Ultra.
When more rows are active, the scheduler MUST decode them in consecutive
forwards of at most that many rows. This is a per-forward bound; it does not
change the slot count.

A ragged prefill forward in which the model attended outside the per-row
path (it called SDPA itself) MUST be rejected before any token is sampled
or any row state is committed. Its rows fail with
`continuous_batching_prefill_failed` and are released, not retried, because
each row's paged cache already holds the chunk. Later ragged groups for that
model MUST prefill serially.

## AC-16 addition (FR-CB2)

Append to AC-16: a backend-driven bitwise test feeds rows with their own
histories through the shared decode cache, the ragged prefill cache and the
packed verification cache at served head dimensions, and requires each row's
attention output to match its lone call bit for bit. Each row cache must hold
exactly its own history plus its new tokens. A scheduler test requires every
decode forward to carry at most the configured decode row bound.

## CONFORMANCE mapping (SPEC-038-R002)

New tests to map:
- `PagedKVRuntimeBridgeTests.testSharedDecodeAndVerifyAttentionMatchLoneBitsAtServedHeadDims`
  (`testRaggedPrefillAttentionMatchesLoneCausalAttentionBitwise` keeps its mapping; it now drives the ragged batch cache)
- `PagedKVRuntimeBridgeTests.testRowAttentionExtentsSplitOnlyPaddedRows`
- `PagedKVRuntimeMixedCacheTests.testRaggedPrefillThatBypassesPerRowAttentionFailsItsRowsAndLaterGroupsRunSerially`
- `ContinuousBatchSchedulerTests.testDecodeRouteBoundFollowsTheCoreVectorLimitPerDevice`
- `ContinuousBatchSchedulerTests.testDecodeForwardsNeverCarryMoreRowsThanTheDecodeRouteBound`
