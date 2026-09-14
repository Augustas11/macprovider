# Build 1 reservation search progress R4 — architecture audit (Sol)

Verdict: **BLOCKED**. 0 Critical, 3 High, 2 Medium, 0 Low.

The frozen R4 implementation does not pass the architecture gate. The authority graph accepted as `complete` is not closed over the frozen membership, the cutover cannot meet the supported 1,024-owner resource profile, and the reported 79 tests omit multiple mandatory qualification classes. Two mutation paths also violate the approved owner/pending-intent protocol.

Review base: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Governing plan SHA-256: `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21`. Current-source compatibility approval SHA-256: `d19a8bc39fecb61ad58e073fcbc147bb45e792a977d18b6972780a7e0c1a32e9`.

## H1 — Completed migration authority is not closed over its frozen membership

**Evidence.** `captureReservationCompletion` loads the source, progress, install, and completed-index snapshot, but its terminal checks cover only root identifiers, hashes, and generations (`ModelCatalogTransactionReservationMigration.swift:556-596`). It does not prove that the completed snapshot has the source membership, that each source member has the progress-acknowledged class/left references, or that every referenced origin/class/left file validates. The reusable completion receipt retains only the four root files and later rechecks only those file identities plus the live root fields (`ModelCatalogTransactionReservationMigration.swift:114-146`). Per-entry source/progress validation exists only in `captureReservationAuthority` while the live index phase is `classifying` (`ModelCatalogTransactionReservationMigration.swift:344-395`); it is skipped after completion. This is weaker than the plan's requirement to verify exact frozen membership and all authority references before completion and to treat missing acknowledged metadata as protected failure (`reservation-search-progress-addendum-r4.md:476-489, 621-642, 719-724`).

**Consequence.** A completed v4 journal can retain a valid root completion receipt while one frozen member's acknowledged class or left file is missing or substituted. A writer of another healthy UUID can then validate only its own entry and mutate it under a globally incomplete historical graph. The completion receipt therefore does not prove the closed authority graph that authorizes v4 mutation, and corruption of an untouched member is detected only if that member is later visited.

**Required correction.** Before publishing `finalizing`, validate exact source/completed membership and every progress entry against the completed snapshot and its immutable origin/class/left evidence. Carry a reusable completion receipt whose validation preserves that closed proof, or a content-addressed aggregate that commits to it, while still validating current dynamic membership separately. Add corruption tests that remove or substitute each acknowledged member outside the UUID being mutated and prove all mutation entry points fail before changing bytes.

## H2 — The owner-fence design cannot satisfy the required 1,024-entry resource profile

**Evidence.** Each present owner probe opens and exclusively flocks one descriptor and retains it until cutover ends (`ModelCatalogTransactionReservationMigration.swift:170-205`). Cutover creates and retains one probe for every active entry before taking the journal lock (`ModelCatalogTransactionReservationMigration.swift:703-710`). The active limit is 1,024 (`ModelCatalogTransactionRetention.swift:110`). On the audited Mac, `launchctl limit maxfiles` reports a soft limit of 256; no `setrlimit`, `RLIMIT_NOFILE`, or launchd resource-limit configuration exists under `phase3-binary`. The only reported 1,024-entry case fabricates records without owner paths (`ModelCatalogTransactionRetentionTests.swift:655-678`) and therefore does not exercise this descriptor strategy. The approved plan explicitly requires 1,024 entries with all owner paths present, descriptor accounting, exhaustion cleanup, and an eight-second result without raising limits (`reservation-search-progress-addendum-r4.md:659-666`).

**Consequence.** A valid journal near capacity with stable owner paths present cannot complete cutover on the default supported launchd profile. It reaches descriptor exhaustion well before 1,024 probes, so reservation migration remains unavailable even when every owner is quiescent. This is a capacity-dependent compatibility dead end, not only missing performance evidence.

**Required correction.** Replace the all-descriptors-held fence with a cutover authority mechanism that prevents old owner mutation across the format/index fence within bounded descriptors, while preserving the noncreating, nonblocking and prior-binary guarantees. If the retained-descriptor design remains, the supported runtime contract must first be changed and independently approved; the frozen plan expressly forbids raising limits to pass qualification. Exercise present, absent, substituted and exhausted owner-path cases at 1,024 entries and record descriptors, flocks, cleanup, elapsed time and budget checks.

## H3 — The 79 passing tests do not prove the approved protocol

**Evidence.** The dedicated R4 suite contains four tests: same-process thrown-boundary recovery for one departure, same-process thrown-boundary migration for one entry, a structural phase-shape table, and a reservation-class size envelope (`ModelCatalogTransactionReservationMigrationTests.swift:8-168`). The 1,024-entry test uses small fabricated legacy records, no owner inodes, and completes reservation migration in repeated calls before retirement (`ModelCatalogTransactionRetentionTests.swift:655-727`). The frozen files contain no R4 qualification using actual prior binaries, no 1,024-entry all-owner descriptor/exhaustion run, no 1,024 records at 4 MiB and 2,048 events with controlled chunk latency, no real child death at the R4 migration/allocation boundaries, and no full concurrent reserve/reserve plus allocation/retirement absence-CAS matrix. The implementation checkpoint itself leaves package-wide Swift and post-c944 compatibility open (`implementation-reservation-r4.md:46-50`). These are explicit stop conditions, not optional coverage (`reservation-search-progress-addendum-r4.md:621-728`).

**Consequence.** The passing count demonstrates useful focused regressions, but it does not establish prior-binary fencing, crash durability, max-shape feasibility, resource cleanup, concurrency uniqueness, or the complete corruption matrix. The architectural acceptance claim is therefore unsupported, and H1/H2 reached frozen source without a test capable of detecting them.

**Required correction.** Implement and run the complete mandatory qualification matrix against the corrected frozen candidate: actual prior binaries at every named phase; real child death and thrown errors at every publication/allocation boundary; concurrent owner, reserve and retirement barriers; two-UUID pending recovery; all graph substitutions; 1,024 present/absent owner profiles; max-body/event latency and no-reread accounting; shared-budget expiry at every durable boundary; and fresh catalog quick/verify behavior. Report commands, measurements and immutable artifacts rather than only aggregate test counts.

## M1 — A queued cancellation can return success while recording no cancellation

**Evidence.** `reconcile` attempts the UUID owner for every cancel, swallows `busy`, then captures the active receipt (`ModelCatalogTransactions.swift:561-580`). If the primary is still queued and the owner remains unavailable, the `guard let owner` branch validates the unchanged receipt and returns the unchanged record (`ModelCatalogTransactions.swift:592-605`). The plan requires bounded busy when the owner is busy and the primary is queued or has metadata intent, so the existing caller retries rather than treating an unrecorded cancel as a result (`reservation-search-progress-addendum-r4.md:316-325`).

**Consequence.** A cancellation racing a starter before its first primary write can be acknowledged by the API path as an ordinary successful reconciliation even though no `cancel_requested` or terminal event was durably published. The worker may then start and run despite the caller believing the cancel command completed.

**Required correction.** After recapture, if cancellation is requested, the primary remains queued, and owner custody was not obtained, return the bounded busy error. Preserve the existing started-primary cancel-request path. Add a barrier test with the starter holding the owner before its first write and assert no successful cancel response precedes durable cancellation.

## M2 — Retirement can discard an entry with unresolved reservation metadata intent

**Evidence.** `retireOne` acquires the UUID owner and captures reservation authority but does not recover or reject `entry.reservationPublication` before building and committing retirement (`ModelCatalogTransactionRetention.swift:561-631`). `captureReservationAuthority` validates the current class/left files but does not validate or finish a pending receipt in completed phase (`ModelCatalogTransactionReservationMigration.swift:344-395`). A primary-first terminal transition can legitimately leave such an intent after interruption. The plan requires every writer/control path to finish the exact per-entry pending metadata bundle before mutating that UUID, and says referenced intent cannot be bypassed (`reservation-search-progress-addendum-r4.md:453-474`).

**Consequence.** Maintenance can remove the active member and publish a retirement certificate while its content-addressed class/left intent remains unresolved. That drops the pending interlock from current membership and permits later allocation without ever installing the frozen metadata bundle, weakening crash-recovery evidence and the promised first-departure history.

**Required correction.** Under the already-held owner, recover and validate the exact pending reservation publication before evaluating retirement, then recapture the index receipt and retirement proof. If recovery cannot validate, preserve membership and fail protected. Add terminal-entry tests interrupted at receipt, intent, class, left and final-index boundaries, followed directly by maintenance and restart.

## Frozen snapshot

All reported hashes were recomputed with SHA-256 and matched exactly.

```text
3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21  docs/product-roadmap/build-1/reservation-search-progress-addendum-r4.md
d19a8bc39fecb61ad58e073fcbc147bb45e792a977d18b6972780a7e0c1a32e9  docs/product-roadmap/build-1/reviews/reservation-search-progress-r4-current-sol.md
60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift
b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
5bc526e395b048c9d1c41cede30d7430321da83395d2a9a02590e35ecfa4b4df  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift
c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionReservationMigration.swift
0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
a0c700eb26cce0938d6dcf973f2dea1eacd8194de2a368ad1fb2270611aa2c35  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionReservationMigrationTests.swift
bf45cf3a914b377d61ecd10b9013467784acf4a9f234fee01e1f5ebd0c7d55cb  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift
009611a1f01fb26dc695ae588abb7e401d1b4cf93c90d6e3fa21249bf6144121  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift
```

Audit method: static authority and control-flow review of the exact nine frozen files against the approved plan and compatibility review; independent hash verification; focused inspection of the reported 79-test evidence; local resource-profile measurement. No source, test, or plan file was changed, and this lane did not rerun the already reported long test selections.
