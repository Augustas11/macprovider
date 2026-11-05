# GLM-5.3-Flash native MTP: cap extension 4096 -> 32768 (#2198)

Lab window 2026-11-05 on the lab build of `eaf5ecfa49e210b1dbce47d3bb5d4bc6bbb42352`.
This evidence qualifies the GLM-5.3-Flash native-MTP tuple at a signed
`max_prompt_tokens` of 32768 through a SPEC-048 0.1.72 cap extension (MTP-15).
It does not rerun the cells the 4096-cap formal matrix already holds.

## What changed

- `eaf5ecfa4` applies the GLM drafter's 4096-column prompt window to chunked
  continuous-batching prefill (SPEC-048 0.1.71, MTP-6). Before it, the window
  from mlx-swift-lm `3.32.3-macprovider.23` (`93234b64`, SPEC-048 0.1.70,
  `GLM5NextMTP.prepareDrafterState`) never applied in production: any prompt
  over one 2048-token chunk advanced the drafter over every chunk.
- The changed decode-path lines are the window start
  `max(0, P - 4096)` in `ContinuousBatchScheduler` (per-chunk
  `nativeMTPPromptWindowStart`, `nativeMTPPromptPrefill` only past it) and
  the matching fresh-state seed in `PagedKVRuntimeBridge`. For a prompt of
  4096 tokens or fewer the window start is 0, which is the previous behavior
  exactly. Prompt-snapshot rows keep window start 0.

## Measurement (extension run)

Policy `scripts/lab/cb-studio/glm53-2198/r015-p32k-window.json`
(sha256 `00c3e55310cfefde810ebab55bf498c731f019e7c74aae5beca0cc1e6101e244`):
one slot, prompt 32768, outputs 128 and 512, 10 blocks, seed 20261102, the
current SPEC-048 0.1.69 gate set, provider `eaf5ecfa4`, mlx-swift-lm
`93234b64b87368d94081932d103bfdb7ee8e88a7`. The target, MTP and tokenizer
digests, hardware, methodology and request profile equal the prior formal
policy's.

| Cell | Status | Blocks | Decode ratio | Decode LB | TTFT UB | TPOT p95 UB | Gap p99 UB | Rejection UB | E2E ratio |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| s1-p32768-o128 | PASS | 10/10 | 1.103 | 0.082283 | 0.00593199 | -0.0760272 | -0.0659261 | 0 | 0.9987 |
| s1-p32768-o512 | PASS | 10/10 | 1.127 | 0.0989707 | 0.0053536 | -0.0900564 | -0.188236 | 0 | 1.011 |

Medians:

| Cell | Native TTFT | Ordinary TTFT | Native decode | Ordinary decode | Acceptance |
| --- | ---: | ---: | ---: | ---: | ---: |
| s1-p32768-o128 | 88.3 s | 87.8 s | 40.3 tok/s | 36.4 tok/s | 71.5% |
| s1-p32768-o512 | 88.3 s | 87.9 s | 41.5 tok/s | 36.5 tok/s | 75.1% |

There were 0 parity mismatches in all 38 paired records. Before `eaf5ecfa4`
(lab windows 2026-11-04 and earlier on 2026-11-05, fork `.23` without the
chunk window), native TTFT at 32768 was 91.5 s against 87.7 s ordinary, and
the decode gain was +14.07% / +14.65%; see `../glm53-mtp-cap-2026-11-04/`.
The chunk window removes most of that TTFT cost: native TTFT is now within
0.6% of ordinary.

## What is reused

The 4096-cap formal R015 qualification of this tuple:
`docs/research/spec048-r015/glm53-flash-r015-v2/`, policy `policy.json`
(`ed775bdbfe8c420b27ae5a814d5f229d89d4b9ee662c19658e74e3e79ea8c13f`), runs
`window-20261019T010258Z/r015-glm53.jsonl`
(`a0acbd83c625f970ef2f3a89fc76ab5315ae61561afe0240447bb708d2768b10`),
analysis `window-20261019T010258Z/analysis.json`
(`f607170c08d5ec3293cefd1bb7f122ba1fc5698aaccdb171e3e9f455ed29a4d6`, PASS,
gate set 0.1.25-0.1.68, which reanalyzes byte-identical today). It supplies
cells `s1-p1536-o128`, `s1-p1536-o512`, `s1-p4096-o128`, `s1-p4096-o512`, the
gated cells `s2-p1536-o512` and `s4-p1536-o512`, and the 1800 s sustained
window on `s4-p1536-o512`. Every one of those cells runs at a prompt of 4096
or fewer, where the change above leaves drafting, verification and commit
unchanged (AGENTS.md HARD RULE 2, SPEC-048 MTP-13). The cap-32768 matrix is
those cells plus the two cells measured here.

## Files

| File | What |
| --- | --- |
| `policy.json` | byte copy of the extension policy above |
| `r015-glm53-p32k.jsonl` | extension runs (header binds the policy SHA-256) |
| `analysis.json`, `analysis.md` | per-run analyzer output (`EXPLORATORY_NO_VERDICT`, both cells PASS) |
| `identity.sha256` | lab harness binary and `mlx.metallib` SHA-256 |
| `cap-extension.json` | the `macprovider.native-mtp-r015-cap-extension.v1` record |
| `cap-extension-analysis.json` | `--cap-extension` output, `overall_status` PASS |

The record binds the five inputs by SHA-256:

```json
{
  "schema": "macprovider.native-mtp-r015-cap-extension.v1",
  "maximum_prompt_tokens": 32768,
  "decode_path_change": "eaf5ecfa4 (ContinuousBatchScheduler nativeMTPPromptWindowStart = max(0, P - 4096); PagedKVRuntimeBridge seeds the drafter at the window start) on mlx-swift-lm 93234b64 (GLM5NextMTP.prepareDrafterState prefills the last 4096 prompt columns): window start 0 for every prompt at or below 4096, so the reused cells draft, verify and commit as measured",
  "prior_policy_sha256": "ed775bdbfe8c420b27ae5a814d5f229d89d4b9ee662c19658e74e3e79ea8c13f",
  "prior_runs_sha256": "a0acbd83c625f970ef2f3a89fc76ab5315ae61561afe0240447bb708d2768b10",
  "prior_analysis_sha256": "f607170c08d5ec3293cefd1bb7f122ba1fc5698aaccdb171e3e9f455ed29a4d6",
  "extension_policy_sha256": "00c3e55310cfefde810ebab55bf498c731f019e7c74aae5beca0cc1e6101e244",
  "extension_runs_sha256": "<sha256 of r015-glm53-p32k.jsonl>",
  "provider_commit": "eaf5ecfa49e210b1dbce47d3bb5d4bc6bbb42352",
  "mlx_fork_revision": "93234b64b87368d94081932d103bfdb7ee8e88a7"
}
```

Reproduce the verdict:

```bash
R=docs/research/spec048-r015/glm53-flash-r015-v2
E=docs/evidence/glm53-mtp-cap-2026-11-05
python3 scripts/native_mtp_r015_analyze.py "$E/r015-glm53-p32k.jsonl" "$E/policy.json" \
  --cap-extension "$E/cap-extension.json" \
  --prior-policy "$R/policy.json" \
  --prior-runs "$R/window-20261019T010258Z/r015-glm53.jsonl" \
  --prior-analysis "$R/window-20261019T010258Z/analysis.json" \
  > "$E/cap-extension-analysis.json"
```

It exits 0 only on PASS: the prior matrix reanalyzes to its committed PASS,
the extension holds exactly `s1-p32768-o128` and `s1-p32768-o512` under the
current gate set, both pass, and Holm over all 40 hypotheses of both runs as
one family passes.

## Sign

After this PR merges and the next CLI cut publishes (identity rebind of the
tuple to that release, `runtime_revision` `93234b64…`, per
`docs/runbooks/native-mtp-enablement.md` step 3):

1. In `phase3-binary/catalog/autotune/native-mtp-admission-tuple.json`, the
   `zai-org/glm-5.3-flash` entry gets `max_prompt_tokens` 32768,
   `benchmark_policy_sha256` = SHA-256 of `cap-extension.json`, and
   `performance_evidence_sha256` = SHA-256 of `cap-extension-analysis.json`.
   The other evidence digests stay.
2. `python3 scripts/catalog-release.py generate`, then
   `scripts/resign-autotune-static.sh`, then
   `python3 scripts/catalog-release.py verify` (runbook step 6). Re-pin the
   restamped source inputs in `ops/recipes/native-mtp-glm53-binding.v1.json`.
3. Deploy: `scripts/ops/catalog-activate.sh status`, then
   `scripts/ops/catalog-activate.sh next --run`, one step at a time.

Related: #2198
