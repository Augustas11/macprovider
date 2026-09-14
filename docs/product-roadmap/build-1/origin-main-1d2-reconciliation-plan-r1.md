# Build 1 reconciliation PRD and implementation plan — origin/main 1d2 r1

Status: **PROPOSED; not implementation authorization**. Source reconciliation is
prohibited until an independent GPT-5.6 Sol adversarial review of this exact
revision and its paired test specification reports zero Critical, High, and
Medium findings.

Date: 2026-09-11

Scope: Product Build 1 — Self-Service Model Supply

Repository/base revision: `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`, tree
`39270b08dee665a298e3a67580b127d9368e0f65`

Frozen source worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`,
branch `codex/product-build-1`, HEAD
`914f7cafcdbcfc1805a10f4f34167218341d5587`, dirty and two commits behind
`origin/main` when this plan was written.

Primary current-state assessment: `origin-main-1d2-impact-sol.md`, SHA-256
`8541a4e495b90d047da1cbe8e049f79a3fcd28810368e6a7f4944739ba75c745`.
The historical roadmap was available at
`/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md`; its
baseline `422fc2f13fc62c1ff8987522f822d9ef856e4a96` is context, not current
implementation evidence. No `d-inference` source was inspected.

This plan replaces the c944 reconciliation authorization. The useful c944
invariants are carried forward explicitly below; the c944 plan's base,
positive-promotion design, lock graph, and proposed evidence envelope are
superseded by the architecture landed in PR #1470.

## Product outcome and truthful journeys

Build 1 lets a provider use shipped CLI and Malibu.app actions to discover a
supported model, understand the trusted artifact source and download size,
prepare one supported primary MLX artifact, cancel without disturbing the
serving model, adopt the verified artifact explicitly, submit and inspect a
signed admission offer, and eventually serve a correctly priced and settled
request after the coordinator's existing operator-origin admission workflow
has completed.

The provider journey has these truthful states:

1. **Discover.** The provider sees the signed catalog target, artifact identity,
   runtime/profile fit, expected size or an explicit unavailable-size state,
   and catalog economics. Catalog economics are labeled separately from the
   provider's current paid-admission state.
2. **Prepare.** The provider confirms the exact target, size/trust disclosure,
   and long-running operation. The CLI downloads into owned staging, verifies
   the full artifact, and publishes only verified durable content.
3. **Cancel or recover.** Cancellation before publication removes only owned
   staging and preserves the incumbent. Cancellation after the commit point
   reports `too_late` and reconciles durable truth. Restart resumes status and
   cleanup from the transaction journal without inventing success.
4. **Adopt.** Explicit activation revalidates the prepared target and uses the
   existing lock/journal/runtime rollback protocol. Preparation alone never
   changes the serving model.
5. **Offer and wait.** The provider signs an offer and can query typed status.
   The automatic synthetic probe remains bounded at
   `network_admitted_unsettled`. The UI reports operator review, catalog-priced,
   pending second approval, settlement-capable, revoked, expired, or blocked as
   separate states.
6. **Operator decision.** The authenticated operator endpoint landed at
   `1d2c930` remains the only production origin of positive coordinator
   decisions. A transition to `settlement_capable` requires the landed distinct
   second actor and pending-decision flow.
7. **Serve and settle.** A buyer route must pass the landed immutable route
   guard. The receipt settles once against the captured model member and price.
   The provider UI does not report a paid-ready outcome until authoritative
   status readback proves it.

The physical acceptance journey includes the provider actions, two operator
decision actions, an actual MLX request on a physical Mac, receipt persistence,
and settlement accounting. The operator actions are an explicit trust boundary,
not hidden automation or a provider-facing self-approval.

## Current implementation inventory and roadmap mapping

| Roadmap outcome | State at `1d2c930` | Code evidence | Planned disposition and proof |
|---|---|---|---|
| Signed artifact-feed production and distribution | Landed | `phase4-coordinator/internal/buyer/catalog_artifacts_feed.go`, `autotune_feeds.go`; release scripts/runbook | Preserve. Re-run producer/server/release conformance and negative feed tests. |
| Provider feed verification | Parser/binding foundation landed at the historical worktree base; executable transaction integration remains missing on main | `phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift`, `AutotuneRecommend.swift`, `BYOMDiscovery.swift` | Reconcile the dirty command/app consumption only after the gate. Require signer, candidate release, freshness, exact member identity, and safe compiled fallback checks before artifact action. |
| Trusted artifact preparation | Missing on main; implemented but unaccepted in dirty worktree | `DurableModelArtifactStore.swift`, `ModelsSubcommand.swift`, `ModelCatalogTransactions.swift`, transaction/storage helpers | Replay after R4 correction approval. One primary MLX target, disclosed size, isolated staging, no-follow/containment, full integrity check, cancellation, atomic publication, restart reconciliation. |
| Durable discovery and adoption | Foundation landed; dirty bridge is unaccepted | `DurableModelArtifactStore`, `DurableModelDiscovery`, `RecommendationAdoptionJournal`, existing adoption command/runtime control | Preserve stable target identity, revalidate before adoption, no hidden download, incumbent rollback. |
| Coordinator model/artifact identity | Substantially landed | `artifactidentity.Index`, `BuildArtifactIdentitySets`, `releaseSnapshotState`, `matchModelAdmissionOffer`, `evaluateCatalogPreconditionsLocked` | Preserve as authority. Delete/supersede parallel dirty authority resolution and generation ownership. |
| Positive admission and dual control | Landed operator path; automatic probe intentionally unsettled | `handleAdminModelAdmissionDecisions`, `handleAdminModelAdmissionApprove`, `CASAppendModelAdmissionDecision`, `runModelAdmissionSyntheticProbe` | Preserve operator-only origin and distinct second actor. Dirty `promoteModelAdmission` positive edges must not be ported. |
| Immutable route and settlement evidence | Landed for release-bound primary and feed members | `ModelAdmissionRouteGuard`, `CompareAndInsertModelAdmissionRouteSnapshot`, `requireBYOMRouteSnapshotBinding`, `applyBYOMRouteSnapshotBinding` | Reuse the landed six-value artifact binding and exact model-key price owner. Do not add the obsolete 24-field authority envelope. Add compatibility/tamper/replay proof. |
| Executable provider UX | Partial on main; dirty app/CLI implementation unaccepted | `ModelCatalogEconomics.makeCatalogOnlyRow`, `ModelsSubcommand`, Malibu `ModelManagement` and `RecommendationManagement` | Wire capability-negotiated actions and typed statuses. Prepared, active, admitted, priced, and settled remain separate. |
| Physical prepared-to-settled request | Unproven | No fresh combined signed-feed/physical-MLX/settlement record | Keep open until executed. Local fixtures and package tests do not satisfy it. |

## Normative contracts

The implementation must preserve `SPEC-010` v1.8 and `SPEC-047` v0.1.5 as
landed at `1d2c930` unless a narrowly scoped, separately governed successor is
required. It also obeys `SPEC-023` artifact feed/release authority, `SPEC-044`
provider economics/action truthfulness, `SPEC-022` route/receipt settlement,
`SPEC-005` pricing, `SPEC-011` warm swap, and the existing SPEC-001/provider
wire and BUILD_SPEC_953 adoption contracts.

The following clauses are normative for this reconciliation:

1. A provider assertion, prepared file, local benchmark, successful probe, or
   signed offer cannot create `catalog_priced` or `settlement_capable`.
2. Positive production transitions originate only at the landed authenticated
   operator decision endpoint. `settlement_capable` is created only after a
   distinct authorized actor consumes an unexpired pending decision whose head,
   release, session, member, receipt key, and catalog preconditions are freshly
   re-evaluated.
3. Synthetic probing continues to stop at `network_admitted_unsettled`.
4. The coordinator resolves model identity from the signed catalog/artifact set;
   the resolved `catalog_model_key` is the price key. Model ID, artifact ID,
   provider-asserted key, or local path is never substituted for price authority.
5. The release's candidate row and exact artifact member form the identity
   proof defined by SPEC-010 R004/R007. A primary MLX preparation action is the
   supported Build 1 provider transaction; coordinator support for already
   landed non-primary members remains intact but is not broadened by this slice.
6. New dispatch uses live release/provider/decision checks. Once a route and
   billing snapshot are inserted, delayed receipt settlement and replay use the
   immutable snapshots and do not consult mutable current feed, keyring, catalog,
   session, or rate data.
7. The c944 six-field artifact route extension remains byte-for-byte compatible,
   including `artifact_candidate_catalog_sha256`. Existing rows and digests are
   never rewritten. The proposed dirty `macprovider.artifact_admission.v2`
   24-field envelope is superseded: landed decision, binding, route, and billing
   records own those facts. Any later schema extension requires a new SPEC gate.
8. The private GGUF retry journal remains local-only. A retry is authorized only
   by reopening the same no-follow file and matching complete file identity,
   locator, size/timestamps, and recomputed digest; none of those local details
   may enter provider wire bytes or logs. This compatibility work cannot mint a
   paid state and is independent of the primary-MLX preparation journey.
9. Feed failure is fail closed for new preparation. A baked fallback is usable
   only when its compiled signer/release/freshness contract is valid for the
   target action; a nil, stale, cross-release, corrupt, or unverifiable fallback
   means the action is unavailable. It never becomes current network authority.
10. Transaction status is durable truth. UI state, progress events, and provider
    claims are projections and cannot substitute for the journal, durable store,
    coordinator event head, or route/billing snapshot.

## Disposition of the c944 reconciliation invariants

| Prior invariant | 1d2 disposition |
|---|---|
| Historical exact six-field decoding and digest | **Still required.** Landed route binding is retained and golden/restart tests are mandatory. |
| New exact 24-field v2 authority envelope | **Superseded.** Do not implement. It duplicates the landed operator event, session binding, release generation, and billing snapshot owners. |
| Strict raw JSON/null/duplicate/numeric parsing for that v2 envelope | **Superseded with the envelope.** Existing closed schemas retain their own strict tests; no dead decoder is added. |
| JCS-safe `2^53-1` common ceiling for that envelope | **Superseded with the envelope.** Existing wire fields continue under their governing schema bounds. |
| Combined WS catalog/index publication token proposed for c944 | **Superseded.** Use landed `releaseSnapshotState`, staging, `publishRelease`, and `PublishArtifactIdentitySetsWith`; do not add a parallel publisher. |
| SQLite-first c944 automatic-promotion phases | **Invalid under v0.1.5.** Remove the automatic positive promotion path. The landed operator CAS/pending store is authoritative. |
| Immutable settlement does not consult mutable authority | **Preserved and still required.** New route is live-guarded; already inserted snapshots settle from captured state. |
| Exact coordinator-resolved model key owns price | **Substantially satisfied; verify.** Preserve route/billing resolution and add malicious alternate-key tests. |
| GGUF retry bound to complete local file identity | **Still required.** Reconcile only the local retry safety behavior, never positive admission authority. |
| Frozen-tree recovery checkpoint before replay | **Still required.** No in-place rebase of the dirty worktree. |
| Physical signed-feed → MLX → settlement evidence | **Still blocked/unproven.** It remains a qualification criterion. |

## Ownership and dependency graph

| Owner | Authoritative state and mutation boundary |
|---|---|
| Release owner (`ws.releaseSnapshotState`) | Current/compatible catalogs, per-release artifact identity sets, staged Tier2 publication, `feedIntegrityFailed`, and monotonic release generation. Publication is one release write transaction. |
| Catalog subowner (`Server.autotuneCatalogMu`) | Pointer pair for current and compatible catalog, used only inside the release publication/read protocol. It is not a second release generation. |
| Provider owner (`ws.providerSection`) | Per-provider append/binding serialization and binding generation. Every admission append origin enters the same section; same-provider nesting is forbidden. |
| Live-session owner (`pool`) | Provider registry, assigned session, `ModelAdmissionSessionEpoch`, runtime identity, receipt key, and installed admission binding. |
| Decision owner (`ModelAdmissionStore`) | Immutable event head, request idempotency, CAS append, pending decision, approval consumption, expiry, and release-sweep revocations. |
| Route owner (`ModelAdmissionRouteGuard` / WS compare-and-insert) | Pre-dispatch expectation over candidate event, binding generation, session epoch, and validated release generation. |
| Settlement evidence owner (`billing.Store`) | Immutable route snapshot, billing snapshot, price, digest, receipt deduplication, debit/credit, and replay outcome. |
| Provider artifact owner (`DurableModelArtifactStore` plus CLI transaction journal) | Owned staging, verified durable bytes, active/prepared references, transaction outcome and cleanup. This local state is never coordinator admission authority. |
| UI projection owner (CLI JSON/JSONL and Malibu model-management view model) | Typed rendering and executable action dispatch only; no trust or economic inference beyond authoritative inputs. |

Dependency flow:

`signed release feeds` → `releaseSnapshotState` → `signed provider offer` →
`offer-time catalog/member match` → `unsettled probe` → `operator decision CAS`
→ `distinct approval` → `session binding` → `route expectation` → `immutable
route + billing snapshots` → `provider receipt` → `single settlement`.

The local preparation flow is deliberately separate:

`verified feed target` → `owned staging` → `full digest/manifest verification`
→ `atomic durable publication` → `explicit adoption` → `signed offer`.

Only the signed offer crosses from local preparation into coordinator admission.

## Lock and lifecycle graph

The reconciliation adds no parallel coordinator authority mutex or generation.
It preserves and tests the landed order:

1. **Decision/append path:** provider section → pool registry read → release read
   lock → decision-store read/CAS or pending mutation. Release read is released
   before `afterModelAdmissionAppendLocked` refreshes the binding. The same
   provider section remains held across the operation.
2. **Binding refresh/heartbeat/hello:** provider section → pool registry →
   release read. A provider section is never acquired while a pool or release
   lock is held.
3. **Release publication:** release write lock → catalog pointer swap / staged
   Tier2 and identity-set publication → release generation increment → release
   write unlock. `afterReleasePublished` and provider sweeps run only after the
   write lock is released; each sweep takes one provider section and then the
   ordinary registry/release-read order.
4. **Route insertion:** pool registry snapshot → release read precheck → release
   unlock → immutable route insert → fresh release read/postcheck plus registry
   comparison. The route path never takes a provider section. A failed postcheck
   leaves the audit snapshot but forbids dispatch and settlement.
5. **Evidence/settlement:** after dispatch, receipt verification and settlement
   operate on immutable route/billing snapshots. They take no release or
   provider-section lock and call no live feed/catalog/keyring accessor.
6. **Local preparation:** transaction control lock → transaction row/journal →
   owned staging descriptor → artifact-store publication lock. It must never
   hold a UI callback, network feed request, child-process wait, or coordinator
   lock. Cancellation and cleanup acquire only the named transaction and owned
   staging resources.

Every newly introduced callback is documented with a must-not-hold list. Race
tests pause each boundary and prove bounded completion, one coherent generation,
and reverse-order release on error/cancellation. Material lock-order or owner
changes reopen the plan gate.

## Migration and compatibility

1. Do not rebase the dirty source worktree in place. Freeze writers, record
   tracked and untracked SHA-256 manifests, create a private recovery ref and
   verified bundle outside the repository, and exclude secrets/build output.
2. Create a fresh hidden worktree and `codex/` branch from exact
   `1d2c930bad81704dd0acc0322226725d8b64aceb`. Replay only approved Build 1
   slices with per-slice file manifests.
3. Keep every `1d2c930` event, pending-decision, provider-binding, release-set,
   route-guard, and artifact-six-value column/migration. Merge dirty SQLite
   changes by a new forward migration only when a required field has one clear
   owner and a compatibility test. Never renumber or edit landed migrations.
4. Preserve no-extension route snapshots and exact c944 six-field route
   snapshots. Do not create or migrate the abandoned 24-field v2 envelope.
5. Legacy CLI/app capability versions remain conservative: unsupported actions
   render unavailable, unknown states remain non-paid, and old clients never
   infer preparation or admission from new fields.
6. Preserve existing provider wire compatibility. Local journal-only GGUF proof
   does not change request wire schemas. Unknown future admission/intake fields
   follow their closed-schema owner rather than being silently ignored.
7. A database rollback disables new command/coordinator integration and retains
   immutable events, pending records, route snapshots, receipts, and ledger
   rows. It never rewrites settled history. Provider rollback retains the
   incumbent and verified prepared artifact; owned orphan staging is removable
   through the typed cleanup action.

## Separate slice-5 intake branch

`/Users/augstar/macprovider-byom-v02-slice5`, branch
`feat/byom-v02-slice5-intake-pipeline`, is a separate unmerged dependency based
on `1d2c930`. At plan time it is one commit ahead with proposed SPEC-047 v0.1.6,
SPEC-017 v0.2.1, and SPEC-023 v0.10.4 intake contracts, and it also contains an
untracked `phase4-coordinator/internal/intake/` implementation directory. None
of that work is landed or part of this Build 1 diff.

Build 1 must not cherry-pick, copy, delete, or edit that worktree. If slice 5
lands before Build 1 source replay, rebase the fresh Build 1 integration branch
onto the landed commit, retain the intake contract and selectors, and choose the
next non-conflicting SPEC version only if Build 1 truly needs a normative
amendment. If it remains unmerged, Build 1 stays based on `1d2c930` and documents
the dependency in the PR; governance conflict resolution is performed after
slice 5's disposition is known. Intake signals may inform later operator work,
but they cannot become automatic positive admission or price authority in this
build.

## Conflict-path dispositions

| Conflict path | Required resolution |
|---|---|
| `phase4-coordinator/cmd/coordinator/main.go` | Keep landed release staging, identity-set publisher, route guard, operator endpoints, and store wiring. Add only approved provider UX/support wiring; do not install dirty automatic authority callbacks. |
| `internal/buyer/autotune_feeds.go` | Keep coherent `(feeds, commit)` observation, previous-release loading, and artifact identity set construction. Do not add an independent feed/billing generation owner. |
| `internal/buyer/model_admission.go` | Keep landed `ModelAdmissionRouteGuard` and exact binding checks. Remove/supersede dirty `ResolveModelAdmissionAuthority` positive-authority path. |
| `internal/buyer/server.go` | Keep `WithModelAdmissionRouteGuard`. Any lifecycle close hook must be orthogonal and may only make admission unavailable; it cannot install authority. |
| `internal/pool/provider.go` | Keep session epoch, artifact identity, admission binding, and generation semantics. Merge only additive wire/status fields whose owner is defined and tested. |
| `internal/ws/model_admission.go` | Keep landed event fields, store CAS, pending decision schema, migrations, release sweep support, and operator origin validation. Add no second positive transition origin. |
| `internal/ws/server.go` | Keep release state/provider sections and `runModelAdmissionSyntheticProbe(..., "network_admitted_unsettled", false)`. Delete the dirty call to `promoteModelAdmission`. |
| `internal/buyer/route_snapshot.go` | Keep route expectation and WS compare-and-insert. Do not reconstruct authority in buyer code. |
| `internal/tier2/catalog.go` | Keep staged publication under the release owner; no split setter capable of enabling paid admission. |
| `internal/ws/admin_endpoints.go` | Keep the authenticated operator decision/list/approve surface and exact rate-limit/auth semantics. Provider CLI never calls it. |
| `internal/billing/route_snapshot.go` and `settlement_receipts.go` | Preserve landed six-value artifact evidence, canonical digest, model-key price, and immutable replay. Do not add the obsolete v2 envelope. |
| `phase3-binary/.../BYOMDiscovery.swift` and admission tests | Three-way reconcile landed artifact-digest/member support with dirty durable discovery. Candidate identity remains path-free and stable. |
| `specs/SPEC-010`, `SPEC-047`, `CONFORMANCE.json`, `README.md` | Start from v1.8/v0.1.5 and landed selectors. Do not restore older text. Coordinate with slice 5 before any successor version and regenerate indexes. |

## Bounded implementation phases

### Phase 0 — freeze and recovery

Freeze all source/test writers. Capture the dirty tree, recovery ref, verified
bundle, file manifests, current package lockfile provenance, and exclusion scan.
Create the fresh integration worktree from exact `1d2c930`. No implementation
replay occurs before the plan gate and recovery check pass.

### Phase 1 — preserve the landed authority baseline

Replay no dirty source yet. Run the newly landed targeted race suites and record
selected tests. Lock in operator-origin, dual-control, release publication,
provider binding/session epoch, drift sweep, route guard, and six-field evidence
tests as non-regression gates.

### Phase 2 — R4 reservation correction prerequisite

The nine frozen R4 reservation files remain outside this reconciliation until
their separate corrective plan passes an independent Sol gate at zero Critical,
High, and Medium findings. Correct and audit that slice in isolation. If the
final R4 design changes transaction architecture, storage quotas, cancellation,
or recovery semantics, update this plan and reopen its gate before replaying the
dependent preparation transaction.

### Phase 3 — provider feed, durable inventory, and preparation

Replay the provider-only signed-feed consumption, durable discovery, transaction
storage, primary-MLX preparation, cancellation, cleanup, adoption bridge, and
CLI JSON/JSONL contract in small commits. Each commit names owned paths and runs
its targeted Swift tests. No coordinator positive-state code is included.

### Phase 4 — truthful Malibu.app and CLI composition

Wire capability-negotiated actions to the CLI-owned transaction. Render size,
trust source, progress, cancellation, prepared/active state, admission head,
pending dual approval, catalog price, and paid readiness independently. Run
SwiftPM command tests and Xcode MalibuTests; Swift CLI tests do not substitute
for Xcode app evidence.

### Phase 5 — coordinator reconciliation by deletion and adaptation

Start from the landed authority path. Remove/supersede dirty
`model_admission_authority.go`, automatic `promoteModelAdmission`, parallel buyer
authority/preparer, and their bypass-oriented tests. Adapt useful dirty tests to
prove evidence can support offer matching and status without creating a positive
decision. Preserve unsettled automatic probes, operator CAS/pending approval,
release/provider locks, route compare-and-insert, and immutable settlement.

### Phase 6 — schema/governance and compatibility

Add only fields demonstrated necessary after reuse of landed event/route/billing
owners. Apply forward-only migrations, golden historical fixtures, strict
closed-schema tests, and governance selectors. Reconcile the slice-5 dependency
as specified above. No conformance evidence entry claims a release, deployment,
physical run, enforcement, or economic activation.

### Phase 7 — combined verification, audit, and reviewable PR

Run targeted tests, then full appropriate Swift, Xcode, Go, integration, vet,
lint, dist, and governance checks. Docker-dependent integration runs only with a
ready Docker runtime. Three independent GPT-5.6 Sol lanes review the complete
diff as it will land for code correctness, security, and architecture. Fix and
repeat until every lane reports zero Critical, High, and Medium findings. Draft
and validate the PR governance declaration; do not merge, release, deploy, or
enable economic enforcement.

## Acceptance criteria and verification mapping

| Acceptance criterion | Implementation step | Verification |
|---|---|---|
| Fresh verified feed or explicitly safe baked fallback selects one exact target | Phase 3 | 1D2-T03/T04 |
| Provider sees trusted source and exact/unknown size before mutation | Phases 3–4 | 1D2-T05/T08 |
| Preparation stages, verifies, publishes atomically, and survives restart | Phase 3 | 1D2-T05/T06 |
| Cancellation preserves incumbent at every boundary | Phase 3 | 1D2-T06 |
| Provider can execute prepare/adopt/offer/status/retry through CLI/app | Phases 3–4 | 1D2-T07/T08/T17 |
| Preparation/provider assertion cannot mint price or paid admission | Phase 5 | 1D2-T09/T10 |
| Operator-origin catalog-priced and dual-control settlement-capable remain authoritative | Phase 5 | 1D2-T09/T10/T11 |
| Exact model member and coordinator model key bind immutable price and receipt | Phases 5–6 | 1D2-T12/T13 |
| Corrupt, cross-release, stale, drifted, unsupported and unapproved inputs fail closed | Phases 3–6 | 1D2-T04/T06/T09/T13/T14 |
| c944/no-extension rows settle with unchanged digest semantics | Phase 6 | 1D2-T12 |
| Combined local software verification and audits pass | Phase 7 | 1D2-T18/T19 |
| Physical Mac performs preparation through correctly settled real MLX request | Qualification | 1D2-T20; remains open until run |

## Observability and failure recovery

Use bounded, typed, low-cardinality reason codes for feed unavailable/invalid/
stale, size unknown, insufficient space, integrity mismatch, cancelled,
`cancel_too_late`, cleanup required, preparation ready, adoption rolled back,
offer unsettled, operator review required, pending second approval, stale head,
release/session/binding drift, route stale, receipt invalid, and settlement
complete. Include transaction ID, candidate ID, coordinator event ID, release
generation, and request/receipt IDs where their owner permits it. Never log raw
feeds, signed envelopes, local model paths, file identities, journal contents,
API/operator keys, private key material, or payout data.

On provider restart, reconcile transaction journal and durable store before the
UI can offer retry or cleanup. On coordinator restart, replay immutable events,
pending decision state, binding refresh, and route/billing snapshots through
their landed stores. Failure to read current authority disables new paid routes;
it does not reinterpret prior settled records. Release-publish failure retains
the prior coherent release. A route postcheck failure blocks dispatch even when
an audit snapshot was inserted.

## Hardware and qualification requirements

Local physical acceptance requires a suitable Apple Silicon Mac, exact supported
primary MLX artifact bytes, recorded chip/RAM/macOS/Swift/MLX/runtime and binary
versions, a valid signed candidate/artifact release, independently justified
Tier2/reference material, isolated coordinator/gateway/PostgreSQL services,
test-scoped provider/buyer/operator identities, and a verified receipt plus
balance delta. Test configuration, identity, HMAC, cache, and model roots must be
isolated outside operator defaults and repository roots. No production secret or
installed production provider may be mutated.

If any prerequisite is absent, 1D2-T20 remains **BLOCKED / UNPROVEN**. A Swift
fixture, deterministic provider, local digest test, selected Go suite, or prior
historical run cannot replace actual MLX inference and settlement. Release asset
signing/notarization and deployed production qualification remain separate even
after the physical local journey succeeds.

## Rollback

Provider rollback disables the new action capability and leaves the incumbent
configuration/runtime and verified durable artifacts intact. Transaction cleanup
removes only resources proven owned by that transaction. Coordinator rollback
removes no landed operator decision, dual-control, release, binding, route-guard,
or settlement protection; the Build 1 coordinator reconciliation is primarily
deletion of the conflicting automatic path. Schema rollback is forward-safe and
retains historical rows. Any incompatible migration blocks rollout and requires
a new plan revision.

## Explicit non-goals

- No automatic positive admission, self-approval, or provider-authored pricing.
- No weakening of operator authentication, dual control, release sweeps, route
  guards, receipt verification, sanctions, caps, or replay protection.
- No new paid support claim for arbitrary, unsupported, or provider-only models.
- No new runtime, throughput engine, compute-integrity tier, privacy claim, or
  Trusted Pool behavior.
- No production enforcement, reward/payout activation, epoch/payment work,
  release publication, deployment, merge, hardware procurement, spending, or
  operator-secret change.
- No claim that local tests, deterministic fixtures, or one successful probe
  prove physical computation, release qualification, or production settlement.

## Stop and reopen conditions

Implementation may start only after the paired plan gate passes and Phase 0 is
complete. Reopen the gate for any change to positive-decision origin, dual
control, receipt/evidence schema, pricing key, release/provider lock order,
transaction commit point, R4 architecture, supported artifact/runtime scope, or
test strategy. Build 1 can be implementation-complete and locally verified while
physical, release, deployed-service, or production qualification remains blocked;
those states must be reported separately.
