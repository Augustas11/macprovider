# perf/mlx-compile-bf16 — CODE-lane audit (round 1)

You are the **code** lane of a three-lane audit (code / security /
architect) of the `perf/mlx-compile-bf16` branch. Stay narrowly in
your lane.

## Branch / commit
- Branch: `perf/mlx-compile-bf16`
- Worktree: `/Users/augstar/macprovider-perf-mlx` (rebased on origin/main HEAD = 1ba48fa)
- Spec: `specs/perf-mlx-compile-bf16-upgrade.md`
- Reference design: https://github.com/Layr-Labs/d-inference/pull/482

## Files in scope (`git diff origin/main`)

New code:
- `phase3-binary/Sources/macprovider-cli/WeightCast.swift` — fp16→bf16 cast helper, env-flag gated, dtype histogram.
- `phase3-binary/Sources/macprovider-cli/CompiledDecode.swift` — `MLX.compile()` decode-step scaffolding, env-flag gated, `KVCacheUpdatableAdapter` for cache state threading.
- `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift` — `decode-bench` subcommand (pure-decode benchmark, JSON output).

Modified:
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` — registers `DecodeBenchCommand`.
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — calls `applyWeightCastIfEnabled` in BOTH the loader closure and bootstrap synchronous load path.

New tests:
- `phase3-binary/Tests/macprovider-cliTests/WeightCastTests.swift` — 8 tests covering env-flag parsing, percentile math, pin tag.

New audit notes (read-only context):
- `audits/2026-06-30/mlx-upgrade-report.md`
- `audits/2026-06-30/perf-deferred.md`
- `audits/2026-06-30/perf-mlx-engine.md`

## What this change does (operator summary — NOT the audit answer)

Lands the upstream-portable subset of d-inference#482's MLX decode
perf work on our `mlx-swift-examples 2.29.1` pin. Phase 1 confirmed
the pin is already at HEAD; an attempted Path B mlx-swift override
was rejected by SwiftPM (`.upToNextMinor` intersection failure), so
Path C (stay) shipped. Phases 3 (bf16 weight cast) and 4 (compile()
decode wrapper) ship as new code behind env flags
(`MACPROVIDER_BF16_WEIGHTS=1`, `MACPROVIDER_COMPILED_DECODE=1`) with
defaults OFF. The compile() runtime wire-in is intentionally deferred
to a follow-up PR that can run the correctness gate on M-series
hardware; the scaffolding is reviewable in this PR. A new
`decode-bench` subcommand provides a coordinator-free, WS-free decode
benchmark with versioned JSON output to `state/perf/`.

Production decode path is unchanged when both env flags are unset.

## Code-lane scope (apply each; stay in lane)

### CODE-1. `WeightCast.swift` correctness
- `isEnabledByEnvironment(_:)`: parses `MACPROVIDER_BF16_WEIGHTS`. Truthy: `1`, `true`, `yes` (case-insensitive, whitespace-trimmed). Trace: empty string, "maybe", "0", missing key.
- `castFloat16ToBFloat16(_:)`: calls `model.apply { array in array.dtype == .float16 ? array.asType(.bfloat16) : array }`. Apply's default filter is `Module.filterValidParameters` — confirm this excludes quantized blocks (per the MLXNN Module docs at line 545). Trace: does `apply` also visit embedding / lm_head / norm tensors? What about `RMSNorm.weight` (typically fp32)?
- `applyIfEnabled(to:env:logger:)`: short-circuits when flag off (does NOT touch the model). The diagnostic stderr line uses `event=bf16_weight_cast before=…` — readable, single-line, no PII.
- `DTypeHistogram(model:)`: uses a `Box` class to capture mutation inside the `apply` closure. Confirm Swift compiles this without warning — the `Box` workaround exists because `init` cannot capture `self` for mutation through an `@escaping` closure. Is there a cleaner pattern (e.g. just compute counts via `model.leafModules().reduce`)?

### CODE-2. `CompiledDecode.swift` correctness
- `isEnabledByEnvironment(_:)`: same shape as WeightCast — symmetry check.
- `KVCacheUpdatableAdapter`: `final class` holds `KVCache` by ref, implements `innerState() -> [MLXArray]` by forwarding. The KVCache protocol declares `Evaluatable` (same signature), but the adapter exposes `Updatable`. Trace: does the adapter's `innerState()` reflect the most-recent cache state on every call? (Cache `update(...)` mutates `keys` / `values` ivars; the adapter's forward should pick those up.)
- `CompiledDecodeStep.init`: builds the forward closure capturing `model` and `cache` by reference. The closure is `(MLXArray) -> MLXArray`, calling `model(token, cache: cache.isEmpty ? nil : cache)`. Trace: is `cache.isEmpty` re-evaluated on every call (closure captures the *array*, which is value-type → captured copy → empty check is stable for that closure)? Or is the intent that `cache` is non-empty after prefill?
- `MLX.compile(inputs: updatables, outputs: updatables, shapeless: false, forward)`: passing the same updatables in both `inputs:` and `outputs:` is the canonical mutable-state pattern. Confirm against `Transforms+Compile.swift` line 137 docstring.
- `step(_:)`: returns `compiled(token) ?? uncompiled(token)`. The uncompiled fallback is always available even when `enabled == true` and `compiled != nil` — verify no scenario where `compiled` is non-nil but should not be used.
- **Wire-in caveat**: `CompiledDecodeStep` is NOT yet called from `ModelRuntime`'s decode loop. The runtime decode path still goes through MLXLMCommon's `generate(...)` unchanged. The audit comment from `perf-mlx-engine.md` documents this. Confirm: are the env-flag short-circuits correct given that the runtime ignores `MACPROVIDER_COMPILED_DECODE` today? (Expected: yes, because reading the env in the runtime would be dead code until wire-in.)

### CODE-3. `DecodeBenchCommand.swift` correctness
- `run()`: requires `--model` OR `MACPROVIDER_MODEL`; validates positive `--tokens`, `--prefill`, `--runs`. Trace error paths: ExitCode(2) vs ExitCode(1).
- `runOnce(...)`: timing model:
  - `prefillStart` = before `container.perform`.
  - `firstTokenAt` = on first non-empty callback batch.
  - `endAt` = after `container.perform` returns.
  - `prefillElapsed` = `firstTokenAt - prefillStart` (covers tokenization + processor.prepare + model load-cache + first forward).
  - `decodeElapsed` = `endAt - firstTokenAt`.
  - `decodeTPS` = `(generationTokens - 1) / decodeElapsed` (the `-1` excludes the first token timed in prefill).
  - Edge case: `generationTokens == 0` → `max(generationTokens - 1, 0)` → 0 TPS. Acceptable.
- Warmup: run index 0 is `isWarmup=true`, not included in `samples`. Confirm the warmup token count (256 by default) is large enough to amortize the model's first-forward warmup cost on M-series.
- File output: `state/perf/<label>-<modelTag>-<pinTag>-<ts>.json`. Atomic write. `modelTag` is the last path segment of `--model` — collision if two different orgs publish same-named model. Acceptable risk?
- `mlxSwiftExamplesPinTag()` hardcodes `"mlxsx-2.29.1"`. Drift risk if `Package.swift` pin bumps without updating this constant. The `testPinTagMatchesPackageSwiftPin` test pins the value but does not re-parse Package.swift. Acceptable for v0.1 of this work? Suggest a follow-up.
- `percentileTPS(_:p:)`: nearest-rank percentile. For 3 samples sorted, p=0.5 → `rank = round(0.5 * 2) = 1` → middle element ✓. For 1 sample → returns it ✓. For empty → 0.0 ✓.

### CODE-4. `ModelRuntime.swift` wire-in
- `applyWeightCastIfEnabled(to:)`: static func, calls `container.perform { context in WeightCast.applyIfEnabled(to: context.model) }`. Trace:
  - Is `container.perform` the correct execution context to mutate `context.model.apply { ... }`? (The container is single-threaded by design; perform serializes access.)
  - The closure runs `apply` which mutates parameter MLXArrays in-place. The container's `update` method exists for atomic context replacement (line 79 of ModelContainer.swift); we're NOT calling that. Is in-place parameter mutation safe inside `perform`?
- Two call sites: loader closure (line ~278) AND bootstrap synchronous load (line ~295). Both invoke the same helper. Trace: any path where the cast could be skipped (e.g. test loader, no-modelID branch)? The `guard let modelID else { return }` short-circuit on `nil` is intended (no model to cast).

### CODE-5. Tests adequacy
- `WeightCastTests`: 2 env-flag tests for WeightCast, 2 for CompiledDecode flag, 4 for bench helpers. No live model coverage (documented decision — model load is out-of-band).
- Missing coverage to flag? Specifically:
  - Does the symmetry between `WeightCast.isEnabledByEnvironment` and `CompiledDecode.isEnabledByEnvironment` warrant a shared helper, or is duplication intentional (no cross-coupling)?
  - The bench command's JSON schema is versioned (`schemaVersion: 1`) but no test asserts the round-trip. Acceptable for v0.1?

## Out of scope for THIS lane
- Security review: defer to security lane.
- Architectural fit (does this match the rest of the repo's perf-feature pattern?): defer to architect lane.
- The deferred-items audit (`perf-deferred.md`): documentation only, no code to audit.

## Required output format

For each finding, emit a YAML entry:
```
- id: CODE-<n>
  severity: CRITICAL | HIGH | MEDIUM | LOW | NIT
  file: path/to/file.swift
  lines: "L:M" or "L:M..L:N"
  finding: <one paragraph>
  recommendation: <concrete fix or accept/reject>
```

End with a one-line tally: `# tally: critical=<n> high=<n> medium=<n> low=<n>`.

Bar: 0 CRITICAL/HIGH/MEDIUM. LOW/NIT are tracked but not blocking.
If 0 findings at all lanes, the body of the next round can be
`ACCEPT — no further work in this lane`.
