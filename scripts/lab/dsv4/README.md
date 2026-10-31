# DeepSeek V4-Flash reference window (#2111)

The first Studio window of campaign #2111 (AGENTS.md rule 12). It measures the
mlx-vlm reference on `TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX` at
`d6be051ae238b2021de56cf098d8f0206328754a` before any port code exists. It
records:

- TTFT at 4096 and 32768 prompt tokens;
- output tok/s at 1 and 4 concurrent rows (1024-token prompts, 256 output tokens);
- peak memory for every run;
- greedy oracles at 1024, 8192 and 32768 prompt tokens for the port's parity test.

It runs as the `dsv4-reference` job of `scripts/ops/studio-lab-window.sh`
(runbook: `docs/runbooks/studio-lab-window.md`). The provider is paused and
drained and its model unloaded for the run, then the signed provider is
restored. The receipt is measurement-only.

## Files

| File | Purpose |
| --- | --- |
| `dsv4_reference_bench.py` | The fixed reference command. Temperature 0, no prompt cache. One row runs through `generate_step`. Several rows run through mlx-vlm's `BatchGenerator`. Both are mlx-vlm's own decode paths, so decode tok/s is valid (the GLM T2 harness's bare loop was not). |
| `dsv4-reference-policy.json` | The job policy. It pins the artifact revision, the full-snapshot identity of the fixture, and the `mlx`, `mlx-metal` and `mlx-vlm` versions. The window helper accepts only this exact contract. |
| `dsv4_tf_reference.py` | DeepSeek's reference, not mlx-vlm: the MLX port of `inference/model.py` + `kernel.py` shipped in the artifact (`deepseek_v4.py`), with its `hc_post` stream mix , its attention (bf16 weights against each 64-key block's running max) and its indexer's top-k order corrected to DeepSeek's, and its QAT simulations off unless `--qat`. Subcommands `oracle` (greedy oracles in this job's `.npz` format, on the existing oracles' prompts), `tokens` (a teacher-forced sequence from a coding-compare result), `dump` (per-layer state at chosen positions) and `compare` (against the fork's `DeepseekV4TeacherForcedDumpTests` dump). mlx-vlm's port diverges from the reference (zeroed ratio-4 overlap per call, HISA indexer, bf16 router/attention/compressor/experts/head), so its oracles are not a parity target for fork tag `3.32.3-macprovider.10.9` and later. |

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
   cp -cR <download-dir> .lab-window/fixture/target   # APFS clone, no extra space
   rm -rf .lab-window/fixture/target/.cache           # hf download bookkeeping
   install -m 600 scripts/lab/dsv4/dsv4-reference-policy.json .lab-window/qualification-policy.json
   ```

4. Check that the policy's `target_sha256` equals the fixture's snapshot
   identity (`snapshot_identity` in `scripts/ops/lib/studio-lab-window-manifest.py`).
   The window preflight checks this again and refuses on any difference.

Then run `status`, `next` and `next --run` from a clean `origin/main` checkout,
with `STUDIO_LAB_JOB_KIND=dsv4-reference` and `STUDIO_LAB_SOURCE_DIR` /
`STUDIO_LAB_GIT_HEAD` naming the clone. Memory: 167 GB of weights plus a
32k-token KV cache. The live model is unloaded first.

## Campaign CB and DSpark add-on (PR #2151)

`dsv4_cb_dspark_addon.sh` is job `x` after the existing Window 2 job `d`.
It leaves the Window 1/2 controller and its budget unchanged. Run `--plan`
first: it prints commands and creates no output directory. Launching any
measured cell requires the supervisor's hardware window. The add-on never
pauses, restarts or changes a serving provider.

The controller supplies these private inputs through its environment. Keep
their actual values in the private campaign handoff, outside this repository.

| Input | Required value |
| --- | --- |
| `LAB` | Prepared campaign window workspace |
| `NEWBIN` | Exact candidate binary built in Window 1, with its matching metallib |
| `W1_OUT` | Existing Window 1 results and candidate identity; mandatory for native cells |
| `DSV4_MODEL_DIR` | Verified target artifact directory for the CB and reference cells |
| `PY` | Pinned mlx-vlm reference environment's Python executable |
| `ORACLES` | Existing reference oracle directory |
| `LIVE_URL` | Local provider status endpoint used only to refuse an overlapping run |
| `DSV4_NATIVE_BENCH_ROOT` | Native bench fixture root containing the target artifact |
| `DSV4_NATIVE_POLICY_DIR` | Frozen native policies `depth-1.json`, `depth-2.json`, `depth-3.json`, `depth-5.json` |
| `DSV4_NATIVE_LONG_TOKEN_IDS` | JSON exported from the existing oracles: exactly keys `8192` and `32768`, each containing that many token IDs |
| `DSV4_PROVIDER_COMMIT` | Candidate source commit, lowercase 40-hex and matching the native policies |
| `DSV4_R015_ANALYZER` | Existing repository `scripts/native_mtp_r015_analyze.py`; optional in the repository layout, required when deploying the add-on as a flat directory |
| `PAUSE_T`, `CEILING_S` | Original controller pause time and ceiling; passed through unchanged |

Each native policy binds `proposal_depth` to its filename's depth and uses
`quantization: "mlx_mxfp4_mxfp8"`. Supply preregistered R015 policies and their
artifact, runtime and hardware identities; this add-on does not mint policies
or admission entries. The requests file is the existing 12-request frozen
corpus. No encoding implementation is duplicated here.

The add-on lists the following cells, in order:

| Cells | Evidence and outputs |
| --- | --- |
| CB throughput at 1/2/4/8 rows and parity at 1/2/4/8 rows | Existing `msb-throughput` cells; matching Window 1 throughput results are reused. The four-row gate is at least 1.8× same-build, same-window serial with exact parity at all row counts and the strict FR-CB14 floors. The 67.44 tok/s mlx-vlm reference is informative. |
| Reference DSpark, block sizes 2/3/4/6 | Corrected mlx-vlm ordinary/DSpark controls over the frozen requests and long prompts; `dspark/dspark.json`. This is reference evidence only. |
| Native frozen-request probes, depths 1/2/3/5 | `native-mtp-bench --requests ... --requests-sha256 ... --long-token-ids ...`; `native/dN.jsonl`. Each depth covers all 12 individual requests, four-row groups for prose/reasoning/code, and one-/four-row groups at 8192/32768 tokens. Records carry exact token parity, acceptance by position, TTFT, decode throughput and peak memory. These scheduler integrity probes have `qualifies_r015: false`. |
| Native R015 benches, depths 1/2/3/5 | Separate regular `native-mtp-bench` invocations without `--requests`, with the same frozen per-depth policy; `native/r015-dN.jsonl`. These run the policy's matrix and sustained window through the regular bench path. The existing R015 analyzer supplies the qualification verdict. |

Within the existing cell order, four-row CB throughput runs first, then CB
parity, the reference DSpark lane, the other CB throughput cells, native
integrity probes, and native R015 benches. The frozen native commands include
`MACPROVIDER_NATIVE_MTP_E2E=1`, the fixture root, model ID, policy, provider
commit and output. Hardware-host and identity checks remain in the command.

The authorized campaign has no wall-clock deadline. Estimates are planning
information and never skip a cell. Explicit abort/ceiling markers, controller
death and no-progress supervision still stop the add-on. Missing cells remain
`INCOMPLETE`.

`x/summary.json` keeps CB, reference DSpark, native integrity, and native R015
results separate. Missing native cells, missing identity binding or incomplete
qualification leave native hardware proof `INCOMPLETE`. A reference `GO` or a
passing integrity probe never substitutes for R015 qualification.
