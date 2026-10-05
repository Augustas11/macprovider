# R2 architecture lane result (codex, -2026-10-05T13-47-24-778)

ARCHITECTURE REVIEW ROUND 2

Round 1 items:

SEC M: VERIFIED. `<mlx-swift-lm-fork>/Libraries/MLXLLM/Models/Qwen35FusedMoE.swift:121` validates packed uint32 weights and bf16 scale/bias tensors with exact kernel-indexed shapes before fusion; mismatch returns nil/stock. Covered by `<mlx-swift-lm-fork>/Tests/MLXLMTests/Qwen35FusedMoETests.swift:107` `testMismatchedQuantizedLayoutIsNotFusable`.

ARCH M: VERIFIED. Swift caps proposal depth at 6 in `phase3-binary/Sources/macprovider-cli/NativeMTPAdmissionSidecar.swift:5`, enforced for `$.mtp.max_proposal_depth`, `$.mtp.adaptation_max_depth`, and R024 `proposal_depth` at lines 1025, 1143, and 1406. SPEC-048 0.1.23 and SPEC-023 v0.22.11 now say native verification rows are `proposal_depth + 1` and cap depth at 6. Python generator tests passed.

CODE M: VERIFIED. `scripts/check-upstream-throughput-blockers.sh:163` keeps `native_mtp_exception_review_approved = False`, derives `native_mtp_public_row_mapped_transactions_reviewed` from the full exception approval at line 429, and `beta/throughput-engineering/UPSTREAM_WATCH.json:396` carries `false`.

Findings:

LOW (1)

1. `scripts/check-upstream-throughput-blockers.sh:452`
   Issue: The watch-generator metadata still emits the older, less precise fused-candidate review wording/scope: `candidate_extension_pending_studio_and_freeze_audits` and `...fused_moe_v3_t1_through_t7`, while the committed `UPSTREAM_WATCH.json` has the clearer ordinary-path qualification wording and `rows_t1_through_t7_chunked` scope.
   Scenario: A future watch refresh can regress the durable metadata away from SPEC-048 0.1.23’s explicit “ordinary-path qualification + freeze audits” and chunked row-envelope description, even though the checked-in JSON currently says the right thing.
   Fix: Update the generator strings at `scripts/check-upstream-throughput-blockers.sh:435-456` to match `UPSTREAM_WATCH.json:398-411`.
   Status: new in this diff.

No CRITICAL, HIGH, or MEDIUM architecture findings found.

Regression / coherence checks:
- Fused pin decoupling from native-MTP R015 is coherent in SPEC-048 R003 and CONFORMANCE R003: R015 gates native tuple signing/activation, not the ordinary-path fused pin.
- Decode rows do not switch between fused and stock as batch composition changes: fork `Qwen35FusedMoE.forward` keeps decode/verify-shaped rows fused up to 7 tokens per row and chunks flattened batches above 7; Swift admission caps native verification rows to that envelope.
- Native MTP remains default-off: `AppConfig.defaults` sets `.off`; `MACPROVIDER_NATIVE_MTP_MODE` / `--native-mtp auto` are explicit opt-ins. Local status is bounded; coordinator-visible native tuple offers require an admitted capability and self-test path.
- Release/rollback surface exists for the fused ordinary path via `MLX_LM_QWEN35_FUSED_MOE=0`; KV identity bumps to the new fork pin, so cold-tier misses on upgrade are expected.

Validation run:
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest ...` passed 115 tests.
- `python3 scripts/gen_spec_index.py --check` passed.
- `python3 scripts/check_spec_governance.py --base-ref origin/main` passed.
- `git diff --check origin/main...HEAD` and fork `git diff --check` passed.
- Swift/MLX tests were not run per instruction.

VERDICT: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 1 LOW
