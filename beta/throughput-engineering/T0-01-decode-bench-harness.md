# T0-01 — Decode-Bench Harness

**Status:** GREEN — build + tests pass; bench run deferred (see §5)  
**Task ID:** T0-01  
**Branch:** `perf/decode-bench-harness`  
**Worktree:** `/Users/augstar/macprovider-throughput-t0-01`  
**Date:** 2026-07-07  
**Executor:** Cursor agent

---

## 1. Objective

Restore the `decode-bench` subcommand on `main` without `CompiledDecode`,
bf16 cast, or any `ModelRuntime` wire-ins. This is the harness-only landing
that unblocks T0-02 (baseline matrix).

---

## 2. Source

Cherry-ported from `origin/perf/mlx-compile-bf16` commit `aa10847`
(`perf(provider): MLX compile()+bf16 decode-engine scaffolding`).

**Files added:**
- `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift` (new)

**Files modified:**
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` — added
  `DecodeBenchCommand.self` to subcommands list

**Files NOT ported (by design):**
- `CompiledDecode.swift` — T2-01 scope
- `WeightCast.swift` — DEFERRED (bf16 confirmed net-negative on M-series, `perf-mlx-engine.md`)
- `ModelRuntime.swift` changes — no bf16/compile wire-in in T0-01

---

## 3. CLI shape

```bash
macprovider-cli decode-bench \
  --model mlx-community/Qwen2.5-7B-Instruct-4bit \
  --prefill-tokens 512 \
  --decode-tokens 256 \
  --runs 5 \
  --output state/perf/baseline-qwen-2025-07-07.json
```

Full `--help` output:

```
OVERVIEW: Run a pure-decode benchmark for a target model (T0-01 of throughput runbook).

USAGE: macprovider-cli decode-bench [--model <model>] [--decode-tokens <decode-tokens>]
       [--prefill-tokens <prefill-tokens>] [--runs <runs>] [--label <label>]
       [--output <output>] [--output-dir <output-dir>] [--stdout-only]

OPTIONS:
  --model <model>              HuggingFace model ID or local path. Falls back to MACPROVIDER_MODEL.
  --decode-tokens <decode-tokens>   Number of decode tokens to generate per run. Default 256.
  --prefill-tokens <prefill-tokens> Approximate prefill token target. Default 512.
  --runs <runs>                Number of timed runs (after a single warmup). Default 3.
  --label <label>              Label suffix for auto-generated output filenames.
  --output <output>            Full output path for JSON result file.
  --output-dir <output-dir>    Output directory for auto-generated JSON (default: state/perf/).
  --stdout-only                Skip writing the JSON file to disk.
```

---

## 4. TPS semantics

**Generation-only TPS** — denominator excludes TTFT.

Matching `Stage1Iterator.swift` v1.7.8 Track A4 semantics (commit comment
`"v1.7.8 Track A4: measure generation-only throughput"`):

```
generationElapsed = endAt - firstTokenAt   // first token is TTFT boundary
decodeTPS = (generationTokens - 1) / generationElapsed
```

The `-1` subtracts the boundary token counted at TTFT. The `Stage1Iterator`
equivalent counts SSE `deltaCount` starting from `firstTokenAt != nil`, which
achieves the same exclusion at the SSE streaming layer.

This matches the semantics that `min_sustained_tps` catalog gates express
(warm-generation throughput, not whole-request throughput).

---

## 5. Build + test results

**System:**
- Chip: Apple M5
- RAM: 32 GB
- macOS: 26.5
- `macprovider-cli` version: 1.8.19
- `mlx-swift-lm` pin: 3.31.4
- `mlx-swift` pin: 0.31.6

**Build:**
```
swift build -c release   # in phase3-binary/
Build complete!  (562.6s)   exit_code: 0
```

Warnings observed: pre-existing Swift 6 Sendable / `GenerateResult` warnings
in `ModelRuntime.swift`. No new warnings introduced by this PR.

**Tests:**
```
swift test               # in phase3-binary/
Executed 946 tests, with 8 tests skipped and 0 failures (0 unexpected)
exit_code: 0
```

---

## 6. Bench run attempt

**Status: DEFERRED — active production provider**

Attempted to locate cached models for a dry-run benchmark:

| Model | Cache state |
|-------|-------------|
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | refs only (no snapshots) — NOT available |
| `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit` | refs only — NOT available |
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | snapshots present (20B, 3-shard) |
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | snapshots present (30B) |

At bench time, `live.malibu.provider` was **running** (launchctl state=running,
PID 64586). Per local benchmark operating notes, running decode-bench
concurrently with the production 30B model on 32 GB risks GPU/RAM contention
and MLX crashes.

**Decision:** Defer bench run to T0-02 operator window when production provider
can be temporarily drained. Build + tests are GREEN, satisfying the T0-01
pass criterion.

**To run the bench (after draining production provider):**
```bash
# 1. Drain production provider (bench will run a separate model instance)
launchctl bootout "gui/$(id -u)/live.malibu.provider" 2>/dev/null || true

# 2. Run bench
.build/arm64-apple-macosx/release/macprovider-cli decode-bench \
  --model mlx-community/Qwen2.5-7B-Instruct-4bit \
  --prefill-tokens 512 \
  --decode-tokens 256 \
  --runs 5 \
  --output state/perf/baseline-qwen25-7b-mlxlm-3.31.4.json

# 3. Restore production provider
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/live.malibu.provider.plist 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/live.malibu.provider"
```

JSON output will be committed to `audits/2026-07-07/decode-bench-harness/` in T0-02.

---

## 7. Metallib note

The `mlx-swift_Cmlx.bundle` pattern from `audits/2026-06-30/perf-mlx-engine.md`
(manually copying the bundle next to the release binary) was required in that
bench session because it used a standalone release binary extracted from the
package. In the worktree's `.build/arm64-apple-macosx/release/` tree, SPM
places the `phase3-binary_macprovider-cli.bundle` adjacent to the binary;
MLX resolves Metal shaders via the bundle at that path.

For the T0-02 bench run (production or operator-extracted binary), apply the
same `mlx-swift_Cmlx.bundle` copy step if running outside the `.build/` tree.

---

## 8. JSON output schema (reference)

```json
{
  "bf16WeightsEnvFlag": false,
  "compiledDecodeEnvFlag": false,
  "decodeTokensTarget": 256,
  "label": "baseline",
  "mlxSwiftLMPin": "mlxlm-3.31.4",
  "modelID": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "modelTag": "Qwen2.5-7B-Instruct-4bit",
  "prefillTokensTarget": 512,
  "runs": 3,
  "samples": [
    {
      "decodeSeconds": 8.76,
      "decodeTPS": 29.1,
      "decodeTokensActual": 256,
      "isWarmup": false,
      "prefillSeconds": 1.87,
      "prefillTPS": 273.0,
      "promptTokensActual": 512,
      "ttftSeconds": 1.87
    }
  ],
  "schemaVersion": 1,
  "timestamp": "2026-07-07T...",
  "warmup": { "..." }
}
```

Fields `bf16WeightsEnvFlag` and `compiledDecodeEnvFlag` are always `false`
in this T0-01 harness. T2-01 will introduce compiled decode and flip
`compiledDecodeEnvFlag` when `MACPROVIDER_COMPILED_DECODE=1`.

---

## 9. Pass / fail

| Criterion | Result |
|-----------|--------|
| CLI subcommand registers and shows help | PASS |
| `swift build -c release` exits 0 | PASS |
| `swift test` exits 0 (946 tests, 0 failures) | PASS |
| Bench run on M-series with JSON output | DEFERRED — production provider active |
| No CompiledDecode / WeightCast / ModelRuntime bf16 wire-in | PASS |

**VERDICT: GREEN** — build + tests pass; bench run deferred to T0-02 operator window.

---

## 10. Blockers for T0-02

None from harness side. T0-02 needs:
1. A maintenance window with `live.malibu.provider` drained
2. `mlx-community/Qwen2.5-7B-Instruct-4bit` downloaded (not yet cached locally)
3. `mlx-community/gemma-4-26b-a4b-it-4bit` downloaded (not yet cached)
4. Same for `mlx-community/gpt-oss-20b-MXFP4-Q8` — weights ARE cached; can use immediately

`gpt-oss-20b` bench can start as soon as provider is drained.
