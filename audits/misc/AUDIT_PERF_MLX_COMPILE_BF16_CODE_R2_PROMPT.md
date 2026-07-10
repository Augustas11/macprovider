# perf/mlx-compile-bf16 — CODE-lane audit (round 2)

Round 1 returned ONE LOW (CODE-1, WeightCast quantized-block filter).
This round verifies the fix and re-checks the same scope for new regressions.

## Branch / commit
- Branch: `perf/mlx-compile-bf16` (same worktree)
- Files touched since round 1:
  - `phase3-binary/Sources/macprovider-cli/WeightCast.swift` —
    introduces `nonQuantizedParameterFilter` (rejects any descent into
    `any Quantized` module before falling back to
    `Module.filterValidParameters`); both `castFloat16ToBFloat16` and
    `DTypeHistogram.init` use it.

## Round-2 scope (narrow)

### CODE-1 (R1) verification
- The new filter is `(module, key, item) -> Bool` with the shape:
  `module is any Quantized ? false : Module.filterValidParameters(module, key, item)`.
- Does this correctly prune the ENTIRE subtree of a Quantized module
  (`.weight`, `.scales`, `.biases`), or does mlx-swift's `apply`
  descend into the module's children even when the filter rejects
  the module itself? (Trace `Module.apply` → `update(parameters:)`
  → `filterMap(filter:map:)` resolution path in
  `phase3-binary/.build/checkouts/mlx-swift/Source/MLXNN/Module.swift`.)
- Is `@Sendable` required on the closure type? The closure references
  no captured state; verify the type matches `apply`'s signature
  exactly.
- `DTypeHistogram.init`'s use of the same filter means the
  *diagnostic* now excludes quantized scales/biases. Confirm this is
  the desired semantics (the diagnostic should mirror what the cast
  actually touches).
- Is there any sample model in the autotune candidate set whose
  parameter tree's structure makes this filter wrong (e.g. a model
  that mixes quantized and non-quantized layers in the same parent)?
  Verify by inspection of MLXLLM model definitions in
  `phase3-binary/.build/checkouts/mlx-swift-examples/Libraries/MLXLLM/`.

### Regression check on unchanged scope
- All other CODE-* items from round 1 were ACCEPTed implicitly (no
  finding). Re-confirm the unchanged files (`CompiledDecode.swift`,
  `DecodeBenchCommand.swift` apart from the SEC-2 fix, `MacProviderCLI.swift`,
  `ModelRuntime.swift`) have NOT regressed.

## Required output format
Same as round 1. Bar: 0 CRITICAL/HIGH/MEDIUM.

If fully accepted, the body can be `ACCEPT — CODE-1 (R1) resolved, no
new findings`.
