# Qwen 27B native MTP: prompt cap 4096 -> 32768 (#2429)

Two formal matrices, one per dense 27B tuple: Qwen3.6-27B (`qwen36/`) and
Qwen3.8-27B (`qwen38/`, [below](#qwen38-27b)).

## Qwen3.6-27B

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

## Qwen3.8-27B

Formal SPEC-048 R015 matrix at `maximum_prompt_tokens` 32768 for the
`qwen/qwen3.8-27b` native-MTP tuple, analyzer `overall_status` PASS. The
catalog release `published-2026-11-20-qwen38-27b-mtp-cap-32k-v289` binds it.
The full matrix is needed for the same reason as Qwen3.6: only the digest of
the 2026-11-04 runs was committed. This directory commits the raw runs
(`qwen38/r015.jsonl`).

### Run

Studio M3 Ultra 256 GB, 2026-11-20, live provider and buyer runner paused,
same isolated lab harness (`QMTP_FORMAL=1 QMTP_CAP=32768`) built from
`637b0ad61` on `campaign/abliterated-perf`, mlx-swift-lm `ddc6f974…` (the
3.32.3-macprovider.84 pin this branch carries), release `mlx.metallib`
`3d9b4a74…` (`qwen38/identity.sha256`). Target `8a8786e9…`, drafter
`25d2e7e3…`, tokenizer `06b95093…` (the tuple's). One row, depth 1, four
qualified slots, prompts 1536/4096/32768, outputs 128/512, 12 blocks, gated
`s2-p1536-o512` and `s4-p1536-o512`, 1800 s sustained on `s4-p1536-o512`,
request shape `plain_text`, SPEC-048 0.1.71 gate set, `exclusion_rules`
`single_token_identical_pair` (SPEC-048 0.1.115). The policy's
`xcode_build_version` reads `unknown`, as for Qwen3.6.

| Cell | Status | Blocks (excluded) | Decode ratio | Decode LB | TTFT UB | TPOT p95 UB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| s1-p1536-o128 | PASS | 12 (0) | 1.319 | 0.280 | 0.020 | -0.218 |
| s1-p1536-o512 | PASS | 12 (0) | 1.375 | 0.334 | 0.019 | -0.250 |
| s1-p4096-o128 | PASS | 12 (0) | 1.302 | 0.264 | 0.021 | -0.209 |
| s1-p4096-o512 | PASS | 12 (0) | 1.322 | 0.298 | 0.021 | -0.230 |
| s1-p32768-o128 | PASS | 12 (1) | 1.092 | 0.058 | 0.035 | -0.055 |
| s1-p32768-o512 | PASS | 12 (0) | 1.128 | 0.088 | 0.035 | -0.081 |
| s2-p1536-o512 (gated) | PASS | 12 (0) | 1.069 | 0.056 | -0.024 | -0.045 |
| s4-p1536-o512 (gated) | PASS | 12 (0) | 1.019 | 0.012 | 0.042 | 0.027 |

Zero parity mismatches, errors and fallbacks. The sustained window passed.

### The excluded block and the earlier FAIL

In `s1-p32768-o128`, block 9 committed exactly one token per request on both
paths, with the same token ids and content digests. One token has no decode
interval, so the block has no decode throughput or inter-token gaps. Under
`single_token_identical_pair` it still feeds every hard gate (parity, errors,
fallbacks, admissions, native counters, memory) and is left out of the
bootstrap statistics; the cell keeps 11 measurable blocks, above the ten
SPEC-048 requires.

An earlier run of the same matrix (2026-11-19, built from `ba4e46990`,
mlx-swift-lm `a219eafe…`, 10 blocks, `exclusion_rules` `none`; policy
`5d2a33e2…`, analysis `b87bb885…`, not committed) hit the same block 9 in
`s1-p32768-o128`. Under `none` a record with no decode interval is an invalid
run record, so that cell, and the run, failed (9/10 blocks) while every other
cell passed. That run motivated the preregistered rule in SPEC-048 0.1.115.
This matrix froze the rule and 12 blocks in its policy before it ran; the
analyzer never applies the rule to a policy that froze `none`, so the earlier
run stays FAIL.

Reproduce:

```bash
E=docs/evidence/qwen27b-mtp-cap-2026-11-20/qwen38
python3 scripts/native_mtp_r015_analyze.py "$E/r015.jsonl" "$E/r015-policy.json" | cmp - "$E/r015-analysis.json"
```

### Tuple fields

In `native-mtp-admission-tuple.json`, entry `qwen/qwen3.8-27b`:

- `max_prompt_tokens` 32768;
- `benchmark_policy_sha256` = SHA-256 of `qwen38/r015-policy.json`
  (`c9b266d2…`);
- `performance_`, `fit_`, `quality_evidence_sha256` and
  `ordinary_baseline.measurement_sha256` = SHA-256 of
  `qwen38/r015-analysis.json` (`8f9a2ea1…`);
- `throughput_delta_ppm` 19105 and `ordinary_baseline.aggregate_tps_milli`
  36644, from the `s4-p1536-o512` cell by the same rule as Qwen3.6.

The other evidence digests and the bound release fields stay until the next
CLI cut, as for Qwen3.6. The measured build pins mlx-swift-lm `ddc6f974…`,
the engine this branch ships to the next cut; binding the entry to that cut
is the identity rebind of `docs/runbooks/native-mtp-enablement.md`.

Related: #2429
