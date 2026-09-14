# Build 1 impact assessment: `origin/main` 1d2c930

Date: 2026-09-11

Reviewer: independent GPT-5.6 Sol lane

Scope: Product Build 1, Self-Service Model Supply

Disposition: code-grounded reconciliation assessment; no source or test edits

## Revisions and evidence boundary

This assessment compares three distinct states:

| State | Revision / tree | Meaning |
|---|---|---|
| Historical Build 1 worktree base | `914f7cafcdbcfc1805a10f4f34167218341d5587` | Base of `/Users/augstar/.codex/worktrees/macprovider/product-build-1` |
| Newly landed `origin/main` | `1d2c930bad81704dd0acc0322226725d8b64aceb` | Squash merge of PR #1470, BYOM v0.2 slice 4 |
| Parent of newly landed commit | `c9445561e4fe00a073926ff2ab0fdb0536d00e37` | Previous `origin/main` observed by the Build 1 reconciliation plan |
| `origin/main` tree | `39270b08dee665a298e3a67580b127d9368e0f65` | Exact source tree inspected for newly landed behavior |
| Active Build 1 working tree | branch `codex/product-build-1`, HEAD `914f7cafcdbcfc1805a10f4f34167218341d5587`, dirty | Uncommitted feed, preparation, app/CLI, coordinator, and reservation work under review |

The source roadmap was present at `/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md`. Its baseline commit, `422fc2f13fc62c1ff8987522f822d9ef856e4a96`, remains historical evidence only. Repository `AGENTS.md`, `CLAUDE.md`, `SPEC-010`, `SPEC-047`, governance indexes, changed source, and relevant tests were inspected. No `d-inference` source was inspected.

Commit `1d2c930` changes 55 paths relative to `c944556`, with 6,368 insertions and 291 deletions. The active Build 1 worktree has 54 modified tracked paths and 281 untracked paths. Thirteen tracked paths overlap the new `c944556..1d2c930` delta; seventeen overlap the full `914f7ca..1d2c930` delta. No currently untracked Build 1 path collides by exact pathname with a file in the `1d2c930` tree.

## Executive verdict

PR #1470 lands a substantial coordinator-side authority and decision slice. It introduces catalog and artifact-set binding, release-generation state, provider-session binding, operator decision endpoints, compare-and-set decision persistence, pending dual-control approvals, release sweeps, and route-snapshot guards. It does not complete Build 1 as a self-service product.

Provider-side signed-feed consumption, trusted artifact preparation, cancellation-safe adoption, and executable preparation/switch UX remain absent from `origin/main`; corresponding implementations exist only in the dirty Build 1 worktree and are not yet accepted. Automatic synthetic probes still deliberately stop at `network_admitted_unsettled`. The newly landed positive admission path is operator-origin and requires dual control for `settlement_capable`; the dirty Build 1 automatic promotion path conflicts with that contract and cannot be replayed unchanged.

The prior c944 reconciliation plan is stale as execution authorization. Its safety invariants remain useful, but its base, lock graph, release publication assumptions, normative version, production caller assumptions, and test inventory have changed materially. The architecture and adversarial plan gates must reopen before any source-level integration.

## Roadmap outcome classification on `origin/main` 1d2c930

| Requested outcome | Classification | Evidence and consequence |
|---|---|---|
| Provider discovers an appropriate model and sees economics/readiness | **Partial** | Existing discovery, offer, status, and withdrawal surfaces remain. `ModelCatalogEconomics.makeCatalogOnlyRow` still makes `switchAction` and `prepare` unavailable with `no_cli_transaction_available`, so the provider cannot complete the journey from the shipped CLI/app. |
| Verified feed consumption with signer, release, freshness, and baked fallback | **Missing on `origin/main`** | PR #1470 publishes and binds coordinator artifact identity sets, but it does not add the provider CLI feed-consumption transaction. The dirty Build 1 worktree contains unmerged work for this outcome. |
| Trusted artifact preparation with size disclosure, staging, integrity, cancellation, and adoption | **Missing on `origin/main`; partial and unaccepted in dirty Build 1** | No landed executable preparation transaction closes this journey. The dirty worktree adds preparation/store/UI work, but its material changes and reservation-related review findings remain unresolved. Preparation assertions alone cannot authorize paid admission. |
| Authoritative model identity and catalog pricing | **Substantially landed coordinator slice; product outcome partial** | `release_snapshot.go`, `model_admission_binding.go`, `model_admission_operator.go`, artifact identity sets, and catalog-member bindings establish coordinator-derived catalog identity. However, SPEC-047 remains draft/partial/not-deployed, provider-facing self-service is absent, and signed end-to-end evidence is missing. |
| Settlement-capable admission | **Partial and deliberately operator-gated** | Operator decisions, CAS persistence, pending approvals, and dual control for `settlement_capable` landed. Automatic probes in `ws/server.go` still call `runModelAdmissionSyntheticProbe(..., "network_admitted_unsettled", false)`. A physical settled journey has not been proven. |
| Executable provider UX with truthful readiness and economics states | **Partial** | Status/offer/withdraw commands exist, but preparation and switch remain unavailable on `origin/main`. The new runbook explicitly states the operator decision surface is not provider-facing. Dirty UI/CLI changes need reconciliation and fresh acceptance. |
| Correctly priced and settled request from a physical Mac | **Blocked / unproven** | No fresh physical signed-feed → preparation → real MLX inference → admission → immutable pricing/settlement acceptance run exists. Package tests cannot prove this outcome. |
| Corrupt artifact, cross-release feed, stale signature, cancellation preservation, rate/model drift, unsupported/non-primary model negative paths | **Partial test coverage; Build 1 acceptance unproven** | PR #1470 adds catalog/release/binding/operator tests, while dirty Build 1 adds feed/preparation/evidence tests. The combined behavior has not been reconciled, run, or audited from a single reviewable diff. |

## Newly landed implementation and exact symbols

### Release and identity publication

- `phase4-coordinator/internal/ws/release_snapshot.go`
  - Adds `releaseSnapshotState`, a release read/write lock, release generations, and staged catalog, Tier2, and artifact-identity sets.
  - Establishes a new lock and publication boundary that reconciliation must preserve.
- `phase4-coordinator/internal/buyer/autotune_feeds.go`
  - Adds `BuildArtifactIdentitySets` and previous-release loading.
  - Changes feed observation to publish a coherent `(feeds, commit)` state.
- `phase4-coordinator/internal/tier2/catalog.go`
  - Adds release publisher/staging integration.
- `phase4-coordinator/internal/artifactidentity/index.go`
  - Adds member-level allowed runtime-source data.
- `phase4-coordinator/internal/autotune/catalog.go`
  - Adds `Keys` and `NormalizeModelID` helpers.
- `phase4-coordinator/cmd/coordinator/main.go`
  - Wires per-release artifact identity sets, release staging/publication, the feed observer, and the buyer route guard.

### Provider binding and admission lifecycle

- `phase4-coordinator/internal/ws/model_admission_binding.go`
  - Adds `providerSections`, `withProviderSection`, binding generations, `matchModelAdmissionOffer`, `applyModelAdmissionOfferCatalogMatch`, `evaluateCatalogPreconditionsLocked`, provider-session binding lifecycle/drift handling, and release sweeps.
- `phase4-coordinator/internal/pool/provider.go`
  - Adds `ModelAdmissionBinding`, provider session epochs, and `SetModelAdmissionBinding`.
- `phase4-coordinator/internal/ws/model_admission.go`
  - Extends `ModelAdmissionEvent` with catalog match/reason, row/release/member set and member values, bound runtime source, and evaluated release generation.
  - Extends `ModelAdmissionStore` with compare-and-set, listing/sweep, and pending-decision behavior, including SQLite persistence/migrations.
- `phase4-coordinator/internal/ws/model_admission_pending.go`
  - Adds memory and SQLite pending-decision persistence.

### Operator decisions and immutable routing

- `phase4-coordinator/internal/ws/model_admission_operator.go`
  - Adds `handleAdminModelAdmissionDecisions`, `handleAdminModelAdmissionApprove`, and `handleAdminModelAdmissionOffers`.
  - Adds `applyModelAdmissionDecisionLocked`, `evaluateModelAdmissionDecisionLocked`, pending dual-control handling, `bindDecisionToCatalogLocked`, and `CompareAndInsertModelAdmissionRouteSnapshot`.
- `phase4-coordinator/internal/buyer/model_admission.go`
  - Adds `ModelAdmissionRouteGuard` and route eligibility based on coordinator-derived binding plus exact catalog event/member content.
- `phase4-coordinator/internal/buyer/route_snapshot.go`
  - Routes inserts through the model-admission route guard.
- `phase4-coordinator/internal/buyer/server.go`
  - Adds `WithModelAdmissionRouteGuard`.
- `phase4-coordinator/internal/ws/admin_endpoints.go`
  - Registers the operator decision endpoints.

### Normative and operational changes

- `specs/SPEC-047-network-model-admission.md`
  - Advances to version 0.1.5, still `draft`, `implementation_status: partial`, `production_status: not-deployed`.
  - Defines the operator endpoint as the production-origin caller for positive decisions and requires dual control for `settlement_capable`.
- `specs/SPEC-010-model-catalog.md`
  - Advances to version 1.8 and clarifies R004 composite-proof behavior.
- `specs/CONFORMANCE.json` and `specs/README.md`
  - Map new R001/R003/R006/R008 coverage.
- `docs/runbooks/byom-admission-decisions.md`
  - Documents operator decision operation and explicitly states that the surface is not provider-facing.

The conformance mappings point to new tests, but the corresponding evidence arrays remain empty. SPEC-047 section 6 also continues to state that there is no implementation or production evidence. This is an evidence-status inconsistency to reconcile; it is not a basis for claiming production acceptance.

## Dirty Build 1 overlap and conflict analysis

### Direct textual conflicts against `914f7ca`

A three-way `git merge-file` simulation using the historical Build 1 base found conflicts in ten paths:

| Path | Conflict regions | Principal collision |
|---|---:|---|
| `phase4-coordinator/cmd/coordinator/main.go` | 1 | Upstream release/route-guard wiring versus dirty authority/transport wiring |
| `phase4-coordinator/internal/buyer/autotune_feeds.go` | 1 | Upstream coherent feed/commit observer and identity sets versus dirty generation/authority publication |
| `phase4-coordinator/internal/buyer/model_admission.go` | 2 | Upstream route guard and bound members versus dirty authority evaluation |
| `phase4-coordinator/internal/buyer/server.go` | 2 | Upstream route-guard option versus dirty availability, close, and generation fields |
| `phase4-coordinator/internal/pool/provider.go` | 1 | Upstream session epoch/binding versus dirty admission state additions |
| `phase4-coordinator/internal/ws/model_admission.go` | 16 | Event/store/SQLite schema collision: upstream binding, CAS, pending decisions versus dirty offer identity, evidence, and retry fields |
| `phase4-coordinator/internal/ws/server.go` | 1 | Upstream release/provider lock state and unsettled probe path versus dirty authority state |
| `specs/CONFORMANCE.json` | 3 | New slice-4 requirement mappings versus dirty Build 1 selectors |
| `specs/README.md` | 1 | Normative index/version collision |
| `specs/SPEC-047-network-model-admission.md` | 4 | Upstream operator/dual-control contract versus dirty successor contract text |

Three overlapping paths merge textually without conflict but still need semantic review:

- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/tier2/catalog.go`
- `phase4-coordinator/internal/ws/admin_endpoints.go`

The full `914f7ca..1d2c930` overlap also includes:

- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift`
- `phase3-binary/Tests/MacProviderCoreTests/BYOMAdmissionTests.swift`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/settlement_receipts.go`

Textual mergeability does not establish semantic compatibility for those files.

### Architectural conflict that must not be auto-resolved

The dirty worktree adds `ws/model_admission_authority.go`, `ws/model_admission_commit.go`, buyer admission-authority/guard files, and an automatic `promoteModelAdmission` flow that advances:

`network_admitted_unsettled` → `catalog_priced` → `settlement_capable`

with coordinator actor/reason `primary_artifact_authority_verified`.

That flow conflicts with the newly landed SPEC-047 v0.1.5 contract. Under 1d2c930, positive production transitions originate from the operator decision endpoint, and `settlement_capable` requires dual control. The local automatic promotion implementation must not be ported as another positive-state caller or used to bypass pending approval. Local evidence may feed validation of an upstream operator decision, but cannot itself mint the paid state.

The two implementations also use different concurrency and identity models:

- Dirty Build 1: separate `modelAdmissionAuthorityMu`, `SetModelAdmissionAuthority`, `PreparedModelAdmissionAuthority`, guarded append, feed/billing generations, transport availability and close hooks.
- Landed 1d2c930: `releaseSnapshotState.mu`, per-provider sections, binding generation, provider session epoch, release sweeps, operator decision CAS/pending state, and guarded route snapshot insertion.

The lock graph, snapshot ownership, and lifecycle boundaries therefore require a fresh architecture review before code integration.

## R4 reservation slice

The newly landed commit touches none of the nine frozen R4 reservation source/test files. Their current SHA-256 hashes are:

| File | SHA-256 |
|---|---|
| `phase3-binary/Sources/MacProviderCore/LocalModelBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `phase3-binary/Sources/MacProviderCore/LocalModelEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `phase3-binary/Sources/MacProviderCore/LocalModelEvidenceMigration.swift` | `5bc526e395b048c9d1c41cede30d7430321da83395d2a9a02590e35ecfa4b4df` |
| `phase3-binary/Sources/MacProviderCore/LocalModelEvidenceReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `phase3-binary/Sources/MacProviderCore/LocalModelEvidenceRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `phase3-binary/Sources/MacProviderCore/LocalModelEvidenceTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |
| `phase3-binary/Tests/MacProviderCoreTests/LocalModelEvidenceReservationMigrationTests.swift` | `a0c700eb26cce0938d6dcf973f2dea1eacd8194de2a368ad1fb2270611aa2c35` |
| `phase3-binary/Tests/MacProviderCoreTests/LocalModelEvidenceRetentionTests.swift` | `bf45cf3a914b377d61ecd10b9013467784acf4a9f234fee01e1f5ebd0c7d55cb` |
| `phase3-binary/Tests/MacProviderCoreTests/LocalModelEvidenceTransactionsTests.swift` | `009611a1f01fb26dc695ae588abb7e401d1b4cf93c90d6e3fa21249bf6144121` |

This absence of path overlap permits independent planning, but it does not approve the R4 implementation. Its prior Sol audit rounds contain unresolved High/Medium findings, and the corrective R10 plan remains a prerequisite to source fixes. The observed 79 targeted test passes are regression evidence only; they cannot be promoted to Build 1 acceptance while those findings remain open.

## Status of the prior c944 reconciliation plan

The prior approved artifacts were:

- Plan revision 6 SHA-256: `a4b03061e95fe78ec68ad4a02d2aba4a50ae9a364f953e6c0c57af4c9dd3890a`
- Test specification revision 10 SHA-256: `3225b7d5db321d936fb8326df392533d735fdb4f8fd29368c530c0c96ebe45b9`
- Review record revision 6 SHA-256: `79aa5eddbf47e84f19c2232d0b2af5319798bd3e89e6deab94ccc47c2f2bdc24`

Those artifacts are no longer valid as implementation authorization because:

1. They explicitly excluded the then-unlanded slice 4; slice 4 is now `origin/main`.
2. They target SPEC-047 after version 0.1.4; main is now version 0.1.5, and a separate active slice-5 worktree has uncommitted version-0.1.6 intake-contract edits.
3. Their lock-order analysis predates the release RW lock, per-provider section, binding generation, and provider session epoch.
4. They propose a new combined catalog/index publisher and token to repair split setters; 1d2c930 now provides `PublishArtifactIdentitySetsWith` and release staging, changing the prerequisite and call graph.
5. They contemplate direct positive state setting from the preparer path; the new normative contract restricts positive production transitions to the operator path and requires dual control for settlement capability.
6. They do not cover new decision CAS, pending approval, binding-generation/session-epoch drift, release sweeps, exact operator error precedence, or upstream R001/R003/R006/R008 tests.

The following prior invariants remain valuable inputs to the replacement plan:

- Preserve immutable historical-event interpretation for the earlier six-field representation.
- Enforce strict v2 schema validation and safe integer handling if a v2 evidence schema remains necessary.
- Never make immutable settlement consult mutable live authority.
- Bind pricing to exact authoritative model/artifact identity.
- Bind retry authorization to exact GGUF file identity.
- Create a recovery checkpoint before replaying the dirty tree.
- Keep the physical Mac end-to-end acceptance blocker explicit.

The proposed 24-field `artifact_admission.v2` shape must be reassessed against 1d2c930's operator decision event and immutable route/billing snapshots. It may still carry necessary preparation evidence, but it must not duplicate authority already assigned to the landed binding and decision contracts.

## Gates that must reopen

The following gates are reopened by the new mainline architecture and normative changes:

1. **Code-grounded PRD and test-spec gate.** Produce a new revision from exact `origin/main` 1d2c930 plus frozen dirty-tree hashes. Map every c944 invariant to one of: satisfied by 1d2c930, still required, superseded, or invalid.
2. **Normative contract gate.** Adopt SPEC-047 v0.1.5 operator-origin and dual-control requirements. Coordinate with the separate slice-5 intake work before choosing a successor version; do not overwrite or silently claim its uncommitted 0.1.6 state.
3. **Architecture and concurrency gate.** Define one owner for release/catalog/artifact snapshots, provider-section locking, session epochs, decision CAS/pending state, route guards, preparation evidence, and any billing/feed generations. Prove lock ordering and failure recovery.
4. **Adversarial plan gate.** A fresh independent GPT-5.6 Sol verifier must inspect the exact replacement plan and test specification and report zero Critical, High, and Medium findings before source reconciliation begins.
5. **R4 corrective gate.** Finish and approve the R4 corrective plan before changing its frozen source/test set.
6. **Combined-diff audit gate.** After implementation, run independent GPT-5.6 Sol code, security, and architecture reviews over the complete rebased diff until all Critical, High, and Medium findings are resolved.
7. **Acceptance and qualification gate.** Run targeted and broad software checks, then separately record physical-hardware, real-MLX, release-signing, deployed-service, and production qualification evidence. None may be inferred from unit/package tests.

## Safe integration order

1. Freeze Build 1 source and test writers. Documentation-only reconciliation may continue.
2. Record `1d2c930` as landed and mark the c944 plan/test authorization stale.
3. Write the replacement PRD/test specification using exact main and frozen dirty-tree hashes. Include upstream operator/dual-control semantics, route guards, release/provider lock graph, new upstream tests, and every original Build 1 outcome and negative case.
4. Pass the independent GPT-5.6 Sol adversarial plan gate at zero Critical, High, and Medium findings.
5. Create a recovery checkpoint, bundle, and private manifest for the frozen dirty tree. Then create a fresh hidden worktree from `origin/main` 1d2c930; do not rebase in place and do not cherry-pick the old slice-4 branch.
6. Reconcile in bounded slices:
   1. Preserve the landed 1d2c930 specifications, release publisher, operator decisions, CAS/pending approvals, provider bindings, route guards, and upstream tests.
   2. Replay provider-side Swift feed consumption, trusted preparation, cancellation-safe adoption, and truthful UI/CLI work where it does not weaken the landed authority boundary.
   3. Retain the nine R4 reservation files only after their corrective gate passes; they have no direct 1d2c930 path conflict.
   4. Merge event and SQLite schemas deliberately, preserving upstream catalog members, pending/CAS state, and lifecycle sweeps. Add local evidence/retry fields only where the replacement contract proves their authority and compatibility.
   5. Replace local automatic positive promotion with evidence supplied to the landed operator-decision and immutable route-snapshot path. No preparation/provider assertion may mint `catalog_priced` or `settlement_capable`.
   6. Unify publication and locking around `releaseSnapshotState`, provider sections, binding generation, session epoch, and route guard. Retain local feed/billing generations only if the new architecture demonstrates a necessary immutable pin without lock cycles.
   7. Reconcile SPEC/governance at the correct successor version after checking slice-5 status. Include upstream R001/R003/R006/R008 selectors and Build 1 feed, preparation, drift, evidence, recovery, and settlement-negative selectors.
7. Run the newly landed race-test baseline, Build 1 targeted tests, broader Swift/Go/integration/dist checks appropriate to the combined surface, and the three independent Sol audit lanes.
8. Keep physical signed-feed → real MLX → settled-request acceptance open until executed on suitable hardware and services. Do not enable production enforcement or economic activation.

## Relevant active work

- `/Users/augstar/macprovider-byom-v02-slice4`, branch head `edd935d6`, is clean and its history is represented by squash commit `1d2c930`. It must not be cherry-picked into the replacement branch.
- `/Users/augstar/macprovider-byom-v02-slice5`, branch `feat/byom-v02-slice5-intake-pipeline`, is based at `1d2c930` and currently has dirty specification-only changes for an `/admin/model-admission/intake` contract, including proposed SPEC-047 version 0.1.6 changes. No commit or PR was observed. Build 1 must document an explicit dependency or choose a later compatible normative revision if that work lands; it must not duplicate or overwrite the intake contract.

## Fresh verification evidence

The following command ran against canonical `origin/main` at `1d2c930`:

```text
cd /Users/augstar/macprovider-poc/phase4-coordinator && \
  go test -race ./internal/artifactidentity ./internal/tier2 ./internal/pool ./internal/buyer ./internal/ws
```

Result: exit 0.

```text
ok  github.com/malibu/malibu-provider/phase4-coordinator/internal/artifactidentity  1.704s
ok  github.com/malibu/malibu-provider/phase4-coordinator/internal/tier2             2.035s
ok  github.com/malibu/malibu-provider/phase4-coordinator/internal/pool              2.438s
ok  github.com/malibu/malibu-provider/phase4-coordinator/internal/buyer            46.674s
ok  github.com/malibu/malibu-provider/phase4-coordinator/internal/ws               54.042s
```

This proves the selected newly landed coordinator packages pass their fresh race-enabled regression suites. It does not prove the dirty Build 1 diff, Swift CLI/app, physical artifact preparation, actual MLX inference, release assets, deployment, pricing settlement, or production qualification.

## Required status after this assessment

- **Landed before this reconciliation:** PR #1470 coordinator catalog binding, operator decisions, dual-control settlement transition, release/provider binding lifecycle, route guard, and related tests.
- **Implemented only in the dirty Build 1 worktree:** provider signed-feed consumption, preparation/adoption/UX work, additional admission evidence/authority work, and R4 reservation work. None is accepted or safely rebased yet.
- **Locally verified:** selected `origin/main` coordinator packages only, as listed above.
- **Blocked or unproven:** combined Build 1 implementation, physical Mac preparation, real MLX inference, correctly settled request, release-signing journey, deployment, and production qualification.
- **Explicit non-goals:** production enforcement, reward/payout activation, operator-secret changes, deployment, release publication, merge, and hardware procurement.
