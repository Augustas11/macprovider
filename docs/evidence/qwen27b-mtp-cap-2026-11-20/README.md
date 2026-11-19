# Qwen3.6-27B native MTP: prompt cap 4096 -> 32768 (#2429)

Formal SPEC-048 R015 matrix at `maximum_prompt_tokens` 32768 for the
`qwen/qwen3.6-27b` native-MTP tuple, analyzer `overall_status` PASS. The
catalog release `published-2026-11-20-qwen36-27b-mtp-cap-32k-v289` binds it.

## Why a full matrix, not a cap extension

A SPEC-048 0.1.74 cap extension (the path the GLM-5.3-Flash cap took,
`../glm53-mtp-cap-2026-11-05/`) needs the prior formal runs file:
`scripts/native_mtp_r015_analyze.py --cap-extension` checks its SHA-256 and
reanalyzes it. For the 2026-11-04 Qwen 27B qualification only the digest was
committed (`../qwen27b-native-mtp-2026-11-04/README.md`); the file is not
retained. SPEC-048 then requires the full matrix ("a later raise extends a
formal matrix again or runs the full matrix"). This directory commits the raw
runs (`qwen36/r015.jsonl`) so a later extension can reuse them.

## Run

Studio M3 Ultra 256 GB, 2026-11-19/20, live provider and buyer runner paused,
isolated lab harness (`scripts/lab/ablit-perf/job-qwen-mtp-cap.sh`,
`QMTP_FORMAL=1 QMTP_CAP=32768`) built from `ba4e46990` on
`campaign/abliterated-perf`, mlx-swift-lm `a219eafe…`, release
`mlx.metallib` `3d9b4a74…` (`qwen36/identity.sha256`). Target `518ef47c…`,
drafter `88b6d3e0…`, tokenizer `87a7830d…` (the tuple's). One row, depth 1,
four qualified slots, prompts 1536/4096/32768, outputs 128/512, 10 blocks,
gated `s2-p1536-o512` and `s4-p1536-o512`, 1800 s sustained on
`s4-p1536-o512`, request shape `plain_text`, SPEC-048 0.1.71 gate set.
The policy's `xcode_build_version` reads `unknown` (the job did not set
`DEVELOPER_DIR`); the bench recorded the same value in the run header.

| Cell | Status | Decode ratio | Decode LB | TTFT UB | TPOT p95 UB |
| --- | --- | ---: | ---: | ---: | ---: |
| s1-p1536-o128 | PASS | 1.399 | 0.373 | 0.020 | -0.274 |
| s1-p1536-o512 | PASS | 1.388 | 0.359 | 0.020 | -0.264 |
| s1-p4096-o128 | PASS | 1.347 | 0.324 | 0.021 | -0.245 |
| s1-p4096-o512 | PASS | 1.338 | 0.324 | 0.020 | -0.245 |
| s1-p32768-o128 | PASS | 1.085 | 0.034 | 0.035 | -0.041 |
| s1-p32768-o512 | PASS | 1.122 | 0.072 | 0.035 | -0.067 |
| s2-p1536-o512 (gated) | PASS | 1.078 | 0.066 | -0.020 | -0.041 |
| s4-p1536-o512 (gated) | PASS | 1.006 | 0.004 | 0.043 | 0.031 |

Zero parity mismatches, errors and fallbacks. The sustained window passed.

Reproduce:

```bash
E=docs/evidence/qwen27b-mtp-cap-2026-11-20/qwen36
python3 scripts/native_mtp_r015_analyze.py "$E/r015.jsonl" "$E/r015-policy.json" | cmp - "$E/r015-analysis.json"
```

## Tuple fields

In `native-mtp-admission-tuple.json`, entry `qwen/qwen3.6-27b`:

- `max_prompt_tokens` 32768;
- `benchmark_policy_sha256` = SHA-256 of `qwen36/r015-policy.json`
  (`a0aae38a…`);
- `performance_`, `fit_`, `quality_evidence_sha256` and
  `ordinary_baseline.measurement_sha256` = SHA-256 of
  `qwen36/r015-analysis.json` (`ba847838…`);
- `throughput_delta_ppm` 6221 and `ordinary_baseline.aggregate_tps_milli`
  36696, from the `s4-p1536-o512` cell as in
  `../qwen27b-native-mtp-2026-11-16/README.md`.

The other evidence digests (journey, security negatives, bank, window bound,
quantization) and the bound release fields (runtime `6c27b743…`, decode-path
digest `940e2541…`) stay until the next CLI cut. The measured build pins the
same mlx-swift-lm as `origin/main` (`a219eafe…`), which includes the Qwen MTP
changes since `6c27b743…` (fork `9317a90`, the MTP layer's norm and MLP on the
read column only), so this matrix measures the decode path the next cut ships;
binding the entry to that cut is the identity rebind of
`docs/runbooks/native-mtp-enablement.md`.

Related: #2429
