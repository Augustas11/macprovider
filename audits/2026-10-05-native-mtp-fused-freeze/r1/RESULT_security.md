# R1 security lane result (codex, -2026-10-05T13-32-47-894)

**Findings**

MEDIUM — new in pinned fork diff: fused MoE eligibility does not fully validate quantized tensor companion shapes before launching custom Metal kernels.  
File: [<mlx-swift-lm-fork>/Libraries/MLXLLM/Models/Qwen35FusedMoE.swift:123](<mlx-swift-lm-fork>/Libraries/MLXLLM/Models/Qwen35FusedMoE.swift:123)  
Scenario: `resolve(_:)` checks the module family, bit width, group size, some weight dimensions, and a few leading dimensions, but it does not prove that every `scales` and `biases` array has the exact rows/groups required by the kernel. The kernels then index those companion arrays from derived expert/row/group offsets, for example in the gate/up and down paths at lines 390-394 and 529-533. A malformed or loader-accepted inconsistent affine module could make the fused ordinary path read past the intended companion tensor buffer for every A3B buyer decode step.  
Fix: before caching `Weights`, validate exact shapes for each packed weight, scale, and bias tensor: router/shared gate, expert gate/up/down, and shared expert gate/up/down. Keep the fused path disabled unless all shapes match the kernel’s indexing formulas.

No CRITICAL, HIGH, or additional MEDIUM issues found in the MacProvider PR diff. I also did not find release-build reachability for the lab harnesses, a network-facing path into lab-only overrides, a fail-open native-MTP admission path, or a SPEC/CONFORMANCE trust-tier weakening.

Validation run:
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_native_mtp_r015_analyze scripts.tests.test_native_mtp_lab_flag_guard scripts.tests.test_native_mtp_admission_sidecar scripts.tests.test_native_mtp_post_gateway_replay_analyze scripts.tests.test_upstream_watch` passed: 114 tests.  
`python3 scripts/gen_spec_index.py --check` passed.  
`python3 scripts/check_spec_governance.py --base-ref origin/main` passed.  
Swift/MLX tests were not run per instruction.

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM, 0 LOW
