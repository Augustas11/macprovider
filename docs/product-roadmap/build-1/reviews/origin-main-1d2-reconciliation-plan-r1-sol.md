# Independent adversarial review — Build 1 origin/main 1d2 reconciliation plan r1

Review date: 2026-09-11

Reviewer lane: independent GPT-5.6 Sol, high reasoning

Verdict: **REJECTED — implementation gate does not pass**

Finding count: **Critical 0, High 3, Medium 4, Low 0**

The plan and test specification may not authorize source reconciliation until
the High and Medium findings below are corrected and a fresh independent review
of the exact revised artifacts reports zero Critical, High, and Medium findings.

## Exact reviewed inputs

- Plan: `docs/product-roadmap/build-1/origin-main-1d2-reconciliation-plan-r1.md`
  - SHA-256: `0e717a9d9435394b345da7a739a71cb3fb2156ca7b33116f95b4a4e2925d5335`
- Test specification:
  `docs/product-roadmap/build-1/test-spec-origin-main-1d2-reconciliation-r1.md`
  - SHA-256: `7d2d675e110b4d3ee351e2aac84926329603797d09586b4d33bd8df553ad5eb2`
- Impact assessment:
  `docs/product-roadmap/build-1/origin-main-1d2-impact-sol.md`
  - SHA-256: `8541a4e495b90d047da1cbe8e049f79a3fcd28810368e6a7f4944739ba75c745`
- Repository base: `origin/main`
  `1d2c930bad81704dd0acc0322226725d8b64aceb`
- Inspected dirty worktree head:
  `914f7cafcdbcfc1805a10f4f34167218341d5587`

The separate slice-5 dependency was inspected only for status. At review time,
`/Users/augstar/macprovider-byom-v02-slice5` was on
`feat/byom-v02-slice5-intake-pipeline` at
`c44c422e1be97788e0df8d4883edd637c0d6d4ab`, one commit ahead of
`origin/main`, with dirty SPEC files and an untracked
`phase4-coordinator/internal/intake/` directory. No slice-5 file was modified.
No `d-inference` source was inspected.

## Review method

I read the exact plan and test specification, inspected the named impact
assessment, and independently inspected the relevant `origin/main` Go and Swift
implementation, landed specifications, tests, the dirty Build 1 worktree, and
the active slice-5 dependency status. I challenged the claimed current-state
classification, trust and pricing boundaries, operator origin and dual control,
provider-visible state sources, lock graph, replay semantics, migrations,
recovery, compatibility, and whether the proposed tests can prove the physical
and economic claims.

This was a design gate, so I did not treat historical or currently passing tests
as acceptance evidence and did not run implementation acceptance suites.

## Findings

### H1 — The plan assumes authoritative pricing is substantially landed, but the live billing path still prices by the request model

**Severity:** High

**Evidence:**

- Plan lines 111–113 make the coordinator-resolved `catalog_model_key` the sole
  price key, and line 151 classifies that invariant as “Substantially satisfied;
  verify.” Phases 5–6 describe preservation, deletion, and optional additive
  schema work, but define no concrete mutation that moves billing to the resolved
  key.
- On exact `origin/main`, `phase4-coordinator/internal/buyer/route_snapshot.go`
  builds `billing.RouteSnapshot.ModelID` from `provider.ModelID` (line 141).
  `applyBYOMRouteSnapshotBinding` adds
  `ModelAdmissionCatalogModelKey` as separate evidence, but does not replace the
  pricing model.
- On exact `origin/main`,
  `phase4-coordinator/internal/buyer/billing_recorder.go` constructs
  `HotPathInput.Model` from `row.Model` (line 414) and selects
  `RateEntry: billing.RateFor(..., row.Model)` (line 428).
  `phase4-coordinator/internal/billing/hotpath.go:hotPathRateEntry` repeats the
  lookup with `RateFor(in.RateCard, in.Model)` when a rate card is present.
- The immutable route snapshot does carry
  `ModelAdmissionCatalogModelKey`, so the trusted identity exists, but the money
  path does not consume it as the rate lookup key.
- Test T13 would expose this defect by placing attractive rates under alternate
  identifiers, but the implementation plan gives no ownership, data flow,
  compatibility rule, or migration for fixing the failure.

**Consequence:** A provider/runtime/request alias can select a different or
default rate from the coordinator-resolved catalog key. That breaks the mission's
“correctly priced and settled request” claim and permits a route that is strongly
bound for identity while billing under another identifier. A test that detects
the problem is not an executable implementation plan for correcting it.

**Required correction:** Revise the plan to classify authoritative pricing as
partial/missing on `1d2c930` and define a bounded money-path slice. It must derive
the billing model key from the accepted route binding, fail closed when a BYOM
route lacks or disagrees with that key, select and freeze the effective rate
before dispatch, and bind the exact key, rate, unit, version, multiplier, share,
and cap inputs into the immutable billing evidence used for settlement/replay.
Specify the non-BYOM compatibility path, request-log and billing-snapshot schema
impact, forward migration/backfill or explicit legacy handling, rollback, and
governance ownership under SPEC-005/SPEC-022/SPEC-047. T13 must prove both the
new BYOM path and unchanged legacy pricing.

### H2 — Positive-decision origin and dual control are properties of handlers, not enforced by the decision store that the plan calls authoritative

**Severity:** High

**Evidence:**

- Plan lines 103–109 and 162–165 say positive production decisions originate
  only in the authenticated operator path and assign pending/approval authority
  to `ModelAdmissionStore`. T09 requires direct store calls to be unable to append
  `catalog_priced` or `settlement_capable` outside the authenticated operator
  request/approval functions.
- On exact `origin/main`, memory
  `AppendModelAdmissionDecision` calls the generic
  `appendCoordinatorModelAdmissionEvent` directly
  (`phase4-coordinator/internal/ws/model_admission.go`, lines 267–269). The
  SQLite implementation does the equivalent at lines 692–694.
- The common memory append accepts trusted-catalog fields and a legal state edge;
  it does not possess or verify an authenticated operator capability. It rewrites
  the actor to `coordinator` unless the supplied string already starts with
  `operator:` (lines 377–419). The ordinary decision append does not require a
  pending record or approval capability for `settlement_capable`.
- Landed tests use that bypass as normal setup. For example,
  `phase4-coordinator/internal/ws/model_admission_test.go` lines 696–721 directly
  append `catalog_priced` and then `settlement_capable`; and
  `phase4-coordinator/internal/buyer/artifact_settlement_test.go` lines 56–94
  directly append both states through the public store interface.
- Phase 5 says to preserve the landed store/operator path and delete the dirty
  automatic authority path. It does not design the interface/capability change
  needed to make T09 true for memory, SQLite, production helpers, and tests.

**Consequence:** A future same-package production caller, accidental helper
reuse, or compromised coordinator-internal path can mint a paid admission state
without per-actor authentication or dual control. Static call-graph checks over
today's handlers do not establish the normative invariant, and the stated T09
acceptance is infeasible without a material API change.

**Required correction:** Define a store-enforced transition-origin design before
implementation. Positive decisions need an unforgeable typed capability or a
separate private API available only after the operator handler completes
authentication and evaluation; `settlement_capable` must additionally require
an atomically consumed pending approval capability. Offer, withdrawal, probe,
drift, and operator methods must expose only their closed target/reason sets.
Apply this to memory and SQLite stores, restart/replay/idempotency paths, and
production interfaces. Replace direct positive test setup with an explicit
test-only seeding fixture that cannot compile into production behavior, or drive
the real authenticated operator endpoints. Update SPEC governance if the
current public store contract changes, and reopen the architecture/lock gate for
the resulting interface change.

### H3 — The provider UX requires pending-approval and paid/settled states but defines no authoritative provider-visible read contract for either

**Severity:** High

**Evidence:**

- The provider journey (plan lines 59–71), Phase 4 (lines 314–320), and T08
  (test-spec lines 165–169) require distinct `pending second approval` and
  `paid/settled` view states.
- On exact `origin/main`, provider status is
  `GET /v1/provider/model-admission/status`. The handler reads only
  `LatestModelAdmissionStatus` and serializes the latest immutable event
  (`phase4-coordinator/internal/ws/model_admission.go`, lines 1836–1866).
- `modelAdmissionStatusResponseFromEvent` has the exact
  `model_admission_status.v1` fields and no pending-decision or request-settlement
  field (lines 2358–2374). Its unused boolean argument does not add state.
- SPEC-047 v0.1.5 deliberately keeps the exact `model_admission_status.v1` field
  set. A first `settlement_capable` operator decision records a pending decision
  and appends no event, so the provider endpoint continues to report the prior
  state. Pending details are exposed by operator-only decision responses and must
  not be inferred or handed to the provider.
- `settlement_capable` is admission eligibility, not proof that a specific
  request was paid. Per-request receipt/ledger state belongs to billing. The plan
  names no provider-scoped billing read model, endpoint, version, authentication,
  pagination, freshness, or join key that could truthfully render
  `paid/settled`.

**Consequence:** The implementation cannot satisfy the UX acceptance without
guessing from stale admission state, exposing an operator-only surface, or
conflating settlement eligibility with an actual settled request. Any of those
would violate the plan's own truthfulness and trust-boundary requirements.

**Required correction:** Define the exact authoritative provider-visible read
contracts before UI implementation. For pending approval, specify whether a
versioned provider capability/read model may expose only a sanitized boolean and
expiry, how it is authenticated and candidate-scoped, and how consumption,
invalidation, expiry, restart, and stale reads resolve without disclosing actor
or operator data. For paid/settled, identify a provider-scoped billing/receipt
activity source with request/attempt identity, terminal state, amount/unit,
freshness and pagination, and state explicitly that admission status alone never
proves payment. Define old-client behavior, endpoint/schema ownership,
observability, privacy bounds, and tests for delayed, duplicate, reversed,
failed, and missing settlement. If Build 1 is not meant to add that billing read
surface, remove the paid/settled UI outcome and acceptance claim rather than
fabricating it; the mission still requires the settled request to be proven in
the acceptance report.

### M1 — The R4 prerequisite inventory names nine nonexistent paths, so its freeze and replay gate is not reproducible

**Severity:** Medium

**Evidence:**

- The impact assessment's “R4 reservation slice” table names nine files under
  `phase3-binary/Sources/MacProviderCore/LocalModel...` and
  `phase3-binary/Tests/MacProviderCoreTests/LocalModel...`.
- None of those paths exists in the reviewed dirty worktree. The listed hashes
  instead match files under the executable target and its tests:
  `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift`,
  `ModelCatalogTransactionEvidence.swift`,
  `ModelCatalogTransactionMigration.swift`,
  `ModelCatalogTransactionReservationMigration.swift`,
  `ModelCatalogTransactionRetention.swift`,
  `ModelCatalogTransactions.swift`, and the three matching files under
  `phase3-binary/Tests/macprovider-cliTests/`.
- Plan Phase 2 refers only to “the nine frozen R4 reservation files” and T16
  requires exact approved R4 digests without restating an executable path/hash
  manifest. This makes the incorrect impact table the practical inventory.
- Additional transaction files (`ModelCatalogTransactionArchive.swift`,
  `ModelCatalogTransactionStorage.swift`, and fixture helpers) exist nearby, so
  an inaccurate boundary also risks omitting a material dependency.

**Consequence:** Phase 0 cannot prove that it froze the intended prerequisite,
the no-overlap check can report a false result, and later replay/audit may miss or
silently substitute files. T16 cannot establish that the approved R4 artifact is
the implementation being replayed.

**Required correction:** Correct the impact artifact and copy the exact canonical
R4 path/hash manifest into the revised plan/test specification. Include every
source and fixture file the approved R4 architecture owns, pin the exact R4
plan, test-spec, review, implementation commit/tree, and post-fix audit digests,
and make Phase 0/T16 fail on missing, additional, renamed, or hash-mismatched
files. Recompute dirty-tree overlap using the corrected paths.

### M2 — Successful preparation incorrectly allows unknown artifact size even though the trusted artifact feed requires a measured positive size

**Severity:** Medium

**Evidence:**

- Plan lines 45–50 and acceptance mapping line 354 permit “expected size or an
  explicit unavailable-size state” before a preparation mutation.
- T05 requires “expected bytes or explicit unknown size” for a successful primary
  MLX preparation, and T08 explicitly tests unknown-size confirmation.
- On exact `origin/main`, the signed artifact-feed validator rejects an artifact
  unless `size_bytes` is present and greater than zero
  (`phase4-coordinator/internal/buyer/catalog_artifacts_feed.go`, lines 254–270).
  The roadmap's supported preparation target is a verified primary artifact from
  that release-bound feed.
- The proposed free-space preflight and bounded reservation cannot be proven for
  an unknown-size actionable download without a separately specified hard quota
  and stream-abort contract.

**Consequence:** A browse-only/incomplete feed state can become an actionable
mutation, weakening signer/feed authority and disk-safety guarantees. The UI can
claim that size disclosure occurred while being unable to state the required
measured size.

**Required correction:** Make exact verified `size_bytes` mandatory for an
actionable Build 1 preparation, from both live and baked release-bound sources.
Unknown size may render a non-actionable browse/unavailable state only. Test
exact UI/CLI equality with the authenticated feed value, mismatched HTTP content
length, early and late stream overflow, reservation/quota/free-space accounting,
and no journal/staging/config mutation when size is absent or invalid.

### M3 — Retry acceptance conflates a fresh re-evaluation request with an exact idempotent replay

**Severity:** Medium

**Evidence:**

- T07 says an “idempotent retry uses fresh signature/timestamp/nonce.” T15 tests a
  protected tuple plus fresh replay material, but does not separately require an
  exact replay of the same retry envelope.
- SPEC-047 R002 v0.1.4 defines two distinct operations: an explicit bounded retry
  uses a fresh nonce/idempotency key and current timestamp while preserving the
  protected offer tuple; an exact replay returns the stored outcome without a
  duplicate probe or transition.
- The Swift CLI reflects the first operation: `ModelsAdmissionRetryCommand`
  calls `BYOMModelAdmissionRuntime.retryOffer`, which constructs fresh signed
  request material after validating the pending journal's protected tuple.
  Calling that operation “idempotent” leaves the server replay requirement and
  the client recovery behavior untested.

**Consequence:** Tests may accept duplicate probes/transitions for retransmission
of an identical envelope, or incorrectly expect a fresh request to replay an old
outcome. Crash/reconnect recovery can then violate nonce, idempotency, and CAS
semantics even though the happy-path retry passes.

**Required correction:** Split the test and plan terminology. Test (1) exact
transport replay of byte-identical signed retry material: same nonce,
idempotency key, digest, and signature, returning the stored result with no new
probe/event; and (2) a new bounded re-evaluation: fresh request identity,
timestamp, nonce, idempotency key, and signature over the exact protected offer
tuple, subject to current head/session/authority checks. Add crash points before
send, after coordinator persistence before response, and after local journal
update, plus concurrent identical and distinct-fresh retries.

### M4 — The active slice-5 dependency is checked only if it lands before replay, leaving a race through implementation and PR preparation

**Severity:** Medium

**Evidence:**

- The plan correctly records slice 5 as separate and unmerged, but lines 254–260
  require rebase only “if slice 5 lands before Build 1 source replay.” T18 uses
  the same “if slice 5 lands first” condition.
- Slice 5 already changes SPEC-047 and related intake governance on top of the
  reviewed base and has an untracked implementation directory. Build 1 Phase 6
  may also change SPEC-047, `CONFORMANCE.json`, and `specs/README.md`.
- There is no required fetch/base comparison after replay begins, before each
  governance edit, before complete-diff audits, or immediately before PR
  creation. A later slice-5 landing could therefore leave the Build 1 plan's
  exact base and semantic assumptions stale while ordinary text conflict
  resolution appears sufficient.

**Consequence:** Build 1 can overwrite or silently diverge from newly landed
intake contracts, run its final review against a stale base, or present a
misleading per-build diff. Governance generation can detect index drift but does
not prove preservation of the intake implementation's trust boundary.

**Required correction:** Add explicit origin checkpoints after Phase 0, before
every normative/governance slice, before complete-diff review, and immediately
before PR creation. If slice 5 or any relevant mainline change lands, stop source
work, rebase the fresh integration branch, regenerate the per-build and
cumulative diff manifests, independently inspect the landed semantics, rerun
affected tests, and reopen the plan gate for material contract/architecture/test
changes. If it remains unmerged, record its exact commit plus dirty manifest and
keep a clearly documented dependent branch/PR relationship without copying its
untracked work.

## Areas that are adequately bounded in this revision

The plan correctly keeps the dirty automatic positive-promotion path excluded,
preserves the landed release/provider lock ordering as a non-regression target,
keeps the automatic probe ceiling at `network_admitted_unsettled`, separates
local artifact preparation from coordinator authority, preserves historical
six-field settlement evidence, requires separate SwiftPM and Xcode evidence,
and leaves physical Mac/actual MLX/production qualification explicitly blocked
until fresh evidence exists. Those strengths do not offset the findings above.

## Gate disposition

This exact plan/test revision is **not approved**. No Critical finding was found,
but three High and four Medium findings remain. The next revision must correct
all seven without weakening acceptance criteria or reclassifying requested
outcomes, then undergo a new independent GPT-5.6 Sol review against its exact
digests and the then-current repository/base and active-work status.
