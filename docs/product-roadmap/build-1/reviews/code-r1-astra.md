# Build 1 code audit — Astra r1

Status: **CHANGES REQUIRED / preliminary changing-tree review**. No zero-finding or final acceptance claim. Native independent code lane; reviewed AGENTS.md, CLAUDE.md, approved plan-r4/test-spec-r4 and retry/storage addenda. Base `914f7cafcdbcfc1805a10f4f34167218341d5587`.

## Snapshot and scope

Initial implementation/spec/test snapshot SHA-256: `5f676fa3e500f41b983633ff09b0e6272c8897cbb773ff66c4ccc18770ae6e1a`.
At report preparation the source snapshot had changed to `1482ff03ccd9bb66424b5fd5b69ecce6a162f694ca3fbd0d9d9c979f15eae7b6` (55 files). The digest is SHA-256 of the newline-terminated, lexically path-sorted manifest `SHA256(file bytes) + "  " + relative path`, over the union of `git diff --name-only BASE` and `git ls-files --others --exclude-standard`, excluding `docs/product-roadmap/` and non-files. This includes untracked new implementation/tests, not merely `git diff` output. Documentation/reviews and their planning authority were read separately. A final stable combined-diff/delta review is mandatory.

Reviewed the complete changed CLI transaction/discovery/retry/storage/runner surfaces; app capability, validators, command dispatch, recovery and rendering; coordinator authority/probe/retry/store/routing/billing; normative amendments; and added regression/integration tests. No source edits, secret inspection, or d-inference reads. The checked-in prerequisite is already contained in the named base; this report does not claim a new independent audit of every unchanged prerequisite source file.

## Findings

### CODE-M1 — Cleanup disappears when the authority that failed preparation is unavailable

**Severity: MEDIUM. Confidence: high.**

Evidence: `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift:663–686`: `makeModelCatalogLocalActions` iterates only current candidate rows and returns early unless `ModelCatalogTransactionAuthority.resolve` succeeds and the model is currently supported. `latestCleanup` is consulted only after that guard. The preparation owner refreshes the feed before publication and can fail on unavailable/expired/drifted authority; it independently records `cleanupRequired` if owned staging removal fails. CLI `cleanup-staging` correctly needs only the journal and ownership, not current feed authority. The UI only receives cleanup actions through this authority-gated projection.

Consequence: preparation can leave recoverable owned staging and then hide the recovery action precisely because its feed became unavailable, untrusted, stale, removed the model, or no longer supports the original target. This breaks the approved B1-T04/B1-T05 actionable staging recovery contract. It does not permit paid routing, but strands the app journey and leaves potentially large disk usage without its promised action.

Required correction: project safe journal-owned cleanup independently of live feed eligibility, including a model removed from the current catalog. Retain exact transaction/target ownership and confirmation; expose no preparation, activation, prices or trust claims from this local recovery record. Add a regression starting from a terminal cleanup-required journal, then remove/expire/reject the feed (and remove its row), verify only cleanup remains actionable and executable, and verify active/published bytes are preserved. App fixture cleanup tests alone do not test this producer failure.

### CODE-M2 — Approved deterministic owner/bootstrap acceptance remains untested

**Severity: MEDIUM. Confidence: high.**

Evidence: `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift:111–174` runs a successful tiny preparation, cancellation during the initial authority fetch, and a pure input-comparison helper. Its positive download consists solely of `weights.bin` and does not prove a verified ready discovery result requiring model configuration. `DurableModelArtifactStoreTests.swift:128` cancels the older `adoptVerifiedStaging` copy path, while the new owner invokes `stageVerifiedCopy` followed by `publishVerifiedCopy`. The prepared-map negative tests in `AutotuneRecommendTests` prove fail-closed map handling but do not execute the new transaction owner's successful recommendation/result path. The app composition at `app/Tests/MalibuTests/ModelManagementTests.swift:1946` supplies a prewritten recommendation and fake CLI replies. `test/integration/build1_artifact_journey_test.go:193` starts with a ready fixture provider and hand-constructed signed offer; it exercises real coordinator/gateway/SQLite transport and settlement, not CLI discovery/preparation/recommendation/adoption composition.

Consequence: green existing unit and service integration suites cannot prove the new owner preserves incumbent state and cleans up/terminates children at its commit, cancellation, timeout and crash boundaries, nor that the actual CLI result can be consumed through adoption and signed offer. These are explicit approved acceptance requirements, not optional physical benchmarks. The independent physical-feed blocker does not prevent adding these deterministic cases.

Required correction: implement and freshly run the missing deterministic cases below, clearly distinguishing fixture evidence from physical qualification:

| Approved ID | Missing runnable evidence |
| --- | --- |
| B1-T03/T04 | Drive the actual preparation owner through cancellation during metadata, transfer, hash and `stageVerifiedCopy`; coordinate cancellation immediately before and after publication; assert terminal truth, no destination before commit, original config/incumbent preservation and owned staging cleanup. Inject owner loss at reservation/start/publication intent/rename/terminal-journal boundaries and reconcile after restart. Exercise competing prepare/adopt, disk-space/write failure, cleanup failure and recovery, timeout, and feed drift during the real owner flow. Existing isolated lower-level checks remain useful but are not this owner matrix. |
| B1-T11/T12 | A fixture CLI command journey starting with no target session, admission, saved recommendation or HF cache: prepare -> process restart -> durable discover/projection -> recommend-prepared -> original result readback -> explicit adoption -> signed offer/status/retry. Assert stable identity, exactly one ready row, no hidden downloader calls, and no incumbent change before activation. Reuse the real service fixture for settlement rather than claiming app mocks are equivalent. |
| B1-T14 | Execute the actual recommendation owner with controllable isolated runner/prober/lifecycle seams: valid durable target and complete prefetched map, runner-derived numbers deliberately different from catalog thresholds, full JSON result consumed by adoption, and a downloader spy that fails on every call. Missing/corrupt target must fail before runner creation. Cancel/timeout/pressure at probe start, middle and result must verify child termination, prior lifecycle restoration, no configuration application and truthful terminal/result availability. |

Full Swift/Xcode/Go gates must follow the final source version, with selected test counts. A hand-written eligible recommendation is acceptable for narrow app wire tests but cannot replace B1-T11/T14 producer acceptance.

## Known corrections and other evidence

The lead identified app controls during provider drain, terminal admission recovery, reservation retention, and CLI root-ancestor symlink checks before this audit. They are not duplicated as new findings here; changing fixes still require final stable review and regressions. The retry signing-custody correction is present in the reviewed runtime factory. Cached billing repricing and recovery now load captured artifact rates; live registry gates and status expiry are rechecked. No new Critical or High finding is established by this preliminary code review.

Fresh independently run command:

```text
cd phase4-coordinator
go test ./internal/ws ./internal/buyer ./internal/billing -run 'Test(PrimaryArtifact|SignedAdmissionRetry|ArtifactAdmission)' -count=1
```

Exit 0. Packages: ws 1.582s, buyer 0.958s, billing 2.132s. This is selected Go fixture evidence, not a full Go suite, race run, Swift/Xcode result or real MLX qualification. Source changed during the review; the final gate must use a stable snapshot.

B1-T10 remains independently **BLOCKED / unproven** by the recorded public signed-feed HTTP 404 and unavailable justified physical authority. Fixture keys/receipts and green service integration cannot satisfy physical preparation -> actual MLX -> persisted settlement. Xcode 16.4 release qualification likewise remains separate from local Xcode 26.6 evidence. These are acceptance limitations, not fabricated code defects or reasons to waive CODE-M2.

Gate at r1: **0 Critical, 0 High, 2 Medium new findings; FAIL**. Final stable audit pending.
