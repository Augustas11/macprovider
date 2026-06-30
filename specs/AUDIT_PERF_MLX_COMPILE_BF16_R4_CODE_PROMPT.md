# perf/mlx-compile-bf16 — CODE-lane audit (round 4)

R3 CODE returned ACCEPT (0 C/H/M, 4 LOW — none promoted). This round
verifies the additional code changes made to address the SECURITY R3
MEDIUM (SEC-1) and the adversarial-verifier MEDIUM (ADV-1).

## Branch / commit
- Branch: `perf/mlx-compile-bf16`
- Worktree: `/Users/augstar/macprovider-perf-mlx`

## Files touched since R3
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`:
  - New `receiptsEnabled: Bool` stored field on the actor.
  - First `init` signature gains `receiptsEnabled: Bool = false`. The
    new field is captured into a `let castGuard = receiptsEnabled` local
    before the loader closure is built, then threaded through into
    `applyWeightCastIfEnabled(to:receiptsEnabled:)`. The bootstrap
    synchronous load also passes `receiptsEnabled` (using the
    just-stored field).
  - Second (test/mock) `init` initializes `receiptsEnabled = false`
    unconditionally with a comment explaining tests don't exercise
    receipts state.
  - `applyWeightCastIfEnabled(to:receiptsEnabled:)`: early-returns if
    env flag unset; if `receiptsEnabled == true`, emits a one-line
    stderr diagnostic and returns; otherwise calls
    `WeightCast.applyIfEnabled(to: context.model)` inside
    `container.perform`.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`:
  - `ServeCommand` passes `receiptsEnabled: resolved.enableReceipts`.
- `phase3-binary/Sources/macprovider-cli/CompiledDecode.swift`:
  - Docstring on `CompiledDecodeStep` now spells out the "construct
    AFTER prefill" precondition.
  - `init` adds `precondition(cache.allSatisfy { !$0.innerState().isEmpty })`
    when `enabled == true`. Empty-cache construction with `enabled: false`
    is still allowed (test path).

## Round-4 scope (narrow)

### SEC-1 fix correctness (CODE lens)
1. `let castGuard = receiptsEnabled` capture pattern: is this Swift-correct given the closure is `@Sendable`? The captured value is a `Bool` (Sendable). Confirm no implicit reference to `self` is captured.
2. The second `init` sets `receiptsEnabled = false` for ALL test/mock callers, even ones that might one day exercise receipts. Acceptable in this PR (no current test does), or should the second `init` also gain a `receiptsEnabled:` parameter?
3. The new `applyWeightCastIfEnabled` reads `WeightCast.isEnabledByEnvironment()` directly (without the env dictionary parameter the helper otherwise supports). Trace: does this short-circuit before `container.perform`, so the cost of the cast-skip path is bounded? Yes — early `return` before perform. Confirm.

### ADV-1 fix correctness (CODE lens)
1. `precondition(cache.allSatisfy { !$0.innerState().isEmpty })`: trace the failure mode when the precondition holds (single cache, populated) and when it doesn't (multi-layer cache where one layer's innerState is empty post-prefill — does that ever happen for KVCacheSimple?).
2. The precondition only fires when `enabled == true`. A future caller constructing the step with `enabled: false` (e.g. for the uncompiled fallback path) bypasses the check — correct, because the uncompiled path doesn't compile-trace.
3. The precondition message references the audit file path. Is hardcoding a doc path in a runtime message a maintenance risk? Acceptable given the precondition is a programmer-error guard (not a runtime-recoverable error).

### Regression check
- The 12 existing tests in `WeightCastTests.swift` still pass after the signature changes. Confirm no new compile errors in test mocks calling `ModelRuntime`.

## Required output format
Same as prior rounds. Bar: 0 CRITICAL/HIGH/MEDIUM.
If fully accepted: `ACCEPT — SEC-1 + ADV-1 fixes correct, no new findings`.
