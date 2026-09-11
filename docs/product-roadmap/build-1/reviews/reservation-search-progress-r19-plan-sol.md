# Build 1 reservation search progress R19/R25 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: exact R19 plan and R25 test specification at reviewed commit
`2904e74f3393e25b3ee9856a45a2febc77f0d7c2`, inspected independently against
the R18 findings, the dirty R4 Swift implementation, the historical Build 1
base, and current `origin/main`. No source, test, SPEC, deployment, or release
work was authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 10 High, 3 Medium, 0 Low.**

R19 successfully withdraws the infeasible custom carrier/B+ tree design,
produces executable SQLite DDL, restores a valid SHA-256 continuation shape,
and introduces a credible root-owned custody boundary. The implementation gate
nevertheless remains closed. The authoritative schema cannot represent the
fixed transition predecessor, has no reachable allocation path for a new
source row, and does not close the abort/retry graph. Appendix B freezes labels
but not their effects, while the required atomic incumbent/replacement switch
cannot fit the plan's eight-row mutation ceiling. Bootstrap recovery loses its
random candidate name before B6 and conflicts with the declared SQLite open,
journal, and sibling rules. GC can strand a candidate permanently in
`checking`, and the privileged daemon has no closed rule for locating the
provider's configurable staging source. These are feasibility and trust-boundary
failures, not missing test polish.

## Frozen inputs and independent checks

The requested artifacts and revisions were recomputed:

| Input | SHA-256 / revision |
|---|---|
| R19 plan | `bab5195f99d937b511b34e8fd3378d620480d670dda59f24f2306ccb848f179c` |
| R25 test specification | `a262e1be9717a49d6d26abc8f81b5463442aeca7979f56b003e8485dffbd7daf` |
| Reviewed commit | `2904e74f3393e25b3ee9856a45a2febc77f0d7c2` |
| Actual historical Build 1 base | `914f7cafcdbcfc1805a10f4f34167218341d5587` |
| Current `origin/main` | `1d2c930bad81704dd0acc0322226725d8b64aceb` |

The long historical-base hash supplied to the reviewer,
`914f7caf9c1bd470f7e9b22eb367f80bd9d3f834`, is not a repository object. The
unambiguous short revision `914f7caf` resolves to the value in the table.
BYOM slice 5 remains separate and unmerged, so it was not treated as landed.

Independent Appendix A extraction produced 22 normalized SQL lines, 21
non-internal SQLite objects (14 tables and 7 indexes), schema digest
`79a8230e95296628f683fb840de9c78841f2af3753b951262d72306b0c07dc75`,
and a clean `foreign_key_check` on SQLite 3.53.4. Appendix B expands to 174
unique row names and 320 unique fixed names. Under the eight-field grammar and
section 5 state/charge rules, the 494 LF-terminated lines are 33,836 bytes with
digest `9ded7d3e8574bf324b417bc4fde86d9017f62c9c7d36e43fa16e3f1fc115e63b`.
The arithmetic is correct: `174*1024+320=178,496` semantic slots and
`522*1024+960=535,488` selected commits.

The dirty implementation is still the R4 JSON/sidecar authority. In
`ModelCatalogTransactionRetention.swift`, `initializeRetention` and
`captureIndexReceipt` select `format.json` plus `active.json`, while
`reserveOperation` scans active rows and allocates a new UUID-backed row.
`DurableModelArtifactStore.gcInactive` still enumerates directories and calls
`removeItem`. No R19 database, tuple codec, SQL transition engine, custody
daemon, or SQL GC is present. There are 165 direct legacy sidecar/name matches
across seven `ModelCatalogTransaction*.swift` files, in addition to direct
adoption callers in `MacProviderCLI.swift` and `AutotuneRecommend.swift`.

## Critical (0)

None.

## High (10)

### R19-PLAN-H1 — fixed transitions have no authoritative predecessor state

**Severity:** High. **Confidence:** High.

**Evidence.** Section 5 assigns fixed ordinal `n` the edge `fixed-n ->
fixed-(n+1)` and begin must validate the exact domain predecessor
(`R19:364-388,486-493`). Appendix A has no fixed-state singleton or other field
that stores this value. `protocol_meta.state` is limited to
`bootstrap|ready|protected`; `gc_meta` contains only rounds. `operations`
stores the caller's expected string but cannot prove it against selected
domain state. The 320 fixed labels also span unrelated source, merge, tree,
verification, materialization, and recovery workflows, yet the grammar makes
them one global linear sequence.

**Consequence.** A fixed begin either trusts the caller, derives state by an
unreviewed scan of prior operations, or invents a new state row. It cannot
implement the promised predecessor CAS, exact replay, or independent fixed
operations from Appendix A. R25-04 has no executable legal-predecessor oracle.

**Required correction.** Add a reviewed fixed authority schema and complete
state machine. Define whether fixed entries are one linear migration, separate
workflow instances, or repeatable scoped operations; bind each operation to
the stored predecessor and successor in the same transaction. Regenerate the
registry, capacity arithmetic, crash cases, and DDL from that decision.

### R19-PLAN-H2 — no post-bootstrap path can allocate a new source row

**Severity:** High. **Confidence:** High.

**Evidence.** B4 inserts exactly the R4 rows observed during migration
(`R19:324-335`). A row-scoped `operations.source_row_ordinal` must already
reference `source_rows`; fixed operations require that column to be null
(Appendix A `operations`). No reviewed transition allocates a row, assigns its
ordinal, inserts its four evidence references, and initializes `row_state`.
This is required by the current executable path:
`ModelCatalogTransactionRetention.swift:400-470` scans for a reusable row and,
when none exists, creates a new transaction UUID and publishes it. Catalog
reads call that path through `ModelsSubcommand.swift:1315-1339`.

**Consequence.** A clean migration with R=0 cannot create its first provider
operation. A migration with existing rows can never grow beyond that snapshot.
Implementing allocation would require an unnamed mutation outside the claimed
`174R+320` closed graph or a new operation shape not reviewed here.

**Required correction.** Define a directly addressable free-row allocation
authority, exact ordinal selection/CAS, operation scope, evidence publication,
row-state genesis, charge and crash recovery. Include empty-store, concurrent
first allocation, 1,023/1,024/1,025, and replay vectors and update the lifetime
capacity formula.

### R19-PLAN-H3 — the abort/retry graph has no legal entry restoration edge

**Severity:** High. **Confidence:** High.

**Evidence.** Abort slot zero requires the exact predecessor
`coarse-A1-or-A2-and-abort-generation-g`; later slots advance only through
`row-abort-g-1...8` (`R19:486-499`). No normal registry row produces the slot
zero predecessor string, and no abort row restores a normal fine state. The
prose says an "explicit product action" restores A1/A2 and increments the
generation in a preceding terminal transition, but Appendix B contains no such
edge. R25 simultaneously rejects abort-to-normal edges and requires generations
0...7 to retry (`R25:107-124,188-200`).

**Consequence.** The first abort cannot be entered from the normal graph, and a
completed abort cannot legally retry. An implementation must mutate
`row_state.fine_state`, coarse state, or abort generation outside Appendix B,
invalidating replay, accounting, and ninth-failure protection.

**Required correction.** Publish the complete normal-to-abort and terminal-
abort-to-retry/protected transition table, including exact coarse/fine values,
counter updates, charge disposition, registry ordinals, and legal cancellation
points. Make R25 assert reachability rather than testing isolated rows on
fabricated predecessors.

### R19-PLAN-H4 — Appendix B closes names but leaves semantic effects undefined

**Severity:** High. **Confidence:** High.

**Evidence.** Every generated registry line contains only scope, ordinal, name,
from/to strings, charge rule, zero payload, and a maximum row-change count
(`R19:463-480`, Appendix B). It does not specify the exact affected tables,
columns, old/new values, required evidence kind, external-intent branch,
catalog/custody relationship, exact change count, or filesystem action for any
of the 494 entries. Section 4 says progress applies "the one named semantic
transition" and that `total_changes` equals a registry-generated expected
count, but that count/effect is absent from the registry (`R19:364-410`). R25
asks an independent implementation to execute every entry and generate its
economic rule, which would require human interpretation of names.

**Consequence.** Production and the purported independent oracle can implement
different mutations while sharing the same registry digest. The digest does
not commit to the behavior whose safety and economics the plan claims, so the
R18 codec-closure finding is not fully resolved.

**Required correction.** Add a machine-readable semantic manifest covered by
`registry_sha256`. For every entry, freeze exact preconditions, DML, external
authorization/evidence, coarse/fine state update, charge equation, expected
SQLite change count, idempotent replay result, and protection branch. Generate
production dispatch and independent completeness checks from that artifact.

### R19-PLAN-H5 — atomic replacement exceeds the mandatory eight-row mutation ceiling

**Severity:** High. **Confidence:** High.

**Evidence.** R19 requires an incumbent active binding and replacement pending
binding to switch atomically, retiring the incumbent and activating the
replacement (`R19:628-651`; R25-06). Under Appendix A and section 4, the
minimum progress transaction changes: transition insert (1), operation update
(2), incumbent released custody event (3), incumbent `artifact_current` (4),
incumbent binding to released (5), replacement active custody event (6),
replacement `artifact_current` (7), replacement binding to active (8), and
`protocol_meta.generation` (9). Section 4 and R25 reject a ninth row change
(`R19:403-410`; `R25:115-118,135-140`).

**Consequence.** The required switchover cannot be both atomic and conformant.
Dropping either current-head update leaves section 6's selected custody head
false; splitting the work exposes a partial switchover and violates incumbent
preservation.

**Required correction.** Redesign the binding/current-head representation or
review a larger exact mutation bound. Freeze the literal SQL statement order
and crash/replay states for replacement, and rerun page/WAL/change-count
measurements with the new maximum.

### R19-PLAN-H6 — a pre-B6 bootstrap candidate cannot be rediscovered without forbidden enumeration

**Severity:** High. **Confidence:** High.

**Evidence.** B1 creates
`v2-bootstrap/<migrationUUID>/catalog-state.sqlite3.tmp`, but the selected R4
authority does not record that random UUID. The UUID enters the v5 fence only
after the candidate has moved to the fixed final path (`R19:274-312,320-348`).
R19 forbids directory enumeration as authority, while R25 kills the process at
every B1-B5 boundary and requires the exact candidate to resume
(`R25:61-79`).

**Consequence.** After process death before B6, a new process has no direct name
with which to open the candidate. It must enumerate/guess, leak orphaned
candidates, or start another random migration. The required deterministic
resume and unequal-candidate protection cannot be implemented from selected
state.

**Required correction.** Use a deterministic source-bound bootstrap path, or
atomically select a bounded candidate reference in existing authority before
creation. Define collision, stale-candidate, and multi-process rules and test
restart without directory enumeration.

### R19-PLAN-H7 — bootstrap cannot satisfy the declared SQLite connection and sibling contracts

**Severity:** High. **Confidence:** High.

**Evidence.** Section 2.1 says every connection uses
`READWRITE|FULLMUTEX`, sets/verifies WAL, and permits only main/WAL/SHM siblings
(`R19:72-112`). B2 must create a new database in DELETE mode, which requires
`SQLITE_OPEN_CREATE`; B7 writes the ready transaction before converting the
final database from DELETE to WAL (`R19:320-342`). That ready commit can create
`catalog-state.sqlite3-journal`, a sibling the contract calls unknown. R25
kills at journal and WAL-conversion boundaries but also requires unknown names
to reject (`R25:70-79`).

**Consequence.** A conforming bootstrap cannot open/create its database under
the stated flags. A crash during the B7 rollback-journal commit can leave a
candidate that the stated sibling validator must reject rather than resume.

**Required correction.** Freeze separate bootstrap and selected-connection
profiles, including exact flags, journal modes, temporary sibling allowlist,
recovery ordering, and the point each profile becomes authoritative. Prefer
conversion/checkpoint before the ready commit if that closes the journal
window; prove every crash state against the literal name set.

### R19-PLAN-H8 — the SQLite open path omits the plan's own no-follow protection

**Severity:** High. **Confidence:** High.

**Evidence.** R19 requires descriptor and no-follow pathname identity on every
connection (`R19:72-74,314-318`) but explicitly specifies only
`SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX` (`R19:110-112`). The platform SDK
exposes `SQLITE_OPEN_NOFOLLOW`; it is absent. Existing `AutotuneDB.swift:95-103`
opens a pathname with `sqlite3_open_v2` and likewise does not provide an
openat-bound VFS. SQLite also derives WAL/SHM sibling names internally. R25
expects no-follow open and symlink race evidence but supplies no implementation
contract that can produce it.

**Consequence.** Validation and SQLite open are separate pathname operations.
The selected database or a path component can be exchanged between them, and
the plan has not closed how main/WAL/SHM are bound to the validated directory.
This violates the stated authority boundary before any higher-level digest
check runs.

**Required correction.** At minimum require and verify
`SQLITE_OPEN_NOFOLLOW`; define how ancestor identity and SQLite's auxiliary
files remain bound across open and mutation. If a custom VFS or a locked/private
directory invariant is required, make it an explicit reviewed implementation
slice with race tests instead of inheriting the pathname-only AutotuneDB
precedent.

### R19-PLAN-H9 — a crash after GC claim permanently strands `checking`

**Severity:** High. **Confidence:** High.

**Evidence.** A GC invocation first commits the candidate and event as
`checking`, closes SQLite, then starts filesystem work (`R19:653-675`). The
schema and prose say only `queued` and `deleting` are selectable
(`R19:545-553`, Appendix A `idx_gc_fair`). No PID, time, lease, or recovery
owner is authority. R25 kills at every result/event/commit boundary and expects
the selected reverse-depth prefix to resume (`R25:203-231`).

**Consequence.** Death immediately after the checking commit leaves no indexed
work item that a later invocation may claim. The artifact remains permanently
busy/ineligible without a typed protected transition, defeating bounded GC,
fairness, replacement, and crash recovery.

**Required correction.** Define a restart-safe claimed state: make `checking`
deterministically selectable with the same helper UUID/result path, or eliminate
the durable pre-child claim and use a different CAS. Specify concurrent
reclaimer behavior and kill/restart tests for every interval before and after
child spawn/reap.

### R19-PLAN-H10 — the privileged daemon cannot locate a staging source under the closed request contract

**Severity:** High. **Confidence:** High.

**Evidence.** The custody request contains only operation, model, release,
artifact digest, and UUID and explicitly cannot contain a path or FD
(`R19:566-587`). C0 nevertheless requires a user-staging source. The plan
defines paths only beneath the daemon's configured custody root, not the source
root. Current code allows the provider store to be relocated by
`MACPROVIDER_MODEL_ARTIFACT_ROOT` (`DurableModelArtifactStore.swift:11-20`) and
passes concrete staging URLs to `adoptVerifiedStaging` (`MacProviderCLI.swift:
1056-1061,1092-1097`). R19 does not bind that configuration or transaction
staging path into authenticated XPC state.

**Consequence.** The daemon must guess a user path, accept an unreviewed path,
or ignore supported relocation. Guessing can copy the wrong same-digest/name
candidate or cross an unreviewed mount; accepting a path reopens the arbitrary-
path privileged confused-deputy boundary the plan says is closed.

**Required correction.** Define one daemon-approved source namespace and an
unforgeable source reference derived from the authenticated UID plus selected
transaction authority. Specify behavior for the environment override,
non-console/headless provider accounts, mount boundaries, and stale/replaced
staging. Add authenticated positive and cross-user/configuration negative XPC
vectors.

## Medium (3)

### R19-PLAN-M1 — lifetime store growth is not bounded by the printed capacity formula

**Severity:** Medium. **Confidence:** High.

**Evidence.** `semanticSlots` bounds only `operations` and their three
transitions (`R19:414-429`). `evidence_objects`, `verification_chunks`,
`custody_events`, and especially retryable/quantized `gc_events` are append-only
without a per-artifact or global row ceiling. Section 8 advances an event on
every quantum and recovery result; no pruning/compaction contract exists.
R25-05 executes semantic slots but does not require a lifetime maximum for
these other authorities.

**Consequence.** A legal workload can reach the 512-MiB limit before the
advertised slot ceiling, after which GC itself may be unable to record progress
or protection. The plan has a storage failure response, but not a bounded
metadata-store proof.

**Required correction.** Add analytical and measured maxima for every table,
including custody/verification/GC retries and indexes, or define authenticated
compaction/checkpoint rules that preserve replay evidence. Include first-over
tests and reserve enough write headroom for terminal protection/GC completion.

### R19-PLAN-M2 — the two new external tuple codecs still contain scalar/default ambiguity

**Severity:** Medium. **Confidence:** High.

**Evidence.** Both codecs declare `daemon_protocol_version=1` but never assign
it a tuple scalar tag. "Counts are u63" and "cursors and counters are u63" do
not classify a protocol version (`R19:221-238,253-269`). The path digest uses
`path.count` without saying byte count despite paths being byte blobs
(`R19:151-195`). `gc_result_v1` says after-root identity is non-null only for
progress/protected and null when the child is unreaped, but R25 asks only for
generic illegal-null rejection rather than a complete outcome/null truth table.

**Consequence.** Swift and the independent Python codec can choose different
tags/preimages while both plausibly follow the prose. This contradicts the
no-human-default acceptance rule.

**Required correction.** Provide a literal per-column type/null/digest table
for both codecs and the custody-entry transcript. State that path length is raw
byte length and freeze the complete phase/outcome/root-identity matrix with
golden bytes and digest values.

### R19-PLAN-M3 — the phased implementation does not map the replacement authority to current Swift ownership and callsites

**Severity:** Medium. **Confidence:** High.

**Evidence.** The code grounding names four broad anchors, while current R4
authority is distributed across at least seven transaction source files with
165 direct sidecar/name uses. `initializeRetention`, `captureIndexReceipt`,
`recaptureIndexReceipt`, and `reserveOperation` have callers in archive,
binding, evidence, migration, read, and action construction paths. Adoption is
also called directly from `MacProviderCLI.swift` and `AutotuneRecommend.swift`.
R19's seven implementation slices (`R19:750-760`) do not state API ownership,
adapter boundaries, cutover order, dual-read prohibition, or the exact files
and symbols retired in each slice.

**Consequence.** A slice can compile while leaving an active `active.json` or
user-owned adoption path that bypasses the SQLite/custody authority. Reviewers
cannot distinguish intentional compatibility reads from a second mutable
authority, and per-slice tests do not prove all executable entrypoints moved.

**Required correction.** Add a code-grounded migration matrix for every public
store API and direct sidecar/adoption callsite. For each slice, name the owner,
new interface, compatibility behavior before/after B8, forbidden legacy writes,
and a static test/search proving no bypass remains.

## Low (0)

None.

## R18 finding disposition

| Prior finding | R19 result |
|---|---|
| H1 five mutations funded as three | **Partially closed.** Begin/progress/finish is literal, but H4/H5 show the effects and row ceiling are not executable for required replacement. |
| H2 impossible carrier packing | **Closed by deletion.** No carrier is emitted. |
| H3 illegal bootstrap controls | **Closed in schema shape.** Bootstrap needs no operation rows, but H6/H7 block crash-safe execution. |
| H4 unreachable pending state | **Reopened in new state graphs.** H1/H3/H9 identify fixed, abort, and GC states without reachable authority/recovery edges. |
| H5 incomplete codec | **Partially closed.** DDL/tuple rules are much stronger; H4 and M2 retain semantic and external-codec defaults. |
| H6 invalid SHA continuation | **Closed in plan.** u32 words, count/tail congruence, IV, padding, and finite tests are explicit. |
| H7 receipt not addressable | **Closed in the selected schema.** Custody evidence has direct path, content, and full identity. |
| H8 same-owner freshness race | **Closed in principle, qualification pending.** Root ownership plus `SF_IMMUTABLE` is the correct class of boundary; H10 blocks the executable source handoff. |
| H9 mutable/unbounded GC index | **Partially closed.** SQLite indexes the current candidate, but H9/M1 leave crash recovery and lifetime growth open. |
| M1 blocked call outlives deadline | **Closed as a truthful qualification rule.** The child deadline and uninterruptible-I/O failure state are explicit, subject to H9's parent-crash recovery gap. |

## Gate decision

The reviewed R19/R25 revision does **not** meet the mandatory plan gate. Swift,
SPEC, test, custody-daemon, or migration implementation must not start from
this revision. Revise the normative artifacts, recompute their exact hashes,
and obtain a fresh independent native GPT-5.6 Sol review with zero Critical,
High, and Medium findings before implementation.
