# R2 code lane result (codex, -2026-10-05T13-48-39-403)

**Round 1 Fixes**

- VERIFIED SEC M: fork layout validation now fails closed before fusing. Evidence: `Qwen35FusedMoE.resolve` requires exact packed `uint32` weights and `bf16` scale/bias shapes at `<mlx-swift-lm-fork>/Libraries/MLXLLM/Models/Qwen35FusedMoE.swift:121` and applies the guard at `:157`; test coverage is at `<mlx-swift-lm-fork>/Tests/MLXLMTests/Qwen35FusedMoETests.swift:107`.
- VERIFIED ARCH M: proposal depth is capped at 6 in Swift consumer, release entry parsing, Python sidecar builder, specs, and tests. Evidence: `phase3-binary/Sources/macprovider-cli/NativeMTPAdmissionSidecar.swift:5`, `:1025`, `:1406`; `scripts/native_mtp_admission_sidecar.py:109`, `:240`; tests at `phase3-binary/Tests/macprovider-cliTests/NativeMTPAdmissionSidecarTests.swift:1173` and `scripts/tests/test_native_mtp_admission_sidecar.py:146`.
- VERIFIED CODE M: watcher reviewed flag remains false while exception approval is pending. Evidence: `scripts/check-upstream-throughput-blockers.sh:151` defines the candidate revision, `:163` requires review approval, `:429` derives the reviewed flag from full approval, and checked-in `beta/throughput-engineering/UPSTREAM_WATCH.json:396` carries `false`.

**Findings**

CRITICAL: none.

HIGH: none.

MEDIUM: none.

LOW: none.

INFO: no correctness finding. Residual validation gap only: I did not run Swift/MLX/Metal tests per the audit constraint and host boundary; fused-kernel behavior was reviewed from source and existing test design. The allowed checks passed: 115 Python tests, spec index check, and spec governance check.

I also re-reviewed the full requested scope for new regressions: fused chunking/reshape path, default-on fork kill switch, pin consistency, lab-only guards, load-gate batch fence, token-bound downgrade recording, R015 analyzer, post-gateway replay analyzer, and sidecar Swift/Python agreement. I found no new CRITICAL/HIGH/MEDIUM/LOW issues.

VERDICT: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW
