# Freeze diff: mlx-swift-lm 3.32.3 / MLX 0.32 dependency upgrade (PR #1927)

Audit the COMPLETE diff as it will land. Read it yourself with these commands
(run them; do not rely on summaries):

1. macprovider (cwd `/Users/augstar/macprovider-mlx332-deps`):
   `git diff origin/main...HEAD -- . ':(exclude)docs/research/mlx-swift-lm-3.32.3' ':(exclude)audits'`
   Evidence (context only): `docs/research/mlx-swift-lm-3.32.3/` (README.md,
   step1-root-cause.md, step3-compile-state.md, step3-native-margin.md).
2. mlx-swift-lm fork (production dependency): `git -C /Users/augstar/mlx-swift-lm-332 diff 3.32.3 3.32.3-macprovider.5`
   and `git -C /Users/augstar/mlx-swift-lm-332 log --oneline 3.32.3..3.32.3-macprovider.5`
3. mlx-swift fork: `git -C /Users/augstar/mlx-swift-332 diff 0.32.3 0.32.3-macprovider.2` (submodule moved to the core fork)
4. MLX core fork: `git -C /Users/augstar/mlx-core-0322 diff v0.32.2 v0.32.2-macprovider.2`

What the change is: macprovider's provider runtime moves from a fork of
mlx-swift-lm 3.31.4 to a fork of 3.32.3 on mlx-swift 0.32.3 / MLX core 0.32.2.
The forks carry only work upstream lacks (packed MTP verification and cache
transactions, packed drafter, fused A3B MoE kernels behind
MLX_LM_QWEN35_FUSED_MOE with layout validation, one-pass GDN verify checkpoint,
a compiled MTP verify step, compile state declared for every trace, upstream
#631 cherry-picked, batch-invariant small-M quantized matmul routing in core,
and per-thread compiled-trace cache cleanup in core). macprovider keeps legacy
`.remainder` prefill chunking, binds the KV cold-tier identity and the native-MTP
bench to the real fork revisions, and moves Swift CI/candidate/release jobs to
macos-26 / Xcode 26.6 (Swift 6.3.3) while sign-only jobs stay on
macos-15-intel with the sealed OpenSSL; the signer re-verifies catalog
signatures on sealed OpenSSL + Go before signing.

Studio evidence: startup batched-isolation probes pass; formal native-MTP R015
PASS on the final stack; CI 19/19 green.

Repo is PUBLIC. Report findings only; do not edit files.

Output format: a list of findings, each with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO),
file:line, the concrete failure scenario, and a suggested fix. End with one line:
`VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW`.
