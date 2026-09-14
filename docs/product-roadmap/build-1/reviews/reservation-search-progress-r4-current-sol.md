# Reservation search progress R4 — current-source Sol compatibility gate

Date: 2026-09-10. Reviewer: independent native GPT-5.6 Sol plan-compatibility
lane. Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.

**Verdict: APPROVED AT THE CURRENT-SOURCE PLAN GATE — 0 Critical, 0 High,
0 Medium, 0 Low.** R4 remains necessary for its stated maximum-shape durable
reservation-progress requirement and remains feasible against the catalog-complete
transaction implementation. Catalog completeness expands the final integrated test
matrix, but it does not require a different R4 authority graph, owner model,
timeout, capacity limit, or migration protocol.

This is a plan-compatibility verdict. It does not authorize a rollout, establish
runtime correctness, waive implementation tests, or replace the final complete-diff
code/security/architecture gate.

## Scope and exact inputs

The complete approved historical R4 proposal and its Build 1 test specification
were read, not inferred from the supporting historical Astra review:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r4.md` | `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` |
| `test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| Supporting historical `reservation-search-progress-r4-astra.md` | `0a311a1aca39c60953943f43e47f6a2adc506bff736bddfe003fda69fb05ddbf` |

The independently inspected current transaction sources were:

| Current source | SHA-256 |
|---|---|
| `ModelCatalogTransactionRetention.swift` | `efc03721e14d7e6e1b1eaf82366795bbb96742560f42499ab332f2729a643108` |
| `ModelCatalogTransactionEvidence.swift` | `100695f7fc0562e12a8161c5d495a2219401468420a27a408db5d4397e94f266` |
| `ModelCatalogTransactionStorage.swift` | `33cf08501a9d0e8509e8433d1cde7537bf9f660b814da0bf26fa1287a104916e` |
| `ModelCatalogTransactions.swift` | `dfa4874517b05d76f3ececc57a76c473ca3e8fd7d4f377550c9f3259990b5a55` |
| Current `ModelCatalogTransactionMigration.swift` | `86ef79bbbafbff366de80d6797b6f33846fd0e9991de8b1f95fa6ac568d001d0` |

The maximum-shape result, full log, and exact test source were also checked:

| Evidence | SHA-256 |
|---|---|
| `evidence/reservation-max-shape-measurement-result-r3.md` | `e6365c4b8c638419ac3f47c6998d2af4772a58735c79047fd095530735f87f5c` |
| `.omx/artifacts/build1-reservation-max-shape-r3.log` | `311ce7f23630815e0562ae6c93e57f1eda031dd9d3c5a40883b474bb0b152941` |
| `ModelCatalogReservationCapacityMeasurementTests.swift` | `69fa2294b0036e4a35bc7d2ec63eecf89b36fb4fb23e5f46a14c7da8de9a5e21` |

Only this review artifact was written. No source, test, proposal, measurement,
or evidence file was changed, and no test or service was run.

## Severity summary

| Severity | Open findings |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |

## RSP4-CUR-01 — necessity remains established

**Severity:** None. **Confidence:** High.

**Evidence:** The current production reservation path still initializes retention,
recovers allocating entries, and then reads and strictly decodes every active
primary before it can establish exact queued reuse absence
(`ModelCatalogTransactionRetention.swift:335-370`). Its maintenance cursor is
visited only after the complete reservation scan, so it cannot provide negative
search authority (`ModelCatalogTransactionRetention.swift:369-370,426-462`).

The maximum-shape fixture used 1,024 active records, 2,048 events per record,
4,194,304 bytes per primary, and 4,294,967,296 primary bytes total. Each of six
production-path calls retained the unchanged eight-second operation budget,
returned typed busy, opened the same 585-primary prefix, decoded the index once,
completed no scan, and published no maintenance progress. The three terminal-last
and three queued-last calls therefore demonstrate repeated-prefix starvation,
not merely a slow successful scan
(`reservation-max-shape-measurement-result-r3.md:32-70`; full log lines 18-34).
The measured maximum single-record decode was 1.640422 seconds and capture plus
proof validation was 0.961168 seconds, each below eight seconds.

**Consequence:** The smaller operation-local index-receipt correction removed the
healthy small-record failure but did not create durable negative classifications
for maximum-shape repeated calls. R4's stated structural goal remains necessary.
A cursor, maintenance-first pass, or negative-only decode of already-read bytes
still cannot prevent rereading a previously classified large primary after the
call ends; R4 correctly selects immutable origin-bound classification and
departure evidence referenced by the active-index CAS
(`reservation-search-progress-addendum-r4.md:20-37`).

**Required correction:** None at plan level. The maximum-shape measurement must be
rerun after implementation because R4 changes the measured retention/evidence
path, exactly as the evidence artifact requires.

## RSP4-CUR-02 — current storage and evidence keep R4 feasible

**Severity:** None. **Confidence:** High.

**Evidence:** Current descriptor-relative storage supports validated direct child
directories and components, no-follow/private regular-file opens, stable placement
metadata, exclusive publication, atomic rename, file fsync, and directory fsync
(`ModelCatalogTransactionStorage.swift:59-163,204-289`). The current file-evidence
object reads in 64 KiB chunks, checks the shared budget around every chunk, retains
the stable open descriptor, hashes exact bytes, and revalidates inode, placement,
size, mode, ownership, link count, and timestamps without rereading the body under
the journal lock (`ModelCatalogTransactionEvidence.swift:35-95`). These primitives
support R4's content-addressed direct receipt path and exact immutable class/left
files; they do not force directory enumeration or a caller-provided locator.

The v4 entry/reference growth remains bounded by the existing 1,024-entry and
1,048,576-byte index limits. R4 already requires largest-accepted origin/entry
derivation tests and rejects any implementation that narrows the existing 4 MiB
primary or 16 KiB origin acceptance contract
(`reservation-search-progress-addendum-r4.md:147-150,247-252`). The fresh measured
index was 174,293 bytes at 1,024 maximum-shape entries, leaving material space for
the proposed closed refs, subject to the mandatory exact maximum-encoding tests.

**Consequence:** Catalog completeness added compact witnesses and an explicit
atomic-publication truth result for recommendation pointers, but neither changes
R4's persistence authority. Recommendation pointers remain a separate derived
lookup: they cannot replace a reservation class, left anchor, migration
acknowledgment, or active-index reference. The proposal remains implementable on
the current storage boundary without a dependency, limit increase, or alternate
allocation root.

**Required correction:** None at plan level. Implementation must continue to use
index-derived canonical UUID/digest components, exclusive immutable publication,
exact readback, and the R4 collision rule that checks the scoped reservation-
receipt directory itself without enumerating or adopting its contents.

## RSP4-CUR-03 — catalog completeness does not change mutation authority or ownership

**Severity:** None. **Confidence:** High.

**Evidence:** Catalog completeness added full cleanup inventory and recommendation
index preparation, but its mutations route through the same transaction seams
already covered by R4:

- `prepareRecommendationIndex` may call budgeted `reconcile`, obtain the affected
  UUID owner for a succeeded evaluation, and publish a recommendation pointer
  (`ModelCatalogTransactionRetention.swift:778-825`).
- Complete local actions call `reserveOperation` with the caller's supplied work
  budget (`ModelCatalogTransactions.swift:1292-1335`).
- Complete recovery rows call `reserveCleanup`, which uses the affected UUID owner
  and active receipt (`ModelCatalogTransactionRetention.swift:526-564,875-900`).
- Complete cleanup inventory itself is read/evidence capture. It decodes every
  active primary and provenance graph, returns compact witnesses, and performs no
  primary/index transition (`ModelCatalogTransactionRetention.swift:590-627`).

R4's writer inventory expressly includes generic update/commit, live start,
reconcile status/cancel, retirement, success-binding and index recovery, result and
seal publication, cleanup admission/start/heartbeat/result/original updates,
allocation recovery, and direct production `writePrivate`/directory writes
(`reservation-search-progress-addendum-r4.md:605-613`). It also requires every
first-departure writer to join the primary-first classification protocol and every
old/new writer to revalidate the mandatory format immediately before mutation
(`reservation-search-progress-addendum-r4.md:327-333,412-431`). The newly composed
catalog command invokes those same writers; it does not mint a new owner or a new
primary-transition authority.

**Consequence:** During reservation migration, a catalog-triggered reconcile,
cleanup reservation, recommendation-pointer publication, or ordinary reservation
must obey the same per-UUID owner, class-before-write, pending-publication, format-
fence, and active-index CAS rules as its standalone path. A complete inventory
cannot use a reservation class/left as a substitute for current primary cleanup
truth; catalog completeness deliberately requires every active primary to remain
decidable.

**Required correction:** None at plan level. The implementation audit must map the
actual owned quick/verify call graph to the R4 writer inventory so a wrapper cannot
bypass classification or convert pending/protected migration evidence into absent
actions or recoveries.

## RSP4-CUR-04 — budgets remain compatible; integrated tests become mandatory

**Severity:** None. **Confidence:** High.

**Evidence:** The current `ModelTransactionWorkBudget` carries one monotonic
deadline plus an optional shared request/phase check; `limiting` can only shorten
that deadline (`ModelCatalogTransactionEvidence.swift:5-32`). The catalog read
creates at most an eight-second transaction view of its existing 10-second quick
or 1,800-second verify request and threads that same view through recommendation
recovery, complete inventory, action reservations, final inventory, and final
witness validation (`ModelCatalogRead.swift:45-91`;
`ModelCatalogReadCommand.swift:111-140`). Reconciliation accepts that incoming
budget instead of renewing it (`ModelCatalogTransactions.swift:534-577`).

R4 repeatedly requires the original eight-second budget at activation,
classification, primary-first metadata publication, allocation recovery, and each
final CAS; it forbids raising the budget/watchdog to pass qualification
(`reservation-search-progress-addendum-r4.md:262-276,339-356,525-543,659-666,
709-728`). This is compatible with the newer shared-check representation: every
R4 helper must preserve the incoming deadline and closure rather than constructing
a fresh default budget.

Catalog completeness explicitly does not promise that 1,024 four-MiB primaries
finish inside a ten-second catalog read. A supported shape that cannot complete
must return explicit unavailable/incomplete without shrinking the fixture,
skipping recovery, or lengthening limits
(`catalog-read-completeness-addendum-r2.md:191-210,338-343`). That honest finite
failure does not weaken R4's separate durable reservation-progress obligation.
Conversely, R4 progress made before a later catalog-read failure is durable
recoverable journal truth and must not be rolled back to fabricate an atomic
pre-call state.

The test strategy is therefore additive. R4's crash/concurrency/maximum-shape
matrix remains mandatory, as do test-spec-r4 B1-T01-B1-T14. Catalog completeness
already requires every CC-01-CC-10 and lifecycle CR-01-CR-13 result against the
same final landing source manifest, including the transitive reservation,
reconcile, pointer, cleanup, shared-budget, final-inventory, and actual app/CLI
paths (`catalog-read-completeness-addendum-r2.md:315-343,345-403`). R4 itself keeps
all existing migration/binding/retirement/cancellation/cleanup tests and the final
complete-diff review mandatory (`reservation-search-progress-addendum-r4.md:681-738`).

**Consequence:** Catalog completeness materially expands final validation, not the
R4 design contract. Separate green R4 helper tests and stale catalog-completeness
logs cannot qualify the combined implementation.

**Required correction:** None to the approved proposal. The final implementation
evidence must include fresh joint cases at minimum for: owned quick and verify
during classifying/finalizing/pending publication; shared-budget expiry before and
after durable class/left/index/pointer writes; action-side reservation or reconcile
creating a cleanup obligation followed by final complete inventory; concurrent
unrelated pending UUIDs while catalog reconciliation runs; explicit incomplete
output with retained progress; and successful completed-migration catalog output
with unchanged recovery/action truth. No helper may renew the work budget, emit a
false empty recovery, or roll back a durable publication after the outer read fails.

## RSP4-CUR-05 — migration safety and rollback remain coherent

**Severity:** None. **Confidence:** High.

**Evidence:** The current binding migration source/progress/receipt implementation
and its completion validation are unchanged from the historical R4 plan review
(`ModelCatalogTransactionMigration.swift`, SHA-256 `86ef79...`). Current index
receipts validate exact format/index placement plus the binding-migration completion
receipt under the same budget (`ModelCatalogTransactionEvidence.swift:139-157`).
R4 adds a separate reservation-migration lineage only after the binding migration,
retains the existing lineage, freezes source membership at the early mandatory-
format fence, and preserves later dynamic current membership independently
(`reservation-search-progress-addendum-r4.md:78-145,335-489,576-603`).

Catalog completeness neither changes migration files nor authorizes a format
downgrade. Its complete reads propagate incomplete/error states and preserve atomic
journal changes already made before an outer read failure. R4's actual prior-binary
qualification and final mandatory-format recheck therefore remain the controlling
mixed-writer safety gate.

**Consequence:** There is no new migration authority cycle or rollback route.
Recommendation pointers and cleanup witnesses remain derived/current evidence;
they do not enter the frozen reservation source membership or historical install
digest. After the v3-format/v4-index fence, only a compatible binary may proceed,
and recovery completes forward or returns protected failure.

**Required correction:** None at plan level. Implementation must preserve both
lineages explicitly in every v4 index CAS, retain all reservation and recommendation
history, and run the R4 actual-binary fence matrix plus the fresh catalog-owned
command cases above before the final zero-Critical/High/Medium complete-diff gate.

## Gate disposition

R4 remains both necessary and feasible on the current catalog-complete source.
Catalog completeness changes the final source manifest and requires joint command-
level qualification, but the already approved contracts compose without a new
authority, ownership, capacity, timeout, or migration decision. The historical
Astra approval is supporting evidence only; this current-source review independently
finds no Critical, High, Medium, or Low plan-compatibility defect.
