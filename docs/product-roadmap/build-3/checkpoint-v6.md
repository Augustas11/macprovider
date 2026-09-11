# Product Build 3 — Planning Checkpoint Revision 6

Checkpoint: `build3-checkpoint-v6`
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Branch/worktree: `codex/product-build-3` at `/Users/augstar/.codex/worktrees/macprovider/product-build-3`
Date: 2026-09-11

## State

Independent GPT-5.6 Sol review of revision 5 failed with 0 Critical, 4 High, 1 Medium and 0 Low findings. Revision 6 addresses all five in the plan and test specification without implementing source code, collecting governed numeric evidence, enabling observation enforcement or economics, deploying, changing operator secrets, weakening acceptance, or inspecting `d-inference`. `reviews/plan-v5-findings-disposition-r6.md` maps every correction. Approval remains pending a fresh independent gate.

The two pre-product executable slices remain unstarted. Collector Slice H0 requires Gate H0 approval of both hook and acquisition-authority designs and then Gate H1 complete-diff approval. No numeric path can run without a later Gate-A0 capsule and live one-time consumption grant. Feasibility Tooling Slice B0I may independently start after Gate B0D because it consumes only synthetic nonnumeric inputs, then requires Gate B0E before any benchmark counts. Product Slices 1–7 remain blocked until both lanes join and Gate B passes.

## Revision 6 decisions

- A separately governed approval key and replicated online sequence authority make Gate A0 executable authority. One shared measurement-module operation checks the signed capsule, exact job and live one-use grant immediately before any CLI or runtime tensor value access. Offline/cached access, sequence reuse and rolled-back authority fail closed.
- SQLite PREPARE now binds an exact ordered mutation manifest. Only the lineage owner can install a connection-and-transaction-bound authorization after both authorities durably acknowledge PREPARE. Durable triggers consume exact occurrences; finalization plus a commit hook rejects incomplete, changed, extra, split or reused work, including same-process direct SQL.
- Payout-wallet authority stays in SPEC-016 SQLite with an immutable lifecycle event/head. The mirror applies contiguous events into a Postgres reward revision. Reward reads return a composite Postgres/wallet version only when a fresh authoritative SQLite head equals the applied head; pending/stale wallet state disables wallet/withdrawal truth without collapsing balance, compute, payment or USDC state.
- Foreground `macprovider-cli serve` and launchd-direct own the same cross-process lifecycle lease themselves before runtime initialization. App/supervisor paths retain parent ownership. Signal, crash, PID reuse, device quiescence, wrapper mode and drain/exit/restart upgrade rules cover all supported entrypoints.
- Numeric calibration and nonnumeric lineage feasibility are parallel lanes. Gate B0D/B0I/B0E can proceed before physical calibration, but cannot import governed numeric evidence, unlock Product Slices, publish status, qualify production or create settlement/economic authority. Both lanes join only at the evidence bundle and Gate B.

## Remaining gates and blockers

1. Commit revision-6 artifacts and exact digests.
2. Run a fresh independent GPT-5.6 Sol high-reasoning plan review. Revise until zero Critical, High and Medium findings.
3. If approved, the independent lanes may proceed under their own gates: author and approve the exact Gate-H0 hook/acquisition-authority design before Collector Slice H0; author and approve the exact Gate-B0D package before Feasibility Tooling Slice B0I.
4. Collector Slice H0 must pass Gate H1. Gate A0 must then approve exact collector/profile/protocol/reference policy and issue the first acquisition capsule before any governed numeric access.
5. The numeric lane still requires two disjoint references, 80 calibration units, custody split, held-out false-suspension and meaningful-drift power. The nonnumeric lane still requires Gate-B0E-reviewed executable tooling plus synthetic capacity/crash/continuation evidence.
6. Gate B must approve the joined evidence bundle before Product Slices 1–7. Gate C must approve a built/signature-bound release before positive local qualification. Production observation additionally requires separate rollout authorization.

Current qualification blockers include: no approved acquisition-authority or collector design; no collector source/executable/module/signing manifest; no Gate-A0 approval capsule or live sequence authority; no two disjoint reference authorities or admitted series; no 80-unit physical/custody campaign; no held-out observation or refresh power result; no Gate-B0D exact schema/mutation/storage/witness/archive package; no B0I executable or Gate-B0E review; no independent witness/archive topology or multi-year recovery evidence; no Build 3 actual-MLX/Xcode/browser/physical trace; no built release qualification; no separately authorized production accrual for provider-visible real-job reward acceptance; and no production qualification. Enforcement, reward-capability/economic activation, payment execution, epochs, deployment, procurement, release publication and operator-secret changes remain out of scope.

Exact revision-6 gate inputs before commit:

- `prd-implementation-plan-v6.md` SHA-256: `91b3d488c06de68d90b697a8374aa3acfa1711f6883a3a9de12c10cd6c6e5830`
- `test-spec-v6.md` SHA-256: `fc5658d42c5b94d7649733df11c4f847a4769be32c92aab8631cca77d2178d85`
- `reviews/plan-v5-findings-disposition-r6.md` SHA-256: `7b8d33570b5dc7a76241c7465456ef55e76549affac76e6738a6766a579b8ac7`
- source failed review SHA-256: `31ba0be5c46302e44bf814ffa1db6fa18441f7244b4532458e2f9a46745f4341`

The independent reviewer must recompute these values from the committed tree.
