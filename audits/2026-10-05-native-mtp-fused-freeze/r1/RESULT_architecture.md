# R1 architecture lane result (codex, -2026-10-05T13-33-34-598)

CODE REVIEW REPORT - ARCHITECTURE LANE

CRITICAL (0)
(none)

HIGH (0)
(none)

MEDIUM (1)

1. `phase3-binary/Sources/macprovider-cli/NativeMTPAdmissionSidecar.swift:1398`
   Issue: The sidecar still admits `proposal_depth` up to 16, while the pinned fused MoE path only stays fused for rows with at most seven row tokens. Native verification uses `depth + 1` target tokens, so a signed tuple with `proposal_depth >= 7` can run native verification on the stock kernel, then later drop to depth <= 6 or depth zero under scheduler pressure and move the same sticky row back onto the fused/ordinary path. The dynamic depth reduction is in `ContinuousBatchScheduler.swift:3002`, and the fork returns stock for `rowTokens > 7` at `<mlx-swift-lm-fork>/Libraries/MLXLLM/Models/Qwen35FusedMoE.swift:640`.
   Scenario: An operator later signs a tuple with proposal depth 7 or higher. As batch composition or capacity changes, a native row crosses the fused/stock boundary even though SPEC-048 says a decode row must not move between kernels as the batch grows or shrinks. Since fused and stock are not bit-equal at near ties, acceptance/parity can become batch-shape dependent.
   Fix: For this fused pin, fail closed on `proposal_depth > 6` in SPEC-023 R024 generation and Swift sidecar consumption, or change the fork/runtime so native verification rows above seven tokens stay on one qualified kernel family. Bind that row-token envelope explicitly in the sidecar/R015 policy.
   Status: New in this diff’s fused-pin envelope. The broad depth range existed, but the fused/stock row-boundary hazard is introduced by the new ordinary-path fused kernel contract.

LOW (0)
(none)

INFO (0)
(none)

Validation: allowed Python native-MTP tests passed: 114 tests OK. `python3 scripts/gen_spec_index.py --check` passed. `python3 scripts/check_spec_governance.py --base-ref origin/main` passed. Swift/MLX tests were not run per instruction.

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM, 0 LOW
