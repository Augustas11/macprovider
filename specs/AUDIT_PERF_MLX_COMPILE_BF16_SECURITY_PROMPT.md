# perf/mlx-compile-bf16 — SECURITY-lane audit (round 1)

You are the **security** lane of a three-lane audit. Stay narrowly
in your lane.

## Branch / commit
- Branch: `perf/mlx-compile-bf16`
- Worktree: `/Users/augstar/macprovider-perf-mlx` (rebased on origin/main HEAD = 1ba48fa)
- Spec: `specs/perf-mlx-compile-bf16-upgrade.md`

## Files in scope (`git diff origin/main`)
- `phase3-binary/Sources/macprovider-cli/WeightCast.swift` (new)
- `phase3-binary/Sources/macprovider-cli/CompiledDecode.swift` (new)
- `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift` (new)
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` (subcommand registration)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (bf16 cast wire-in, 2 call sites)
- `phase3-binary/Tests/macprovider-cliTests/WeightCastTests.swift` (new tests)
- `audits/2026-06-30/*` (read-only context)

## What this change does

Adds opt-in (env-flag gated, defaults OFF) perf paths:
1. fp16→bf16 weight cast at model-load time (warm-swap loader and bootstrap).
2. `MLX.compile()` per-token decode scaffolding (NOT yet wired into runtime decode loop).
3. New `decode-bench` CLI subcommand that loads a model and runs a pure-decode benchmark, writing JSON to `state/perf/`.

Money-path code (billing, gateway, coordinator, receipts) is NOT touched.

## Security-lane scope

### SEC-1. Env-flag handling
- `MACPROVIDER_BF16_WEIGHTS` and `MACPROVIDER_COMPILED_DECODE` are read via `ProcessInfo.processInfo.environment`. Both default OFF. Trace:
  - Can either flag's value leak into logs, receipts, or coordinator wire messages? (Grep for the flag names elsewhere.)
  - Does flipping the bf16 flag at runtime (e.g. via a `kill -HUP` re-read) create any state inconsistency? (The cast is applied at load time only — confirm.)
  - Is the `applyIfEnabled` stderr diagnostic safe (no PII, no operator token, no model path leakage)?

### SEC-2. Decode-bench subcommand surface
- `decode-bench` accepts `--model`, `--output-dir`, `--label`.
- `--output-dir` defaults to `state/perf/` (relative) — confirm no path-traversal risk if an operator runs the binary from `/` or with a malicious cwd. The code uses `URL(fileURLWithPath:)` + `createDirectory(at:withIntermediateDirectories:)` + `write(to:options:[.atomic])`. Trace: can `--output-dir` be set to `/etc/` or similar privileged path and silently fail? Is failure-mode loud enough for operators?
- `--label` and `--model` are interpolated into the output filename. Trace: shell metacharacters, path separators (`/`, `\`), null bytes, very long values. The code uses `String` concatenation, not shell exec — but filename injection could still produce unexpected paths (`label=../../etc/passwd` → file at `state/perf/../../etc/passwd-<model>-…json`). Acceptable for an operator-only CLI subcommand, or worth sanitizing?
- The bench command honors `MACPROVIDER_MODEL` fallback — same security posture as `serve` (already audited). Confirm no new surface.

### SEC-3. `decode-bench` does not bypass authentication
- The bench command loads `ModelRuntime` directly. It does NOT start the HTTP server, does NOT open a coordinator WS, does NOT register a control socket. Confirm: no path where an attacker could trigger inference (and thus billable / metered work) via the bench surface.
- The bench command is operator-local (`macprovider-cli decode-bench`); not exposed via the coordinator API, the buyer API, or the gateway. Confirm no inadvertent surface in `phase4-coordinator/` or `phase5-gateway/`.

### SEC-4. ModelRuntime cast wire-in
- The bf16 cast runs INSIDE `container.perform { ... }`, which is the container's serial execution context. Confirm:
  - The cast cannot race with a concurrent inference (the container serializes).
  - The cast cannot race with a concurrent warm-swap (the loader closure is invoked during `beginSwap`, before the new container is swapped in).
  - The cast doesn't perturb the model hash (`modelWeightArtifactManifestHash`) — the hash is computed from on-disk weight files via the configuration's `modelDirectory()`, NOT from in-memory dtypes. Confirm.
- Receipt integrity invariant: SPEC-015's receipts include `model_hash` from the on-disk manifest. The cast happens AFTER the hash is computed (or in parallel via warm-swap). Trace: is there any code path where a cast would change a hash-derived value used in receipts?

### SEC-5. CompiledDecode adapter scope
- `KVCacheUpdatableAdapter` holds a `KVCache` reference. The adapter is constructed in `CompiledDecodeStep.init` and discarded with the step. Trace: any retain cycle (KVCache → adapter → KVCache)? The adapter is `final class`, the cache is held via `let cache: KVCache`, no reverse reference. Likely clean — confirm.
- The `MLX.compile()` invocation produces a `@Sendable ([MLXArray]) -> [MLXArray]` (or the single-array overload). The captured `model` and `cache` references must outlive every step call. Trace: lifetime of the compiled closure vs `CompiledDecodeStep`. Closure is stored as `compiled: ((MLXArray) -> MLXArray)?` — held by the step. Step held by the caller (eventually `ModelRuntime`'s decode loop in follow-up). OK as long as step is discarded at end-of-request.

### SEC-6. Untrusted input
- bf16 cast: input is the loaded model, sourced from disk via `LLMModelFactory.shared.loadContainer(configuration:)`. Trust boundary = config-supplied model ID + HuggingFace download path. No new attack surface vs status quo.
- compile() wrapper: input is the prompt's tokens (already trust-boundary-crossed at the HTTP layer); the wrapper does not parse, deserialize, or otherwise interpret the tokens — it forwards `MLXArray` to the model. No new injection surface.
- decode-bench: prompt is hardcoded `"Summarize the following technical document. "` × replications. Not user-controlled. Trust boundary irrelevant.

### SEC-7. Dependency posture
- No new third-party dependencies. The change uses MLX / MLXLMCommon / MLXLLM / MLXNN APIs already pulled via `mlx-swift-examples 2.29.1`. Confirm: no `.package` additions in `Package.swift`.

### SEC-8. Logging / diagnostic surface
- `applyIfEnabled` writes one stderr line: `event=bf16_weight_cast before=fp16=...,bf16=...,fp32=...,other=... after=...`. Trace: does this leak count or layout information an attacker could use? (Highly unlikely — but confirm we don't add detail later that includes weight magnitudes or layer names.)
- bench command writes a stderr summary + a JSON file. The JSON includes `modelID` (operator-supplied) and timestamps. No tokens, no operator credentials, no IP addresses.

## Out of scope for THIS lane
- Code correctness of the cast / compile() implementation: defer to code lane.
- Architectural fit: defer to architect lane.

## Required output format

For each finding, emit a YAML entry:
```
- id: SEC-<n>
  severity: CRITICAL | HIGH | MEDIUM | LOW | NIT
  file: path/to/file.swift
  lines: "L:M" or "L:M..L:N"
  finding: <one paragraph>
  recommendation: <concrete fix or accept/reject>
```

End with: `# tally: critical=<n> high=<n> medium=<n> low=<n>`.
Bar: 0 CRITICAL/HIGH/MEDIUM.
