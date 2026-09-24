## Lane: CODE (correctness, concurrency, tests)

Check:
- The reattach trim-to-C and prefill-cursor alignment.
- The MambaCache restore: state layout per layer and dtype.
- Checkpoint chaining across turns.
- Every new await point: is a cancel recorded meanwhile honoured? This is the
  same class as the two step-1 races.
- Retained-sequence ownership and discard on every miss, fail, cancel and
  replay path, including leaks and double discards.
- Flag-off byte-for-byte equivalence.
- Tests that would fail on a real regression.
