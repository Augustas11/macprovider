# DeepSeek V4-Flash reference window (#2111)

The first Studio window of campaign #2111 (AGENTS.md rule 12). It measures the
mlx-vlm reference on `TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX` at
`d6be051ae238b2021de56cf098d8f0206328754a` before any port code exists. It
records:

- TTFT at 4096 and 32768 prompt tokens;
- output tok/s at 1 and 4 concurrent rows (1024-token prompts, 256 output tokens);
- peak memory for every run;
- greedy oracles at 1024, 8192 and 32768 prompt tokens for the port's parity test.

It runs as the `dsv4-reference` job of `scripts/ops/studio-lab-window.sh`, alone or after the GLM parity job in `glm-parity-prefill512-then-dsv4-reference`
(runbook: `docs/runbooks/studio-lab-window.md`). The provider is paused and
drained and its model unloaded for the run, then the signed provider is
restored. The receipt is measurement-only.

## Files

| File | Purpose |
| --- | --- |
| `dsv4_reference_bench.py` | The fixed reference command. Temperature 0, no prompt cache. One row runs through `generate_step`. Several rows run through mlx-vlm's `BatchGenerator`. Both are mlx-vlm's own decode paths, so decode tok/s is valid (the GLM T2 harness's bare loop was not). |
| `dsv4-reference-policy.json` | The job policy. It pins the artifact revision, the full-snapshot identity of the fixture, and the `mlx`, `mlx-metal` and `mlx-vlm` versions. The window helper accepts only this exact contract. |

## Outputs

These go to `.lab-window/result-<nonce>/` in the lab source clone:

- `environment.json`: package versions read just before the run.
- `reference.log`: one JSON line per run.
- `reference/speed.json`: versions, macOS build, load time and all runs.
- `reference/oracle_{1024,8192,32768}.npz`: `prompt` (int32), `greedy` (int32, 256 ids), and `top_idx` / `top_logprob` (16 x 16) for the first 16 decode steps.

The batch rows also report `row0_matches_single_row_oracle`. Row 0's prompt is
the 1024-token oracle prompt, so this checks that batched decode matches the
one-row decode.

## Preparation on the Studio

This is disk and CPU work only, at `nice -n 19`. Nothing loads the model.

1. Create the venv: Python 3.12, then `pip install mlx-vlm==0.7.10 mlx==0.32.4`.
   This also installs `mlx-metal` 0.32.4.
2. Download the artifact at the pinned revision with `hf download`. Verify every
   file's size and SHA-256 (git blob SHA-1 for non-LFS files) against
   `https://huggingface.co/api/models/<repo>/revision/<rev>?blobs=true`.
3. Clone this branch, tracked-clean, at the exact campaign commit. Then, in the clone:

   ```sh
   mkdir -m 700 .lab-window .lab-window/fixture
   ln -s <venv> .lab-window/dsv4-venv
   cp -cR <download-dir> .lab-window/fixture/dsv4-target   # APFS clone, no extra space
   rm -rf .lab-window/fixture/dsv4-target/.cache           # hf download bookkeeping
   install -m 600 scripts/lab/dsv4/dsv4-reference-policy.json .lab-window/dsv4-reference-policy.json
   ```

4. Check that the policy's `target_sha256` equals the fixture's snapshot
   identity (`snapshot_identity` in `scripts/ops/lib/studio-lab-window-manifest.py`).
   The window preflight checks this again and refuses on any difference.

Then run `status`, `next` and `next --run` from a clean `origin/main` checkout,
with `STUDIO_LAB_JOB_KIND=dsv4-reference` (or the sequence kind) and `STUDIO_LAB_SOURCE_DIR` /
`STUDIO_LAB_GIT_HEAD` naming the clone. Memory: 167 GB of weights plus a
32k-token KV cache. The live model is unloaded first.
