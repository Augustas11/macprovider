# GLM-5.3-Flash native-MTP admission inputs, bound to CLI 1.8.256

Staged inputs for the catalog release that adds a second native-MTP tuple,
`zai-org/glm-5.3-flash`, next to the unchanged Qwen3.6 A3B entry
(`docs/runbooks/native-mtp-enablement.md`, "Adding a second model to the
admission set"). Nothing here is read by the catalog generator yet. The cut
copies these files into `phase3-binary/catalog/autotune/` once the Studio
outputs below exist. Every all-zero digest in these files is the
pending-evidence placeholder, which `scripts/native_mtp_admission_sidecar.py`
refuses to build.

SPEC-048-R014 item 10 holds: 1.8.256 is the released CLI and reads the v2
projection, the embedded `checkpoint_mtp` observer and the 1024-entry
exception bound.

## Release-owned identity (CLI 1.8.256)

All entries of one sidecar share it (SPEC-048-R013 0.1.36). It is recorded
provenance, not a match against the running CLI.

| Field | Value | Source |
| --- | --- | --- |
| `source_commit`, `provider_revision` | `2a575c453639938ff6dbbf905001b7ea893d650d` | the `v1.8.256` tag commit |
| `reproducible_build_sha256` | `98578218416352357fd05174a9ba92067498a6e1cb33ebb5a3dc010dfe128ebd` | SHA-256 of the signed 1.8.256 `macprovider-cli`; equals the live CB policy entry's `package_manifest_sha256` |
| `live_executable_cdhash` | `a775f10652452256a9d5929ff24f47c815a8f115` | `codesign -dvvv` of the same binary; equals the CB policy entry |
| `artifact_manifest_sha256` | `92a047c3caac2910ca117218affd02d6215eab8d022bbf1a9654869f16b851b6` | `native-mtp-artifact-manifest.v2.json`, rendered from `projection-models.json` by the sidecar script's `projection` command |
| `challenge_bank_sha256` | pending | SHA-256 of the two-entry bank (below) |

The release's `mlx.metallib` is `3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b`
and its mlx-swift-lm pin is `87dc5159c87d73f4d7abd524fbdd17760cf56285`.

## GLM tuple input (`admission-tuple-input.glm53.json`)

| Field | Value | Source |
| --- | --- | --- |
| `model_key`, `artifact_id`, `artifact_hash` | `zai-org/glm-5.3-flash`, `mlx-oq4e-mtp`, `7299b6a7…` | verified member of `autotune-artifacts-source.json` |
| `tokenizer_sha256`, `mtp_manifest_sha256` | `19e77364…`, `2f4077a0…` | `tokenizer.json` and `config.json` of the served snapshot; equal to the journey record |
| `mtp_family_adapter`, `mtp_state_class`, `cache_state_classes` | `glm5_next_mtp_v1`, `hybrid_stageable_rewindable` | the values the harness admits for glm5_next |
| `proposal_depth`, `max_native_active_rows`, `request_feature_profile` | 1, 1, `native_mtp_greedy_text_v1` | SPEC-048 MTP-2 for glm5_next (greedy only, one native row) |
| `qualified_slots`, `max_prompt_tokens` | 4, 4096 | the CB grant on the Studio and the journey tuple |
| `complete_window_bytes_by_depth` | `[1003257856, 1150877696]` | `NativeMTPHardwareE2EFamily.glm5Next.completeWindowBytesByDepth(maxContextTokens: 65536)`: 12 staged latent layers x 1,088 B per token at 64k, plus one KDA state set (34 x 4,341,760 B) per kept prefix |
| `quantization` | `mlx_affine`, group 64, 554 per-layer overrides (467 at 8 bits, 70 at 6, 17 at 5), no unquantized modules, manifest `6cc3178a…` | derived from `config.json` and cross-checked: `NativeMTPGLM5NextObservationTests.testRealGLM53ArtifactObservesWith554Overrides` on the served snapshot prints the same manifest digest |
| `runtime_revision`, `ordinary_baseline.runtime_revision` | `87dc5159…` | the 1.8.256 mlx-swift-lm pin |
| `hardware_class`, `ram_bytes` | `apple-m3-ultra`, 274877906944 | the Studio |
| thresholds (`decrease`, `increase`, `max_verification_positions…`) | 400000, 700000, 2500 | policy choices, as in the Qwen entry |
| `benchmark_policy_sha256` | `14741db0…` | `docs/research/spec048-r015/glm53-flash-v1.8.256/policy.json` |
| `correctness_`, `state_rollback_`, `batch_evidence_sha256` | `fef89c32…` | `docs/evidence/glm53-flash-t4-2026-10-17/final-mtp/journey-20261017T135947Z/mtp-journey.json` (steps 04-10 pass), reused (below) |
| `performance_`, `fit_`, `quality_evidence_sha256`, `ordinary_baseline.measurement_sha256` | **pending** | SHA-256 of the R015 `analysis.json` |
| `ordinary_baseline.aggregate_tps_milli` | **pending** (1 is a stand-in) | `analysis.json` cell `s4-p1536-o512`, ordinary `aggregate_committed_tps` median x 1000, truncated |
| `throughput_delta_ppm` | **pending** (0 is a stand-in) | same cell, `metrics.throughput.median` x 1e6, rounded |
| `security_negative_evidence_sha256` | `62cc8eb1…` | `security-negatives.json`: the GLM artifact, capability and self-test negatives (91 tests, 0 failures) on the v1.8.256 source with the served snapshot, CPU only |

## Evidence reuse (AGENTS.md hard rule 2)

The journey record was produced by lab harness `0ec22520…` built at
`07301b6bf` on mlx-swift-lm `87dc515` with the lab `mlx.metallib`
`589e56e0…`. Between `07301b6bf` and `v1.8.256` no decode-path line changed:
`Package.resolved` is identical; the `ModelRuntime.swift` changes are request
preparation for guaranteed tool calls (#2046) and the tuple re-offer after
`bank_mismatch` (#2050); `PagedKVRuntimeBridge.swift` adds lab-only round
numbering; `ContinuousBatchScheduler.swift` adds the fence lift for a
re-offered tuple. The correctness, state and batch digests therefore bind
that record.

The challenge-bank entry is not reused. Its expected tokens, counters and
committed-state digest must equal what the signed 1.8.256 binary computes, and
the release metallib is not the one the record ran on: #2052 builds it for
the macOS 14 deployment target, and every one of the 17,248 kernels the two
libraries share has a different function hash. The bank entry is recorded
again with the release metallib.

## Challenge text and bank entry

The record at `07301b6bf` used the journey's default challenge text. On it
GLM accepted 19 of 43 proposals, and native took 1.81 s against 1.80 s
ordinary. The provider's on-device self-check (SPEC-048-R016 0.1.32) runs the
bank's challenge and needs 1.15x, so that entry would disable the tuple on
the Studio after every load.

Window 1 (2026-10-18 13:09-13:17Z, harness `6585ae23…`, release metallib)
recorded four texts in one load (`native-mtp-journey-e2e --selftest-only`,
`bank-journey-20261018T130906Z.json`, binary identity in
`bank-identity.sha256`). Every candidate passed its provider-local checks
(native equals the ordinary oracle; tokens, counters and committed state
equal across two runs). Speedup estimates: 0.995 (default text), 1.237
(counting, 31 accepted / 0 rejected), 1.236, 1.215. The bank takes candidate 1,
the counting text, at a 1.20 floor: a load that measures under 1.15 runs
without native MTP and stays fail-closed. `bank-entry.glm53.json`
(`a0c8bafe…`) is that step's unmodified `challenge_bank_entry`, with
`challenge_id` `native-mtp-selftest-glm53-flash-0001` (bank ids are unique
across the whole bank). Its token digest and committed count satisfy the
coordinator's record checks.

## R015 bench on an embedded-MTP target

Window 1's R015 leg stopped before loading: `native-mtp-bench` required a
`mtp/` directory. The bench now resolves the MTP artifact from the target's
family as the hardware runner does (`target/` for glm5_next), sets the
family's MLX command-buffer budget and cache limit before any device use as
serve does, refuses a sampled or wider-than-signed policy for the family
before loading, and hashes the target once per process plus the pre-load
re-check. `--validate-only` runs every pre-load check and exits; on the
window-1 fixture it passed (family `glm5_next`, MTP directory `target`, all
identities, the frozen policy and the environment). The window runs one bench
process per cell, and one for the sustained window, so two GLM copies are
never resident.

## Steps

1. CPU, before the window (no downtime): build the lab harness from the
   `v1.8.256` tag source plus this branch's
   `NativeMTPJourneyE2ECommand.swift`, with
   `swift build -c release --product macprovider-cli --build-path .build-lab-harness`
   and the lab-harness define, then copy the signed 1.8.256 `mlx.metallib`
   next to it (done: harness `6585ae23…`). Run the GLM negatives suites
   (`NativeMTPGLM5NextObservationTests`, `NativeMTPAdmissionSidecarTests`,
   `NativeMTPHardwareE2EGLMTests`, `NativeMTPSelfTestTests`) on the same
   source with `MACPROVIDER_GLM53_ARTIFACT_DIR` set (done:
   `security-negatives.json`). Copy the frozen R015 policy to the Studio
   (done).
2. Studio windows (live provider paused, drained and booted out, buyer
   runner stopped, watchdog armed) with
   `scripts/lab/cb-studio/glm53-mtp-admission-window.sh`. Window 1 (done)
   recorded the bank entry. Window 2 runs `r015` alone on harness
   `26b075b4…` (same source plus the bench changes).
3. CPU, after the window: `scripts/native_mtp_r015_analyze.py` on the JSONL and
   the policy; commit `analysis.json` with the run's identity next to the
   policy.
4. Fill the pending fields above; write the bank (the Qwen entry unchanged,
   the GLM entry from `bank-entry.glm53.json`); set the release input's
   `challenge_bank_sha256`.
5. Cut, as #2060 did: copy the tuple file as a JSON array `[Qwen, GLM]`, the
   v2 manifest, the bank and the release input into
   `phase3-binary/catalog/autotune/`; `catalog-release.py restamp`, `generate`
   against the live release directory, `resign-autotune-static.sh`,
   `verify`; move the test pins.
6. Activate through `scripts/ops/catalog-activate.sh` (one SIGHUP; the canary
   loads the two-entry bank). The provider fetches the admission set, runs
   its self-check on the GLM challenge and offers the tuple; done when
   `/v1/status` shows `native_mtp.enabled=true` and a buyer request through
   the gateway is served with native MTP.

## After the 1.8.256 R015 FAIL: R015 v2 and the release it binds

R015 on 1.8.256 failed (window 2026-10-18T13:38Z, `analysis.json`
`224b18b0…`): the one-row cells keep their decode gain, the 4096-token TTFT
bound and every gated-cell gate fail. The diagnosis and the fix (commit
`916faf3b7`, SPEC-038 v0.3.22 FR-CB2: on a backend whose grouped prefill rows
always run alone, as glm5_next's do, a native prompt row joins ragged groups)
are in `docs/research/spec048-r015/glm53-flash-r015-v2/PREREGISTRATION.md`.
The v2 run measures a lab-harness build of that commit.

1.8.256 does not contain the fix, so the GLM entry cannot bind it. The order
is:

1. R015 v2 passes on the lab harness (policy `5ca7e3b3…`).
2. The campaign PR merges; the next CLI release carries the fix. Its
   release input replaces `native-mtp-admission-release.v1.8.256.json`:
   `source_commit`, `provider_revision`, `reproducible_build_sha256` and
   `live_executable_cdhash` of that release, and the `challenge_bank_sha256`
   of the bank written in step 4 below.
3. `benchmark_policy_sha256` becomes `5ca7e3b3…`; the pending performance
   fields take the v2 `analysis.json`. The correctness, state and batch
   digests stay: the fix moves when a native row's prompt chunk runs, not the
   serial prefill path or any decode path the journey record covers, and the
   v2 gated cells hard-fail on any native/ordinary token difference.
4. The challenge-bank entry stays when the new release's `mlx.metallib`
   SHA-256 equals `3d9b4a74…`: the self-check is one row, which never joins a
   group, so its tokens, counters and committed state do not change. A
   different metallib means re-recording the entry with
   `glm53-mtp-admission-window.sh bank` on the signed release before the cut.
5. The Qwen3.6 A3B entry rebinds to the new release by identity only: its
   backend keeps the equal-offset rule (paged attention has no flattened-token
   cap), so no A3B scheduling or decode line changes.
