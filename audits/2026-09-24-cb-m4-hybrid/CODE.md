## Lane: CODE (correctness, MLX state semantics, concurrency, tests)

Check:
- Checkpoint positions and chunk-split math, including off-by-one at C.
- Whether a restored recurrent state exactly corresponds to C tokens, and
  whether the attention trim leaves offset == C (`begin` trims by
  `canonical.count - C`).
- Checkpoint freshness: re-snapshot vs reuse on a hit that is already past a
  checkpoint.
- MambaCache `state` aliasing: can a later in-place update ever mutate a stored
  snapshot?
- Materialize correctness and token-count consistency, including the dropped
  trailing stop and tokens decoded past the stop within a lockstep window.
- Cancellation and failure leaks.
- Scheduler actor reentrancy around the snapshot and materialize awaits.
- Tests that would fail on a real regression.
