# Product Build 3 — Plan v7 Independent Adversarial Review

Review status: **PASS — zero Critical, High, or Medium findings**

Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning  
Review type: independent plan, architecture, trust-boundary, economics, UX, failure-recovery, and acceptance-test gate  
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`  
Reviewed commit: `132247867fc27ba37ed5844dbe4b2831a2559887`  
Plan: `prd-implementation-plan-v7.md`, SHA-256 `514d024ad2b6d44ae09d9fce1f5d211627512689e77c4f82924aeb0baf103752`  
Test specification: `test-spec-v7.md`, SHA-256 `6a6c877ffcc05764a7b6e4c601be539e99cc6e8549e93eedd21a91d2288bcd5a`  
Finding dispositions: `plan-v6-findings-disposition-r7.md`, SHA-256 `53bc41e940f8655ac7e9e8672dd58482423927b9f5548254ac9042f63939dc2f`  
Source failed review: `plan-v6-sol.md`, SHA-256 `786bd6a7eba541edf4e905f62de28514c25b84d0890bbbcf040b593bcc05a431`

## Verdict

Revision 7 resolves the revision-6 Medium finding without rewriting wallet mutation provenance. `source_committed_at` remains the time of the last authoritative wallet-content mutation. The new checkpoint sequence `C` records a separately durable, head-bound unchanged-state checkpoint, and a fresh request challenge obtains three independently authenticated assertions over the same fully committed `(source_incarnation,H,C)`. The accepted observation interval comes from the coordinator's live request and monotonic deadline; neither the checkpoint nor polling time is presented as mutation time.

The checkpoint and challenge protocols are closed against the material replay and restart cases. A checkpoint conditionally advances only `C` after dual PREPARE and exact `H`/prior-`C` comparison, then requires dual COMMIT. Assertions bind the complete challenge digest, authority, key epoch, serving incarnation, wallet/checkpoint heads, checkpoint record, and independent times. The originating request consumes its in-memory nonce once. Coordinator restart discards outstanding challenges; authority restart changes the serving incarnation and requires durable-head verification before signing. Stale, future-dated, replayed, substituted, rolled-back, forked, partial, or one-authority evidence fails the wallet domain closed.

The composite reward view is coherent for the stated scope. Postgres supplies one repeatable-read snapshot at reward revision `R` and applied wallet head `H`; the live three-authority observation supplies the matching current `H` and checkpoint `C`. The response exists only for an agreeing `(R,H,C)`. A later wallet mutation either leaves a valid old-head linearization point, creates a Postgres/source-head mismatch, or returns a bounded race failure. Pagination retains the original composite version and truthfully ages its observation rather than silently refreshing eligibility.

The failure mapping preserves independent product domains. Wallet observation failures affect wallet binding and withdrawal eligibility while retaining last-known wallet facts and distinct mutation, checkpoint, observation, verification, reward, payment, USDC, and response times. They do not erase balances, promote unknown compute to idleness, claim current earning, or imply operational payment. Production reward capability and payment execution remain disabled, and qualification shadow evidence remains structurally excluded from provider-visible economics.

The accumulated plan also retains the earlier gate corrections: acyclic collector/profile/calibration/release construction; live Gate-A0 authorization immediately before the first governed value access; 80 independent physical decision units and blind held-out power evidence; restart-safe request routing; transaction-scoped SQLite lineage authorization; dual-authority recovery; independently executable nonnumeric feasibility work; bounded lineage storage; complete seven-scope reward inputs; lifecycle ownership for every MLX process path; and explicit physical, Xcode, browser, production-accrual, and rollout blockers.

Finding counts: **0 Critical, 0 High, 0 Medium, 0 Low**.

## Revision-6 finding disposition

| Revision-6 finding | Revision-7 assessment |
| --- | --- |
| M1 quiet payout-wallet sources age into false unavailability | **Resolved at plan level.** A valid unchanged wallet can obtain a new challenge-bound observation without changing payout rows, wallet sequence/head, or `source_committed_at`. Checkpoint currency and source observation are separately authenticated, time-bounded, restart-aware, replay-resistant, and required to agree with the immutable wallet head and both lineage authorities. B3-R029–R039 cover quiet intervals, all authority restarts, replay/substitution, expiry and clock faults, witness/local loss, checkpoint crash boundaries, mutation races, stale pagination, cross-client wallet-only failure behavior, and bounded concurrent load. |

## Adversarial assessment

### Trust and feasibility

- The SQLite owner, local journal authority, and witness cannot individually mint current wallet truth. The plan requires distinct pinned signing keys, exact shared heads, authenticated channels, complete recovery state, and a committed checkpoint record. Gate B0D must close the concrete identities, key rotation, failure domains, topology, rates, storage, and selected SQLite-driver mechanism before feasibility implementation.
- The unchanged-head checkpoint does not become a second wallet mutation authority. Its CAS advances only `C`; a wallet mutation wins by changing `H`, forcing renewal or a typed race result. The last wallet mutation time remains immutable.
- Work is bounded by a source-global singleflight, a 150-second unchanged-head renewal floor, governed wallet-mutation admission, three renewal attempts, a five-second challenge lifetime, and Gate-B0D rate/storage limits. B3-R039 makes failure under excess load wallet-local rather than permitting stale success or unbounded lineage growth.
- The plan does not assume that the current source implements these mechanisms. Current `internal/rewards/wallet_mirror.go` still polls mutable payout rows and stamps projection time, while `internal/rewards/projection.go` directly reads payout SQLite and hardcodes compute state unknown. These remain implementation work after the later gates.

### Economics and UX truthfulness

- Compute observation cannot activate SPEC-022 settlement, reward accrual, withdrawal execution, payment, or a trust tier. Provider signatures, a positive shadow result, and observation availability remain insufficient economic evidence.
- Historical production-ledger balances and wallet/withdrawal facts are independent from current compute and payment availability. Missing observation does not become confirmed idle or current earning.
- The physical first-job path may show provider-visible earning only if a separately authorized production reward capability and authoritative production accrual already exist. Otherwise that acceptance item remains blocked, even if receipt, mirror, shadow, and UI tests pass.

### Test adequacy and proof boundary

The test specification contains **179 unique test IDs** with no duplicates. The R029–R039 additions directly test the previous omission and its interactions with restart, replay, mutation, pagination, UX, and load. The complete matrix also distinguishes unit/fixture integration, Swift runtime, Xcode, browser, actual MLX, physical journey, production qualification, and independent review.

These IDs are an adequate specification for the proposed gates; they are not executed evidence. Gate approval does not prove that any collector, checkpoint authority, SQLite transaction hook, journal, witness, reward projection, app/portal client, physical calibration, or real-MLX journey exists. Each claim becomes eligible only after its named implementation and evidence class passes freshly. Skipped, timed-out, zero-selected, fixture-only, historical, or weaker-class runs cannot satisfy stronger acceptance classes.

## Fresh verification

The pinned base, reviewed commit, and all four supplied SHA-256 digests matched exactly. Fresh conservative-baseline checks passed:

```text
cd phase4-coordinator && go test ./internal/computeintegrity ./internal/stats/billingmirror ./internal/rewards ./internal/billing ./internal/buyer -count=1
  PASS: five packages; zero reported failures

cd frontdoor/provider-portal && node --test mining-health.test.mjs
  PASS: 9 tests; 9 passed; 0 failed; 0 skipped

git diff --check HEAD^ HEAD
  PASS

rg -o 'B3-[A-Z]+[0-9]{3}' docs/product-roadmap/build-3/test-spec-v7.md | sort -u | wc -l
  PASS: 179 unique IDs; no duplicate IDs
```

These checks prove only that revision 7 preserves the conservative baseline and supplies a unique 179-ID future acceptance matrix. They do not implement or prove the planned production behavior or stronger qualification classes.

## Gate decision

**PASS with zero Critical, High, or Medium findings.** Revision 7 may serve as the approved accumulated Build 3 plan for its explicitly bounded next gates. It authorizes only the documented Gate-H0 design work and, after its separate Gate-B0D approval, Feasibility Tooling Slice B0I. It does not authorize Product Slices 1–7, governed numeric acquisition, positive status publication, enforcement, economic activation, payment execution, deployment, or production qualification. Every subsequent gate must bind exact committed artifacts and independently reach zero Critical, High, and Medium findings before its dependent work begins.
