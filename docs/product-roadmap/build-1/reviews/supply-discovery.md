# Build 1 supply discovery

Status: bounded discovery, not plan approval. Inspected base `422fc2f13fc62c1ff8987522f822d9ef856e4a96` and read-only PR #1468 head `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`. Read AGENTS.md and CLAUDE.md. No implementation changes and no tests run. This report is the only file written by this inspection lane. No d-inference source or operator secrets were inspected.

## Landed foundations

- `phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift:85`: `adoptVerifiedStaging` copies regular files into a private durable model/revision/hash directory, rejects symlinks, and rehashes the copy. `gcInactive(keeping:)` at line 121 preserves caller-specified paths.
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:3618`: `prefetchedArtifactPreservingExisting` preserves the incumbent canonical snapshot and downloads replacement bytes into a hash-qualified sibling. `verifiedExistingArtifact` verifies signed catalog revision/hash and promotes into the durable store.
- `AutotuneRecommend.swift:3335`: `HuggingFaceSnapshotDownloader.downloadSnapshot` uses temporary staging, pinned revisions, guarded redirects, path validation, and cleanup on thrown errors. Retry/resume and deadline support already exist.
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:1398`: `autotune --recommend --prefetch --candidate-models … --prefetch-receipt …` acquires explicit signed catalog rows without benchmarking, writes a private receipt, and binds subsequent cache-only work to catalog identity.
- `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:923`: recommendation adoption has signed authority checks, a configuration lock, durable recovery journal, runtime preparation, configuration rollback, commit/finalization, and live-model reconciliation. It emits `model_adoption_event.v1`, with `cancellable: false`.

## Partial and missing outcomes

- `ModelsSubcommand.swift:6` registers no preparation, transaction cancellation, or staging cleanup commands.
- `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift:423` advertises switch/prepare/adopt/cleanup as unavailable. This is truthful today.
- Malibu decodes typed prepare/cleanup actions, but `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:2649` derives executable actions only for switch/evaluate. A preparation-required row becomes `.needsPreparation` with `.evaluate` or `.none`.
- Malibu's displayed `estimatedGB` in `ModelManagementViews.swift:331` is a model/fit estimate, not an authoritative download-size promise.
- Existing prefetch prints final text rather than SPEC-044 transaction events. It does not provide periodic progress, typed cancellation, cleanup inventory, or projection-based completion.
- Existing process cancellation in `ModelManagement.swift:1215` terminates a launched CLI process. Its current background recommendation use must not be reused for preparation cancellation: SPEC-044-R002 requires the CLI-owned transaction interface.
- `assertDeadlineActive` in `AutotuneRecommend.swift:3395` checks wall-clock deadlines only. The inspected staging/copy/hash loops have no explicit task-cancellation checks. Preparation must thread cancellation through those boundaries.

## Existing PR dependency and activation

[PR #1468](https://github.com/Augustas11/macprovider/pull/1468) was OPEN when inspected. Branch: `feat/byom-v02-slice2c-cli-artifact-feed`.

It already owns `AutotuneArtifactFeed.swift`: strict decoding, `Artifact.sizeBytes`, signature/release/candidate binding, freshness qualification, `QualifiedArtifactFeed`, fetched and baked selection. It integrates `loadRecommendationInputs(includeArtifactFeed:)`, content-addressed BYOM matching, Malibu's four artifact-warning allow-list additions, and a shared Python/Go/Swift conformance corpus. Build 1 should depend on this implementation, not recreate it in parallel.

The PR's compiled snapshot has a **nil baked artifact feed**. Its loader returns nil without fetching when the baked feed is nil. Landing the PR alone therefore does not activate artifact-backed size or preparation. The first artifact-bound catalog release is an explicit operator prerequisite for using this feed in production. If Build 1 requires signed size, that activation must be included in the delivery dependency and verified from the actual selected release. If size is unavailable, SPEC-044-R007 permits nullable `estimated_bytes`, provided confirmation explicitly states that size is unavailable.

## Bootstrap contract gap

SPEC-044-R003 currently includes Prepare among actions requiring trusted economics. R002 permits trusted economics only after valid coordinator admission authorizes catalog economics (`catalog_priced` or `settlement_capable`). Requiring those economics before a new provider can acquire and verify its model creates a bootstrap dependency cycle.

Resolve this normatively before implementation; do not silently bypass the existing gate. The narrow amendment should permit **non-economic local preparation and its cleanup** for an exact signed target, with valid local-default admission, `catalog_economics_permitted: false`, `settlement_capable: false`, unavailable economics, and null money fields. That action conveys only local readiness, never paid eligibility, admission, routing, or provider credit. Invalid/malformed identity or admission evidence must remain fail-closed. Keep trusted-economics and settlement gates for money-motivated actions and copy unchanged.

Reconcile R002, R003, R006, and R008 so the same row can truthfully appear in Needs preparation and offer this non-economic action. R007's confirmation/staging/cancellation/integrity contract still applies. Preserve existing `prepare_model` and `cleanup_staging` transaction kinds and row fields where possible. Add an explicit preparation capability advertisement, or version the protocol if the existing closed validator semantics cannot safely represent the amendment; older apps/CLIs must remain non-actionable. Document and test that decision rather than assuming compatibility from unchanged JSON field names.

## Recommended minimal transaction approach

1. Introduce a CLI-owned transaction dispatcher for run/status/cancel of one exact advertised row action. A possible command family is `models transactions run|status|cancel`; command spelling is a design recommendation, not a landed interface. Bind run to transaction ID, kind, exact target, selected signed release identity, and immutable artifact hash. Revalidate at dispatch rather than trusting a stale projection.
2. Let the owning CLI process manage preparation independently of the provider's active runtime. A private local transaction control endpoint can receive a second CLI invocation's cancellation request while the original CLI emits the same `model_catalog_transaction_event.v1` stream. Reuse existing control-socket ownership and framing patterns where appropriate. The app calls the CLI cancellation command; it neither terminates the owner process nor deletes files. Cancellation must reach the owning transaction even when downloads stall.
3. Implement the SPEC-044 states, per-transaction event sequences, deadlines, stage labels and heartbeat at least every 10 seconds. Persist enough private staging ownership and terminal state for restart recovery and bounded cleanup. The app receives sanitized IDs/reason codes, not private artifact paths or raw feed bytes.
4. Reuse verified prefetch and durable promotion. Thread explicit cancellation through download, hash, and copy. Do not reuse the general `verifiedArtifact` cache-repair path, which may remove a canonical snapshot, as preparation cleanup. Inventory only transaction-owned staging.
5. Define promotion's commit point. Before it, cancellation removes only owned staging and leaves active configuration, model bytes, and runtime identity unchanged. After it, return the actual terminal result; report that cancellation arrived after commit. Durable local preparation success is not adoption success.
6. Derive `estimated_bytes` from the qualified artifact feed when available; show unavailable size explicitly otherwise. Disclose signed trust source separately from size. Account for transient staging/durable disk usage in implementation capacity checks without relabeling RAM estimates as download size.
7. Detect abandoned staging at startup. Emit `staging_cleanup_required` when cleanup fails and advertise a narrowly scoped CLI cleanup transaction. Protect active artifacts and adoption/recovery references. Do not use broad `gcInactive` for cancellation. Its hidden-file enumeration deserves targeted coverage before relying on it for `.tmp-*` cleanup.
8. Advertise prepare/cleanup only when the dispatcher and cancellation path are executable. Extend Malibu's action/store/view handling for exact typed dispatch, size/trust confirmation, live progress, delayed-response state with cancellation still visible, and fresh projection reconciliation before success.
9. Keep adoption unavailable for an unprepared target. After preparation, refresh projection and regenerate/revalidate the recommendation, then reuse the existing cache-only adoption protocol. Preserve its lock/journal/rollback/runtime authority checks; do not silently add artifact downloads to it. If exposed through the new generic dispatcher, adapt its events and terminal result without inventing cancellability beyond its actual commit semantics.

## Verification recommendations

- Extend `DurableModelArtifactStoreTests.swift` for interrupted copy, wrong hash, orphan temporary-directory cleanup, and active/journal-referenced artifact preservation.
- Reuse `AutotuneRecommendTests.swift:testPrefetchPreservesMismatchedIncumbentSnapshotWhileAcquiringReplacement` (line 2741), receipt-drift tests, and download deadline fixtures.
- Add preparation transaction tests for cancellation during metadata/download/hash/copy; cancellation versus commit; disk-full/network failure; missing/signed size; feed/catalog drift; heartbeat cadence; cleanup failure; owner-process restart; duplicate dispatch; and cross-transaction cancellation rejection.
- Extend `ModelCatalogEconomicsTests.swift` for bootstrap non-economic preparation with null money fields, invalid admission fail-closed behavior, availability iff executable, exact target binding, no adoption before readiness, and signed/nullable size.
- Extend Malibu `ModelManagementTests.swift` for confirmation content, typed dispatch, transaction/event matching, delayed response after 30 seconds, cancellation-too-late disclosure, projection timeout, bootstrap row visibility without money claims, older-capability fallback, and success only after fresh reconciliation.
- Preserve `ModelsSubcommandTests.swift` adoption success/rollback/recovery coverage. Add integration evidence that preparation and cancellation preserve an actively serving incumbent and that subsequent adoption uses only the verified prepared artifact.
- Verify nil-bake behavior and first artifact-bound activation separately. A passing feed decoder or synthetic UI fixture is not production activation proof.

Confidence: high for the observed landed/missing surfaces and PR dependency; transaction transport and normative amendment details are recommendations requiring plan review. No tests were run, and this report is not plan approval.
