# R2 security lane result (codex, -2026-10-05T13-49-19-703)

**Round 2 Security Review**

All three Round 1 Mediums are **VERIFIED fixed**. I found **no new CRITICAL, HIGH, MEDIUM, or LOW security findings** in the PR diff or pinned fork diff.

**Prior Items**
SEC M, fork fused MoE layout validation: **VERIFIED**. [Qwen35FusedMoE.swift](<mlx-swift-lm-fork>/Libraries/MLXLLM/Models/Qwen35FusedMoE.swift:121) now requires exact uint32 packed weights and bf16 companion tensor layouts before fusing, and returns nil to the stock path on mismatch. The regression test exists at [Qwen35FusedMoETests.swift](<mlx-swift-lm-fork>/Tests/MLXLMTests/Qwen35FusedMoETests.swift:91). I re-read the kernel index paths for router, top-k, gate/up, shared expert, down projection, per-call scratch allocation, chunking, and the resolve/kernel caches; I did not find an OOB, cross-row, cross-chunk, or cross-request state-sharing regression. New in fork diff; fixed in `b1811029`.

ARCH M, proposal depth vs fused row envelope: **VERIFIED**. Swift caps native MTP proposal depth at 6 in [NativeMTPAdmissionSidecar.swift](phase3-binary/Sources/macprovider-cli/NativeMTPAdmissionSidecar.swift:5), with release tuple validation at [NativeMTPAdmissionSidecar.swift](phase3-binary/Sources/macprovider-cli/NativeMTPAdmissionSidecar.swift:1406). The generator cap is also 6 in [native_mtp_admission_sidecar.py](scripts/native_mtp_admission_sidecar.py:109), and the spec requires `1..6` at [SPEC-023](specs/SPEC-023-installer-autotune-recommend.md:3193). Existing Python tests cover rejecting depth 7 and accepting depth 6. New in PR diff; fixed in `7d55924eb`.

CODE M, upstream-watch reviewed flag: **VERIFIED**. [check-upstream-throughput-blockers.sh](scripts/check-upstream-throughput-blockers.sh:429) derives `native_mtp_public_row_mapped_transactions_reviewed` from `native_mtp_exception_approved`, and [UPSTREAM_WATCH.json](beta/throughput-engineering/UPSTREAM_WATCH.json:396) carries `false` while the exception remains pending. New in PR diff; fixed in `7d55924eb`.

**Security Findings**
CRITICAL: none.

HIGH: none.

MEDIUM: none.

LOW: none.

**Validation**
Ran the allowed existing tests: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_native_mtp_r015_analyze scripts.tests.test_native_mtp_lab_flag_guard scripts.tests.test_native_mtp_admission_sidecar scripts.tests.test_native_mtp_post_gateway_replay_analyze scripts.tests.test_upstream_watch` -> `Ran 115 tests ... OK`.

Also ran `python3 scripts/gen_spec_index.py --check` -> spec index up to date, and `python3 scripts/check_spec_governance.py --base-ref origin/main` -> governance validation passed. I did not run Swift/MLX builds or tests per the Metal/build constraint. Worktree remained read-only and clean: `## HEAD (no branch)`.

VERDICT: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW
