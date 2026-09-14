# Build 1 durable discovery implementation

Implemented in the approved Build 1 worktree on the explicit PR #1468 dependency.

## Changes

- `BYOMDiscoveryEnvironment.production` takes optional `config: AppConfig?` and resolves its internal durable root through `CachedModelArtifactResolver.forConfig(config, environment:homeDirectory:)`. Direct environment construction accepts optional `durableArtifactRoot: URL?` for hermetic callers.
- `BYOMDiscoveryRunner` accepts an injectable `catalogMatcher`, inventories qualified primary MLX durable targets, and deduplicates them against HF cache candidates using the existing stable candidate ID. Durable rows retain `runtime_source: mlx_cache` and the signed candidate model reference.
- `BYOMCatalogMatcher.durableTargets` requires matching candidate/feed model ID, immutable revision and SnapshotManifestV1 hash, verified primary MLX artifact status, and the existing qualified-feed authority.
- `DurableModelDiscovery` checks canonical root containment, rejects symlink paths and artifacts through the existing verifier, hashes actual bytes, and preserves the exact selected target. Missing/corrupt targets under an existing model directory become `needs_weights` / `local_only`; a cache copy cannot overwrite that failure. Discovery neither repairs nor deletes artifacts.
- The existing discovery wire schema, identity/admission labels and pricing authority are unchanged. Local paths and artifact hashes are not added to wire candidates.

## Validation

Initial command:

```sh
cd phase3-binary
swift test --disable-automatic-resolution --skip-update --filter DurableModelDiscoveryTests
```

Passed **8 tests, 0 failures**, at 2026-09-10 13:52:05 local test-run clock. Log: `/tmp/macprovider-build1-durable-tests.log`.

Covered empty HF cache and stable identity after staging removal/restart, simultaneous copies and durable metadata preference, corrupt bytes without repair/cache fallback, wrong revision/hash siblings, missing/symlinked weights, symlinked root/ancestor, unqualified-feed rejection, and injected resolver consistency.

Subsequent code additionally checks candidate-row/feed revision/hash equality, preserves unrelated cache adapter warning codes, and strengthens the restart test by deleting the HF cache root. A ninth test covers candidate/feed target disagreement.

Broader command:

```sh
swift test --disable-automatic-resolution --skip-update --filter 'DurableModelDiscoveryTests|BYOMDiscoveryTests|AutotuneArtifactFeedTests'
```

**Interrupted / failed build; not a passing validation.** Swift detected that another lane modified `ModelCatalogEconomicsTests.swift` during the build. Log: `/tmp/macprovider-build1-discovery-regression.log`. Root must rerun the combined selection after source freeze, including the ninth test and final small changes.

`git diff --check` passed for the modified existing discovery file. `Package.resolved` remained unchanged. No commits were created.

## Integration and remaining evidence

The CLI transaction lane owns passing loaded command config into production environments and the injectable resolver implementation. Root owns cumulative code/security/architecture audits and executable/physical acceptance through recommendation, adoption, offer/readback and settlement. These are not replaced by the fixture tests here.

Actual durable bytes are rehashed during each inventory; physical model hashing latency remains unmeasured. No persistent local verification cache was introduced.

## Approved retry extension

The root approved `retry-journal-addendum-r2.md` after an independent zero-finding gate. The retry status wire cannot carry the original evidence tuple, so the CLI now journals the closed signed offer envelope privately before HTTP and uses it to build a fresh retry envelope.

Additional files: `BYOMPendingOfferJournal.swift`, `BYOMPendingOfferJournalTests.swift`, and extensions to `BYOMAdmissionTests.swift` / `BYOMDiscovery.swift`. The journal uses descriptor-relative no-symlink file access, private modes, atomic/fsynced publication, a 64 KiB record bound, 128-record limit, operation locks held across HTTP, and generation checks. Different unresolved evidence is preserved until explicit authoritative terminal reconciliation. No bearer token or private signing key is journaled.

`BYOMModelAdmissionRuntime.retryOffer(providerID:target:)` reads current status, checks the recorded exact tuple and current admission signing key, applies current local readiness, and sends the fresh provider-signed envelope to `/v1/provider/model-admission/retry`. It preserves evaluation and artifact evidence and rejects terminal states, changed discovery, rotated keys, and missing/corrupt journal records. Successful withdrawal retires its journal only after coordinator confirmation.

The environment also accepts an injected catalog matcher for the same selected qualified live inputs snapshot used by command projection/recommendation. Discovery and all admission/evaluation runtimes inherit this snapshot; the adapter itself creates no authority or network feed.

Additional tests cover original-envelope signature validation, key rotation, terminal states, exact retry transport/readback, private journal modes, restart, count/size limits, symlinks, corruption, identity substitution, operation locks, stale generations, pre-HTTP persistence, an accepted-but-lost response, rejection of a different unresolved offer with byte-identical original retention, restarted retry, and missing/corrupt records without retry POST. These tests are pending the coordinated final Swift build; no passing result is claimed here yet.

## Coordinated validation update

The CLI lane's `/tmp/build1-cli-swift4.log` records these final owned/relevant suites passing on 2026-09-10:

| Suite | Tests | Failures |
| --- | ---: | ---: |
| AutotuneArtifactFeedTests | 28 | 0 |
| BYOMAdmissionTests | 35 | 0 |
| BYOMDiscoveryTests | 44 | 0 |
| BYOMPendingOfferJournalTests | 7 | 0 |
| DurableModelDiscoveryTests | 9 | 0 |

That is **123 passing tests** for this lane and its matcher/discovery/admission regressions. The complete shared selection was **167 tests, one skipped physical serve-lifecycle test, one failure** in the separate CLI-owned `DurableModelArtifactStoreTests.testVerifiedCopyPublishesAtomicallyAndPreservesCorruptDestination` (`artifact contains unsafe file`). The complete shared run must not be represented as passing.

The final passing journal tests include nearest-repository-root rejection, terminal reconciliation/generation protection, and descriptor-relative root handling. Withdrawal now acquires its journal operation lock before fallback coordinator status reads.

Subsequent `Package.resolved` changes appeared during shared builds owned by the CLI lane; this lane did not restore or overwrite those changes. Its initial isolated commands left the lock unchanged.

A further recovery clarification is under independent review: unrecoverable journal bytes must never be discarded based only on an unrelated coordinator terminal tuple. Current code fails closed. No corrupt-record deletion/recovery behavior has been implemented without the additional gate.

Exact CLI-lane swift4 command:

```sh
swift test --filter 'ModelCatalogTransactionsTests|DurableModelArtifactStoreTests|CandidateParentLifetimeGuardTests|CandidateProviderRunnerTests|AutotuneRecommendTests.testEngineDocumentPreservesCatalogKeyAndCanonicalArtifactIdentityForAdoption|BYOMAdmissionTests|BYOMPendingOfferJournalTests|DurableModelDiscoveryTests|BYOMDiscoveryTests|AutotuneArtifactFeedTests' > /tmp/build1-cli-swift4.log 2>&1
```

After that run, the explicit no-repository-journal boundary was extended to other repositories as well as the active worktree, with a hermetic foreign-repository marker test. This adds the eighth journal test, pending the next shared run.

## Approved corrupt-record preservation correction

Implemented the independently approved `retry-corrupt-recovery-r2.md` (SHA-256 `fd957ea3833b82e25ccfbf0c446e74744146ad042c8eedc05a7d4a1032a7366d`). A distinct JSON decoding error is emitted only after bounded reading of a safe private regular journal file. Explicit withdrawal may proceed using its existing signed coordinator tuple in that case; a confirmed withdrawal preserves every corrupt byte and writes a sanitized stderr warning. The coordinator response remains untouched. Retry and new offers remain blocked by the unrecoverable record. There is no deletion, quarantine, partial-envelope parser, or automatic replacement for corrupt records.

Security/filesystem errors, unknown-field or identity mismatches, and unsafe/symlink roots still fail before HTTP. A dangling journal-root symlink is detected with `lstat` and cannot masquerade as an absent legacy journal.

Four additional admission tests cover preservation of a malformed wrapper containing an unrelated signed envelope, continuing retry/replacement rejection, valid-record cleanup, failed withdrawal without success claims, and unsafe-file/root rejection before HTTP. Final expected suite sizes are BYOMAdmissionTests 39 and BYOMPendingOfferJournalTests 8; the new tests await the next coordinated run.

## Lane handoff and final gate pending

The subsequent shared `/tmp/build1-cli-swift5.log` **failed compilation; no test pass is claimed**. Root identified and fixed the retry command's missing import. The next shared Swift run (`swift6`) and its final exact selection/counts are owned by root and the CLI lane. This lane's source is frozen and handed off; the latest four admission tests and eighth journal test remain unverified until that result is recorded.

Evidence mapping: B1-T12 has nine passing durable discovery fixtures in swift4; the same run covers 28 artifact-feed and 44 existing discovery regressions relevant to B1-T01. Signed retry/journal coverage passed 35 admission and seven journal tests before the approved preservation correction. These fixtures do not prove B1-T10 physical inference/settlement or the full B1-T11 executable bootstrap journey. Root owns those acceptance results and the complete combined-diff code/security/architecture audit gate.
