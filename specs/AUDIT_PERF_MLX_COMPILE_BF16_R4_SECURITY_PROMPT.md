# perf/mlx-compile-bf16 — SECURITY-lane audit (round 4)

R3 returned ONE MEDIUM (SEC-1: bf16 weight cast vs. SPEC-015 model_hash
attestation). This round verifies the fix.

## Branch / commit
- Branch: `perf/mlx-compile-bf16`
- Worktree: `/Users/augstar/macprovider-perf-mlx` (unpushed delta on top of PR #265 head)

## Files touched since R3
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`:
  - New stored field `receiptsEnabled: Bool` on the actor.
  - First `init` gains a `receiptsEnabled: Bool = false` parameter, plumbs it into both the warm-swap loader closure and the bootstrap synchronous load path.
  - Second (test/mock) `init` defaults `receiptsEnabled = false` (tests do not exercise receipts state).
  - `applyWeightCastIfEnabled(to:receiptsEnabled:)` now: (a) checks env flag first; (b) if `receiptsEnabled == true`, writes a one-line stderr `event=bf16_weight_cast_skipped reason=receipts_enabled` diagnostic and returns WITHOUT applying the cast; (c) otherwise runs the cast as before.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`:
  - `ServeCommand.run()` passes `receiptsEnabled: resolved.enableReceipts` to the new `ModelRuntime` init.
  - `SelfTestCommand` continues to use the default `receiptsEnabled = false` (self-test never emits receipts).
- `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift`: unchanged. The bench command's `ModelRuntime(modelID:)` invocation uses the default `receiptsEnabled = false`, so the bench command is unaffected and can continue to exercise the bf16 cast for measurement.

## Round-4 scope (narrow)

### SEC-1 (R3) verification
1. Does the guard correctly fire on the serve path? Trace `ServeCommand.run()` → `ModelRuntime.init(...)` → loader closure → `applyWeightCastIfEnabled(to:receiptsEnabled:)`. With `MACPROVIDER_BF16_WEIGHTS=1` AND `resolved.enableReceipts == true`, the cast should NOT run.
2. Does the guard correctly NOT fire on the bench path? Trace `DecodeBenchCommand.run()` → `ModelRuntime(modelID:)` (no `receiptsEnabled` arg) → loader closure → `applyWeightCastIfEnabled(to:receiptsEnabled: false)`. With env flag set, the cast SHOULD run.
3. Warm-swap path: the loader closure captures `castGuard = receiptsEnabled` at init time. Confirm: if `receiptsEnabled` were to change post-init (it cannot — `let` constant; verify), the warm-swap would respect the value-at-init, which is the right semantics.
4. Stderr diagnostic content: contains `MACPROVIDER_BF16_WEIGHTS=1 ignored` and the rationale. No PII, no operator token, no model paths.

### Regression check on unchanged SEC scope
- R3 SEC-2 was LOW (decode-bench `--output-dir` absolute-path concern, accepted as residual). No code changed; should still be LOW or accepted.
- ADV-1 (CompiledDecodeStep empty-cache precondition) was addressed in this same round via a precondition + docstring update in `CompiledDecode.swift`. Not in your scope (code lane), but noted for context.

## Required output format
Same as R3. Bar: 0 CRITICAL/HIGH/MEDIUM.
If fully accepted: `ACCEPT — SEC-1 (R3) resolved, no new findings`.
