# Qwen3.6-27B and Qwen3.8-27B native-MTP admission inputs (#2383)

These records complete the evidence that
`docs/evidence/qwen27b-native-mtp-2026-11-04/README.md` listed as missing
("Evidence not recorded" and "Tuple sizing"). The catalog release
`published-2026-11-16-qwen27b-native-mtp-v289` binds them. R005, R015 and the
self-test bank entries are the 2026-11-04 records and are not rerun here.

The lab run was on 2026-11-16 on an M3 Ultra with 256 GB, isolated from live
serving. It used a lab-harness build of campaign commit `03d208542`: binary
`0ac9fbaa…`, lab `mlx.metallib` `9ba197c5…` and decode-path digest `b09c85ef…`.
Both models ran in the same build, one model resident at a time.

## Files and the tuple fields they bind

| File | SHA-256 | Tuple field |
| --- | --- | --- |
| `qwen36/mtp-journey.json` | `5ec6a7788483f5c357b2060d65f97ce283209c50420d5db86421d23fafe2b6b1` | `correctness_`, `state_rollback_`, `batch_evidence_sha256` |
| `qwen36/security-negatives.json` | `de5920e497ba12e44fb04c6808433f5bcf62541ad86e25cd0d6a661ad70928cc` | `security_negative_evidence_sha256` |
| `qwen38/mtp-journey.json` | `47f1c6e5e44bf831f651bff001898fbc56449160b003aba7c5659c575fbdaf0f` | `correctness_`, `state_rollback_`, `batch_evidence_sha256` |
| `qwen38/security-negatives.json` | `752052f9a01cd5111f11e968ab275675c1a6ca0d6a6002682f28f8ab6f7aa0f2` | `security_negative_evidence_sha256` |
| `<model>/window-bound.json` | | `complete_window_bytes_by_depth` `[193986560, 196083712]` |
| `<model>/quantization.json` | | `quantization` |
| `<model>/identity.json` | | `tokenizer_sha256`, `mtp_manifest_sha256`, projection artifacts |

The other fields come from the 2026-11-04 records:

- `benchmark_policy_sha256` is the SHA-256 of `r015-policy.json`.
- `performance_`, `fit_`, `quality_evidence_sha256` and
  `ordinary_baseline.measurement_sha256` are the SHA-256 of
  `r015-analysis.json`.
- `throughput_delta_ppm` is the `s4-p1536-o512` cell's `metrics.throughput.median`
  x 1e6, rounded: 63597 for Qwen3.6 and 56356 for Qwen3.8. That median was
  the gated cell's decode ratio, not an end-to-end gain (#2442; end to end
  -0.62% and -0.20%). SPEC-048 0.1.116 gates it on end-to-end throughput;
  see `docs/evidence/r015-gated-end-to-end-reanalysis-2026-11-20/`.
- `ordinary_baseline.aggregate_tps_milli` is the same cell's ordinary
  `aggregate_committed_tps` median x 1000, truncated: 40009 for Qwen3.6 and
  39006 for Qwen3.8.

The thresholds (400000, 700000, 2500) and the bound release fields are the
same as the Qwen3.6-35B-A3B entry: runtime revision `6c27b743…`, decode-path
digest `940e2541…` and metallib `3d9b4a74…`. The same goes for the
`apple-m3-ultra` hardware class, 256 GiB RAM, depth 1, one native row, four
slots and the 4096-token prompt cap. The decode-path binding is identity only
(SPEC-048 MTP-13; the 2026-11-04 README, "Decode path since this evidence").

## Results

- **Journey** (`native-mtp-journey-e2e`, four slots, one native row, 4096-token
  cap): steps 04, 05, 06, 07-08, 09 and 10 pass for both models. Step 12 is
  `partial`: its provider-local self-test half passed, and the coordinator
  SPEC-031-R033 canary half runs at activation.
- **Step 10 (warm swap).** The new request after the swap returned only
  reasoning text at the 96-token cap for Qwen3.6-27B (content 0 characters,
  reasoning 364, finish `length`, observed hash `518ef47c…`). For Qwen3.8-27B it
  returned content 191 and reasoning 199 characters. The step counts reasoning
  text as output for every family. It still requires finish `stop` or `length`
  and an observed hash equal to the snapshot's. The 2026-10 A3B and GLM step-10
  records came from before #2109, which moved an open `<think>` into
  `reasoning_content`.
- **Security negatives (CPU only):** `NativeMTPAdmissionSidecarTests` (83),
  `NativeMTPArtifactObservationTests` (31), `NativeMTPSelfTestTests` (10) and
  `NativeMTPHardwareE2ETests` (1, skipped: real-model GPU case). 0 failures.
  Per-test results come from the XCTest console output. The test bundle is
  `07b540e1…`.
- **Quantization:** `mlx_affine`, group 64, no per-layer or unquantized
  exceptions, for both models. The representation manifest is `7deae874…`.
  The value is the same for both models because the manifest covers only the
  exception lists, which are empty for both.
- **Window bound:** the A3B analytical bound
  (`docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-provenance.md`).
  It covers 48 linear-attention and 16 full-attention layers, x1.25, rounded up
  to whole MiB. The formula reproduces the A3B entry `[81788928, 83886080]`.

Related: #2383, #2222, #2199
