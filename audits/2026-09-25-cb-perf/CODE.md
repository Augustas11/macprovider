## Lane: CODE (correctness, concurrency, tests)

Check:
- In-place buffers:
  - aliasing: can a caller-held `MLXArray` (state getter, handoff,
    materialize, retained/serial conversation cache) be mutated by a later
    in-place write?
  - capacity growth and the `maxResidentTokens` cap;
  - trim then write;
  - block views after trim or growth;
  - `mutationCount` bookkeeping;
  - the ragged in-place path vs rebuild in `PagedKVBatchLayerCache`;
  - compiled writeback and `syncRowsFromBatch`.
- The prefill change: is anything still reading prefill logits (parity probe,
  harness, checkpoints)? For hybrid models, does `eval(state.caches)`
  materialise recurrent (`MambaCache`) state correctly, and is `output.state`
  still valid?
- The decode window: FR-CB5 join latency, cancellation latency, stop
  sequences mid-window, `maxOutputTokens` bounds, and interaction with
  recurrent checkpoint prefill chunks.
- Tests that would fail on a real regression.
