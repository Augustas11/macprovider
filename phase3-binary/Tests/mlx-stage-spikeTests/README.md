# mlx-stage-spikeTests

Spike 01 — Llama-only MLX stage-forward parity.

Proves that `mlx-swift-lm` can run a **contiguous slice** of Llama transformer layers
on a hidden-state tensor (not token IDs), using per-layer KV cache, and that the two-stage
greedy argmax matches the full single-pass forward.

## How to run

```bash
cd phase3-binary
swift test --filter StageForwardParityTests
```

## MLX Metal shader library

`swift test` does not always place `mlx-swift_Cmlx.bundle` where the test host can load it.
If you see `Failed to load the default metallib`, either:

1. Run a release build first (`swift build -c release`), or
2. Copy a pre-built `default.metallib` (or `mlx-swift_Cmlx.bundle`) into
   `.build/arm64-apple-macosx/debug/phase3-binaryPackageTests.xctest/Contents/MacOS/`
   before re-running with `--skip-build`.

Without a cached model the suite still **SKIP**s cleanly; this step is only needed for a real **PASS**.

## Tests

| Test | What it checks |
|------|----------------|
| `testLlamaLayerBlockShape` | Embed one token, run `layers[0]` only, assert output shape `[1, 1, hiddenSize]` and no NaN. |
| `testLlamaStagedForwardMatchesFullModel` | Full forward vs. two-stage sliced forward on one token — greedy argmax must agree. |

## Model discovery (in priority order)

1. `SPIKE01_MODEL_PATH` env var — absolute path to a local model directory.
2. `MACPROVIDER_INTEGRATION_MODEL` env var — same format.
3. HF cache: `~/.cache/huggingface/hub/models--mlx-community--Llama-3.2-3B-Instruct-4bit`
4. HF cache: `~/.cache/huggingface/hub/models--mlx-community--Llama-3.2-1B-Instruct-4bit`
5. HF cache: `~/.cache/huggingface/hub/models--mlx-community--Meta-Llama-3.1-8B-Instruct-4bit`

If no model is found the tests emit `XCTSkip` and the suite is marked **skipped**, not failed.
CI without weights passes cleanly.

## Expected outcome

- **PASS** — model cached locally; both tests green.
- **SKIP** — no model on disk; suite skipped with message.
- **FAIL** — model present but staged argmax ≠ full argmax (implementation bug).
