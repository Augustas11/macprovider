# Build 1 reservation R4 security audit (Sol)

Date: 2026-09-10  
Reviewer: independent GPT-5.6 Sol security lane  
Decision: **FAIL — changes required**

## Gate result

| Severity | Count |
|---|---:|
| CRITICAL | 0 |
| HIGH | 2 |
| MEDIUM | 2 |
| LOW | 0 |

The R4 implementation does not meet the repository security gate because HIGH
and MEDIUM findings remain. The review was read-only except for this artifact.

## Frozen authority and implementation

The audited plan SHA-256 is
`3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` and the
approval SHA-256 is
`d19a8bc39fecb61ad58e073fcbc147bb45e792a977d18b6972780a7e0c1a32e9`.
The durable implementation report SHA-256 is
`1eeef81a89f0ecc0b0340812ec36741469ede98cda0d9d31988560f9782d6167`.

All nine frozen implementation hashes were independently recomputed and match
the implementation report:

| File | SHA-256 |
|---|---|
| `ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `ModelCatalogTransactionMigration.swift` | `5bc526e395b048c9d1c41cede30d7430321da83395d2a9a02590e35ecfa4b4df` |
| `ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |
| `ModelCatalogTransactionReservationMigrationTests.swift` | `a0c700eb26cce0938d6dcf973f2dea1eacd8194de2a368ad1fb2270611aa2c35` |
| `ModelCatalogTransactionRetentionTests.swift` | `bf45cf3a914b377d61ecd10b9013467784acf4a9f234fee01e1f5ebd0c7d55cb` |
| `ModelCatalogTransactionsTests.swift` | `009611a1f01fb26dc695ae588abb7e401d1b4cf93c90d6e3fa21249bf6144121` |

## Findings

### R4-SEC-H1 — A rolled-back queued primary can replay an excluded transaction

**Evidence.** `captureReservationAuthority` validates the origin, class, and
optional left files, but it does not compare an allocated transaction's current
primary with its immutable departure state
(`ModelCatalogTransactionReservationMigration.swift:344-395`).
`captureActiveReceipt` only publishes a missing departure while
`isPermanentlyNonreusable` is false; an already anchored left therefore skips
the rollback check and returns the current primary record
(`ModelCatalogTransactionEvidence.swift:240-285`). `run` accepts a returned
record whenever it is nonterminal and has no `startedAt`, then acquires custody,
writes a new start, and launches the operation
(`ModelCatalogTransactions.swift:738-776`). Consequently, replacing the
primary with its exact original queued bytes after a left anchor makes an
explicit run of that UUID admissible again.

There is a second form of the same defect in reservation search. Search does
not first recover an entry's `reservationPublication`. It captures the old
class/left graph, and when the rolled-back primary satisfies `initialQueued`,
it returns the old UUID as reusable
(`ModelCatalogTransactionRetention.swift:406-447`). Thus a crash after the
first-left intent was indexed, followed by primary rollback, can bypass the
pending immutable departure. This contradicts the approved plan's required
ordering and explicit “primary rolled back to queued” fail-closed case
(`reservation-search-progress-addendum-r4.md:285-306`).

**Consequence.** A same-user journal rollback, restored filesystem snapshot, or
coherent local tamper can replay a transaction that has already started,
failed, or been cancelled. That can duplicate downloads or evaluation and
break the one-operation-per-reservation contract. Success-binding checks do
not protect prepare operations or non-success departures.

**Required correction.** Before any run, control, status, or reservation
decision, recover the affected UUID's referenced reservation publication under
its exact owner custody. After authority capture, reject a current primary that
is initial-queued when the index anchors a left departure. A referenced
first-left intent must be completed from its frozen receipt before the primary
can be considered reusable. Add adversarial tests for both an anchored left and
a pending first-left receipt with the primary replaced by its exact original
queued bytes; reserve, run, check, status, and cancel must never launch or
return reusable authority.

### R4-SEC-H2 — Unresolved allocation intent does not block fresh allocation

**Evidence.** `recoverAllocations` uses `continue` for malformed, mismatched,
busy-owner, receipt-directory, and contradictory sidecar states
(`ModelCatalogTransactionRetention.swift:317-368`). Its catch block also
swallows every error except index-publication and `changed`, after merely
revalidating the current index and budget
(`ModelCatalogTransactionRetention.swift:393-397`). The unresolved
`allocating` entry therefore remains authoritative. `reserveOperation` then
searches only `active` entries and, if the total count is below the cap,
publishes a new UUID (`ModelCatalogTransactionRetention.swift:400-505`). It
does not assert that allocation recovery eliminated every allocating entry.

The recovery validation also checks that `allocatedGeneration` is syntactically
a UUID but never requires it to equal the operation generation decoded from the
primary/origin (`ModelCatalogTransactionRetention.swift:337-356`). A substituted
generation can therefore disappear when recovery changes the entry to active.
This violates the approved rule that any unresolved allocating entry prevents
new allocation (`reservation-search-progress-addendum-r4.md:498-506`).

**Consequence.** Corrupt, attacker-created, or crash-incomplete allocation
evidence can be treated as absent for reservation purposes. A second matching
operation can be allocated while the first intent remains, allowing duplicate
work if the first evidence is later restored or repaired. Repeated unresolved
entries can also consume the bounded index and turn the fail-open behavior into
durable resource exhaustion.

**Required correction.** Make allocation recovery return a typed unsafe, busy,
or capacity result for every unresolved allocating entry. After recovery and
before candidate search or new UUID generation, require that the validated
index contains no allocating entry. Cross-check `allocatedGeneration` against
the decoded record selector and origin allocation generation before activation.
Add tests covering invalid generation, primary/origin/class mismatch, unsafe or
busy owner evidence, retained receipt directories, partial files, and budget
exhaustion; every case must prove that no new UUID, primary, sidecar, receipt
directory, or index member is created.

### R4-SEC-M1 — Completed migration history is not cryptographically bound as a closed graph

**Evidence.** The complete-phase index retains an install UUID but clears the
install receipt hash. `captureReservationCompletion` opens
`<installUUID>.json` and `<installUUID>.active.json` by that UUID and validates
some shared fields, but it does not validate `install.preparedIndexSHA256`, does
not require the completed snapshot's members and class/left references to equal
the source/progress acknowledgment graph, and does not bind the current
complete index to the install-file digest
(`ModelCatalogTransactionReservationMigration.swift:556-596`). The retained
completion receipt subsequently checks only file identity, lineage fields, and
that the current generation is at least the completed generation
(`ModelCatalogTransactionReservationMigration.swift:115-146`). A coherent
replacement of both UUID-named install files can therefore be accepted as the
immutable historical completion as long as the limited checked fields match.

**Consequence.** The files claimed to prove the frozen migration cutover can be
rewritten as a mutually consistent pair without detection. Current per-entry
authority still supplies additional checks, so this does not by itself grant a
new operation, but it defeats immutable historical authority, weakens forensic
tamper detection, and can conceal an invalid or incomplete original migration.
That conflicts with the plan's requirement to validate the closed historical
graph and protect altered acknowledged install evidence
(`reservation-search-progress-addendum-r4.md:576-589`).

**Required correction.** Validate the completed snapshot against the exact
source membership and complete progress acknowledgment map, including every
origin/class/left reference and the expected phase fields. Validate
`preparedIndexSHA256` and its generation relationship. Retain or derive an
immutable digest anchor for the install receipt after completion so replacing
the UUID-named receipt and snapshot together cannot establish new authority.
Add coherent two-file replacement tests, including altered membership,
class/left refs, prepared-index hash, and generation lineage.

### R4-SEC-M2 — Publication recovery ignores its frozen prior-index and progress hashes

**Evidence.** A reservation publication records `oldIndexSHA256` and
`previousProgressSHA256` when the intent is prepared
(`ModelCatalogTransactionReservationMigration.swift:800-829`). Recovery never
reads either field. It requires only that `oldIndexGeneration` be lower than
the current generation and accepts a current progress hash mismatch whenever
any entry has a pending publication
(`ModelCatalogTransactionReservationMigration.swift:617-633,865-955`). Thus the
receipt's claimed prior index and progress lineage are unauthenticated data, and
one entry's pending flag relaxes the shared progress check without proving a
monotonic transition from the recorded predecessor.

**Consequence.** Coherently substituted pending index/receipt/progress evidence
can pass recovery without proving that it descends from the frozen state used
to authorize publication. The remaining origin, primary, class, and left checks
limit the direct payload, but replay and tamper detection for concurrent
acknowledgments is incomplete and can erase, replace, or misattribute migration
history before final validation rejects or accepts the resulting graph.

**Required correction.** Verify `oldIndexSHA256` against an immutable or
otherwise authenticated predecessor and require the current index to be the
exact permitted intent successor. Verify `previousProgressSHA256` by accepting
only the recorded predecessor or a proven monotonic merge that preserves every
previous acknowledgment and changes only authorized pending entries. Add
cross-UUID replay/substitution tests with two simultaneous pending receipts and
altered old-index/progress hashes.

## Reviewed controls without findings

The frozen code uses descriptor-relative file operations, `O_NOFOLLOW`, owner
and mode checks, hard-link rejection, bounded file reads, file-identity
revalidation, exclusive immutable publication, fsync-backed writes, strict UUID
and digest syntax, and direct `receipts/<UUID>/<digest>.json` lookup. Owner-lock
handles are held across custody-sensitive mutations and released by Swift
lifetime/defer paths. Reviewed retirement and cleanup paths do not delete the
R4 immutable origin/class/left/receipt/source/install authority. Reservation
receipts contain hashes, classifications, and optional departure evidence, not
model payloads, secrets, or full primary records. No separate path traversal,
symlink/hard-link, deletion-protection, owner-handle leak, or sensitive-data
exposure finding was identified in the frozen scope.

These controls do not cure the state-machine and lineage findings above.

## Verification evidence and limits

The audit recomputed all frozen hashes with `shasum -a 256`, traced every R4
reservation state transition and recovery entry in the six source files, and
reviewed the three frozen test files against the approved adversarial matrix.
The focused command below passed during this audit:

```text
cd phase3-binary
swift test --filter ModelCatalogTransactionReservationMigrationTests
```

Result: 4 tests executed, 0 failures. These tests cover selected crash
boundaries and phase shapes, but do not exercise the four adversarial cases in
this report. The implementation report records 79 targeted tests passing and
explicitly leaves broader package, post-c944, Xcode, and combined final gates
pending; those reported runs were not treated as proof against the findings.

## Security disposition

R4 remains blocked. Acceptance requires correction of R4-SEC-H1,
R4-SEC-H2, R4-SEC-M1, and R4-SEC-M2, new regression evidence for each hostile
case, refreshed frozen hashes, and a new independent security review of the
complete replacement diff. The gate may pass only at 0 CRITICAL, 0 HIGH, and 0
MEDIUM.
