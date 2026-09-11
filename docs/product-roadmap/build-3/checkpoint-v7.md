# Product Build 3 — Planning Checkpoint Revision 7

Checkpoint: `build3-checkpoint-v7`
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Branch/worktree: `codex/product-build-3` at `/Users/augstar/.codex/worktrees/macprovider/product-build-3`
Date: 2026-09-11

## State

Independent GPT-5.6 Sol high-reasoning review of revision 6 failed with 0 Critical, 0 High, 1 Medium and 0 Low findings. Revision 7 addresses that finding in the plan and test specification without implementing source code or tests, collecting governed numeric evidence, enabling observation enforcement or economics, executing payments, deploying, changing operator secrets, weakening acceptance, or inspecting `d-inference`. `reviews/plan-v6-findings-disposition-r7.md` maps the correction. Approval remains pending a fresh independent gate.

The two pre-product executable slices remain unstarted. Collector Slice H0 requires Gate H0 approval of both hook and acquisition-authority designs and then Gate H1 complete-diff approval. No numeric path can run without a later Gate-A0 capsule and live one-time consumption grant. Feasibility Tooling Slice B0I may independently start after Gate B0D because it consumes only synthetic nonnumeric inputs, then requires Gate B0E before any benchmark counts. Product Slices 1–7 remain blocked until both lanes join and Gate B passes.

## Revision 7 decision

- Wallet mutation time remains immutable provenance. A successful poll, status read, challenge, or checkpoint cannot change or relabel `source_committed_at`.
- A distinct durable checkpoint chain `C` records an authenticated unchanged wallet head without changing wallet rows, wallet event sequence/head or mutation time. Dual local/witness PREPARE, an exact SQLite compare-and-swap and dual COMMIT make partial or raced checkpoints nonauthoritative.
- Every summary refresh uses a new five-second, provider/audience/head/boot-bound CSPRNG challenge over mutually authenticated internal channels. SQLite owner, local journal and witness independently authenticate the same `(source incarnation,H,C)` and observation times. The coordinator atomically consumes the challenge; replay, substitution, retired keys, old boots, unavailable authorities, gaps, restores, clock faults and stale checkpoints fail the wallet domain closed.
- The composite view and cursor bind `(R,H,C)`. The response separately reports mutation, checkpoint, source-observation, coordinator-verification and generation times. Pagination preserves the original as-of observation and becomes stale rather than renewing eligibility; explicit summary refresh creates a new challenge.
- Closed observation failure reasons affect only wallet binding and withdrawal eligibility. Eligible balance, reward activity, compute state, payment state and USDC freshness retain their independently authoritative values. Quiet wallets can remain truthfully eligible across unlimited mutation-free intervals when fresh challenge-bound evidence and all durable heads are valid.

## Added verification

The revision-7 test specification contains 179 unique test identifiers. B3-R019–R021 and B3-R024–R028 now bind `(R,H,C)` and separate mutation/checkpoint/observation clocks. B3-R029–R039 add quiet-source windows, coordinator and source-authority restarts, replay/substitution, expiry/future/rollback clock faults, witness/local loss, checkpoint crash recovery, mutation races, stale pagination, cross-client failure-state truthfulness, and bounded concurrent checkpoint load.

## Remaining gates and blockers

1. Commit revision-7 artifacts and exact digests.
2. Run a fresh independent GPT-5.6 Sol high-reasoning plan review. Revise until zero Critical, High and Medium findings.
3. If approved, the independent lanes may proceed only under their existing gates: author and approve Gate-H0 hook/acquisition-authority design before Collector Slice H0; author and approve Gate-B0D package before Feasibility Tooling Slice B0I.
4. Collector Slice H0 must pass Gate H1. Gate A0 must then approve the exact collector/profile/protocol/reference policy and issue the first acquisition capsule before any governed numeric access.
5. The numeric lane still requires two disjoint references, 80 calibration units, custody split, held-out false-suspension and meaningful-drift power. The nonnumeric lane still requires Gate-B0E-reviewed executable tooling plus synthetic capacity/crash/continuation evidence.
6. Gate B must approve the joined evidence bundle before Product Slices 1–7. Gate C must approve a built/signature-bound release before positive local qualification. Production observation additionally requires separate rollout authorization.

Current qualification blockers remain: no approved acquisition-authority or collector design; no collector source/executable/module/signing manifest; no Gate-A0 approval capsule or live sequence authority; no two disjoint reference authorities or admitted series; no 80-unit physical/custody campaign; no held-out observation or refresh power result; no Gate-B0D exact schema/mutation/storage/witness/archive/checkpoint-observation identity and capacity package; no provisioned distinct observation assertion identities or independent witness; no B0I executable or Gate-B0E review; no independent witness/archive topology or multi-year recovery evidence; no Build 3 actual-MLX/Xcode/browser/physical trace; no built release qualification; no separately authorized production accrual for provider-visible real-job reward acceptance; and no production qualification. Enforcement, reward-capability/economic activation, payment execution, epochs, deployment, procurement, release publication and operator-secret changes remain out of scope.

## Exact revision-7 gate inputs before commit

- `prd-implementation-plan-v7.md` SHA-256: `514d024ad2b6d44ae09d9fce1f5d211627512689e77c4f82924aeb0baf103752`
- `test-spec-v7.md` SHA-256: `6a6c877ffcc05764a7b6e4c601be539e99cc6e8549e93eedd21a91d2288bcd5a`
- `reviews/plan-v6-findings-disposition-r7.md` SHA-256: `53bc41e940f8655ac7e9e8672dd58482423927b9f5548254ac9042f63939dc2f`
- source failed review SHA-256: `786bd6a7eba541edf4e905f62de28514c25b84d0890bbbcf040b593bcc05a431`

The independent reviewer must recompute these values from the committed tree.
