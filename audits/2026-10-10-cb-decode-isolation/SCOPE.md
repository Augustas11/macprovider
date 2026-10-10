# Freeze diff: continuous-batching decode isolation (#1906 follow-up to #1927)

Audit the COMPLETE diff as it will land. Read it yourself (run the command; do
not rely on summaries). `$MACPROVIDER` is this repository on the branch
`fix/cb-decode-isolation`:

    git -C "$MACPROVIDER" diff origin/main...HEAD -- . ':(exclude)audits'

Context (read as needed): `audits/2026-10-10-cb-decode-isolation/probes/`
(Studio bitwise and throughput evidence), `SPEC038_DRAFT.md` (the intended
SPEC-038 FR-CB2 text, held back because another session edits SPEC-038),
`specs/SPEC-038-continuous-batching.md` FR-CB2 as on main, and the pinned MLX
core sources for the kernels named below (fork `Augustas11/mlx` at tag
`v0.32.2-macprovider.2`: `mlx/backend/metal/scaled_dot_product_attention.cpp`,
`mlx/backend/metal/kernels/sdpa_vector.h`, `mlx/backend/metal/quantized.cpp`).

What the change is:

1. Rows of different lengths share one paged KV buffer padded to the longest
   row. One SDPA call over it masks the padding, but MLX's vector attention
   kernels (decode, query length <= 8) choose one or two passes, the two-pass
   partition count, and a no-mask GQA variant from the padded key length, and
   the unfused prompt path blocks GEMMs by it, so a row's floating-point
   reduction order depended on its neighbours. `PagedKVBatchLayerCache` now
   implements `KVCacheAttentionProtocol.updateAndAttend`: when rows differ in
   key length, or a packed native-MTP verify row has fewer real columns than
   the call width, each row attends in its own SDPA call over exactly its own
   keys and query columns, with the mask its lone call takes (none for one
   decode token, causal for a prompt chunk, its slice of the packed verify
   mask). Equal rows keep one call. The ragged prefill subclass keeps only
   bypass detection.
2. A ragged prefill forward whose model attended outside the per-row path is
   rejected before sampling or committing; its rows fail and are released.
3. `ContinuousBatchDecodeRouteBound` ports core `get_qmv_batch_limit`; the
   scheduler caps each ordinary decode forward at the device's smallest
   vector limit minus one rows (Ultra 11, M1/M2 non-Ultra 5, M3+ 12) and
   decodes more active rows in consecutive forwards. A lab-harness-only env
   override exists for measurement.
4. Packed native-MTP verification multiplies each quantized projection by
   rows x width tokens; `verifyNativeMTPPackedRound` now splits a round into
   consecutive packed forwards of at most the same device bound in target
   tokens, re-indexing each group and restoring packed row indices.
5. Within one vector-attention route (pass count, partition count, `_gqa`
   first pass) padding does not change a row's bits, so the padded call is
   kept for rows whose lone route equals it (`PagedKVVectorAttentionRoute`,
   a port of core's dispatch pinned by a source-digest test); only the
   others split. Split rows use lone masks only under masks the cache built.
6. Any padded update that reaches the batch cache outside `updateAndAttend`
   (prefill, decode, verify) fails that forward before sampling; the backend
   then serializes rows (decode bound 1, one verify row per forward).
7. Test-only hooks on `PagedKVSharedForwardBackend` (`*ForTest`, compiled
   only in DEBUG or the lab harness) and env-gated served-model probes
   (`CBDecodeIsolationProbeTests`).

Round 1 findings and their fixes: `ROUND1_FIXES.md` (check that each is
closed).

Studio evidence: see `probes/` and the PR body (bitwise before/after on
Qwen3.6-35B-A3B fused on/off and 27B, startup probes, throughput, R015).

Repo is PUBLIC. Report findings only; do not edit files.

Output format: a list of findings, each with severity
(CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, the concrete failure scenario, and
a suggested fix. End with one line:
`VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW`.
