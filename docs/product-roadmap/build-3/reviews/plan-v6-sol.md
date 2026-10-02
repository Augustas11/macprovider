# Product Build 3 — Plan v6 Independent Adversarial Review

Review status: **FAIL — revision required before Gate H0 or Gate B0D work**

Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning
Review type: independent plan, architecture, trust-boundary, economics, UX, failure-recovery, and acceptance-test gate
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Reviewed commit: `dcebefed778ac041979c596a9ad59c8a9573f152`
Plan: `prd-implementation-plan-v6.md`, SHA-256 `91b3d488c06de68d90b697a8374aa3acfa1711f6883a3a9de12c10cd6c6e5830`
Test specification: `test-spec-v6.md`, SHA-256 `fc5658d42c5b94d7649733df11c4f847a4769be32c92aab8631cca77d2178d85`
Finding dispositions: `plan-v5-findings-disposition-r6.md`, SHA-256 `50769913b2615f0991c86aa086b67038f4ced224fc39fd357d579df2e18b578f`
Source failed review: `plan-v5-sol.md`, SHA-256 `cf82a0598ba44d855ab19bbb41824568cfcd86c1f8886b84975f42babbbb0076`

## Verdict

Revision 6 closes all four High findings and the Medium finding from revision 5 at the plan level. It places a live, single-use Gate-A0 authorization immediately before the first governed value access; makes SQLite mutation authority transaction-, connection-, manifest-, and commit-bound after dual PREPARE; gives the payout-wallet source its own durable lineage and a conservative composite Postgres/SQLite join; assigns foreground and launchd-direct serving processes the common lifecycle lease before MLX initialization; and makes the nonnumeric B0 lane independently executable without weakening the later Gate-B join.

The plan still cannot pass. Its payout-wallet freshness contract treats the last wallet mutation's `source_committed_at` as the freshness input for an otherwise live, head-equal authoritative snapshot. A correctly configured wallet may remain unchanged for months or years. Once the closed freshness interval elapses, the plan necessarily reports that wallet source stale and makes withdrawal unavailable even while SQLite, the local journal, the witness, and Postgres all agree at a live read. Poll time correctly cannot impersonate mutation time, but revision 6 defines no separate challenge-bound source-observation time or no-op authenticated head checkpoint that can prove a quiet source was freshly read. The paired tests cover source outage, staleness, and head races but omit the quiet, unchanged, live-source case.

Finding counts: **0 Critical, 0 High, 1 Medium, 0 Low**.

## Findings

### M1 — Quiet payout-wallet sources inevitably age into false unavailability

**Severity:** Medium

**Evidence:** The wallet mutation transaction advances `source_committed_at` only on add, replace, revoke, disable, or remove (`prd-implementation-plan-v6.md:251`). The mirror correctly preserves that source commit time and refuses to relabel poll time as source time (`:253`). The endpoint then requires “the wallet source time” to satisfy a freshness bound before it returns the composite view (`:255`), and exposes wallet `source_committed_at` separately from read/generated times (`:257`). No protocol field records a fresh challenge nonce, authoritative snapshot-observation time, or durably authenticated unchanged-head checkpoint. B3-R019, R024, R026, and R028 test mutation races and unavailable/stale sources, but no test leaves a valid wallet and all three heads unchanged beyond the freshness window while the source owner remains reachable and returns a fresh authenticated snapshot (`test-spec-v6.md:202,207,209,211`). This matters in the current architecture because payout authority is an independently polled SQLite database (`phase4-coordinator/internal/rewards/wallet_mirror.go:17-58`) and the current projection reads it directly (`phase4-coordinator/internal/rewards/projection.go:41-48,71-85`); the replacement contract must distinguish mutation age from observation currency.

**Consequence:** Every long-lived valid wallet eventually becomes `wallet source stale`, so withdrawal eligibility becomes unavailable during normal steady state despite complete, reachable, mutually agreeing authorities. Choosing a large bound only postpones the failure. Choosing an unbounded value would defeat the requested freshness contract and fail to detect an owner that stopped serving current authority. The result is conservative for funds but operationally false and prevents the supported first-job/reward journey from remaining usable without artificial wallet mutations.

**Required correction:** Define two separate clocks. Preserve `source_committed_at` as immutable mutation provenance. Add a nonce-bound, authenticated authoritative snapshot observation (or a durably sequenced unchanged-head checkpoint) whose `observed_at`, expiry, source incarnation, SQLite head, local COMMIT head, witness COMMIT head, and requester challenge are bound together and cannot be replayed. Use that observation currency, plus exact three-head equality and the existing gap/fork/recovery checks, to decide whether the quiet source is currently reachable and complete; never overwrite mutation time. Add tests for an unchanged valid wallet older than the freshness interval with a fresh live observation, replayed/expired/future-dated observations, clock rollback/skew, source-owner restart/incarnation change, witness unavailability, and a wallet mutation immediately before and after observation. The unchanged live case must remain wallet-bound and truthfully withdrawal-eligible when ledger policy allows, while stale or unauthenticated observations fail only the wallet/withdrawal domain closed.

## Revision-5 finding disposition assessment

| Revision-5 finding | Revision-6 assessment |
| --- | --- |
| H1 acquisition can bypass Gate A0 | **Resolved at plan level.** `withAuthorizedPostSamplerValues` is the only governed value-bearing operation. It requires an exact Gate-A0 capsule, one-count job, and live atomic consumption grant immediately before the first value touch. Sequence burning, anti-rollback recovery, mode ordering, compiler/link inventory, and F017–F021 close missing, wrong, replayed, offline, revoked, crash, restore, rotation, and alternate-path cases. Gate H0/H1/A0 remain required before governed acquisition. |
| H2 process-wide SQLite protocol number permits direct same-process mutation | **Resolved at plan level.** Dual PREPARE precedes an unexported authorization bound to the dedicated native connection and SQLite transaction, exact ordered before/after manifest, predecessor, event, and single use. BEFORE triggers consume occurrences; finalization plus the driver commit hook prevents missing, extra, reordered, split, or unfinalized commits. M024–M028 cover direct registered-connection access, alteration, reuse, pooling, rollback, cancellation, and crash boundaries. Exact `modernc.org/sqlite` support is correctly a B0D/B0E feasibility gate rather than an assumed capability. |
| H3 Postgres reward revision omits separately polled payout-wallet authority | **Resolved for lineage and cross-database consistency, subject to new M1.** Wallet lifecycle mutations receive their own dual-authority source journal and atomic SQLite event/head. Postgres applies only contiguous dual-committed ranges under one reward revision, and endpoints compare a stable Postgres snapshot with the authoritative three-head SQLite/local/witness snapshot. Direct payout-row reads are excluded and wallet failures do not collapse balances, compute, USDC, or payment. M1 concerns observation currency during a mutation-free interval, not the repaired lineage or head equality. |
| H4 foreground `macprovider-cli serve` lacks lifecycle owner | **Resolved at plan level.** Interactive and launchd-direct serve acquire the common lease before `ModelRuntime`, Metal, routing, or spawn and retain it through drain, synchronization, destruction, and record clear. Parent-owned app/supervisor modes remain exclusive. P018–P022 cover launcher races, double direct serve, wrapper modes, signals, SIGKILL/PID reuse/quiescence, and drain/exit/restart upgrades. |
| M1 physical calibration blocks independent feasibility work | **Resolved.** Gate B0D/B0I/B0E and synthetic benchmarks form a nonnumeric lane with explicit numeric import/schema exclusions. It can proceed while Gate A0 and the physical campaign are absent, but cannot construct the evidence bundle, unlock Product Slices, publish status, or create settlement/economic authority alone. F020 and H011–H013 prove the separation and Gate-B join. |

## Qualification, economics, and evidence boundaries

The plan remains truthful about the broader mission. Numeric calibration still requires two disjoint references, 80 independent physical decision units, blind custody, sealed held-out false-suspension and meaningful-drift power gates, exact artifact/runtime/hardware/profile identity, and fresh real-MLX evidence. Positive local qualification additionally requires a built and signed candidate, byte-identical measurement module, physical Apple Silicon, actual MLX, Xcode app, real browser, witness/storage topology, and Gate C. Production observation remains separately rollout-authorized.

Compute observation remains narrow and observation-only. It does not prove provider-wide integrity, hardware identity, confidential compute, anonymity, every-request honesty, or physical computation by itself. SPEC-022 observe remains economically excluded. Build 3 fixes reward capability disabled and payment execution unavailable; operator shadow decisions are structurally excluded from provider API, balances, reward activity, earning, withdrawal, and payment. Provider-visible real-job accrual remains blocked unless a separately authorized production reward capability and authoritative production-ledger accrual already exist.

The test specification has **168 unique test IDs**. Its evidence classes distinguish unit/fixture integration, Swift runtime, Xcode, browser, actual MLX, physical journey, production qualification, and independent review. Skipped, timed-out, zero-selected, historical, or fixture-only runs do not satisfy stronger classes.

## Fresh verification

The pinned commit and all four supplied digests matched exactly. Fresh conservative-baseline verification passed:

```text
cd phase4-coordinator && go test ./internal/computeintegrity ./internal/stats/billingmirror ./internal/rewards ./internal/billing ./internal/buyer -count=1
  PASS: five packages; zero reported failures

cd frontdoor/provider-portal && node --test mining-health.test.mjs
  PASS: 9 tests; 9 passed; 0 failed; 0 skipped

git diff --check HEAD^ HEAD
  PASS

rg -o 'B3-[A-Z]+[0-9]{3}' docs/product-roadmap/build-3/test-spec-v6.md | sort -u | wc -l
  PASS: 168
```

These commands prove only that the documentation revision preserves the conservative baseline and that the proposed matrix has 168 unique identifiers. They do not implement or prove the collector, authorization service, transaction hook, lineage witness, wallet journal, serving lease, numeric acquisition, B0 executable, actual MLX campaign, Xcode/browser journey, production accrual, enforcement, economic activation, deployment, or production qualification.

## Gate decision

**FAIL.** Gate H0, Gate B0D, Collector Slice H0, Feasibility Tooling Slice B0I, governed numeric acquisition, and Product Slices 1–7 remain blocked. Revise the wallet-source freshness contract and paired tests to close M1, commit exact new digests, and submit them to a fresh independent GPT-5.6 Sol high-reasoning review. Approval requires zero Critical, High, and Medium findings.
