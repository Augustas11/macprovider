## Lane: CODE (correctness, MLX semantics, tests)

Check:
- Row/token order through `sample`.
- The dtype and shape of concatenated per-row samples, fed back as the next
  input in the compiled path.
- Step indexing across lockstep windows and across batch rebuilds (does
  `samplerStep` advance exactly once per generated token?).
- Equivalence of the parameters with the serial path, including the
  temperature/top_p defaults and the Float conversion.
- The strict-mode test change.
- Tests that would fail on a real regression.
