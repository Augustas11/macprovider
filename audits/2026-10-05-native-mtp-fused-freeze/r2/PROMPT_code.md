METHOD CONSTRAINT: First-party software-correctness / proof review. Do NOT author or construct malformed payloads or exploit inputs; evaluate by reading source and running EXISTING tests; describe gaps abstractly (field + condition) in prose. Do NOT modify any file in either repository.

Repository: the current working directory, a detached worktree of PR #1832 (branch campaign/native-mtp-formal, #1770), which has origin/main merged in. This is the freeze audit before the PR merges with native MTP still default-off and the fused A3B MoE kernel enabled on the ordinary path.

SCOPE (review all of it):
1. The complete PR diff: `git diff origin/main...HEAD` (non-doc surface about 34 files: SPEC-048 0.1.21-0.1.23, SPEC-023 v0.22.9-v0.22.11, CONFORMANCE.json, UPSTREAM_WATCH.json, Package.swift/Package.resolved pin, ModelRuntime.swift, ContinuousBatchScheduler.swift, NativeMTPAdmissionSidecar.swift, NativeMTPBenchCommand.swift, NativeMTPJourneyE2ECommand.swift, NativeMTPHardwareE2ECommand.swift, MacProviderCLI.swift, KVConversationColdTierAdapter.swift, scripts/native_mtp_admission_sidecar.py, scripts/native_mtp_r015_analyze.py, scripts/native_mtp_post_gateway_replay_analyze.py, scripts/check-upstream-throughput-blockers.sh, scripts/read_swiftpm_pins.py, and their tests).
2. The pinned dependency diff, in the read-only clone at <mlx-swift-lm-fork>: `git -C <mlx-swift-lm-fork> diff ef4ff8568c38c640bc90a8176dc3acfe943a288d b181102984a4d1875efbd9e0eab3a7dfd1c012c5` (ef4ff856 is the fork revision currently approved on main; b1811029 adds Libraries/MLXLLM/Models/Qwen35FusedMoE.swift, small hooks in Qwen35.swift and MLXLMCommon/SwitchLayers.swift, and Tests/MLXLMTests/Qwen35FusedMoETests.swift). This code runs on every A3B ordinary decode step for buyers once the PR ships.

Context: a prior three-lane audit (audits/2026-10-02-native-mtp-formal/) covered the campaign up to the round-4 fixes; it does not cover the fused-MoE pin, the lab batch-composition fence, the post-gateway replay analyzer, or the SPEC-048 0.1.22/0.1.23 and SPEC-023 v0.22.9-v0.22.11 changes. Evidence for the fused path: docs/research/spec048-fused-moe/evidence-2026-10-05/ (exploratory; raw data stays on the lab host). The fused-baseline R015 (docs/research/spec048-r015/evidence-2026-10-03-a3b-fused-formal/) FAILED and native MTP is not being activated.

Read first: specs/SPEC-048-native-mtp-serving.md (MTP-3 immutable-dependency exception, the fused-baseline paragraph, changelog 0.1.21-0.1.23), specs/SPEC-023-installer-autotune-recommend.md (R024, changelog v0.22.9-v0.22.11).

You may run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_native_mtp_r015_analyze scripts.tests.test_native_mtp_lab_flag_guard scripts.tests.test_native_mtp_admission_sidecar scripts.tests.test_native_mtp_post_gateway_replay_analyze scripts.tests.test_upstream_watch`, `python3 scripts/gen_spec_index.py --check`, `python3 scripts/check_spec_governance.py --base-ref origin/main`. Swift tests need Metal and run in CI; do not try to build MLX.

Out of scope (do not report): signing keys and how the operator stores them; the live coordinator; release cutting; style nits.

Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line, a concrete failure scenario in prose, and a fix; say whether each is new in this diff or pre-existing on main. Do not report style nits as MEDIUM or above. End with a single final line exactly: `VERDICT: <n> CRITICAL, <n> HIGH, <n> MEDIUM, <n> LOW`.

ROUND 2. HEAD is 7d55924eb; the fork pin is b181102984a4d1875efbd9e0eab3a7dfd1c012c5. Round 1 results: security 0/0/1/0, architecture 0/0/1/0, code 0/0/1/0. All three Mediums were fixed in 7d55924eb and fork commit b1811029. For EVERY item below (all lanes), state VERIFIED or still OPEN with evidence, and check the fix for regressions; then re-review the full scope for anything new.
- SEC M (fork Qwen35FusedMoE.resolve): companion tensor shapes were not validated -> new hasLayout() requires uint32 packed weights and bf16 scales/biases with the exact shapes the kernels index for gate, shared gate, expert gate/up/down, shared expert gate/up/down; mismatch returns nil (stock path); test testMismatchedQuantizedLayoutIsNotFusable.
- ARCH M (proposal depth vs fused row envelope): NativeMTPAdmissionSidecar.swift caps R024 proposal_depth and $.mtp max_proposal_depth / adaptation_max_depth at nativeMTPMaximumProposalDepth = 6; scripts/native_mtp_admission_sidecar.py MAX_PROPOSAL_DEPTH = 6; SPEC-023 R024 table and v0.22.11, SPEC-048 0.1.23 state it; tests in both languages.
- CODE M (watch reviewed flag): check-upstream-throughput-blockers.sh derives native_mtp_public_row_mapped_transactions_reviewed from native_mtp_exception_approved (as on main) and UPSTREAM_WATCH.json carries false while the exception is pending.

LANE: CODE REVIEW (correctness, regressions, test adequacy).

Focus:
- Qwen35FusedMoE.forward (fork): the per-row guard (x.dim(-2) <= 7) versus flattened-token chunking; shapes for x of rank 2 and 3; reshape back to x.shape; contiguity of `flat[start ..< start+count]` slices passed to custom Metal kernels; that every chunk size 1...7 maps to a valid KernelKey; whether any production call shape (ordinary decode, native verify, CB lockstep windows, prefill, warm-up, self-test probes) now takes a different path than intended; kill switch behaviour.
- Fused kernels vs stock: expert selection, top-k ties, shared-expert gate, bf16 rounding points; batch invariance claims in the tests and whether the tests would catch a chunking bug (e.g. wrong offset, dropped tail chunk).
- Pin consistency: Package.swift, Package.resolved, KVBuildIdentity.mlxSwiftLMRevision, NativeMTPHardwareE2ERunner.upstreamRevision, read_swiftpm_pins.py, check-upstream-throughput-blockers.sh, UPSTREAM_WATCH.json all agree; any check that would pass with a stale or unreviewed revision.
- ModelRuntime.recordNativeMTPTokenBoundDowngrade and the lab-only hooks: production behaviour change beyond recording; double counting; compile-time gating of lab code (DEBUG || MACPROVIDER_LAB_HARNESS).
- ContinuousBatchScheduler lab batch-composition fence: can it ever engage in a release build, deadlock, or leak a held batch.
- Analyzers (r015, post-gateway replay, admission sidecar): vacuous passes, fail-open paths, Swift/Python disagreement.
