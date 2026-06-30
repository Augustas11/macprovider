# perf/mlx-compile-bf16 — FULL IMPLEMENTATION re-audit (round 3)

You are one lane of a deeper-pass audit. Earlier rounds (R1+R2)
converged at 0 CRITICAL/HIGH/MEDIUM after fixing CODE-1 (quantized-
block filter) and SEC-2 (filename component path-traversal). The user
is now asking for a heavier-weight audit pass — full implementation,
no scope narrowing — to catch anything earlier rounds missed before
deciding between merge-to-production vs. e2e-testing-first.

## Branch / commit
- Branch: `perf/mlx-compile-bf16` (commit pushed to PR #265)
- Worktree: `/Users/augstar/macprovider-perf-mlx`
- Spec: `specs/perf-mlx-compile-bf16-upgrade.md`
- Reference design: https://github.com/Layr-Labs/d-inference/pull/482

## Lane assignment
Your lane is specified in the lane-specific section below. Stay
narrowly in your lane — the other lanes will catch what you skip.

## Full implementation surface

`git diff origin/main` covers:

**New code:**
- `phase3-binary/Sources/macprovider-cli/WeightCast.swift`
- `phase3-binary/Sources/macprovider-cli/CompiledDecode.swift`
- `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift`

**Modified:**
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` (subcommand registration only)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (calls `applyWeightCastIfEnabled` in BOTH the loader closure and bootstrap synchronous load path)

**Tests:**
- `phase3-binary/Tests/macprovider-cliTests/WeightCastTests.swift` (12 tests)

**Audits / docs (read-only context):**
- `audits/2026-06-30/mlx-upgrade-report.md`
- `audits/2026-06-30/perf-deferred.md`
- `audits/2026-06-30/perf-mlx-engine.md`
- `audits/2026-06-30/perf-mlx-compile-bf16-audit.md`

## What this PR ships

All new behavior behind env flags, defaults OFF. Production decode path is unchanged when both flags are unset.

- **Phase 1 (MLX upgrade research):** Documented Path C (stay on `mlx-swift-examples 2.29.1`); SwiftPM rejected the override attempt.
- **Phase 2 (bench harness):** New `macprovider-cli decode-bench` subcommand.
- **Phase 3 (bf16 cast):** `MACPROVIDER_BF16_WEIGHTS=1` enables fp16→bf16 weight conversion at load time, applied via `Module.apply` with a filter that rejects `any Quantized` subtrees.
- **Phase 4 (compile() decode scaffolding):** `MACPROVIDER_COMPILED_DECODE=1` recognized but NOT yet wired into `ModelRuntime`'s decode loop (runtime wire-in deferred to follow-up PR per spec's "correctness before perf" gate). The `CompiledDecodeStep` class is reviewable as-shipped.
- **Phase 5 (deferred docs):** Sliding-window rotating cache + MoE fused gate+up documented as model-family-gated deferrals.

## What you must NOT block on

- The deferred Phase 4 runtime wire-in is intentional and spec-compliant. Do not raise "compile() not actually used" as a blocker — that's by design.
- Live bench numbers are not in this PR. The spec mandates "default OFF in this branch — flip default in a follow-up after live evidence."
- Pre-existing warnings in `CoordinatorClient.swift` are not in scope for this PR.

## Lane-specific scope

### IF YOU ARE THE CODE LANE

Cover the implementation in `WeightCast.swift`, `CompiledDecode.swift`,
`DecodeBenchCommand.swift`, the wire-in in `ModelRuntime.swift`, and
the tests. Specifically look for:

1. **`WeightCast.nonQuantizedParameterFilter` correctness.** Trace through `mlx-swift-examples/Libraries/MLXLLM/` model definitions (Qwen / Llama). Are there parameter trees where a `Quantized` module hangs off a non-`Quantized` parent in a way that makes the filter prune too eagerly or not eagerly enough? Specifically: does `Module.apply` with `filter: closure` visit grandchildren whose immediate parent is non-Quantized but whose grandparent IS Quantized? Trace `filterMap` semantics in `mlx-swift/Source/MLXNN/Module.swift`.

2. **`WeightCast.castFloat16ToBFloat16` reentrancy.** What happens if `castFloat16ToBFloat16` is called twice (e.g. warm-swap leaves the model in bf16; the second swap re-applies)? Should be a no-op (after-cast there are no fp16 tensors), but verify the `Box`-based histogram + `apply` interaction is idempotent.

3. **`ModelRuntime.applyWeightCastIfEnabled` race.** The cast runs inside `container.perform { context in WeightCast.applyIfEnabled(to: context.model) }`. The `perform` block is `async throws`. `WeightCast.applyIfEnabled` is synchronous and calls `model.apply` which mutates in-place. After the cast returns and before `perform` returns, is there a window where another `perform` call could see the model in a half-cast state? (Likely no, because `container.perform` serializes — but trace it explicitly via `mlx-swift-examples/Libraries/MLXLMCommon/ModelContainer.swift`.)

4. **`CompiledDecodeStep` closure-capture lifecycle.** The forward closure captures `model` and `cache`. `MLX.compile(inputs:outputs:_:forward)` wraps the closure. When `CompiledDecodeStep` deallocs, does the compiled closure also dealloc, releasing the model+cache refs? Or does MLX retain the compiled closure in a global compile cache keyed by the closure's identity, leading to a leak per request? Check `Transforms+Compile.swift` for any global cache behavior.

5. **`DecodeBenchCommand` warmup-budget adequacy.** A single warmup run at `--tokens 256` (default) is the only warmup. After the warmup, the bf16 cast (if enabled) is already applied at load — but the compile() trace happens on first call. If a future caller enables compile and tries to bench with `--runs 3`, the first non-warmup run will pay the compile cost. Is that captured correctly in `prefillSeconds` (which currently includes everything up to first token), or does it leak into `decodeSeconds` and skew the p50?

6. **`DecodeBenchCommand.runOnce` timing semantics.** `firstTokenAt` is set on first non-empty callback. `generate(...)` may call the didGenerate callback once per token. Trace: is the first call's `tokens` array `[firstToken]` or `[token0, token1, ...]`? If batched, `firstTokenAt` undercounts the prefill phase. Check `Evaluate.swift` for the actual callback semantics.

7. **Test surface.** 12 tests. Coverage gaps to flag specifically:
   - No test for the `nonQuantizedParameterFilter` itself (just for env-flag parsing).
   - No test that exercises `applyIfEnabled` with a mock model.
   - The path-traversal sanitizer tests don't cover Unicode (RTL override U+202E, zero-width chars, NFC/NFD differences).

Bar: 0 CRITICAL/HIGH/MEDIUM. List LOW/NIT separately but do NOT block on them.

### IF YOU ARE THE SECURITY LANE

Cover the security implications of:
- Env-flag handling (both flags).
- `decode-bench` subcommand surface (file write, no auth bypass, no money-path).
- `applyWeightCastIfEnabled` race / state invariants.
- `CompiledDecodeStep` lifetime + retain cycles.
- The `sanitizeFilenameComponent` allowlist completeness.

New questions to weigh (didn't surface in R1):

1. **Does `MACPROVIDER_BF16_WEIGHTS=1` change the bytes that flow back to the buyer?** If the cast affects logits slightly (mantissa truncation: fp16 → bf16 loses precision in the small-magnitude range), the output text MAY differ from baseline. SPEC-015 receipts pin output hash. If two providers running identical model+config but different cast settings emit different bytes for the same prompt, do receipts diverge in a way that breaks attestation? Trace SPEC-015's hash domain.

2. **Does the cast change the `model_hash`?** The model hash is computed from on-disk weight manifest, not in-memory dtype. Confirm the cast does NOT touch the manifest computation. (Likely yes — the manifest hash runs BEFORE the model is loaded into memory — but verify.)

3. **Operator-supplied `--label` / `--model` / `--output-dir` post-fix.** With the sanitizer in place, can an operator still write outside `--output-dir` by setting `--output-dir` itself to an absolute path like `/etc/`? The sanitizer normalizes the filename component but `--output-dir` is unconstrained. Acceptable for an operator-local CLI?

4. **`decode-bench` token cost when run accidentally.** If an operator runs `decode-bench` on a coordinator-attached provider Mac that's currently serving paid traffic, the bench loads the model + does ~768 decode tokens × multiple runs. Does this perturb the serve runtime (separate process, no shared state) or does it conflict (single-instance lock, model directory contention)? Even though bench doesn't open the WS / HTTP server, two processes loading the same model at once may contend on the HuggingFace cache.

Bar: 0 CRITICAL/HIGH/MEDIUM.

### IF YOU ARE THE ARCHITECT LANE

Cover architectural fit, evolvability, and consistency with the rest
of the repo. R1 raised 5 LOWs + 1 NIT here — re-examine whether any
should be promoted given the full-implementation re-audit framing.

Specifically:

1. **Phase 4 split decision revisited.** Round 1 ARCH-2 flagged "scaffolding now, wire-in later" as LOW. Now that the PR is heading toward merge, re-examine: is the deferred wire-in better as (a) merge this PR as-is, then a follow-up PR with the wire-in + correctness gate, or (b) hold this PR until the wire-in lands, OR (c) merge but immediately open the follow-up PR draft so it doesn't slip? Recommend a specific path.

2. **`CompiledDecodeStep` API ergonomics.** When the runtime wire-in happens, callers will need to construct a `CompiledDecodeStep` per request, call `.step(token)` in a loop, and discard at end-of-request. Is this API correct, or should it expose a `forward(_:cache:)` style that takes the cache as a parameter (currently the cache is captured at init)? Cache-per-init means the step cannot be reused across requests — is that the right tradeoff?

3. **`decode-bench` divergence from `measureStartupThroughput`.** Both exist in the same binary. The startup-throughput helper at `ModelRuntime.swift:816` is used by the `serve` runtime to advertise capacity. The bench is for offline perf measurement. Could one supersede the other, or are they meaningfully different (timing semantics, output shape, callers)?

4. **Audit doc density (R1 ARCH-5 revisit).** This PR ships FIVE audit notes in `audits/2026-06-30/`. Is that the right model for future perf PRs (each gets its own audit folder), or should the repo establish a per-PR audit subdir convention? Recommend a posture for future PRs.

5. **Env-flag proliferation.** The repo already uses several `MACPROVIDER_*` env flags (`MACPROVIDER_MODEL`, `MACPROVIDER_CONFIG`, `MACPROVIDER_PORT`, ...). Adding two more (`MACPROVIDER_BF16_WEIGHTS`, `MACPROVIDER_COMPILED_DECODE`) is consistent, but is there a missing config-file plumbing that would let operators flip these without env vars? Recommend whether to add config-file fields in a follow-up.

6. **Pin tag drift.** The hardcoded `"mlxsx-2.29.1"` in `DecodeBenchCommand.swift` is tested against itself (the test compares the constant to a literal). When `Package.swift` bumps the pin, the test passes but the bench JSON misattributes. R1 noted this as LOW; in light of the upstream-issue follow-up the user is filing (asking ml-explore to bump their pin), this becomes more likely to actually fire. Promote to MEDIUM and require a fix in this PR, or accept as LOW with a follow-up issue?

Bar: 0 CRITICAL/HIGH/MEDIUM after considering whether any R1 LOW should be promoted.

## Required output format

For each finding:
```
- id: <LANE>-<n>
  severity: CRITICAL | HIGH | MEDIUM | LOW | NIT
  file: path/to/file (or "n/a" for doc/architecture-only)
  lines: "L:M" or "L:M..L:N" (or "n/a")
  finding: <one paragraph>
  recommendation: <concrete fix, "accept as LOW", or "promote from R1 LOW">
```

End with: `# tally: critical=<n> high=<n> medium=<n> low=<n>`.

If fully accepted: `ACCEPT — no CRITICAL/HIGH/MEDIUM findings`.
