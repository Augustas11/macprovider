# Product Build 3 — Planning Checkpoint Revision 5

Checkpoint: `build3-checkpoint-v5`
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Branch/worktree: `codex/product-build-3` at `/Users/augstar/.codex/worktrees/macprovider/product-build-3`
Date: 2026-09-11

## State

Independent GPT-5.6 Sol review of revision 4 failed with 0 Critical, 4 High, 3 Medium and 0 Low findings. Revision 5 addresses all seven in the plan and test specification without collecting governed numeric evidence, implementing a product/runtime source, enabling observation enforcement or economics, deploying, changing operator secrets, weakening acceptance, or inspecting `d-inference`. `reviews/plan-v4-findings-disposition-r5.md` maps every correction. Approval remains pending a fresh independent gate.

The plan now describes two pre-product executable slices. Neither has started and neither is authorized unless its preceding gate passes: Collector Slice H0 follows Gate H0 and must pass Gate H1 before Gate A0; Feasibility Tooling Slice B0I follows Gate B0D and must pass Gate B0E before any benchmark counts. Product Slices 1–7 remain blocked until Gate B.

## Revision 5 decisions

- The historical `1.8.123` CLI is ineligible for numeric collection. A bounded Swift collector slice must implement the sampler tap first, pass complete-diff review, and freeze signed collector plus measurement-module object identity before Gate A0 or calibration.
- The eventual production release must embed byte-identical measurement-module object bytes under the same dependency/compiler ABI. Semantic similarity cannot inherit calibration.
- Daily references are immutable per-source series with predecessor chains and atomic A+B epochs. Gate-A0 calibration precommits and held-out-tests predecessor movement, mutual divergence, skew and meaningful drift. Gate C binds roots and successor policy; invalid refreshes suspend prospectively while old captures remain immutable.
- Reward status uses one Postgres-owned revision across ledger, seven-scope disposition facts, membership, caps, wallet, production accrual, activity and mirror completeness. Every writer commits through a revision-token gate; each summary/first page is one repeatable-read snapshot and pagination stays revision-bound.
- One-way lineage activation is fenced by local+witness epoch, SQLite minimum writer protocol and durable mutation triggers, plus a supervisor signing/digest allowlist. Old binaries and direct legacy mutations fail before mutation; recovery is forward-only after activation.
- Gate B0D approves the executable feasibility design and exact paths. Slice B0I then implements a qualification-only command and shared protocol core; Gate B0E audits and freezes it before measurements. Production packages and deploy graphs must exclude the command.
- `ProviderPreWarmer` is governed as a child process by a supervisor-owned lifecycle lease, liveness channel, PID-start/process-group identity and bounded kill/reap recovery. Serving and candidate processes never overlap.
- Logical lineage remains append-only while hot storage is bounded through sealed segments, digest-preserving checkpoints and dual independently failed archives. Rolling 30-day qualification, multi-threshold exhaustion gates, restore samples and five-year/two-migration tests prevent one-year evidence from becoming an indefinite claim.

## Remaining gates and blockers

1. Commit revision-5 artifacts and their exact digests.
2. Run a fresh independent GPT-5.6 Sol high-reasoning plan review. Revise until zero Critical, High and Medium findings.
3. If the plan passes, author `compute_hook_design.v1`; Gate H0 must approve it before Collector Slice H0.
4. Implement/audit Collector Slice H0, produce its signed manifest, and pass Gate H1. No governed numeric acquisition may precede Gate A0.
5. Commit and pass Gate A0 on exact collector/profile/protocol/reference-successor digests, then satisfy two disjoint references, 80 calibration units, custody split, held-out false-suspension and meaningful-drift power.
6. Commit the closed preimplementation package and pass Gate B0D; only then implement B0I. Pass Gate B0E before capacity/crash/continuation benchmarks.
7. Pass Gate B before Product Slices 1–7; build/sign and pass Gate C before positive local qualification.

Current qualification blockers include: no approved collector design; no collector source/executable/module/signing manifest; no proof that governed numeric values stayed unopened; no two disjoint reference authorities or admitted series; no 80-unit physical/custody campaign; no held-out observation or refresh power result; no Gate-B0D exact schema/mutation/storage/witness/archive package; no B0I executable or Gate-B0E review; no independent witness/archive topology or multi-year recovery evidence; no Build 3 actual-MLX/Xcode/browser/physical trace; no built release qualification; no separately authorized production accrual for provider-visible real-job reward acceptance; and no production qualification. Enforcement, reward-capability/economic activation, payment execution, epochs, deployment, procurement, release publication and operator-secret changes remain out of scope.

Exact revision-5 gate inputs before commit:

- `prd-implementation-plan-v5.md` SHA-256: `8f3e442f027a5908d7af913b900179e399a1cc7dd8134c14142c22d197246111`
- `test-spec-v5.md` SHA-256: `7da0c9b87a71bd3a9698ba9454365ae04a15cc56def090057db479c4f0adf3f8`
- `reviews/plan-v4-findings-disposition-r5.md` SHA-256: `7704d6621d6e49315aa1f0fac25a8b6f8ef3fd42cfeaa39cb46a1312cca55b88`
- source failed review SHA-256: `11baf4d72c197d0947286a8ae03ccd82a25641799b135ca1300a726cb49ab6ee`

The independent reviewer must recompute these values from the committed tree.
