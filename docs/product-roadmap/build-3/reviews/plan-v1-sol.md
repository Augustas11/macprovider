# Product Build 3 — Independent Adversarial Plan Review

Review status: **FAIL — revision required before implementation**
Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Reviewed plan commit: `3e83ade8f84fcc0ff7e79588336fcefba77fb0f9`
Plan: `docs/product-roadmap/build-3/prd-implementation-plan-v1.md`
Plan SHA-256: `8e02cea579d672c9ee9055e359267c6c4ee59521d7772468f7a403cbfc7866d4`
Test specification: `docs/product-roadmap/build-3/test-spec-v1.md`
Test-spec SHA-256: `186e030e400c0335a786f430ee8db0a0334284534e1a7734429caf8b01a5ba2b`
Inspection context verified: `inspection-status-v1.md` SHA-256 `36c65687062eec4bb4584af483318fdb162fa360c5669488959129f24ed70fa1`; `independent-inspection-v1.md` SHA-256 `fca2de09d7c2f3f93008df714ca81b56ae25ebd0f507b25980bba16758928dae`.

## Verdict

The plan is directionally conservative and correctly keeps enforcement, emissions, withdrawals, payments, epochs, deployment, and production qualification out of scope. It also correctly distinguishes fixtures, actual MLX inference, physical end-to-end evidence, Xcode/browser evidence, and production qualification.

It is not yet safe to approve for implementation. The exact pilot identity is intentionally unresolved, the durable observation owner has no linearization design, and the billing event proposal cannot yet carry authoritative request-start compute evidence into rewards. Reference/calibration acceptance also does not prove the independence and class-calibration claims it relies on.

Finding counts: **0 Critical, 5 High, 2 Medium, 0 Low**.

## Findings

### H1 — The supposedly exact covered key is not exact, and the plan does not require a second full gate before production slices

**Severity:** High

**Evidence:** The plan calls the configuration exact but leaves the runtime as “exact release/build identity” and the hardware class as a value to be established later (`prd-implementation-plan-v1.md:14-31`). The profile's tokenizer, prompt bytes, template, processors, encoding, tolerances, timeouts, and ceilings are also deferred to a future manifest (`:31`). The feasibility spike can materially determine whether the sampler stage exists and what owned interface, resource budget, runtime build, and class definition are possible (`:106-116`). Slice 0 asks for reapproval only “if review changes architecture, contracts, scope, or test strategy” (`:181-186`), which does not unconditionally gate Slices 1-7 on the exact outputs of the spike and calibration. Current code confirms that the production CLI version is concrete (`CoordinatorClient.binaryVersion`) but the compute key/capture presently binds only `hardware_runtime_class`, not a frozen Build 3 pilot manifest (`internal/computeintegrity/keys.go:39-52`, `capture.go:16-29`).

**Consequence:** This review cannot assess one explicit model/runtime/profile/hardware path. A later choice of MLX API, runtime identity, class predicate, numeric representation, or resource ceiling could change feasibility and trust boundaries while still being treated as covered by this approval.

**Required correction:** Make the current gate explicitly authorize only the bounded feasibility/governance slice, then require a new independent adversarial gate before any runtime, durable-source, reward-mapping, or user-visible availability implementation. That revision must freeze a canonical covered-key/profile artifact containing the exact CLI/runtime build identity and digest, MLX package revision, supported OS range, tokenizer identity/digest, sampler pipeline and stage, prompt/template bytes and digest, positions, probability encoding, numeric rules, resource ceilings, hardware-class predicate and digest, corpus/reference/calibration/threshold digests, expiry, and compatibility behavior. Alternatively, supply those exact values in the current plan and test spec.

### H2 — No durable owner or linearization point is defined for observation state, revocation, and request-start capture

**Severity:** High

**Evidence:** The plan says only “Coordinator observation tables” with immutable events and a derived snapshot (`prd-implementation-plan-v1.md:162-167`) and later says to implement “durable observation repositories” (`:188-193`). It does not select SQLite/Postgres, define transaction boundaries, lock/CAS ordering, or explain how a request-start read is serialized against policy/reference/calibration expiry or revocation. Yet it requires immediate durable invalidation (`:56-60`) and a deterministic revocation/request-start race (`test-spec-v1.md:B3-E006`). Current positive windows and tombstones live in the in-memory `computeintegrity.Store`, while immutable request-start captures live in the billing SQLite database (`internal/computeintegrity/window.go`; `internal/billing/store.go:266-295`; `settlement_compute_integrity.go:17-55`).

**Consequence:** A request can read a positive derived snapshot while a revocation commits elsewhere, then persist an apparently pre-revocation capture after the revocation. Restarts and concurrent evaluators can also resurrect or overwrite a newer tombstone unless ordering is defined. The test's desired outcome is not implementable deterministically from the plan.

**Required correction:** Name the authoritative database and schema owner. Define one monotonic revision/event sequence, the exact transaction or compare-and-swap that materializes current state, the request-start linearization point, lock order, isolation level, restart reconstruction, and rules for expiry/revocation/evaluation races. If observation authority and billing capture remain in different databases, define a durable protocol that prevents a capture from being committed under a superseded observation revision without relying on clocks or best-effort reads. Add fault-injection tests for every commit ordering, coordinator crash, retry, and stale evaluator.

### H3 — The billing journal does not define an immutable request-bound projection and watches the wrong authority surface

**Severity:** High

**Evidence:** The plan journals an insert or settlement-relevant update “to a request-credit row” and then has the mirror “upsert[] the referenced request-credit state” (`prd-implementation-plan-v1.md:132-141`, `:166-168`). In the current source, the authoritative compute capture is a separate immutable `settlement_compute_integrity_captures` row linked to a route snapshot, not a column on `ledger_request_credits` (`internal/billing/store.go:266-295`; `settlement_compute_integrity.go:17-55`). The current mirror projects only `ledger_request_credits` plus a computed SPEC-022 payable view and does not read compute captures or their snapshot digests (`internal/stats/billingmirror/mirror.go:requestCreditsQuery`, `upsertRequestCredit`). The proposed tests verify journal sequencing and request-level end-to-end correlation, but no test requires the journal payload itself to contain and digest all receipt, exclusion, route, and request-start observation facts.

**Consequence:** Rewards could see a fresh, complete request-credit mirror while lacking the exact observation that applied at request start. Re-reading mutable/current auxiliary tables when consuming an old event can also bind a later state to an earlier sequence. That permits current provider status to upgrade historical work, or makes the requested receipt-to-observation-to-accrual audit impossible.

**Required correction:** Define a versioned, canonical, immutable billing-projection event payload produced in the same SQLite transaction as the authoritative change. It must contain, or digest-and-retain, the complete denormalized reward input: request/attempt/provider identity, route snapshot identity, receipt/verdict/finality state, privacy/reward exclusions, credits/timestamps, and the exact immutable compute request-start snapshot and digest. Consumption must apply the event payload itself, never reconstruct an old event from current source rows. Define events for every auxiliary-table mutation that can change the projection. Add races for multiple mutations between source-max observation and fetch, capture-before-credit, receipt-after-credit, revocation-after-capture, and replay with a changed body.

### H4 — The source-generation and online-bootstrap guarantees are asserted without a mechanism that survives database restore

**Severity:** High

**Evidence:** The plan states that replacing or restoring SQLite changes generation (`prd-implementation-plan-v1.md:136-139`) and that backfill occurs “under a new source generation” (`:166-176`). A generation stored only inside the SQLite file is restored with the file; a sequence and generation pair can therefore move backward together without a mismatch. The plan also does not order generation creation, event-table/trigger installation, backfill, writer locking, and cutover, so concurrent billing writes can fall between the snapshot and the journal authority. `B3-M007` tests only a reset that visibly changes generation, not restoration of an older copy carrying the same generation.

**Consequence:** A restored or in-place replaced source can be mistaken for the current incarnation and reported complete/fresh while events are missing. An online migration can also permanently omit a request mutation even though the target watermark reaches the observed maximum.

**Required correction:** Define a restore-resistant incarnation protocol. Use a monotonic identity anchored outside the restorable SQLite payload, or a target/operator-owned accepted-incarnation record plus an append chain/restore detection rule that fails unavailable on rollback, fork, or unknown lineage. Specify an atomic bootstrap algorithm, including writer exclusion or an equivalent no-gap transaction, trigger/call-site activation, backfill snapshot, tail catch-up, digest/count verification, cutover, rollback, and crash recovery. Add tests for restoring an older full database with the same embedded generation, restoring in place, sequence reuse, source fork, concurrent writes at every migration boundary, and crash/restart at each bootstrap phase.

### H5 — Reference and calibration acceptance does not prove the production claims required by SPEC-036 or the mission

**Severity:** High

**Evidence:** The plan reduces the positive-state prerequisite to two events from “independently controlled execution environments” plus general provenance/signature fields (`prd-implementation-plan-v1.md:120-130`). Existing SPEC-036 requires independence across all three axes—operator identity, physical/power/network failure domain, and independently produced runtime build/kernel provenance—and requires signed golden-fixture validation in addition (`SPEC-036-compute-integrity-receipt.md:825-865`). Its hardware-class calibration contract also commits a known-good cohort, measured false-quarantine numerator/denominator/rate, position and sample counts, tail feasibility, and approval (`:1260-1347`). `B3-C003` only exercises generic correlated/non-independent fixtures, while `B3-A001` records reference/calibration digests but does not prove how they were produced. The hardware prerequisites remain narrative rather than acceptance IDs.

**Consequence:** Two correlated fixtures or cloned hosts could satisfy the written tests and yield a “verified” production observation without independently justified references or a demonstrated numeric-equivalence class. This is the central trust claim of Build 3, so digest presence alone is insufficient.

**Required correction:** Preserve the existing stronger SPEC-036 predicate explicitly. Add acceptance IDs requiring physical evidence for each reference source's operator authority, distinct host and power/network failure domain, independent runtime-build/kernel provenance, signed golden-fixture validation at admission and refresh, catalog/artifact/tokenizer/profile equality, and key/signature verification. Add calibration acceptance IDs with a frozen named hardware class/digest, cohort membership and adjudication evidence, exact sample/position minimums, warm/cold coverage, tail feasibility, measured false-quarantine numerator/denominator/rate versus a predeclared budget, threshold derivation, expiry, and independent approval. Fixture tests remain parser evidence only.

### M1 — Probe transport omits existing encrypted-carrier and shared-scheduler obligations

**Severity:** Medium

**Evidence:** Slice 2 specifies versioned messages, one concurrent compute probe, a queue, and paid-inference priority (`prd-implementation-plan-v1.md:195-201`). It does not state that Tier-2 sessions must use SPEC-036's encrypted carrier, that plaintext probe frames must be rejected when Tier-2 is active, or that compute-integrity and losslessness share an aggregate concurrency ceiling and explicit relative priority. SPEC-036 already mandates those points in FR-6. `B3-P005` tests only two compute leases; there is no cross-profile scheduler or Tier-2 downgrade test. The Swift client currently has an explicit losslessness frame path and NAKs unknown types (`CoordinatorClient.swift:2002-2054`, `:2234-2310`), so compatibility and carrier selection are active design concerns.

**Consequence:** A straightforward implementation can leak settlement-bearing probe material outside the negotiated Tier-2 carrier, exceed the aggregate probe load, starve one probe class, or repeatedly send unsupported frames to older providers without proving the intended compatibility behavior.

**Required correction:** State that the implementation preserves SPEC-036's exact plaintext/Tier-2 carrier separation and shared scheduler contract. Add capability negotiation/version-floor behavior, plaintext-on-Tier-2 and encrypted-without-session rejection, nonce/replay separation across carriers, old-provider NAK/no-disconnect behavior, compute-versus-losslessness priority, aggregate and per-profile caps, buyer-work preemption, cancellation, and starvation tests.

### M2 — The reward projection contract is not a total, reviewable mapping

**Severity:** Medium

**Evidence:** The plan says to add three closed states and closed reasons, and says stale/unavailable inputs cannot produce “earning now” (`prd-implementation-plan-v1.md:143-151`), but it supplies no exact state enums, reason precedence, source-input truth table, or separation between historical request eligibility, current earning visibility, balance eligibility, withdrawal eligibility, and payment execution. Current code derives `earning_verified_work` from any recent mirrored SPEC-022 verified row and hardcodes provider compute state unknown (`internal/rewards/projection.go:86-117`, `:126-179`); the wallet response separately exposes payout authorization and bundles the first audit page (`internal/rewards/wallet_status.go:40-83`, `:167-180`). The test spec names scenarios but does not prove a total cross-product or precedence under simultaneous stale mirror, revoked compute, eligible balance, wallet mismatch, cap, hold, and payment outage.

**Consequence:** App and portal implementations can be individually plausible yet disagree, collapse historical and current facts, or show a withdrawable/earning label selected by an arbitrary primary reason. Unknown future combinations may not fail conservatively.

**Required correction:** Put the exact versioned response schema and total mapping table in the plan/spec before implementation: all enum members, authoritative input owner, freshness requirement, precedence, last-known semantics, recovery action, and display copy for every output. Separate request-level reward eligibility from provider-current observation and from already accrued balance. Keep `payment_state=unavailable` and all production accrual/payment gates off. Generate coordinator, Swift, and portal vectors from the same table and add exhaustive pairwise or property tests for simultaneous conditions and unknown enums.

## Fresh verification

The following fresh commands passed on the reviewed commit. They confirm the current conservative baseline only; they do not resolve the plan findings or constitute Build 3 acceptance.

```text
cd phase4-coordinator && go test ./internal/computeintegrity ./internal/stats/billingmirror ./internal/rewards ./internal/billing -count=1
  PASS: four packages, zero reported failures

cd frontdoor/provider-portal && node --test mining-health.test.mjs
  PASS: 9 tests, 0 failed, 0 skipped
```

## Gate decision

`build3-plan-v1` / `build3-test-v1` is **not approved**. Implementation must not begin from this revision. Revise the plan and test specification to resolve all findings, provide new exact SHA-256 digests, and rerun an independent GPT-5.6 Sol high-reasoning gate over the new committed revision.
