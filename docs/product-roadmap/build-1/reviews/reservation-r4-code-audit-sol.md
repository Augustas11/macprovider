# Build 1 reservation R4 — independent code audit

Date: 2026-09-10. Reviewer: independent native GPT-5.6 Sol code-audit lane.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.

**Verdict: REQUEST CHANGES / FAIL. Architectural status: BLOCK.**

The frozen implementation does not meet the repository gate of zero Critical,
High, and Medium findings. This audit found **0 Critical, 2 High, 4 Medium, and
0 Low** findings. The two independent review perspectives both reject the
implementation: the code lane returns REQUEST CHANGES and the architecture lane
returns BLOCK.

Only this review artifact was written. No source, test, plan, or compatibility
artifact was edited.

## Frozen inputs verified

The governing inputs and all nine implementation files matched the requested
SHA-256 values before review:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r4.md` | `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` |
| `reservation-search-progress-r4-current-sol.md` | `d19a8bc39fecb61ad58e073fcbc147bb45e792a977d18b6972780a7e0c1a32e9` |
| `ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `ModelCatalogTransactionMigration.swift` | `5bc526e395b048c9d1c41cede30d7430321da83395d2a9a02590e35ecfa4b4df` |
| `ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |
| `ModelCatalogTransactionReservationMigrationTests.swift` | `a0c700eb26cce0938d6dcf973f2dea1eacd8194de2a368ad1fb2270611aa2c35` |
| `ModelCatalogTransactionRetentionTests.swift` | `bf45cf3a914b377d61ecd10b9013467784acf4a9f234fee01e1f5ebd0c7d55cb` |
| `ModelCatalogTransactionsTests.swift` | `009611a1f01fb26dc695ae588abb7e401d1b4cf93c90d6e3fa21249bf6144121` |

## Severity summary

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 0 |

## R4-CODE-H1 — maximum-shape migration deterministically exceeds the shipped descriptor limit

**Severity:** High. **Confidence:** High.

**Evidence:** The runtime supports 1,024 active entries
(`ModelCatalogTransactionRetention.swift:109-112`). Reservation cutover creates
and retains one `ModelTransactionNoncreatingOwnerProbe` for every current entry
until the final journal CAS (`ModelCatalogTransactionReservationMigration.swift:
170-220,703-733`). Every present owner path therefore consumes a live descriptor.
Finalization similarly retains an authority receipt for every source member
before entering the journal lock (`ModelCatalogTransactionReservationMigration.swift:
1049-1062,1094-1100`). Each receipt retains live origin and class evidence, plus
left evidence when present (`ModelCatalogTransactionReservationMigration.swift:
344-395`), and every present `ModelTransactionFileEvidence` keeps its descriptor
until deinitialization (`ModelCatalogTransactionEvidence.swift:37-76`). The two
phases therefore require as many as 1,024 and more than 2,048 simultaneous file
descriptors respectively.

The audit host reports `launchctl limit maxfiles` soft `256`; the audit shell has
an elevated soft limit, which explains why the existing 1,024-entry test can pass
without representing the GUI/launchd process profile. The approved plan expressly
requires the 1,024-entry cut with owner paths present and absent, recorded limits,
and injected descriptor exhaustion without raising limits
(`reservation-search-progress-addendum-r4.md:659-666`).

**Consequence:** On the shipped launchd resource profile, cutover with retained
owner paths reaches `EMFILE` before the format fence. Even if cutover happens to
complete, finalization can repeatedly fail at the same descriptor boundary after
all classifications are durable. `initializeRetention`, reservation, and
maintenance then cannot reach the complete phase at the exact supported shape R4
exists to handle. Retrying does not advance either all-at-once descriptor phase.

**Required fix:** Redesign quiescence and final authority validation so live
descriptor use has a small fixed bound. One viable cutover direction is to hold
the journal lock, use sequential nonblocking owner probes, and rely on the
mandatory format revalidation to fence writers that acquire an already-checked
owner before the journal lock is released; the lock order and old-binary proof
must be reviewed explicitly. Finalization should retain compact validated
witnesses and perform bounded revalidation rather than keeping every evidence
descriptor open. Prove both paths with 1,024 present owner paths and 1,024
origin/class graphs under the unraised shipped app and CLI limits, including
injected `EMFILE` cleanup and retry.

## R4-CODE-H2 — unresolved allocating intents do not block a fresh allocation

**Severity:** High. **Confidence:** High.

**Evidence:** `recoverAllocations` leaves an allocating entry unchanged through
`continue` or its catch path when primary, origin, class, left, receipt-directory,
owner, or sidecar evidence is conflicting, unsafe, or otherwise cannot be
completed (`ModelCatalogTransactionRetention.swift:317-398`, especially
337-368 and 393-397). It returns no unresolved state. `reserveOperation` then
searches only active entries, runs maintenance, and appends a new allocating UUID
when total capacity remains; it never requires every existing entry to be active
(`ModelCatalogTransactionRetention.swift:400-406,449-504`).

The approved protocol says an unresolved allocating entry prevents new
allocation and cannot count as absence (`reservation-search-progress-addendum-r4.md:
500-507`). It also requires protected contradictory evidence to preserve the
intent and stop allocation past it (`reservation-search-progress-addendum-r4.md:
547-566`).

**Consequence:** A protected or incomplete allocation is treated as a negative
search result. A matching request can receive a newly durable UUID while the
earlier allocating member and its potentially matching evidence remain unresolved.
This permits duplicate work authority and leaks active capacity while preserving
the contradictory evidence that should have stopped mutation.

**Required fix:** Make recovery return a typed unresolved/protected result or
throw whenever any allocating entry remains. After recovery, recapture the index
and require every entry to be active before search; repeat that invariant under
the final allocation CAS. Add every recovery-table row with a matching request
and assert zero new UUIDs until the original intent is either exactly completed
or safely removed by the specified all-absent transition.

## R4-CODE-M1 — classifying receipts do not validate the global index/progress graph

**Severity:** Medium. **Confidence:** High.

**Evidence:** `validateReservationIndexShape` checks optional-field combinations
but does not correlate classifying index entries with the all-member progress map
and does not validate all entry class, left, and pending digest forms
(`ModelCatalogTransactionReservationMigration.swift:407-466`).
`validateReservationProgress` validates only the progress document internally and
does not receive the current index (`ModelCatalogTransactionReservationMigration.swift:
490-516`). `captureReservationAuthority` correlates source/progress state only for
the one requested UUID (`ModelCatalogTransactionReservationMigration.swift:
378-389`).

**Consequence:** UUID A can be in the explicitly impossible state where its index
contains an acknowledged class or left reference that is absent or different in
progress, while a writer of UUID B obtains a usable classifying receipt and
publishes another primary/index change preserving the invalid global graph. This
violates the plan's decoder-before-use and all-member acknowledgment rules and
turns a protected shared state into a partially usable one.

**Required fix:** Before any classifying receipt is usable, validate every source
member's current class/left/pending shape against the source and acknowledgment
map, including digest syntax and within/beyond-prefix acknowledgments. This is a
read-only graph check and must not acquire or complete unrelated UUID owners.
Add missing-acknowledgment and mismatched-reference cases for members before and
after the prefix while mutating a different healthy UUID.

## R4-CODE-M2 — finalizing recovery mutates to complete before validating source/progress lineage

**Severity:** Medium. **Confidence:** High.

**Evidence:** `recoverReservationFinalizing` validates the current index plus the
install and completed-index files, then writes the completed index
(`ModelCatalogTransactionReservationMigration.swift:1115-1147`). It does not
capture or validate the immutable reservation source and progress evidence before
that write. Those files are first required after mutation when the returned
`captureIndexReceipt(requireCompleted: true)` builds completion evidence
(`ModelCatalogTransactionReservationMigration.swift:1147`; completion capture at
556-601).

**Consequence:** If source or progress is deleted, substituted, or inconsistent
while the active index is finalizing, recovery advances persistent state to
`complete` and only then fails. That contradicts the protected/no-mutation result
required for altered acknowledged history and leaves a stronger false phase over
a graph that cannot validate.

**Required fix:** Capture the exact source, completed progress, binding completion,
install, and completed snapshot before publication; validate their hashes,
phases, generations, lineage, entries, and finalizing/completed relationship; keep
the compact evidence stable through the locked CAS; only then write the completed
index. Add deletion, substitution, same-byte replacement, and in-place mutation
at finalizing for source and progress and assert the active index bytes remain
unchanged.

## R4-CODE-M3 — pending departure recovery is not consistently interlocked with reserve and retirement

**Severity:** Medium. **Confidence:** High.

**Evidence:** `captureReservationAuthority` accepts an active entry whose
`reservationPublication` is set (`ModelCatalogTransactionReservationMigration.swift:
344-395`). Reservation reads the primary, takes the UUID owner, and calls
`publishReservationDeparture` (`ModelCatalogTransactionRetention.swift:400-427`).
That helper first invokes `recoverReservationPublicationIfNeeded` without passing
the already-held owner, so it tries another nonblocking flock on the same owner
path (`ModelCatalogTransactionReservationMigration.swift:988-1013`). A direct
host check confirmed that a second independent flock by the same process blocks
with errno 35. `retireOne` also never resolves a pending reservation publication
before it removes a terminal entry and its pending index reference
(`ModelCatalogTransactionRetention.swift:561-634`).

**Consequence:** A crash after `reservation_publication_intent` can make every
matching reservation call self-contend until a separate status/control path
repairs the metadata. The retirement path can instead remove the authoritative
pending reference before the exact left/progress/index bundle completes, breaking
the required pending-intent recovery chain.

**Required fix:** After acquiring the UUID owner, recover any pending reservation
publication with that exact `heldOwner`, recapture the index, and restart the
primary decision from the refreshed receipt. Apply the same rule before any
retirement decision; retirement may proceed only after the pending metadata
bundle is either exactly completed or rejected without mutation. Add reserve and
maintenance crash-restart cases for every pending boundary.

## R4-CODE-M4 — the frozen tests do not implement the mandatory qualification matrix

**Severity:** Medium. **Confidence:** High.

**Evidence:** `ModelCatalogTransactionReservationMigrationTests.swift:8-168`
contains four tests: a one-UUID thrown-boundary repair loop, a one-record migration
boundary loop, a structural phase-shape unit test, and class-envelope sizing.
The 1,024-entry retention cases either construct an already-completed v4 graph or
run with the audit shell's elevated descriptor limit
(`ModelCatalogTransactionRetentionTests.swift:378-449,655-711`). Across the three
frozen test files there is no conflicting protected allocation followed by a
matching reserve, 1,024-owner cut under the shipped limit, injected descriptor
exhaustion, two simultaneous pending UUIDs with direct-open counting, global
within/beyond-prefix corruption during another UUID's write, source/progress
substitution during finalizing, actual prior-binary fence execution, full dynamic
post-completion membership/history cycle, or 1,024 x 4 MiB x 2,048-event repeated
classification test.

Those cases are mandatory in the approved plan
(`reservation-search-progress-addendum-r4.md:621-728`), including actual child
death rather than thrown-error substitution at the R4 publication boundaries.

**Consequence:** The green focused tests do not prove the required crash,
compatibility, resource, or state-machine behavior and do not expose H1, H2, M1,
M2, or M3. The implementation checkpoint's 79 passing tests are useful regression
evidence, but they cannot qualify R4 acceptance.

**Required fix:** Implement the complete approved R4 qualification matrix with
real subprocess deaths, deterministic CAS barriers, prior-binary manifests,
shipped process limits, exact maximum-body fixtures, direct-open counters, and
protected-state byte-preservation assertions. Rerun all affected focused suites
and the package-wide Swift suite against one unchanged frozen source manifest.

## Verification performed

- Recomputed the two governing SHA-256 values and all nine frozen file hashes;
  every value matched the requested manifest.
- `swift test --filter ModelCatalogTransactionReservationMigrationTests` passed
  4/4 tests with zero failures in 1.972 seconds on the frozen hashes.
- `launchctl limit maxfiles` reported a soft limit of 256 and an unlimited hard
  limit; the audit shell reported an elevated soft limit of 1,048,575.
- A same-process, independently opened second nonblocking `flock` on one file
  returned errno 35, confirming the M3 self-contention path.
- The implementation checkpoint reports 44/44 retention and 31/31 transaction
  tests passing on the same hashes. This audit did not rerun those long suites;
  their reported coverage does not include the required failing scenarios above.

## Gate decision

Code-review recommendation: **REQUEST CHANGES**. Architectural status:
**BLOCK**. Deterministic synthesis: **REQUEST CHANGES / FAIL**.

R4 may return to the code gate only after both High and all Medium findings are
corrected, the mandatory matrix is implemented, and fresh evidence is frozen at
zero Critical, High, and Medium findings.
