# Build 1 PRD and implementation plan — revision 3

Status: DRAFT; implementation prohibited until independent Astra plan gate passes.
Base: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`.
Planned prerequisite: PR #1468 at `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`.
Per-build diff excludes that prerequisite; cumulative review includes it.

## Outcome and journeys

A provider discovers a supported primary MLX artifact, sees its size (or an
explicit unavailable-size disclosure) and authenticated trust source, confirms
preparation, observes progress, safely cancels or completes, adopts prepared
weights, obtains coordinator-authoritative admission and serves one correctly
priced, receipt-verified, persisted settled request. Preparation is never proof
of paid admission, physical computation, or price authority. Failure/restart
preserves the incumbent serving model and leaves actionable recovery status.

## Code-grounded outcome inventory

| Outcome | State at base | Evidence | Change/verification |
|---|---|---|---|
| Signed feed production/distribution | Landed | buyer/catalog_artifacts_feed.go; scripts/catalog-release.py | retain and rerun conformance |
| Verified CLI consumption/fallback | Missing at base; implemented in open prerequisite | PR #1468 AutotuneArtifactFeed.swift, loadRecommendationInputs(includeArtifactFeed:) | import pinned dependency after gate; run corpus and binding negatives |
| Durable storage | Landed foundation | DurableModelArtifactStore.adoptVerifiedStaging, gcInactive | transactional copy/cancel safety tests |
| Safe preparation | Partial | CachedModelArtifactResolver.prefetchedArtifactPreservingExisting; downloader.downloadSnapshot; AutotuneCommand.runRecommendationPrefetch | CLI-owned transaction, progress, cancellation, staging recovery |
| Adoption | Landed foundation | ModelsAdoptRecommendationCommand, lock/journal/runtime protocol in ModelsSubcommand.swift | reuse prepared-only adoption, verify rollback/recovery |
| Authoritative paid admission | Missing production promotion | ws.Server.maybeRunModelAdmissionSyntheticProbeForOffer targets network_admitted_unsettled; model_admission.go bindings and buyer routing gates exist | authority service and immutable evidence; real settlement test |
| Executable truthful app/CLI | Partial | ModelCatalogEconomics.makeCandidateRow actions unavailable; Malibu ModelManagement builds switch/evaluate only | typed preparation/cancel/cleanup, reconciliation and explicit admission action |

Paths in the table are relative to phase3-binary/Sources/macprovider-cli,
phase4-coordinator/internal, or phase3-binary/app/Sources/Malibu as applicable.

## Contracts and dependency graph

SPEC-023 R004 controls feed identity, signer/release/freshness and primary-only
settlement. SPEC-010 R001/R004 controls signed candidate identity. SPEC-022
controls route snapshots and verified receipts. SPEC-047 R001–R008 controls
offer authority, state transition, pricing, sanctions, drift and protected
journey evidence. SPEC-044 R002/R003/R006/R007/R011/R012 controls app actions,
transaction cancellation, recovery and truthful economics. SPEC-046 discovery
remains read-only. Existing SPEC-011/043 adoption boundaries remain intact.

Dependency order: pinned #1468 -> normative amendments -> preparation transaction
-> CLI/app exposure -> authority-backed admission -> end-to-end settlement and
combined review. Independent implementation lanes may run only after approval
and with disjoint ownership. Builds 2–4 remain subsequent separate gates.

Resolve the preparation AND activation bootstrap conflict before runtime edits: SPEC-044 R003
currently classifies every prepare as money-motivated, while R002 bars trusted
economics before admission. Amend R003/R008 narrowly to permit explicitly
non-economic primary-artifact preparation and confirmed local activation based on authenticated identity with
all rate/payout/demand claims suppressed. This does not permit stale/untrusted
artifact-derived operations or weaken paid action gating. Version capability
negotiation so legacy app/CLI remains conservative. R007 already permits null
estimated_bytes only with explicit unavailable-size confirmation.

### Executable bootstrap contract (resolves r1 H1)

Choose non-economic local activation, not premature catalog_priced promotion.
Amend SPEC-044 R002/R003/R006/R008 and the applicable recommendation/adoption
owner requirements to allow a capability-negotiated `adopt_recommendation` for
an exact prepared primary target before network admission. This narrow path
must hide all economics and explicitly say local activation does not authorize
paid routing. No new admission tier or stronger identity claim is introduced.
Signed catalog/rate freshness, supported-model and fit/configuration safeguards
inside the recommendation producer and adoption validator remain mandatory.
Thus authenticated rates may validate configuration without being displayed as
provider-authorized economics. A missing fresh required feed blocks activation
honestly; it never justifies constructing an eligible recommendation by hand.

Starting with no target session, admission record or saved recommendation:
1. Discover catalog target; explicitly confirm non-economic prepare.
2. Publish verified durable target; refresh read-only inventory.
3. Implement a CLI-owned `models recommend-prepared TARGET --json` transaction
   constrained to one verified prepared primary artifact. It invokes
   AutotuneRecommendationBenchmarker.benchmarks with a mandatory complete
   prefetchedArtifacts map resolved from the verified durable target. This
   takes the verifiedExistingArtifact branch; missing map/key/hash fails before
   runner creation, and this path must never fall through to verifiedArtifact
   or download. Use the existing real candidate runner and recommendation
   engine on resulting measured CandidateBenchmark values, with configured
   durable resolver, bounded deadline, memory-pressure monitoring and safe
   drain/restore lifecycle. Emit genuine current local benchmark/fit plus full
   autotune_recommend.v1 config/feed evidence. No synthetic benchmark from
   catalog thresholds, no config application or hidden download is allowed.
   Existing check-only remains an estimate-only background path and is not used.
   Advertise this as confirmed long-running evaluate_model with live progress
   and CLI-owned cancellation; forward cancellation to probe child, wait for
   termination and restore prior serving lifecycle even on timeout/crash.
   Present only fit/local activation implications, suppress monetary/demand
   recommendations in bootstrap UI. Before adoption recheck document age,
   hardware/runtime identity, target hash and authenticated feed bindings.
4. With explicit activation confirmation, invoke existing
   `models adopt-recommendation` on that produced document. Preserve all signed
   authority, hash, SupportedModels, RAM-fit, lock/journal and runtime checks.
   Only after this explicit action may the incumbent change. Reconcile resulting
   current model/session; rollback failures remain visible.
5. Resolve the same durable-discovered candidate, execute provider-signed offer
   through CLI authority, then status/retry. Coordinator independently qualifies
   the loaded session, probes, binds rates/references and promotes. App shows
   non-paid pending state until authoritative readback proves settlement_capable.
6. Dispatch actual buyer request; immutable receipt/snapshot verification and
   ledger checks establish settlement. No earlier step claims earned credit.

The bootstrap app capability names this behavior explicitly; old clients retain
their stricter disabled actions. New UI validators may accept this narrow local
activation path with local_default/nonpaid admission only when capability,
exact target, local verified readiness and typed confirmation all match. They
must not infer trusted economics from action availability. Update SPEC-044's
blanket nontrusted action rejection accordingly, without changing paid gating.

### Durable inventory contract (resolves r1 M1)

CLI lane owns a read-only durable adapter wired into BYOMDiscoveryEnvironment,
BYOMDiscoveryRunner, ModelsDiscover/Evaluate/Offer/Admission command resolution,
and economics projection. Resolve durable roots exactly as
CachedModelArtifactResolver.forConfig (same config/env precedence) and use that
same resolver in the recommendation producer. Do not mutate discovery state or
repair corrupt artifacts while listing. Validate canonical contained paths,
immutable revision and SnapshotManifestV1 hash against qualified candidate/feed
authority before calling a durable target verified/ready.

Reuse BYOMCandidateIdentity's existing namespace/runtimeSource/servedModelRef
identity. Durable primary MLX artifacts remain runtimeSource mlx_cache, with
canonical served model reference from the signed candidate row, not their path.
Candidate IDs must not include storage location. Deduplicate HF and durable
copies on that identity; prefer a verified durable copy over cache. Conflicting
revision/hash copies must not merge into a verified result: preserve the exact
selected catalog target and expose conflict/block state where ambiguous. Keep
IDs stable after owned staging removal, empty HF cache, CLI restart and reoffer.
Never send local artifact paths in offers or UI. Corrupt durable contents become
unready, without deleting the active copy. Tests start with an empty HF cache
and exercise actual commands through projection, recommendation, offer/readback.

## Bounded implementation phases and ownership

1. Lead: pin dependency and record its open status; amend owner specs and
   regenerate governance indexes. Specify preparation protocol and admission
   evidence fields before code. No new third-party dependencies.
2. CLI lane: add `models prepare`, `models transaction status/cancel`, and
   transaction-scoped cleanup using a private CLI-owned journal/lock and
   transaction UUID. Commands accept exact model target and authenticated
   catalog/feed identity, never caller-provided paths or authority flags.
   Preparation requires confirmation and advertises <=1800-second deadline.
   Use SPEC-044 JSONL events; heartbeat <=10 seconds. CLI cancellation uses the
   same transaction owner rather than process termination. Owner checks reject
   unknown/cross-target IDs. Interrupted jobs reconcile before reuse.
3. CLI storage lane: isolated transaction-owned download directories, bounded
   free-space checks, cancellation checks through metadata/download/hash/copy,
   verified temporary durable copy followed by atomic publication. Publication
   is the commit point. Never remove/replace incumbent data during repair;
   protect active and recovery-journal references. Clean only owned staging;
   failed cleanup emits staging_cleanup_required with resumable CLI action.
   Persist terminal outcome across crash/reconnect and serialize competing
   adoption/preparation. Revalidate trusted input immediately before commit.
4. App lane: capability-negotiated preparation/cleanup dispatch, accessible
   localized size/trust confirmation, progress, delayed response after 30s,
   CLI-owned cancellation and too-late disclosure. Refresh projection before
   success; preserve pending/timeout rules. Prepared is distinct from active,
   admitted, priced and settled. Reuse existing prepared-only recommendation
   adoption rather than giving it hidden downloads. CLI supplies all authority.
5. Coordinator lane: construct admission decisions solely from current
   coordinator-owned session, authenticated candidate/feed and effective signed
   rate evidence, current sanction/lease/generation state, successful bounded
   wire probe, supported receipt key/profile, settlement enforce mode and independently loaded Tier2
   reference material. Require exact primary model/hash/algorithm agreement with
   both SPEC-010 session authority and Tier2 SnapshotMaterial. Append decisions
   with expected-current-event concurrency control, recheck predicates at
   route time and settlement, and revoke on drift. Missing references/rates
   leave explicit unsettled status, never provider-asserted promotion. Reconcile
   pending offers on matching live-session readiness or bounded explicit retry;
   an idempotent replay alone currently never reruns the probe. Signed prompt,
   cache/completion rates, share and multiplier must match effective billing;
   reject default-fallback rates for new admission rather than guessing a price.
6. Coordinator/billing lane: artifact-derived admission carries immutable
   artifact_feed_sha256, artifact_id, artifact hash, hash_algorithm,
   artifact_feed_signer_key_id and candidate body digest through the admission
   record and route snapshot digest. Name the candidate digest separately as
   candidate_catalog_sha256: existing CatalogBodyDigest denotes Tier2 catalog
   bytes and must not be repurposed. Validate release/signer/primary consistency
   and reject missing/substituted provenance. Bind selected effective rate
   version and units to snapshot; receipt verification and ordinary billing
   caps/deduplication remain mandatory. Use additive optional fields/migrations;
   old snapshots retain their original digest/version interpretation, and old
   records cannot qualify for the new artifact-derived path. Settlement validates
   captured immutable authority, never reconstructs it from today's mutable feed.
7. Lead: run targeted then surface gates; independent full cumulative code,
   security and architecture audits; fix all >=Medium findings; produce PR and
   acceptance report before advancing to Build 2.

## Acceptance, observability and qualification

The paired test specification maps each outcome to negative and positive
evidence. Structured reason codes distinguish unavailable authority, invalid
feed, preparation failure, cleanup required, admission pending and settlement
failure. Log transaction/event/model identities without secrets, absolute model
paths, raw feeds or verifier transcripts. Admission/settlement records are
durable audit evidence, not UI assertions.

Physical acceptance requires this Apple M5 32 GiB Mac, actual supported MLX
weights, exact artifact hash/runtime/build context, local isolated coordinator
and gateway with PostgreSQL, valid independently sourced reference material and
test-scoped identities. No production secrets or activation are permitted.
The prerequisite's baked artifact feed is nil: code landing does not make a
live authenticated feed available. A missing current signed catalog/feed or
matching justified reference is a named hardware-qualification blocker, not a
reason to forge production authority or claim fixture acceptance. Local
test-generated keys remain explicitly fixtures outside operator trust.

All local integration/physical harness config, identity, HMAC, discovery namespace,
credential and model roots must be explicitly isolated from operator defaults.
Inspect and override every CLI default including AutotuneHMACSecretStore before
running a journey; never create/rotate keys in an operator store or connect the
installed provider to test services. Use test-only identity stores outside repo
roots. Redact paths and secrets from deliverable logs. Release qualification
requires absent Xcode 16.4 separately; local Xcode 26.6 evidence cannot replace it.

## Compatibility, migration, rollback and non-goals

Legacy capability clients keep static UI and reject unsupported actions. No
automatic config switch on preparation. Retain prior config/runtime journal
and artifacts for adoption rollback. New admission behavior is disabled unless
all authority predicates are met; rollback disables new promotion and retains
audit records without rewriting settled ledger entries. Migration rollback is
non-destructive. Do not promote SPEC conformance from unsigned/local evidence.

Non-goals: novel or non-primary paid models, provider prices, stronger compute
claims, new runtimes, release/publication, production enforcement, rewards or
payout activation, epoch/payment work, and capacity-engine changes. These do
not remove any requested Build 1 outcome or physical acceptance requirement.
