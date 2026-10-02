# Provenance of the A3B admission tuple input

Every entry field of `admission-tuple-input.json` and where it came from.
Fields filled in by the release cut (`artifact_manifest_sha256`,
`provider_revision`, `source_commit`, `reproducible_build_sha256`,
`live_executable_cdhash`, `challenge_bank_sha256`) and the envelope (release
id, validity, signer key ids) are not in this file. The generator
`scripts/native_mtp_admission_sidecar.py` refuses them here.

| Field | Value | Source |
| --- | --- | --- |
| `model_key`, `artifact_id`, `artifact_hash` | `qwen/qwen3.6-35b-a3b`, `mlx-4bit`, `3fed776d…` | Verified artifact-feed member in `phase3-binary/catalog/autotune/autotune-artifacts-source.json`; recomputed on the Studio fixture (`macprovider.snapshot-manifest.v1`, 17 files incl. `.gitattributes`). |
| `tokenizer_sha256` | `87a7830d…` | SHA-256 of `target/tokenizer.json`. Equal to the R015 policy and bench header. |
| `mtp_manifest_sha256` | `7b38a336…` | SHA-256 of `mtp/config.json` (MLX drafter manifest). This is the file the lab projection names as `manifest`. |
| `mtp_family_adapter`, `mtp_state_class`, `cache_state_classes`, `mtp_head_count`, `proposal_depth` | `qwen3_5_mtp_v1`, `hybrid_stageable_rewindable`, 1, 1 | Values the R015 bench and journey loaded and admitted (Qwen3.6 targets use the qwen3_5 separate-artifact adapter, SPEC-048 0.1.11). |
| `quantization` | `mlx_affine`, group 64, 80 per-layer 8-bit router-gate exceptions, manifest `770a015d…` | Computed by the production artifact observer (`NativeMTPArtifactObserver.affineRepresentation`) from the same target and drafter bytes. |
| `complete_window_bytes_by_depth` | `[81788928, 83886080]` | **Analytical conservative bound, not measured.** Per row and round: 30 linear-attention layers of recurrent checkpoint state (32 value heads × 128 × 128 × fp32 SSM = 2,097,152 B, plus a 3 × 8192 × bf16 conv state = 49,152 B, per layer; 64,389,120 B in total), plus, per staged position (depth + 1), full-attention KV (10 layers × 2 × 2 heads × 256 × bf16 = 20,480 B), drafter KV 2,048 B, fp32 logits 993,280 B, and hidden buffers 8,192 B. The total is multiplied by 1.25 and rounded up to whole MiB. The scheduler uses only the ratio between the max-depth value × `qualified_slots` and each row's reservation, so the lab values used in R015 (`[1 MiB, 2 MiB]`) schedule identically. A measured derivation is a follow-up. |
| `runtime_revision` | `ef4ff856…` | Pinned upstream mlx-swift-lm fork revision (`NativeMTPHardwareE2ERunner.upstreamRevision`; R015 policy `mlx_fork_revision`). |
| `hardware_class`, `ram_bytes` | `apple-m3-ultra`, 274877906944 | `canonicalHardwareClass("Apple M3 Ultra")`; `hw.memsize` on the Studio. |
| `qualified_slots`, `max_native_active_rows`, `max_prompt_tokens` | 8, 1, 4096 | Frozen R015 policy `30934c07…`. The bound and cap are justified by its passing cells (8192-token prompts failed the decode gate in exploratory evidence). |
| `request_feature_profile` | `native_mtp_sampled_text_v1` | Seeded sampled parity passed in the journey hardware harness (steps 04/06) and in the 2026-10-01 exploratory t=0.7 runs. R015 throughput cells are greedy. |
| `decrease_threshold_ppm`, `increase_threshold_ppm`, `max_verification_positions_per_committed_milli` | 400000, 700000, 2500 | **Policy choices, not measured.** The depth-adaptation and circuit-breaker policy that consumes them is not wired into the continuous-batching path yet, so they have no runtime effect today. Chosen below the observed 0.86–0.93 acceptance and above depth-1's ≤ 2000 positions per committed token. |
| `throughput_delta_ppm` | 14 | `analysis.json` cell `s8-p1536-o512` (the tuple's `qualified_slots` cell), `metrics.throughput.median` = 1.4498e-05 (decode ratio − 1), × 1e6, rounded to the nearest integer. At one active row the gain is +21.6% to +27.8% (s1 cells); at eight slots the gate holds the native row at depth zero. |
| `benchmark_policy_sha256` | `30934c07…` | SHA-256 of `policy.json`. |
| `performance_evidence_sha256`, `fit_evidence_sha256`, `ordinary_baseline.measurement_sha256` | `c780939f…` | SHA-256 of `analysis.json`. It carries throughput, latency, peak footprint, and min-available memory per cell. |
| `ordinary_baseline.aggregate_tps_milli` | 193824 | `analysis.json` cell `s8-p1536-o512`, `reported_metrics.ordinary.aggregate_committed_tps.median` = 193.8249 tok/s, × 1000, truncated. |
| `correctness_evidence_sha256`, `quality_evidence_sha256`, `state_rollback_evidence_sha256`, `batch_evidence_sha256`, `security_negative_evidence_sha256` | all-zero placeholder | **Pending.** They bind to the journey hardware result and the negative-fixture record once the serving journey's steps pass. The generator accepts the placeholder syntactically; a release must not sign it. |

The analyzer input for `analysis.json` is the lab-host file
`mtp-r015-a3b-formal-v2/r015-a3b-formal.jsonl` (211 lines, SHA-256
`88c79a5757caf08d9efcee12756559d4f6dbd36341c6f43831301adb5b04e04d`). Raw JSONL
is kept on the lab host and is not committed, by operator decision. Running
`scripts/native_mtp_r015_analyze.py` on that file with `policy.json`
reproduces `analysis.json`.
