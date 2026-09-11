# Build 1 reservation search progress addendum R22

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R22 replaces R21 as the reservation, retention, custody, and garbage-collection
design candidate. It is reviewed with test specification R28. R22 preserves
R21's deletion of the custom carrier/B+ tree design, the finite SHA-256 oracle,
the root-owned custody boundary, direct evidence references, A1/A2-only refund,
A3+ forward completion, and the physical qualification gate. Every conflicting
R21 schema, count, state, bootstrap, SQLite-open, registry, GC, source-handoff,
or migration statement is withdrawn.

The frozen failed-review input is
docs/product-roadmap/build-1/reviews/reservation-search-progress-r21-plan-sol.md
with SHA-256
176d16e59e897f5aef94afa258e04e4ca32ca1e2b64f1964b92b20fdfa5468e1.
The superseded R21/R27 artifact hashes are
719d8ce73b3152ba885528fd9ec8edcb2e46e1fd1fd44eb6c12a07fa6035429d and
91ac7a9cc2f978261e18d01f3230a7c4e30332d977d82a2c3b6c16f7fde35e8b.
The worktree contains unrelated Build 1 implementation work. R22 changes no
source, test, SPEC, release, deployment, or operator-secret file.

The source inventory for this revision was taken at worktree HEAD
`3ab079f7d2c9d8522546c59e3857bdb4d1f30017` with fetched `origin/main`
`c123ae2d2d08053612d940b3077994f7c4d709d7`. Dirty source was inspected as
working-tree evidence and is not asserted landed.

## 1. Authority and code boundary

The selected authority remains one SQLite database at:

~~~text
ModelTransactions/.retention-v2/.reservation-migration/retirement/v2/catalog-state.sqlite3
~~~

The v5 format fence remains:

~~~text
ModelTransactions/.retention-v2/format.json
~~~

Before the v5 fence is durably selected, the existing R4 format/active-index
and sidecars are the only authority. After selection, only the R22 database is
authority. No runtime dual read, fallback, reconstruction, sidecar write,
directory scan, mutable selector, custom carrier, lease file, or promoted root
is permitted.

Current implementation ownership was reinspected. The R4 authority is spread
across ModelCatalogTransactionRetention.swift,
ModelCatalogTransactionReservationMigration.swift,
ModelCatalogTransactionMigration.swift, ModelCatalogTransactionEvidence.swift,
ModelCatalogTransactionBindings.swift, ModelCatalogTransactionArchive.swift,
and ModelCatalogTransactions.swift. Direct artifact adoption is called by
MacProviderCLI.swift and AutotuneRecommend.swift; DurableModelArtifactStore.swift
owns current user-space adoption and enumerating GC. AutotuneDB.swift proves
only that SQLite3 is already linked; its pathname open is not sufficient for
R22.

SPEC-001 and SPEC-044 must be amended and approved before source implementation.
R22 grants no model identity, pricing, admission, settlement, reward,
enforcement, deployment, release, or production authority.

## 2. SQLite file and open protocol

### 2.1 ABI-conforming directory-confined VFS

R22 requires a complete `MacProviderDirectoryVFS`, not a shim over SQLite's
stock unix VFS. It uses only public `sqlite3_vfs`/`sqlite3_io_methods` version-3
ABI. Registration captures a validated retirement-directory FD in a process
registry and assigns one unguessable process-local VFS name; SQLite receives the
synthetic absolute main name
`/__macprovider_catalog_v5__/catalog-state.sqlite3`. `xFullPathname` accepts
only the configured logical input token and returns that exact absolute name.
`xOpen`, `xAccess`, and `xDelete` accept only that main identity, its documented
`-journal`, `-wal`, and `-shm` suffixes, or the qualification-only null-name
TEMP_DB case below. They map suffixes to byte-exact leaves and use only
`openat`/`fstatat`/`unlinkat` on the captured FD. No stock VFS file method or
pathname open is called after registration.

The local `sqlite3_file` owns the FD and implements every version-3 method:
`pread` with zero-fill/SHORT_READ, checked `pwrite`, `ftruncate`, `fsync` plus
`F_FULLFSYNC` for FULL, `fstat`, sector/device characteristics, and file-control
opcodes required by the pinned SQLite build. `xFetch` always returns null and
`xUnfetch` is a no-op, forcing SQLite through checked reads. The VFS implements
SQLite's documented pending/reserved/shared byte-range locks with `fcntl`; a
process-global inode registry retains one master FD until the last SQLite file
closes so POSIX close semantics cannot discard sibling locks. The same registry
serializes in-process handles and rejects fork-generation reuse. `xShmMap`
opens only the mapped SHM leaf with `openat`, bounds/truncates and `mmap`s exact
regions; `xShmLock` combines the registry mutex with matching `fcntl` ranges;
`xShmBarrier` is a sequentially consistent fence; `xShmUnmap` unmaps and only
deletes after the last local mapping and exclusive recovery authority. Random,
time, sleep, dynamic-library, access, and current-time VFS methods delegate only
their non-filesystem operations to the registered parent VFS.

The captured directory and every opened leaf are revalidated for device, inode,
owner, mode, link count, regular-file type, and ancestor identity before and
after recovery, checkpoint, commit, and delete. Main creation is
`O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC` mode 0600 only when SQLite supplies
CREATE and openat first returned ENOENT. Existing files omit CREATE; O_TRUNC is
never used. WAL writes also enforce section 9's hard byte limit.

A throwaway `/tmp` prototype compiled against the Xcode public header before
plan review must prove the actual callback flow: SQLite passes the synthetic
absolute result of `xFullPathname` to main `xOpen` and appends only documented
journal/WAL/SHM suffixes. Plan approval still requires the local lock/SHM VFS to
pass applicable upstream SQLite unix locking, WAL, crash, fork, short-read,
FULLFSYNC, and malformed-name tests on macOS. Prototype compilation alone is
feasibility evidence, not security qualification.

### 2.2 Runtime and offline qualification profiles

Bootstrap alone uses READWRITE|CREATE|FULLMUTEX|NOFOLLOW and DELETE journaling.
After schema/import it converts to READWRITE|FULLMUTEX|NOFOLLOW, WAL mode, with
CREATE absent. Runtime permits only main/journal during DELETE and main/WAL/SHM
during WAL. Missing selected main is an authority failure.

Every runtime connection sets page_size 4096 before schema construction,
synchronous FULL, foreign_keys ON, trusted_schema OFF, recursive_triggers OFF,
secure_delete ON, busy_timeout 0, wal_autocheckpoint 4096,
journal_size_limit 67108864, max_page_count 131072, application_id 1297109587,
and user_version 22. It enables SQLITE_DBCONFIG_DEFENSIVE, disables extensions,
and requires SQLite 3.37 or later.

`VACUUM` is forbidden on authority databases. The maximum-shape tool first
closes and checkpoints its generated non-authoritative fixture, copies it by
verified FD into an isolated mode-0700 qualification directory, and registers a
separate VFS name with `qualificationVacuum=true`. Its authorizer is a closed
state machine: only while preparing the embedded byte-exact SQL `VACUUM` may it
permit exactly one SQLITE_ATTACH whose first argument is empty; every named
ATTACH, second ATTACH, schema-changing statement, or invocation on an authority
identity is denied. In that state only, one null-name
SQLITE_OPEN_TEMP_DB|SQLITE_OPEN_DELETEONCLOSE call creates fixed leaf
`qualification-vacuum.tmp` with openat O_EXCL, immediately unlinks it, and uses
the retained FD. The flag is cleared before stepping finishes and the copy is
destroyed after measurements. Both the reachable as-grown production fixture
and the offline VACUUM copy must meet section 9; VACUUM is never used to make
the runtime bound pass.

Full integrity_check and foreign_key_check run after candidate recovery, WAL
recovery, startup, and maintenance while mutation readiness is unavailable.
Every transaction verifies schema/registry/manifest digests, pragmas, affected
FKs, statement changes, counters, and WAL reserve.

## 3. Deterministic bootstrap and selection

B0 freezes the selected R4 `active.json` bytes and every directly referenced
primary/origin/class/lineage file under the old lock. It derives `bootstrap_id`
and the candidate path exactly as R21, with tuple domain names advanced to R22.
All SHA operands are raw 32-byte values; source rows encode row ordinal,
transaction UUID, model, release, and the complete four evidence tuples in
active-index order. No enumeration, UUID, timestamp, JSON reserialization, or
host integer enters the identity.

The final `bootstrap-intent-v1` remains the first durable object. Its R22 tuple
binds bootstrap/source/schema/registry/manifest/directory digests, application
ID 1297109587, page size 4096, and schema version 22. Prefix-resumable temp write,
fsync, rename, and directory fsync precede main creation.

B3 creates Appendix A atomically. B4 imports exactly one source row per
transaction. Before BEGIN IMMEDIATE it direct-validates the next source tuple
at `protocol_meta.bootstrap_row_cursor`, looks up its four evidence SHAs, and
selects one of 16 literal missing-evidence masks. Existing evidence must equal
all canonical columns; each missing bit inserts that role's row in role order.
The transaction then inserts the typed source-owner row binding all four named evidence columns, the source row,
and row state, updates the
matching row slot free→occupied, and CASes meta cursor/counts/generation. Exact
changes are `5+popcount(mask)`, at most 9.
Duplicate binding, cursor skip, unexpected row, changed source bytes, wrong
mask, zero/two-row CAS, or count mismatch rolls back. A crash commits either
cursor n or n+1, never a partial row.

Destructive cleanup is ordered after recoverable format changes:

1. B5 commits `b5-import-complete`, closes, recovers any hot journal, runs both
   integrity checks, and proves the rollback journal absent while intent remains.
2. B6 converts to WAL, commits `b6-wal-ready`, checkpoints TRUNCATE, closes, and
   proves main plus only recoverable WAL/SHM while intent remains.
3. B6a deletes the exact matching intent and fsyncs the candidate directory.
4. B7 renames candidate to final, fsyncs the bootstrap parent, opens final
   directly, commits ready plus exact format SHA, and checkpoints.
5. B8 prefix-writes/fsyncs `format.json.tmp-v5`, renames it over format.json,
   fsyncs `.retention-v2`, reopens final, and releases the old lock. Only this
   final parent fsync selects V5.

The exhaustive directly addressed recovery states are:

| state | location/leaves | database predicate | next action |
|---|---|---|---|
| E0 | candidate empty | exact opened directory identity | publish intent |
| E1 | candidate prefix temp intent | byte-exact expected prefix, no main | finish intent |
| E2 | candidate final intent | exact intent, no main/journal | create main |
| E3 | intent+main, optional hot journal | zero valid header or zero/all Appendix-A objects | recover/run B3 |
| I(n), 0≤n<R | intent+main, optional hot journal | complete schema; meta cursor/counts exactly n; rows 0..<n complete and no row n | recover/run B4(n) |
| I(R) | intent+main, optional hot journal | every imported row/binding/counter exact | commit B5 |
| P5 | candidate intent+main, no journal | phase b5-import-complete | convert WAL |
| P6 | candidate intent+main, optional WAL/SHM | phase b6-wal-ready | checkpoint/delete intent |
| P6a | candidate main, optional WAL/SHM | phase b6-wal-ready, intent absent | rename final |
| P7 | final main, optional WAL/SHM; candidate absent; R4 fence | phase b6-wal-ready | commit ready |
| P7r | final main, optional WAL/SHM; R4 fence | state ready and format SHA exact | write temp format |
| P8p | final DB plus prefix temp format; R4 fence | temp is exact expected prefix | finish temp |
| P8f | final DB plus full fsynced temp format; R4 fence | exact bytes/hash | rename format |
| P8r | final DB plus exact V5 format; candidate/temp absent | parent-fsync durability unknown | fsync parent, reopen |
| S | same as P8r | parent fsync/reopen succeed | V5 selected |

At every state final is checked before candidate; both present protects. The
validator permits only the leaves listed for that state. A journal is recovered
and removed before leaving E3/I/P5; intent is never removed while DELETE
recovery remains. A crash after final rename is therefore P7, not an orphan.
Malformed headers, partial schema, cursor/row/count disagreement, unexpected
leaf, wrong prefix, identity drift, or mismatched final format protects without
deleting unknown data. Rollback can remove only an exact E0/E1 candidate; all
later recovery is forward-only.

## 4. Closed source-row and workflow state machines

### 4.1 Row slots and post-bootstrap allocation

Appendix A precreates exactly 1,024 row_slots. A slot is free, allocating,
occupied, exhausted, or retired. The partial index on free ordinals makes SELECT MIN
row_ordinal WHERE state=free an indexed operation. No directory or source-row
scan selects an ordinal.

The registry has one allocation template. Allocation uses the same exact
three-commit operation shape:

1. begin selects the lowest free ordinal, changes it to allocating, inserts the
   allocation operation, four external intents, the begin transition, and meta;
2. progress either (a) direct-validates the primary, origin, class, and
   lineage intents, inserts four evidence rows, source_rows and
   row_state, changes the slot to occupied, inserts progress, updates the
   operation, and meta, or (b) records pre-publication cancellation by inserting
   progress, setting cancel_requested, and updating meta without evidence;
3. finish inserts finish, closes the operation, and advances meta.

Progress initializes coarse state A2 and fine state row-normal-76. Ordinals
0...75 describe imported R4 construction proof and are never replayed for a
new R22 row. Cancellation after allocation begin but before progress takes the
allocation finish-aborted branch, records no source row/evidence, increments
`allocation_attempts`, and releases the A1 reserve. Attempts zero through six
return the slot to free; attempt seven selects exhausted permanently. This
bounds pre-progress cancellation at eight operations per slot. Cancellation
after progress uses the row A2 abort graph. An exact replay uses the same
operation UUID, slot, and allocation-attempt value;
different bytes or a different selected ordinal reject before external work.

The free-slot index and BEGIN IMMEDIATE make concurrent first allocation and
1,023/1,024 boundaries deterministic. The 1,025th returns catalog_full without
a write.

### 4.2 Fixed state

fixed_state contains exactly six rows: source, merge, tree, verification,
materialization, and recovery. Each stores its family-local cursor, fine state,
generation, and active/complete/protected status. Appendix B assigns every one
of the 320 fixed registry entries to exactly one family and a zero-based local
ordinal. A fixed begin joins registry family/local ordinal to the selected
fixed_state row; progress advances that row by exactly one. The six workflows
are independent and may interleave. An entry cannot be selected twice.

The family sizes and global ordinal ranges are source 32 at 0...31, merge 64 at
32...95, tree 32 at 96...127, verification 32 at 128...159,
materialization 32 at 160...191, and recovery 128 at 192...319. Bootstrap
initializes every family at local ordinal zero unless imported evidence proves
a later unique point. There is no caller-supplied fixed predecessor authority
and no single false 320-step cross-family chain.

### 4.3 Reachable abort and retry

A new row starts at A2,row-normal-76. A1 exists only in an allocation operation
before its progress commit and is aborted by that operation's terminal branch.
For a row, abort is legal only from A2,row-normal-76 before directory intent.
Abort generation g in 0...7 has eight exact registry steps.

Slot zero requires A2,row-normal-76,attempt_generation=g and changes the row to
A7,row-abort-g-1. Slots one through six advance row-abort-g-s to s+1. Slot
seven publishes the direct abort receipt and:
- for g 0...6, sets A2,row-normal-76 and increments both attempt_generation and
  abort_generation to g+1;
- for g 7, sets A8,row-abort-terminal, abort_generation 8, and permanently
  closes retry.

Thus the only abort-to-normal edge is the reviewed slot-seven retry edge. No
other abort state can enter normal work. A cancellation at A3 or later sets
forward-only and must reach A6 or protected with the admitted charge retained.
After the generation-seven slot-seven commit the row is terminal
A8,row-abort-terminal with abort_generation 8. A later abort request executes a
read-only `request-outcome-v1` rule registered in the semantic manifest. It
returns canonical tuple_v1 bytes containing row ordinal, transaction UUID,
abort generation 8, current catalog generation, the generation-seven ordinal-173
operation UUID and finish transition SHA, exact consumed/released/abandoned
charges, and literal outcome `retry_exhausted`. It performs no operation,
transition, evidence, receipt, refund, external effect, or database write.
Repetition is byte-identical while the selected generation is unchanged; a
retired or protected row returns its separate typed read-only outcome. No ninth
abort receipt is representable.

## 5. Exact mutation and semantic manifest

### 5.1 Three commits and exact DML templates

Every allocation, row, or fixed operation has exactly begin, progress, finish.
The `operations.open_slot=1` unique partial index admits exactly one open
authority mutation across all scopes. Begin increments
`protocol_meta.open_operation_count` from zero to one and reserves the
manifest's remaining WAL allowance. Finish clears `open_slot`, decrements the
count to zero, and releases the allowance. External work occurs only after a
durable begin and before progress validation.

One mutation unit has one authorization, three generation-CAS commits, and at
most 12 changed SQL rows in any commit. Begin binds maximum charge. Progress
assigns newly consumed bytes. Finish assigns the remainder exactly once to
released only for allocation-A1 or row-A2 abort, or to abandoned for A3+
protection. Terminal charge components equal the maximum. Replay changes zero
rows and returns the stored transition.

Appendix C is literal. A named special progress template **replaces** generic
progress in full; it is never composed with generic rows. The complete counts
are:

| template | ordered row effects | exact changes |
|---|---|---:|
| generic begin K=0 | operation, begin transition, meta/open/WAL reserve | 3 |
| allocation begin K=4 | operation, four intents, begin transition, row-slot CAS, meta/open/WAL reserve | 8 |
| generic progress E | progress transition, operation CAS, row/fixed-state CAS, E evidence, meta | 4+E |
| allocation success progress | progress transition, operation CAS, four evidence, source owner, source row, row state, row-slot CAS, meta | 11 |
| allocation cancel progress | progress transition, operation cancel CAS, meta | 3 |
| staging register progress | progress transition, operation CAS, row-state CAS, receipt evidence, typed receipt owner, staging-source insert, meta | 7 |
| custody verified/pending progress | progress transition, operation CAS, row-state CAS, root+receipt evidence, typed custody owner, custody event, custody-current, exactly one catalog insert-or-CAS, meta | 10 |
| initial activation progress | progress transition, operation CAS, row-state CAS, typed custody owner, active custody event, custody-current CAS, catalog-slot CAS, meta | 8 |
| replacement progress | progress transition, operation CAS, row-state CAS, two typed custody owners, incumbent event/current, replacement event/current, catalog-slot CAS, meta | 11 |
| generic finish | finish transition, terminal operation CAS, meta/open/WAL release | 3 |
| allocation aborted finish | finish transition, terminal operation CAS, allocating-row-slot CAS, meta/open/WAL release | 4 |

Each descriptor supplies its old predicates, setters, counter deltas, evidence
count, and charge delta. Statement changes must be exactly one, except the four
explicit evidence inserts, and total changes must equal the table. Zero or an
extra row rolls back. Initial activation and replacement are distinct templates;
null-incumbent branching inside one ambiguous template is forbidden.

### 5.2 Machine-readable registry expansion

registry_sha256 covers LF-terminated expanded lines with these fields:

~~~text
scope|global-ordinal|family|local-ordinal|name|
coarse-from|coarse-to|fine-from|fine-to|
effect-template|external-template|required-evidence-kind|
charge-rule|begin-changes|progress-changes-base|
progress-changes-with-incumbent|cancel-progress-changes|finish-changes|max-row-changes
~~~

semantic_manifest_sha256 covers the normalized Appendix C DML templates and
the exact mapping rules below. Production dispatch is generated only from the
expanded manifest. The independent oracle separately expands the same literal
grammar and compares all fields and both digests. Human defaults are forbidden.

The allocation line is:
allocation|0|allocation|0|allocate-row|free|A2|free|row-normal-76|
allocation|four-existing-source-evidence|source-set|allocation|
8|10|10|3|3|12.

Row ordinals 0...75 are imported-proof, coarse A2 to A2, fine n to n+1,
state-only, no external effect, zero charge, 3/4/4/4/3/12.
Ordinal 76 phase-A3-directory-intent is A2 to A3, state-only.
Ordinal 77 A3-directory-publication-receipt is A3 to A3,
publish-evidence/create-directory/custody-root/a3-directory and progress 5.
Ordinals 78...79 are A3 state-only. Ordinal 80 is A3 to A4 state-only.
For each A5 body, its intent ordinal changes A4 to A5 for primary and A5 to A5
thereafter; publication-receipt uses create-regular, the matching evidence kind,
a5-evidence, and progress 5; its other three entries are state-only.
Ordinals 101...106 are A5 state-only except prepared-adoption-record, which uses
staging-register/staging-source and progress 6. Ordinal 107 phase-A6 is A5 to
A6. Ordinal 108 activation-record uses custody-copy/custody-receipt, inserts two
direct evidence rows plus verified custody event/current and exactly one
insert-or-CAS catalog pending row, for progress 9. Ordinal 109 checkpoint-record uses
replacement-switch/catalog-custody and selects the standalone seven-row initial
activation or nine-row replacement template before the transaction. Together with the A3 receipt, four A5
publication receipts, prepared-adoption-record, and eight abort receipts, these
are exactly 16 external row entries. Every one of the 128 recovery-family fixed
entries uses legacy-inspect-readonly; all other fixed entries use none. Thus the
intent bound is exactly `32S + 16R + 128`, including four intents for each of
eight allocation attempts per slot.

Abort ordinals 110+8g+s use the graph in section 4.3. Slots 0...6 are
state-only. Slot 7 uses create-regular/abort-receipt/a1a2-release and progress
5. Fixed entries use their family ranges in section 4.2 and family-local fine
states n to n+1. Every one of the 128 recovery entries, without name or keyword
inference, uses exactly one `legacy-inspect-readonly` intent, validates only the
already selected legacy evidence reference, and inserts no evidence row. Its
counts are begin 4, progress 4, finish 3. Every other fixed entry uses `none`,
generates no intent, and has counts 3/4/3. The registry expander asserts exactly
128 recovery intents. Consequently the closed intent formula is
`32S + 16R + 128 = 49,280` at S=R=1,024. A recovery name cannot change the
mapping and cannot create a legacy object.

Charge rules are closed: zero; allocation reserves/releases the current
SPEC-044 lifecycle admission; A3-directory is exactly the selected directory
charge; A5-evidence is exact direct evidence byte length; adoption-lifecycle is
the SPEC-governed artifact delta; a1a2-release returns only unused pre-A3
reserve. SQLite page/WAL bytes are never economic bytes.

## 6. Catalog, custody, and serving representation

Generic immutable bytes remain in `evidence_objects`; four typed owner tables
make their semantic use non-substitutable while allowing one physical evidence
object to be referenced by multiple legitimate source rows.
`source_evidence_owners` binds the four named evidence roles to the complete
source tuple. `staging_receipt_owners` binds receipt evidence to source, artifact,
and creating row operation. `custody_evidence_owners` binds root plus receipt
evidence to source, artifact, custody generation, and the creating operation's
UUID, row, `row` scope, and registry ordinal. `gc_evidence_owners` binds result
or first-over-control evidence to the complete custody tuple, helper UUID, and
closed role. Each consumer uses one composite foreign key to its matching typed
parent; the parent uses scalar evidence FKs plus source/operation/custody FKs.
Fixed/workflow evidence has no typed parent and cannot satisfy any of these
authority references.

`custody_current` has one composite foreign key containing row, transaction,
model, release, artifact, custody generation, and event digest. A generation
above one carries `predecessor_generation=custody_generation-1` and one
composite predecessor FK. Catalog active and pending tuples include custody
generation and use that complete current-custody FK. GC candidate/event tuples
carry the same generation. A catalog binding digest uses domain
`macprovider-r22/catalog-binding-v1` over model, release, artifact, custody
generation, custody event, row, transaction, and creating operation; startup
and every serving/replacement/GC read recompute it. Any owner splice fails its
FK, and an arbitrary binding digest protects before use.

### 6.1 Revocable serving lifetime

The provider process never receives a custody lock FD. The root custody daemon
takes the per-artifact shared `flock`, creates a socketpair, and launches one
dedicated signed MLX worker for the request under the configured restricted
worker UID and process group. The trusted worker inherits one shared-lock duplicate and the daemon retains its
own duplicate and socket end until that exact worker has been reaped. Daemon
death therefore leaves the lock held by the supervised worker; provider death
does not affect lock ownership. The provider receives only the other
socket endpoint plus Appendix D's signed `serving_pin_v1`; it cannot fork/exec
the worker, send file descriptors, access custody paths, or duplicate the
shared lock. The worker sandbox denies `fork`, `exec`, `ptrace`, task ports, and
`SCM_RIGHTS`, and permits read access only to its selected custody root.

The daemon authenticates the provider XPC audit token and binds provider and
worker PID, pidversion, cdhash, boot-session UUID, request, selected catalog and
custody tuple, channel nonce, issue time, and continuous-clock deadline into the
pin. The sole XPC attachment is the provider socket. The first worker frame is
an exact 32-byte daemon nonce whose SHA is signed in the pin; the provider
requires one socket attachment, validates its peer, and consumes that nonce
before sending request bytes. An FD/message substitution closes the channel.
After pin acquisition the caller reopens a short SQLite snapshot and retries if
the active tuple or generation changed before the worker opens the model.

At the 15-minute continuous-clock deadline, cancellation, or provider loss, the
daemon stops new input, sends TERM to the recorded process group, waits one
second, sends KILL, and calls `waitpid` until the exact PID/pidversion/start-time
identity is reaped. Only then may it close the lock. A stopped or hung worker is
therefore terminable without recipient cooperation. Before daemon death it
persists a root-owned `serving-workers/<permit-uuid>.worker-v1` record containing
the signed pin digest and process identity. Launchd restarts the daemon; recovery
direct-opens each SQL-referenced serving record, validates boot session and
pidversion before signaling, kills/reaps the worker, and retains or reacquires
the lock. The worker also holds a parent-death pipe and self-terminates on EOF.
PID reuse or an invalid record quarantines the artifact.

A worker stuck in uninterruptible kernel I/O is not called expired: the daemon
retains the lock and record, marks host custody capacity unqualified, rejects
new serving/adoption, and requires verified reboot recovery. GC needs the
exclusive lock and cannot pass any live/recovering worker record. Duplicate FD,
stopped process, hung process, deadline race, daemon restart, and PID/audit-token
reuse are explicit R28 vectors. Physical qualification must show the supervisor
works for the supported MLX profile.

### 6.2 Directly addressable custody publication

The daemon creates these exact root-owned leaves from the already authorized
operation/artifact; no enumeration participates in recovery:

~~~text
custody-operations/<operation-uuid>.intent-v1
custody-operations/<operation-uuid>.intent-v1.next
custody-tmp/<artifact-hex>-<operation-uuid>.root-v1
custody-tmp/<artifact-hex>-<operation-uuid>.receipt-v1.tmp
artifacts/<artifact-hex>.root-v1
receipts/<artifact-hex>/<operation-uuid>.custody-v1
~~~

The canonical `custody_operation_v1` intent binds source receipt/token, full
source/operation tuple, artifact/manifest, exact temp/final path digests,
entry cursor, flag cursor, receipt-byte cursor, phase, and prior record SHA.
Prefix-write/fsync/rename/parent-fsync of the first intent precedes creation of
any temp object. Each phase update uses `.next`, exact predecessor SHA, rename,
and parent fsync. Only one custody operation may be open globally, so the
maximum uncommitted root-owned footprint is one bounded artifact, one receipt,
and two small intent leaves.

The closed states are C0 intent only; C1 copy cursor 0...4096 with exactly the
manifest prefix present; C2 complete first-pass tree fsynced; C3 hardening/flag
cursor 0...4096; C4 full direct recapture and second content pass; C5 receipt
prefix 0...exact length; C6a final root plus temp receipt; C6b final root and
final receipt; and C7 SQLite acknowledgment. At every state the daemon
validates the exact intent, directly opens the named leaves with no-follow
parent FDs, and either resumes the one successor or protects. Source drift
before C4 cancels by clearing only flags named in the intent and removing the
direct temp tree in reverse manifest order. No untrusted path is deleted.

Once either final rename occurs recovery is forward-only: a C6a replay
validates the final root, completes the receipt rename, fsyncs both parents, and
recaptures both; caller death or cancellation leaves an inactive complete
object for SQL acknowledgment/GC. The intent remains until the SQL custody
progress commit has inserted the exact root/receipt evidence and event, after
which C7 deletes it and fsyncs the operations parent. Reclamation is the same
bounded state machine under the global operation slot; it never scans a
directory or starts a second copy. R28 kills/reboots after every temp write,
entry copy, fsync, chmod/chown/flag, recapture, receipt prefix, both renames,
both parent fsyncs, and SQL acknowledgment.

## 7. Closed staging-source handoff

The canonical source remains
`~/Library/Application Support/Malibu/ProviderStaging/v1/<transaction-uuid>/`,
derived from the authenticated provider UID. The daemon accepts no arbitrary
path or caller-supplied directory FD. Registration binds provider UID, source
transaction/model/release/artifact/manifest, operation UUID/row, token, direct
source transcript, and exact `staging-receipt` evidence owner. The root-owned
receipt is directly addressed as
`staging-authorizations/<uid>/<transaction-uuid>.source-v1`.

The custody intent stores that closed staging reference before copying. The
receipt remains until C7 or audited prepublication cancellation; cleanup uses
that SQL/intent reference, never enumeration. A replacement, cross-user,
cross-volume, changed source, expired caller identity, mismatched operation,
or receipt-owner splice protects without adoption. An override source may be
copied into canonical staging by unprivileged preparation, but the daemon never
consumes the override itself.

## 8. Restart-safe bounded GC

Each checking quantum has a distinct, deterministic helper identity:

~~~text
UUID(first16(SHA256(tuple_v1(
  domain="macprovider-r22/gc-attempt-v1",
  artifact_sha256, custody_generation, custody_event_sha256,
  gc_lifecycle_generation=1, attempt_ordinal,
  checking_event_generation, start_phase, start_cursor))))
~~~

`attempt_ordinal` is 1...24 and `checking_event_generation` is the exact next
generation 2...49. The candidate checking CAS stores both plus the start
cursor/phase/helper, and its checking event carries the same tuple. Exact retry
therefore regenerates the same UUID; another quantum cannot reuse it. Appendix
D's result and deterministic path bind all inputs. A stale cursor, different
checking generation, or duplicate helper with different bytes protects without
deleting. Partial unique indexes enforce one checking helper and attempt per
artifact.

Enqueue is generation 1. Sixteen successful checking/result pairs and eight
failure checking/result pairs consume at most 48 more events, so normal work
ends at 49. Every result advances or terminates the exact stored checking tuple,
increments `result_count` once, and increments exactly one of successful or
failure counts. The daemon processes at most 256 entries, 8 MiB manifest/path
bytes, 1,024 syscalls, or six seconds per attempt. A killed child is reaped; an
unreaped kernel-I/O child selects `blocked-kernel-io`, retains custody, and
removes host qualification.

The first request beyond the legal attempt budget is one standalone
`gc-first-over-protection` transaction. It direct-publishes a canonical
`gc_first_over_control_v1` evidence object owned by the full GC/custody tuple
and deterministic control helper, inserts generation-50 `protected` with event
49 as predecessor, CASes the exact terminal candidate to protected, and CASes
protocol counters by evidence +1/event +1/generation +1. It does not change
`result_count`, success/failure counts, or `gc_meta`; exact replay returns the
same Appendix D control tuple with zero changes. The transaction is exactly
five changes. Generation 51, a second distinct control, wrong predecessor, or
counter mismatch rolls back. The evidence reserve includes one such row per
artifact.

GC never holds SQLite across daemon work. It acquires the exclusive custody
lock and proves no serving-worker record before any delete. The deterministic
result path is
`gc-results/<artifact-hex>/<attempt-ordinal>-<checking-generation>-<helper>.gc-v1`.
Every crash resumes through the stored candidate tuple and direct result path.
The lifecycle bounds remain 16 successful, eight failure, 24 results, one
control, and 50 events per artifact.

## 9. Bounded lifetime and emergency space

R22 has no custom carrier, packed slot, B+ tree, promoted root, or application
page codec. SQLite's reviewed upstream 4,096-byte page format is the sole
physical carrier. Logical row limits are enforced independently of physical
packing; no proof assumes a row count per page. The only physical claim is the
measured maximum-shape database/WAL bound below, on the pinned SQLite build and
supported APFS/macOS profile. A different SQLite version, page size, filesystem,
or hardware profile requires requalification rather than arithmetic reuse.

For R at most 1,024, the hard logical maxima are:

| object | maximum rows |
|---|---:|
| protocol_meta | 1 |
| transition_registry | 495 |
| fixed_state | 6 |
| row_slots | 1,024 |
| source_rows / row_state | R each |
| operations | 174R+8S+320, where S=1,024 slots |
| operation_external_intents | 32S+16R+128 |
| transitions | 3(174R+8S+320) |
| evidence_objects | 48R+128 |
| source_evidence_owners / staging_receipt_owners | R each |
| custody_evidence_owners | 8R |
| gc_evidence_owners | 25R |
| verification_state | R |
| staging_sources | R |
| custody_events | 8R |
| custody_current | R |
| catalog_slots | R |
| gc_candidates | R |
| gc_events | 50R |
| gc_meta | 1 |
| daemon open custody operation records | 1 |
| daemon serving-worker records | 32 |

At S=R=1,024 this is 186,688 operations, 560,064 transitions, exactly bounded
49,280 intents, at most 49,280 evidence objects, 35,840 typed evidence-owner
rows, 8,192 custody events, and
51,200 GC events. Every listed SQLite table and index is populated at its
maximum; the widened evidence owner indexes are part of the 448-MiB measured
fixture. Outside SQLite the daemon permits one directly addressed custody
operation and at most 32 serving workers. The 33rd worker rejects before spawn;
a quarantined unreaped worker keeps its one record through reboot recovery. The evidence ceiling is 48R+128: at most four source/allocation rows,
16 row-workflow rows, 24 GC result rows, four terminal/protection reserve rows
per source, and 128 bootstrap/fixed protection rows. Existing-evidence fixed
inspection adds no duplicate evidence row. Every cap is enforced before begin by protocol_meta counters and by
table-specific ordinal/generation CHECKs. `CatalogAuthorityV5` is the only code
allowed to prepare DML. It installs a SQLite authorizer that denies ATTACH,
DETACH, PRAGMA mutation after open, schema mutation after B3, triggers, views,
virtual tables, and extension calls. Every generated commit CASes the applicable
old counter values and increments all affected counters in its one protocol_meta
update. A counter mismatch or first-over value rolls back before external work.
The maximum-shape oracle compares COUNT(*) for every table with all counters and
the formulas after every crash/reopen. No verification history is
append-only: verification_state is one current continuation per row and is
deleted only in the same transaction that selects its custody receipt. GC and
custody generation first-over cases protect without exceeding their reserved
terminal row.

The main database remains at most 512 MiB. At least 16,384 pages (64 MiB) are
reserved for already-authorized terminal/protection and GC recovery; new begin
is rejected at 114,688 pages. The maximum-shape loader populates every table and
index at the exact caps using maximum-width values, then checks first-over
rejection for every counter, ordinal, generation, and index-bearing owner tuple.
Approval requires main plus indexes at or below 448 MiB.

WAL size is an enforced safety property, not a PRAGMA promise. The selected VFS
tracks the exact WAL leaf and refuses `xWrite` or `xTruncate` whose resulting
logical end exceeds 67,108,864 bytes, returning `SQLITE_FULL` before any byte
crosses the bound. It may read an inherited oversized WAL for recovery, but all
mutations remain disabled until a verified TRUNCATE checkpoint brings it below
the bound. `journal_size_limit` is cleanup guidance only.

Before begin, the sole authority connection proves no open operation, runs
`wal_checkpoint(TRUNCATE)`, requires `busy=0`, requires the WAL at most
16,777,216 bytes, and proves at least 134,217,728 filesystem bytes free. Short
serving snapshots have a two-second hard deadline and never span inference. The
manifest declares measured upper deltas: begin/progress at most 16 MiB each and
finish/protect/recovery/checkpoint at most 8 MiB each. Begin reserves the exact
remaining worst-case bytes in `wal_reserved_bytes`, capped at 48 MiB; each
commit uses `fstat` before/after and atomically decreases that reservation only
by a completed phase's declared allowance. The unique open-operation slot
prevents competing reservations. While it is occupied, only the selected
operation UUID may run progress, finish, or recovery; new begins, bootstrap,
maintenance, enqueue, and GC result commits reject. Standalone GC commits require
open_operation_count=0, wal_reserved_bytes=0, a busy=0 cutoff, and their own
measured 8-MiB allowance. A helper may finish externally while another operation
is open, but its directly addressed result waits without repeating work until
the slot clears. A delta above its allowance, checkpoint busy,
insufficient disk, VFS `SQLITE_FULL`, or reserve mismatch leaves the operation
open and enters its directly addressable idempotent recovery path; it never
starts a second external effect. The 64-MiB VFS cap remains absolute even with
an intentionally retained reader.

Qualification uses the pinned SQLite build and APFS profile to populate the
maximum shape, exercise every 12-row transaction, retain hostile readers, force
checkpoint failures, crash at every write boundary, and prove by `fstat` that
main, WAL, and recovery remain within their bounds. A different SQLite,
filesystem, page size, or larger legal schema reopens this gate.

## 10. Canonical scalar, null, digest, and reference registries

Appendix D defines `tuple_v1` without relying on R19. For database row digests,
every INTEGER is u63 except `cancel_requested`, which is bool; every TEXT is NFC
text; BLOB names ending `_uuid` are UUID; names ending `_sha256`, plus
`bootstrap_id`, are SHA; `relative_path` and `tail` are bytes. A schema column
matching zero or two rules fails construction. SQL NULL maps only to tuple null
and only where Appendix A permits it. A row identity is SHA-256 of tuple domain
`macprovider-r22/<table>` and every DDL column in order, with its own identity
column represented by null. This applies only to `evidence_sha256`,
`transition_sha256`, `custody_event_sha256`, and `gc_event_sha256`.

All other SHA targets are closed: bootstrap_id is the section 3 preimage;
source index/rows and format are the named exact bytes; schema, registry, and
semantic manifest are the normalized appendices; candidate-directory and every
identity field use the Appendix D file-identity tuple; path fields use the
Appendix D path preimage; content fields hash raw bytes; artifact and manifest
fields use SPEC-001; authorization hashes the manifest-expanded operation plus
all parameters/intents/charge; finish/prior/predecessor/current/last-event and
all `*_evidence_sha256` fields are exact referenced row identities; binding
digests hash tuple domain `macprovider-r22/catalog-binding` over
model, release, artifact, row, source transaction UUID, custody-event SHA, and
creating operation UUID; source_token_sha256 hashes the exact
32-byte daemon token. A field outside this registry or a digest resolved by
search rather than its stored foreign-key/direct-path reference rejects.

daemon_protocol_version is u63. Every path length is the raw byte length, never
Unicode scalar or character count. Relative paths are canonical UTF-8 bytes.
Appendix D is the complete external column/type/null/digest registry for
`custody_receipt_v1`, `custody-entry`, `gc_result_v1`,
`gc_first_over_control_v1`, `staging_source_receipt_v1`, `serving_pin_v1`,
and `request_outcome_v1`. No field outside Appendix D is accepted. Typed owner row identities and foreign keys include every displayed semantic
owner column; generic evidence identity remains the direct file identity row.

gc_result root identity truth table is exact:

| outcome | start phase | end phase | before root | after root |
|---|---|---|---|---|
| progress | any non-complete | any legal successor | SHA required | SHA required |
| done | flags/entries/root/fsync | complete | SHA required | null |
| protected | any | same or legal successor | SHA required | SHA required |
| blocked-kernel-io | any non-complete | same | SHA required | null |

Every phase/outcome combination outside that table rejects. Golden minimum,
maximum, null, reordered, unknown-enum, byte-count, and digest-target vectors
are required in R28.

## 11. Complete Swift migration matrix

All new code is owned behind CatalogAuthorityV5. R4MigrationReader is the only
type allowed to decode legacy names, and only before B8 or while validating the
deterministic unselected candidate. The cutover matrix is normative. Every lock, lifetime FD, child argument, and
cache below is classified; transport objects never become authority:

| current owner/symbol group | R22 owner/interface | before B8 | after B8 / forbidden bypass proof |
|---|---|---|---|
| Retention.retentionDirectory, initializeRetention | CatalogAuthorityFactory.open | R4 read or bootstrap | V5 only; no active.json write |
| captureIndexReceipt, recaptureIndexReceipt, snapshotIndex | CatalogAuthorityV5.readSnapshot | R4 receipt | one SQLite read transaction |
| decodeActiveIndex, decodeRetentionRecord | R4MigrationReader | migration only | unreachable from runtime |
| activeReceiptGeneration, validateActiveReceiptMembership | CatalogAuthorityV5.membership | R4 adapter | SQL generation and direct evidence |
| recoverAllocations, reserveOperation | CatalogAuthorityV5.allocateOrReserve | R4 until B8 | row_slots plus manifest operations |
| maintainRetention, retireOne, reserveCleanup | CatalogAuthorityV5.retire | R4 until B8 | row/custody/GC SQL only |
| cleanupRecordsFromIndex, captureCompleteCleanupInventory | CatalogAuthorityV5.cleanupInventory | R4 snapshot | paged SQL read |
| prepareRecommendationIndex, indexedRecommendation, indexCompletedEvaluation | CatalogAuthorityV5.recommendations | R4 compatibility | SQL catalog/evidence only |
| Migration.migrationIndexEvidence, captureMigrationCompletion, initializeBindingMigration | R4MigrationReader/bootstrap | source evidence | no post-B8 calls |
| ReservationMigration all progress/finalize functions and direct active.json writes | R4MigrationReader/bootstrap manifest | candidate construction | no post-B8 writes |
| Evidence.captureActiveReceipt, commit, evidence | CatalogEvidenceStore | R4 evidence import | evidence_objects/direct refs |
| Bindings.captureProvenance, commitEvaluationSuccess, recoverBoundEvaluationSuccess | CatalogSlotStore | R4 until B8 | catalog_slots atomic CAS |
| Archive.captureRetirementProof, validateOriginalBindingEvidence | CatalogAuthorityV5.archive | R4 source proof | SQL/direct refs |
| Transactions begin/update/finish/evaluate/prepare/action constructors | CatalogTransactionEngine | adapter until B8 | manifest-generated DML only |
| ModelCatalogTransactionStore.forConfig/forContext, secure, locked, ownerLock | CatalogAuthorityFactory/CatalogAuthorityV5 | R4 root/lock | v5 directory FD and SQLite transaction only |
| ModelCatalogTransactionStore stagingURL/recordURL/load/append/reserve/update/check/reconcile/result/validatedCommittedResult/validatedPreparationSeal | CatalogTransactionEngine/CatalogEvidenceStore | R4 adapter | manifest operation or direct SQL/evidence read; no JSON record URL |
| ModelCatalogTransactionStore cleanup/cleanupRecords/latestCleanup | CatalogGarbageCollector | R4 adapter | SQL candidate/event lifecycle only |
| ModelCatalogTransactionRunner run/prepare/recommend and task cancel | CatalogTransactionEngine | R4 adapter | v5 operation UUID and cancellation graph |
| modelCatalogTransactionSetup/run/read and command run entrypoints | CatalogAuthorityFactory/CatalogAuthority protocol | format fence dispatch | v5-only dispatch after B8 |
| makeModelCatalogLocalActions/makeCompleteModelCatalogLocalActions/modelCatalogAdoptionAction | CatalogAuthorityV5/TrustedCustodyClient | R4 adapter | SQL snapshot/action plus custody capability |
| prepareCompleteModelCatalogRecommendationIndexes/modelCatalogDiscoveryMatcher | CatalogAuthorityV5 recommendations | R4 adapter | SQL evidence/catalog snapshot only |
| ModelCatalogReadCommand and ModelsSubcommand.prepareProjectionStore caller | CatalogAuthorityFactory.readSnapshot | R4 adapter | v5 read transaction; no projection-side authority |
| ModelsSubcommand catalog reads/actions | CatalogAuthority protocol | R4 before fence | V5 snapshots/actions |
| app/ModelManagement/ModelCatalogRead.swift `MalibuCatalogRead.arguments`, `MalibuCatalogReadRunner.run/openLock/execute`, `MalibuModelCLI.readCatalog` | `AppCatalogSnapshotTransport` | existing child invocation and `catalog-read.lock` serialize app transport before B8 | after B8 child receives one V5 snapshot/lifetime channel; fd 199 remains app-local transport serialization, fd 200 bounds the child only, and neither is custody/SQLite authority |
| app/ModelManagement/ModelManagement.swift `MalibuModelCLIRunning.readCatalog/cancelCatalogRead/catalogReadIsBusy`, `ModelManagementStore.runCatalogRead/refreshCatalogEconomics/stopCatalogVerification` | `AppCatalogSnapshotConsumer` | consumes validated R4 projection/cache | after B8 consumes typed V5 snapshot result only; `MalibuTransactionFiles.load`/pending cache may restore UI orchestration but cannot select catalog, custody, identity, or economics truth |
| MacProviderCLI direct adoptVerifiedStaging calls | TrustedCustodyClient | user staging preparation | no direct active adoption |
| AutotuneRecommend direct adoptVerifiedStaging call | TrustedCustodyClient | user staging preparation | no direct active adoption |
| DurableModelArtifactStore.adoptVerifiedStaging | UntrustedPreparationStore | allowed staging copy only | cannot return adoption eligibility |
| DurableModelArtifactStore.gcInactive | CatalogGarbageCollector | legacy before fence | no contentsOfDirectory/removeItem authority |
| ModelCatalogTransactionStorage name-based helpers | R4MigrationReader or DirectEvidenceStore | migration/evidence only | no authority name writes |
| makeModelCatalogRecoveries/makeCompleteModelCatalogRecoveries | CatalogAuthorityV5.recoverySnapshot | R4 adapter | fixed_state/row_state/operation SQL snapshot |
| MalibuTransactionFiles / ModelTransactionControl.swift | AppCatalogOrchestrator | pending/executable cache may resume UI only | after B8 consumes typed V5 snapshots/results; pending.json never catalog or custody truth |
| MalibuTransactionPayload | AppExecutableTransport | verified CLI copy/scan/remove only | no catalog/custody/economics mutation and no custody-root access |
| MalibuTransactionRequest | AppOperationCancellation | ephemeral cancellation/resource deadline | V5 cancel request or read-only retry_exhausted outcome; never mints transition, evidence, receipt, or refund |

Implementation order is: SPEC amendments; VFS/schema/codec and independent
fixtures; read-only factory plus deterministic bootstrap; allocation and
manifest transaction engine; catalog slot/custody daemon source registration;
replacement and serving cutover; bounded GC; removal of legacy runtime writes;
then full tests and audits. A static build gate enumerates all production
references to active.json, progress.json, maintenance.json, reservation
sidecars, direct adoption, gcInactive, captureIndexReceipt, and
recaptureIndexReceipt. Each match must be in the reviewed R4MigrationReader
allowlist or the build fails. A runtime fault test asserts no R4 file open
occurs after B8.

## 12. Compatibility, rollback, observability, and non-goals

Rollback may remove only the exact deterministic unselected candidate before
B8 after full identity validation. After B8, no rollback to R4 exists.
Operator backup/restore must preserve database identity, schema, registry,
manifest, source transcript, staging/custody evidence, and WAL recovery state.

Metrics expose schema/registry/manifest versions, page/WAL/counter headroom,
operation/transition/fixed/row state, replay, SQLite/VFS result, custody/source
capability, artifact state, GC round/cursor/helper/reap outcome, and protection
reason. They expose no paths, model bytes, source bytes, secrets, tokens, or
private keys.

Non-goals remain network admission, pricing authority, settlement, rewards,
economic activation, deployment, release, production enforcement, custom
carriers, custom B+ trees, general privileged file copying, and claiming
physical qualification from fixtures.

## 13. R21 finding disposition

| finding | exact R22 correction | R28 proof |
|---|---|---|
| H1 | complete public-ABI VFS maps one synthetic absolute identity to captured-directory `openat`; local I/O, POSIX lock, SHM, sync, and hard-WAL methods are qualified | R28-02 |
| H2 | four typed owner tables bind generic evidence; source/staging/custody/GC consumers use complete composite owner FKs; custody current/predecessor/catalog/GC keys include generation and operation scope/ordinal | R28-06 |
| H3 | attempt ordinal, checking generation, start phase/cursor derive and persist one distinct helper UUID per quantum | R28-09 |
| H4 | no provider receives a lock FD; daemon-supervised worker is TERM/KILL/reaped before lock release, with restart and uninterruptible-I/O quarantine | R28-08/09 |
| H5 | Appendix D defines complete pin/outcome codecs, daemon Ed25519 trust, channel-nonce FD binding, continuous-clock expiry, and replay | R28-12 |
| H6 | literal per-row B4 DML and states E0 through S cover import, journal cleanup, WAL conversion, rename, ready commit, format rename, and parent fsync | R28-03/05 |
| H7 | durable custody intent and deterministic temp/final leaves define C0-C7 recovery/reclamation with one open operation | R28-08 |
| M1 | offline copied-fixture VACUUM has one closed ATTACH/TEMP_DB exception; authority VACUUM remains forbidden and as-grown state must pass | R28-02/11 |
| M2 | `ModelCatalogRead.swift` runner/lock/FD/child path and `ModelManagement.swift` consumers are classified as snapshot transport/consumer in the matrix and generated manifest | R28-12 |
| M3 | standalone five-change generation-50 descriptor inserts owned control evidence/event, CASes candidate/counters, preserves result counts, and zero-writes exact replay | R28-05/09/11 |

No finding is downgraded, waived, or converted to a weaker claim. The plan gate
remains closed until an independent GPT-5.6 Sol review reports zero Critical,
High, and Medium findings for these exact R22/R28 bytes.

## Appendix A — normalized authoritative DDL

Normalization removes CR and trailing whitespace and retains exactly one LF
after each SQL statement. No trigger or view exists.

~~~sql
PRAGMA application_id=1297109587;
PRAGMA user_version=22;
CREATE TABLE protocol_meta(id INTEGER PRIMARY KEY CHECK(id=1),schema_version INTEGER NOT NULL CHECK(schema_version=22),bootstrap_id BLOB NOT NULL CHECK(length(bootstrap_id)=32),source_index_sha256 BLOB NOT NULL CHECK(length(source_index_sha256)=32),source_rows_sha256 BLOB NOT NULL CHECK(length(source_rows_sha256)=32),candidate_directory_identity_sha256 BLOB NOT NULL CHECK(length(candidate_directory_identity_sha256)=32),schema_sha256 BLOB NOT NULL CHECK(length(schema_sha256)=32),registry_sha256 BLOB NOT NULL CHECK(length(registry_sha256)=32),semantic_manifest_sha256 BLOB NOT NULL CHECK(length(semantic_manifest_sha256)=32),format_sha256 BLOB CHECK(format_sha256 IS NULL OR length(format_sha256)=32),state TEXT NOT NULL CHECK(state IN('bootstrap','ready','protected')),bootstrap_phase TEXT CHECK(bootstrap_phase IS NULL OR bootstrap_phase IN('b3-schema','b4-import','b5-import-complete','b6-wal-ready','b7-ready')),bootstrap_row_cursor INTEGER NOT NULL CHECK(bootstrap_row_cursor BETWEEN 0 AND 1024),generation INTEGER NOT NULL CHECK(generation>=1),source_row_count INTEGER NOT NULL CHECK(source_row_count BETWEEN 0 AND 1024),operation_count INTEGER NOT NULL CHECK(operation_count BETWEEN 0 AND 186688),transition_count INTEGER NOT NULL CHECK(transition_count BETWEEN 0 AND 560064),intent_count INTEGER NOT NULL CHECK(intent_count BETWEEN 0 AND 49280),evidence_count INTEGER NOT NULL CHECK(evidence_count BETWEEN 0 AND 49280),source_evidence_owner_count INTEGER NOT NULL CHECK(source_evidence_owner_count BETWEEN 0 AND 1024),staging_receipt_owner_count INTEGER NOT NULL CHECK(staging_receipt_owner_count BETWEEN 0 AND 1024),custody_evidence_owner_count INTEGER NOT NULL CHECK(custody_evidence_owner_count BETWEEN 0 AND 8192),gc_evidence_owner_count INTEGER NOT NULL CHECK(gc_evidence_owner_count BETWEEN 0 AND 25600),staging_source_count INTEGER NOT NULL CHECK(staging_source_count BETWEEN 0 AND 1024),custody_event_count INTEGER NOT NULL CHECK(custody_event_count BETWEEN 0 AND 8192),catalog_slot_count INTEGER NOT NULL CHECK(catalog_slot_count BETWEEN 0 AND 1024),gc_candidate_count INTEGER NOT NULL CHECK(gc_candidate_count BETWEEN 0 AND 1024),gc_event_count INTEGER NOT NULL CHECK(gc_event_count BETWEEN 0 AND 51200),open_operation_count INTEGER NOT NULL CHECK(open_operation_count BETWEEN 0 AND 1),wal_reserved_bytes INTEGER NOT NULL CHECK(wal_reserved_bytes BETWEEN 0 AND 50331648),wal_hard_limit_bytes INTEGER NOT NULL CHECK(wal_hard_limit_bytes=67108864),begin_wal_limit_bytes INTEGER NOT NULL CHECK(begin_wal_limit_bytes=16777216),page_limit INTEGER NOT NULL CHECK(page_limit=131072),begin_page_limit INTEGER NOT NULL CHECK(begin_page_limit=114688),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((state IN('bootstrap','ready') AND protected_code IS NULL)OR(state='protected' AND protected_code IS NOT NULL)),CHECK((state='bootstrap' AND bootstrap_phase IS NOT NULL AND format_sha256 IS NULL)OR(state='ready' AND bootstrap_phase='b7-ready' AND format_sha256 IS NOT NULL)OR state='protected')) STRICT;
CREATE TABLE transition_registry(scope TEXT NOT NULL CHECK(scope IN('allocation','row','fixed')),ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 319),family TEXT NOT NULL CHECK(length(family) BETWEEN 1 AND 32),local_ordinal INTEGER NOT NULL CHECK(local_ordinal BETWEEN 0 AND 173),name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 128),coarse_from TEXT NOT NULL CHECK(length(coarse_from) BETWEEN 1 AND 32),coarse_to TEXT NOT NULL CHECK(length(coarse_to) BETWEEN 1 AND 32),fine_from TEXT NOT NULL CHECK(length(fine_from) BETWEEN 1 AND 128),fine_to TEXT NOT NULL CHECK(length(fine_to) BETWEEN 1 AND 128),effect_template TEXT NOT NULL CHECK(length(effect_template) BETWEEN 1 AND 64),external_template TEXT NOT NULL CHECK(length(external_template) BETWEEN 1 AND 64),required_evidence_kind TEXT CHECK(required_evidence_kind IS NULL OR length(required_evidence_kind) BETWEEN 1 AND 64),charge_rule TEXT NOT NULL CHECK(charge_rule IN('zero','allocation','a3-directory','a5-evidence','adoption-lifecycle','a1a2-release')),begin_changes INTEGER NOT NULL CHECK(begin_changes BETWEEN 3 AND 12),progress_changes_base INTEGER NOT NULL CHECK(progress_changes_base BETWEEN 4 AND 12),progress_changes_with_incumbent INTEGER NOT NULL CHECK(progress_changes_with_incumbent BETWEEN 4 AND 12),cancel_progress_changes INTEGER NOT NULL CHECK(cancel_progress_changes BETWEEN 3 AND 12),finish_changes INTEGER NOT NULL CHECK(finish_changes BETWEEN 3 AND 12),max_row_changes INTEGER NOT NULL CHECK(max_row_changes=12),CHECK((scope='allocation' AND ordinal=0 AND local_ordinal=0)OR(scope='row' AND ordinal BETWEEN 0 AND 173 AND local_ordinal=ordinal)OR(scope='fixed' AND ordinal BETWEEN 0 AND 319)),PRIMARY KEY(scope,ordinal),UNIQUE(scope,ordinal,family),UNIQUE(scope,family,local_ordinal),UNIQUE(scope,name)) STRICT, WITHOUT ROWID;
CREATE TABLE fixed_state(family TEXT PRIMARY KEY CHECK(family IN('source','merge','tree','verification','materialization','recovery')),current_local_ordinal INTEGER NOT NULL CHECK(current_local_ordinal BETWEEN 0 AND 128),fine_state TEXT NOT NULL CHECK(length(fine_state) BETWEEN 1 AND 128),status TEXT NOT NULL CHECK(status IN('active','complete','protected')),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((status='protected' AND protected_code IS NOT NULL)OR(status!='protected' AND protected_code IS NULL)),CHECK((family IN('source','tree','verification','materialization') AND current_local_ordinal<=32)OR(family='merge' AND current_local_ordinal<=64)OR family='recovery')) STRICT, WITHOUT ROWID;
CREATE TABLE row_slots(row_ordinal INTEGER PRIMARY KEY CHECK(row_ordinal BETWEEN 0 AND 1023),state TEXT NOT NULL CHECK(state IN('free','allocating','occupied','exhausted','retired')),allocation_operation_uuid BLOB CHECK(allocation_operation_uuid IS NULL OR length(allocation_operation_uuid)=16),source_transaction_uuid BLOB CHECK(source_transaction_uuid IS NULL OR length(source_transaction_uuid)=16),allocation_attempts INTEGER NOT NULL CHECK(allocation_attempts BETWEEN 0 AND 8),generation INTEGER NOT NULL CHECK(generation>=1),CHECK((state='free' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NULL AND allocation_attempts<8)OR(state='allocating' AND allocation_operation_uuid IS NOT NULL AND source_transaction_uuid IS NULL AND allocation_attempts<8)OR(state='occupied' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NOT NULL)OR(state='retired' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NOT NULL)OR(state='exhausted' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NULL AND allocation_attempts=8)),FOREIGN KEY(row_ordinal,source_transaction_uuid) REFERENCES source_rows(row_ordinal,transaction_uuid) DEFERRABLE INITIALLY DEFERRED) STRICT;
CREATE INDEX idx_free_row_slots ON row_slots(row_ordinal) WHERE state='free';
CREATE TABLE evidence_objects(evidence_sha256 BLOB PRIMARY KEY CHECK(length(evidence_sha256)=32),kind TEXT NOT NULL CHECK(length(kind) BETWEEN 1 AND 64),root_kind TEXT NOT NULL CHECK(root_kind IN('transaction-store','staging-store','custody-store')),relative_path BLOB NOT NULL CHECK(length(relative_path) BETWEEN 1 AND 512),path_sha256 BLOB NOT NULL CHECK(length(path_sha256)=32),byte_length INTEGER CHECK(byte_length IS NULL OR byte_length BETWEEN 0 AND 2305843009213693951),content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256)=32),device_id INTEGER NOT NULL CHECK(device_id BETWEEN 0 AND 2305843009213693951),file_id INTEGER NOT NULL CHECK(file_id BETWEEN 0 AND 2305843009213693951),file_type TEXT NOT NULL CHECK(file_type IN('regular','directory')),mode INTEGER NOT NULL CHECK(mode BETWEEN 0 AND 65535),owner_uid INTEGER NOT NULL CHECK(owner_uid BETWEEN 0 AND 2305843009213693951),group_gid INTEGER NOT NULL CHECK(group_gid BETWEEN 0 AND 2305843009213693951),link_count INTEGER NOT NULL CHECK(link_count=1),mtime_seconds INTEGER NOT NULL CHECK(mtime_seconds BETWEEN 0 AND 2305843009213693951),mtime_nanoseconds INTEGER NOT NULL CHECK(mtime_nanoseconds BETWEEN 0 AND 999999999),ctime_seconds INTEGER NOT NULL CHECK(ctime_seconds BETWEEN 0 AND 2305843009213693951),ctime_nanoseconds INTEGER NOT NULL CHECK(ctime_nanoseconds BETWEEN 0 AND 999999999),birthtime_seconds INTEGER NOT NULL CHECK(birthtime_seconds BETWEEN 0 AND 2305843009213693951),birthtime_nanoseconds INTEGER NOT NULL CHECK(birthtime_nanoseconds BETWEEN 0 AND 999999999),user_flags INTEGER NOT NULL CHECK(user_flags BETWEEN 0 AND 2305843009213693951),system_flags INTEGER NOT NULL CHECK(system_flags BETWEEN 0 AND 2305843009213693951),identity_sha256 BLOB NOT NULL CHECK(length(identity_sha256)=32),created_generation INTEGER NOT NULL CHECK(created_generation>=1),CHECK((file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL)OR(file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL)),UNIQUE(root_kind,relative_path),UNIQUE(device_id,file_id,birthtime_seconds,birthtime_nanoseconds)) STRICT, WITHOUT ROWID;
CREATE TABLE source_rows(row_ordinal INTEGER PRIMARY KEY REFERENCES row_slots(row_ordinal),transaction_uuid BLOB NOT NULL UNIQUE CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),primary_evidence_sha256 BLOB NOT NULL CHECK(length(primary_evidence_sha256)=32),origin_evidence_sha256 BLOB NOT NULL CHECK(length(origin_evidence_sha256)=32),class_evidence_sha256 BLOB NOT NULL CHECK(length(class_evidence_sha256)=32),lineage_evidence_sha256 BLOB NOT NULL CHECK(length(lineage_evidence_sha256)=32),created_generation INTEGER NOT NULL CHECK(created_generation>=1),UNIQUE(row_ordinal,transaction_uuid),UNIQUE(row_ordinal,transaction_uuid,model_id,release),UNIQUE(row_ordinal,transaction_uuid,model_id,release,primary_evidence_sha256,origin_evidence_sha256,class_evidence_sha256,lineage_evidence_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,primary_evidence_sha256,origin_evidence_sha256,class_evidence_sha256,lineage_evidence_sha256) REFERENCES source_evidence_owners(row_ordinal,transaction_uuid,model_id,release,primary_evidence_sha256,origin_evidence_sha256,class_evidence_sha256,lineage_evidence_sha256)) STRICT;
CREATE TABLE source_evidence_owners(row_ordinal INTEGER PRIMARY KEY,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),primary_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),origin_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),class_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),lineage_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),UNIQUE(row_ordinal,transaction_uuid,model_id,release,primary_evidence_sha256,origin_evidence_sha256,class_evidence_sha256,lineage_evidence_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,primary_evidence_sha256,origin_evidence_sha256,class_evidence_sha256,lineage_evidence_sha256) REFERENCES source_rows(row_ordinal,transaction_uuid,model_id,release,primary_evidence_sha256,origin_evidence_sha256,class_evidence_sha256,lineage_evidence_sha256) DEFERRABLE INITIALLY DEFERRED) STRICT, WITHOUT ROWID;
CREATE TABLE row_state(row_ordinal INTEGER PRIMARY KEY REFERENCES source_rows(row_ordinal),coarse_state TEXT NOT NULL CHECK(coarse_state IN('A2','A3','A4','A5','A6','A7','A8','protected')),fine_state TEXT NOT NULL CHECK(length(fine_state) BETWEEN 1 AND 128),attempt_generation INTEGER NOT NULL CHECK(attempt_generation BETWEEN 0 AND 7),abort_generation INTEGER NOT NULL CHECK(abort_generation BETWEEN 0 AND 8),economic_charge_bytes INTEGER NOT NULL CHECK(economic_charge_bytes BETWEEN 0 AND 2305843009213693951),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((coarse_state='protected' AND protected_code IS NOT NULL)OR(coarse_state!='protected' AND protected_code IS NULL))) STRICT;
CREATE TABLE operations(operation_uuid BLOB PRIMARY KEY CHECK(length(operation_uuid)=16),scope TEXT NOT NULL CHECK(scope IN('allocation','row','fixed')),registry_ordinal INTEGER NOT NULL,row_ordinal INTEGER REFERENCES row_slots(row_ordinal),allocation_attempt INTEGER CHECK(allocation_attempt IS NULL OR allocation_attempt BETWEEN 0 AND 7),fixed_family TEXT REFERENCES fixed_state(family),phase TEXT NOT NULL CHECK(phase IN('open','committed','aborted','protected')),open_slot INTEGER CHECK(open_slot IS NULL OR open_slot=1),authorization_sha256 BLOB NOT NULL UNIQUE CHECK(length(authorization_sha256)=32),base_generation INTEGER NOT NULL CHECK(base_generation>=1),maximum_charge_bytes INTEGER NOT NULL CHECK(maximum_charge_bytes BETWEEN 0 AND 2305843009213693951),charge_consumed INTEGER NOT NULL CHECK(charge_consumed BETWEEN 0 AND 2305843009213693951),charge_released INTEGER NOT NULL CHECK(charge_released BETWEEN 0 AND 2305843009213693951),charge_abandoned INTEGER NOT NULL CHECK(charge_abandoned BETWEEN 0 AND 2305843009213693951),cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN(0,1)),finish_sha256 BLOB CHECK(finish_sha256 IS NULL OR length(finish_sha256)=32),UNIQUE(operation_uuid,authorization_sha256),UNIQUE(operation_uuid,row_ordinal),UNIQUE(operation_uuid,row_ordinal,scope,registry_ordinal),FOREIGN KEY(scope,registry_ordinal) REFERENCES transition_registry(scope,ordinal),FOREIGN KEY(scope,registry_ordinal,fixed_family) REFERENCES transition_registry(scope,ordinal,family),FOREIGN KEY(operation_uuid,finish_sha256) REFERENCES transitions(operation_uuid,transition_sha256) DEFERRABLE INITIALLY DEFERRED,CHECK((scope='allocation' AND row_ordinal IS NOT NULL AND allocation_attempt IS NOT NULL AND fixed_family IS NULL)OR(scope='row' AND row_ordinal IS NOT NULL AND allocation_attempt IS NULL AND fixed_family IS NULL)OR(scope='fixed' AND row_ordinal IS NULL AND allocation_attempt IS NULL AND fixed_family IS NOT NULL)),CHECK((phase='open' AND finish_sha256 IS NULL AND open_slot=1)OR(phase!='open' AND finish_sha256 IS NOT NULL AND open_slot IS NULL)),CHECK((phase='open' AND charge_consumed+charge_released+charge_abandoned<=maximum_charge_bytes)OR(phase!='open' AND charge_consumed+charge_released+charge_abandoned=maximum_charge_bytes))) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX idx_one_open_operation ON operations(open_slot) WHERE open_slot=1;
CREATE UNIQUE INDEX idx_allocation_attempt ON operations(row_ordinal,allocation_attempt) WHERE scope='allocation';
CREATE UNIQUE INDEX idx_row_semantic_slot ON operations(row_ordinal,registry_ordinal) WHERE scope='row' AND registry_ordinal<110;
CREATE UNIQUE INDEX idx_row_abort_slot ON operations(row_ordinal,registry_ordinal) WHERE scope='row' AND registry_ordinal>=110;
CREATE UNIQUE INDEX idx_fixed_semantic_slot ON operations(fixed_family,registry_ordinal) WHERE scope='fixed';
CREATE TABLE operation_external_intents(operation_uuid BLOB NOT NULL REFERENCES operations(operation_uuid),intent_ordinal INTEGER NOT NULL CHECK(intent_ordinal BETWEEN 0 AND 3),kind TEXT NOT NULL CHECK(kind IN('directory','regular','existing-evidence','staging-source')),evidence_kind TEXT NOT NULL CHECK(length(evidence_kind) BETWEEN 1 AND 64),root_kind TEXT NOT NULL CHECK(root_kind IN('transaction-store','staging-store','custody-store')),file_type TEXT NOT NULL CHECK(file_type IN('regular','directory')),relative_path BLOB NOT NULL CHECK(length(relative_path) BETWEEN 1 AND 512),path_sha256 BLOB NOT NULL CHECK(length(path_sha256)=32),byte_length INTEGER CHECK(byte_length IS NULL OR byte_length BETWEEN 0 AND 2305843009213693951),content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256)=32),identity_sha256 BLOB CHECK(identity_sha256 IS NULL OR length(identity_sha256)=32),PRIMARY KEY(operation_uuid,intent_ordinal),CHECK((kind='directory' AND file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL AND identity_sha256 IS NULL)OR(kind='regular' AND file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL AND identity_sha256 IS NULL)OR(kind IN('existing-evidence','staging-source') AND identity_sha256 IS NOT NULL AND ((file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL)OR(file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL))))) STRICT, WITHOUT ROWID;
CREATE TABLE transitions(operation_uuid BLOB NOT NULL REFERENCES operations(operation_uuid),step_ordinal INTEGER NOT NULL CHECK(step_ordinal BETWEEN 0 AND 2),kind TEXT NOT NULL CHECK(kind IN('begin','progress','finish')),base_generation INTEGER NOT NULL CHECK(base_generation>=1),successor_generation INTEGER NOT NULL UNIQUE CHECK(successor_generation=base_generation+1),prior_transition_sha256 BLOB CHECK(prior_transition_sha256 IS NULL OR length(prior_transition_sha256)=32),authorization_sha256 BLOB NOT NULL CHECK(length(authorization_sha256)=32),charged_bytes INTEGER NOT NULL CHECK(charged_bytes BETWEEN 0 AND 2305843009213693951),outcome TEXT NOT NULL CHECK(outcome IN('selected','committed','aborted','protected')),transition_sha256 BLOB NOT NULL UNIQUE CHECK(length(transition_sha256)=32),PRIMARY KEY(operation_uuid,step_ordinal),UNIQUE(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,prior_transition_sha256) REFERENCES transitions(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,authorization_sha256) REFERENCES operations(operation_uuid,authorization_sha256),CHECK((kind='begin' AND step_ordinal=0 AND prior_transition_sha256 IS NULL AND outcome='selected')OR(kind='progress' AND step_ordinal=1 AND prior_transition_sha256 IS NOT NULL AND outcome='selected')OR(kind='finish' AND step_ordinal=2 AND prior_transition_sha256 IS NOT NULL AND outcome IN('committed','aborted','protected')))) STRICT, WITHOUT ROWID;
CREATE TABLE verification_state(row_ordinal INTEGER PRIMARY KEY REFERENCES source_rows(row_ordinal),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),verification_uuid BLOB NOT NULL CHECK(length(verification_uuid)=16),entry_cursor INTEGER NOT NULL CHECK(entry_cursor BETWEEN 0 AND 4096),bytes_completed INTEGER NOT NULL CHECK(bytes_completed BETWEEN 0 AND 2305843009213693951),h0 INTEGER NOT NULL CHECK(h0 BETWEEN 0 AND 4294967295),h1 INTEGER NOT NULL CHECK(h1 BETWEEN 0 AND 4294967295),h2 INTEGER NOT NULL CHECK(h2 BETWEEN 0 AND 4294967295),h3 INTEGER NOT NULL CHECK(h3 BETWEEN 0 AND 4294967295),h4 INTEGER NOT NULL CHECK(h4 BETWEEN 0 AND 4294967295),h5 INTEGER NOT NULL CHECK(h5 BETWEEN 0 AND 4294967295),h6 INTEGER NOT NULL CHECK(h6 BETWEEN 0 AND 4294967295),h7 INTEGER NOT NULL CHECK(h7 BETWEEN 0 AND 4294967295),total_byte_count INTEGER NOT NULL CHECK(total_byte_count BETWEEN 0 AND 2305843009213693951),tail BLOB NOT NULL CHECK(length(tail)<=63),manifest_sha256 BLOB NOT NULL CHECK(length(manifest_sha256)=32),generation INTEGER NOT NULL CHECK(generation>=1),CHECK(length(tail)=total_byte_count%64)) STRICT;
CREATE TABLE staging_receipt_owners(row_ordinal INTEGER NOT NULL,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),operation_uuid BLOB NOT NULL CHECK(length(operation_uuid)=16),operation_row_ordinal INTEGER NOT NULL,receipt_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),PRIMARY KEY(transaction_uuid),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,operation_uuid,operation_row_ordinal,receipt_evidence_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release) REFERENCES source_rows(row_ordinal,transaction_uuid,model_id,release),FOREIGN KEY(operation_uuid,operation_row_ordinal) REFERENCES operations(operation_uuid,row_ordinal)) STRICT, WITHOUT ROWID;
CREATE TABLE staging_sources(transaction_uuid BLOB PRIMARY KEY CHECK(length(transaction_uuid)=16),row_ordinal INTEGER NOT NULL UNIQUE,model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),operation_uuid BLOB NOT NULL CHECK(length(operation_uuid)=16),operation_row_ordinal INTEGER NOT NULL,source_token_sha256 BLOB NOT NULL UNIQUE CHECK(length(source_token_sha256)=32),receipt_evidence_sha256 BLOB NOT NULL CHECK(length(receipt_evidence_sha256)=32),state TEXT NOT NULL CHECK(state IN('registered','consumed','cancelled','protected')),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release) REFERENCES source_rows(row_ordinal,transaction_uuid,model_id,release),FOREIGN KEY(operation_uuid,operation_row_ordinal) REFERENCES operations(operation_uuid,row_ordinal),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,operation_uuid,operation_row_ordinal,receipt_evidence_sha256) REFERENCES staging_receipt_owners(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,operation_uuid,operation_row_ordinal,receipt_evidence_sha256),CHECK((state='protected' AND protected_code IS NOT NULL)OR(state!='protected' AND protected_code IS NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE custody_evidence_owners(row_ordinal INTEGER NOT NULL,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL CHECK(custody_generation BETWEEN 1 AND 8),operation_uuid BLOB NOT NULL CHECK(length(operation_uuid)=16),operation_row_ordinal INTEGER NOT NULL,operation_scope TEXT NOT NULL CHECK(operation_scope='row'),operation_registry_ordinal INTEGER NOT NULL CHECK(operation_registry_ordinal BETWEEN 0 AND 173),root_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),receipt_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),PRIMARY KEY(artifact_sha256,custody_generation),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,operation_uuid,operation_row_ordinal,operation_scope,operation_registry_ordinal,root_evidence_sha256,receipt_evidence_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release) REFERENCES source_rows(row_ordinal,transaction_uuid,model_id,release),FOREIGN KEY(operation_uuid,operation_row_ordinal,operation_scope,operation_registry_ordinal) REFERENCES operations(operation_uuid,row_ordinal,scope,registry_ordinal)) STRICT, WITHOUT ROWID;
CREATE TABLE custody_events(row_ordinal INTEGER NOT NULL,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL CHECK(custody_generation BETWEEN 1 AND 8),state TEXT NOT NULL CHECK(state IN('verified','active','released','abandoned','protected')),predecessor_generation INTEGER,predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),root_evidence_sha256 BLOB NOT NULL CHECK(length(root_evidence_sha256)=32),receipt_evidence_sha256 BLOB NOT NULL CHECK(length(receipt_evidence_sha256)=32),operation_uuid BLOB NOT NULL CHECK(length(operation_uuid)=16),operation_row_ordinal INTEGER NOT NULL,operation_scope TEXT NOT NULL CHECK(operation_scope='row'),operation_registry_ordinal INTEGER NOT NULL CHECK(operation_registry_ordinal BETWEEN 0 AND 173),reason TEXT CHECK(reason IS NULL OR reason IN('initial-activation','replacement','removed','cancelled','authority-corrupt','source-changed','evidence-changed','artifact-changed','custody-unavailable','custody-authorization-failed','storage-full','io-error','kernel-io-blocked','unsupported-filesystem','protocol-mismatch','retry-exhausted')),custody_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(custody_event_sha256)=32),PRIMARY KEY(artifact_sha256,custody_generation),UNIQUE(artifact_sha256,custody_generation,custody_event_sha256),UNIQUE(row_ordinal,custody_generation),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release) REFERENCES source_rows(row_ordinal,transaction_uuid,model_id,release),FOREIGN KEY(operation_uuid,operation_row_ordinal,operation_scope,operation_registry_ordinal) REFERENCES operations(operation_uuid,row_ordinal,scope,registry_ordinal),FOREIGN KEY(artifact_sha256,predecessor_generation,predecessor_sha256) REFERENCES custody_events(artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,operation_uuid,operation_row_ordinal,operation_scope,operation_registry_ordinal,root_evidence_sha256,receipt_evidence_sha256) REFERENCES custody_evidence_owners(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,operation_uuid,operation_row_ordinal,operation_scope,operation_registry_ordinal,root_evidence_sha256,receipt_evidence_sha256),CHECK((custody_generation=1 AND predecessor_generation IS NULL AND predecessor_sha256 IS NULL)OR(custody_generation>1 AND predecessor_generation=custody_generation-1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='verified' AND reason IS NULL)OR(state='active' AND reason IN('initial-activation','replacement'))OR(state='released' AND reason IN('replacement','removed'))OR(state='abandoned' AND reason='cancelled')OR(state='protected' AND reason IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE custody_current(row_ordinal INTEGER NOT NULL UNIQUE,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB PRIMARY KEY CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL,custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256) REFERENCES custody_events(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256)) STRICT, WITHOUT ROWID;
CREATE TABLE catalog_slots(model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),active_artifact_sha256 BLOB,active_custody_generation INTEGER,active_custody_event_sha256 BLOB,active_row_ordinal INTEGER,active_transaction_uuid BLOB,active_binding_sha256 BLOB,active_operation_uuid BLOB,pending_artifact_sha256 BLOB,pending_custody_generation INTEGER,pending_custody_event_sha256 BLOB,pending_row_ordinal INTEGER,pending_transaction_uuid BLOB,pending_binding_sha256 BLOB,pending_operation_uuid BLOB,generation INTEGER NOT NULL CHECK(generation>=1),PRIMARY KEY(model_id,release),FOREIGN KEY(active_row_ordinal,active_transaction_uuid,model_id,release,active_artifact_sha256,active_custody_generation,active_custody_event_sha256) REFERENCES custody_current(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(pending_row_ordinal,pending_transaction_uuid,model_id,release,pending_artifact_sha256,pending_custody_generation,pending_custody_event_sha256) REFERENCES custody_current(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(active_operation_uuid,active_row_ordinal) REFERENCES operations(operation_uuid,row_ordinal),FOREIGN KEY(pending_operation_uuid,pending_row_ordinal) REFERENCES operations(operation_uuid,row_ordinal),CHECK((active_artifact_sha256 IS NULL AND active_custody_generation IS NULL AND active_custody_event_sha256 IS NULL AND active_row_ordinal IS NULL AND active_transaction_uuid IS NULL AND active_binding_sha256 IS NULL AND active_operation_uuid IS NULL)OR(length(active_artifact_sha256)=32 AND active_custody_generation BETWEEN 1 AND 8 AND length(active_custody_event_sha256)=32 AND active_row_ordinal IS NOT NULL AND length(active_transaction_uuid)=16 AND length(active_binding_sha256)=32 AND active_operation_uuid IS NOT NULL)),CHECK((pending_artifact_sha256 IS NULL AND pending_custody_generation IS NULL AND pending_custody_event_sha256 IS NULL AND pending_row_ordinal IS NULL AND pending_transaction_uuid IS NULL AND pending_binding_sha256 IS NULL AND pending_operation_uuid IS NULL)OR(length(pending_artifact_sha256)=32 AND pending_custody_generation BETWEEN 1 AND 8 AND length(pending_custody_event_sha256)=32 AND pending_row_ordinal IS NOT NULL AND length(pending_transaction_uuid)=16 AND length(pending_binding_sha256)=32 AND pending_operation_uuid IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE gc_meta(id INTEGER PRIMARY KEY CHECK(id=1),maximum_round INTEGER NOT NULL CHECK(maximum_round BETWEEN 0 AND 2305843009213693951),generation INTEGER NOT NULL CHECK(generation>=1)) STRICT;
CREATE TABLE gc_candidates(row_ordinal INTEGER NOT NULL UNIQUE,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB PRIMARY KEY CHECK(length(artifact_sha256)=32),state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round BETWEEN 0 AND 2305843009213693951),gc_lifecycle_generation INTEGER NOT NULL CHECK(gc_lifecycle_generation=1),custody_generation INTEGER NOT NULL CHECK(custody_generation BETWEEN 1 AND 8),custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),manifest_cursor INTEGER CHECK(manifest_cursor BETWEEN 0 AND 4096),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),active_attempt_ordinal INTEGER CHECK(active_attempt_ordinal IS NULL OR active_attempt_ordinal BETWEEN 1 AND 24),active_check_generation INTEGER CHECK(active_check_generation IS NULL OR active_check_generation BETWEEN 2 AND 49),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),successful_quanta INTEGER NOT NULL CHECK(successful_quanta BETWEEN 0 AND 16),failure_count INTEGER NOT NULL CHECK(failure_count BETWEEN 0 AND 8),result_count INTEGER NOT NULL CHECK(result_count BETWEEN 0 AND 24),last_event_sha256 BLOB NOT NULL CHECK(length(last_event_sha256)=32),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256) REFERENCES custody_current(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(artifact_sha256,last_event_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256) DEFERRABLE INITIALLY DEFERRED,CHECK((state IN('checking','deleting','blocked-kernel-io') AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND active_attempt_ordinal IS NOT NULL AND active_check_generation IS NOT NULL AND helper_operation_uuid IS NOT NULL)OR(state IN('queued','done','protected') AND manifest_cursor IS NULL AND delete_phase IS NULL AND active_attempt_ordinal IS NULL AND active_check_generation IS NULL AND helper_operation_uuid IS NULL))) STRICT, WITHOUT ROWID;
CREATE INDEX idx_gc_fair ON gc_candidates(eligible_round,artifact_sha256) WHERE state IN('queued','checking','deleting');
CREATE TABLE gc_evidence_owners(row_ordinal INTEGER NOT NULL,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL CHECK(custody_generation BETWEEN 1 AND 8),custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),helper_operation_uuid BLOB NOT NULL CHECK(length(helper_operation_uuid)=16),semantic_role TEXT NOT NULL CHECK(semantic_role IN('gc-result','gc-first-over-control')),evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),PRIMARY KEY(artifact_sha256,helper_operation_uuid,semantic_role),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256,helper_operation_uuid,semantic_role,evidence_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256) REFERENCES gc_candidates(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256)) STRICT, WITHOUT ROWID;
CREATE TABLE gc_events(row_ordinal INTEGER NOT NULL,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL CHECK(custody_generation BETWEEN 1 AND 8),custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),event_generation INTEGER NOT NULL CHECK(event_generation BETWEEN 1 AND 50),predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round BETWEEN 0 AND 2305843009213693951),manifest_cursor INTEGER CHECK(manifest_cursor IS NULL OR manifest_cursor BETWEEN 0 AND 4096),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),attempt_ordinal INTEGER CHECK(attempt_ordinal IS NULL OR attempt_ordinal BETWEEN 1 AND 24),checking_event_generation INTEGER CHECK(checking_event_generation IS NULL OR checking_event_generation BETWEEN 2 AND 49),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),result_role TEXT CHECK(result_role IS NULL OR result_role IN('gc-result','gc-first-over-control')),result_evidence_sha256 BLOB CHECK(result_evidence_sha256 IS NULL OR length(result_evidence_sha256)=32),gc_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(gc_event_sha256)=32),PRIMARY KEY(artifact_sha256,event_generation),UNIQUE(artifact_sha256,gc_event_sha256),UNIQUE(artifact_sha256,event_generation,helper_operation_uuid),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256) REFERENCES gc_candidates(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(artifact_sha256,predecessor_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256) REFERENCES custody_events(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256,helper_operation_uuid,result_role,result_evidence_sha256) REFERENCES gc_evidence_owners(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256,helper_operation_uuid,semantic_role,evidence_sha256),CHECK((event_generation=1 AND predecessor_sha256 IS NULL)OR(event_generation>1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='queued' AND event_generation=1 AND manifest_cursor IS NULL AND delete_phase IS NULL AND attempt_ordinal IS NULL AND checking_event_generation IS NULL AND helper_operation_uuid IS NULL AND result_role IS NULL AND result_evidence_sha256 IS NULL)OR(state='checking' AND event_generation BETWEEN 2 AND 49 AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND attempt_ordinal IS NOT NULL AND checking_event_generation=event_generation AND helper_operation_uuid IS NOT NULL AND result_role IS NULL AND result_evidence_sha256 IS NULL)OR(state IN('deleting','blocked-kernel-io','done','protected') AND event_generation BETWEEN 3 AND 49 AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND attempt_ordinal IS NOT NULL AND checking_event_generation=event_generation-1 AND helper_operation_uuid IS NOT NULL AND result_role='gc-result' AND result_evidence_sha256 IS NOT NULL)OR(state='protected' AND event_generation=50 AND manifest_cursor IS NULL AND delete_phase IS NULL AND attempt_ordinal IS NULL AND checking_event_generation IS NULL AND helper_operation_uuid IS NOT NULL AND result_role='gc-first-over-control' AND result_evidence_sha256 IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX idx_gc_check_helper ON gc_events(artifact_sha256,helper_operation_uuid) WHERE state='checking';
CREATE UNIQUE INDEX idx_gc_check_attempt ON gc_events(artifact_sha256,attempt_ordinal) WHERE state='checking';
~~~

The normalized Appendix A bytes have SHA-256
`edf42410f061176e2b3e3a15d9d60c3b47611784ea3207ac2531fafb94acf0c5`.

## Appendix B — registry grammar

The following is the complete standalone name grammar. Loop lists and order are
literal; `emit` appends one line. Section 5.2 assigns every other field by name,
ordinal, and family with no inherited default. The allocation line precedes the
row lines in the manifest byte stream; fixed lines follow row lines. Expanded
count is 495.

~~~text
ALLOCATION: emit allocate-row

ROW:
for source in [primary,origin,class,lineage]:
  for verb in [publish,storage-index,path-index]: emit source-capture-<source>-<verb>
for name in [raw-source-close,name-source-close,row-source-close,capture-run-close]: emit <name>
for pass in [0,1,2,3,4,5,6]:
  for verb in [bind-input,publish-row-block,index-row-block,advance-output-sequence]: emit merge-pass-<pass>-<verb>
for name in [run-open,run-close,merge-root-open,merge-root-close]: emit <name>
for level in [0,1,2,3,4,5,6,7]:
  for verb in [emit-page,advance-level-sequence]: emit tree-level-<level>-<verb>
for target in [rows-1,rows-2,storage]:
  for verb in [open,publish-block,advance-sequence,close]: emit verify-<target>-<verb>
for name in [phase-A3-directory-intent,A3-directory-publication-receipt,A3-storage-index,A3-path-index,phase-A4-directory-durable]: emit <name>
for body in [primary,origin,class,lineage]:
  for suffix in [intent,publication-receipt,storage-index,path-index,durable]: emit A5-<body>-<suffix>
for name in [prepared-adoption-record,prepared-storage-index,prepared-path-index,lifecycle-reserve,lifecycle-bind,binding-publish,phase-A6,activation-record,checkpoint-record]: emit <name>
for generation in [0,1,2,3,4,5,6,7]:
  for slot in [begin-abort-generation,close-sequence,close-work-root,release-lifecycle-if-selected,prepare-budget-abort-close,record-A7-aborting,record-A8-aborted,publish-abort-receipt]: emit abort-<generation>-<slot>
assert row count == 174

FIXED:
for state in [empty-primary,empty-origin,empty-class,empty-lineage,primary-open,origin-open,class-open,lineage-open,raw-close,name-close,row-close,capture-close,source-verified,source-failed,source-retry,source-protected]:
  for verb in [prepare,commit]: emit source-<state>-<verb>
for pass in [0,1,2,3,4,5,6,7]:
  for verb in [open-input,open-output,bind-input,publish-row-block,index-row-block,advance-output,close-run,close-pass]: emit merge-<pass>-<verb>
for level in [0,1,2,3,4,5,6,7]:
  for verb in [open-level,select-root,advance-sequence,close-level]: emit tree-<level>-<verb>
for target in [rows-1,rows-2,storage,terminal]:
  for verb in [open,publish-block,index-block,advance-sequence,close-pass,record-result,retry,protect]: emit verification-<target>-<verb>
for phase in [A0,A1,A2,A3,A4,A5,A6,A7]:
  for verb in [record-phase,bind-root,record-result,close]: emit materialization-<phase>-<verb>
for state in [selector-temp,selector-renamed,carrier-temp,carrier-renamed,carrier-durable,external-temp,external-renamed,external-durable,directory-created,directory-durable,phase-recorded,budget-reserving,budget-closing,abort-receipt,terminal-selector,protected]:
  for verb in [inspect,adopt,resume,compensate,retry,close,record,protect]: emit recovery-<state>-<verb>
assert fixed count == 320
~~~

The words carrier and selector in recovery names are historical labels. Their
only external template is legacy-inspect-readonly; they cannot create, promote,
or select either object class.

## Appendix C — semantic DML and effect registry

The normalized manifest starts with the following `mutation-v1` descriptors.
The grammar is
`ordinal|verb|table|insert-columns-or-CAS-predicate|new-values`; `;` separates
columns, `=` separates a column from its typed parameter or literal, and LF
terminates a statement. `CAS(old,new)` means one `UPDATE ... WHERE` statement
whose predicate contains every `old` value and whose setters contain every
`new` value. `INC(n)` is exact checked addition. The implementation compiles
only these descriptors to parameterized SQL; generated SQL and bind types are
golden-tested byte-for-byte. Parameters not named by the descriptor cannot be
bound, and every digest parameter is a 32-byte BLOB rather than hexadecimal
text.

~~~text
bootstrap-b4-row(mask) — one literal descriptor for each of 16 masks; E=popcount(mask), exact changes 5+E
0..E-1|INSERT|evidence_objects|all Appendix-A columns in primary,origin,class,lineage order|only missing canonical evidence rows; existing rows were byte-compared before BEGIN
E|INSERT|source_evidence_owners|row_ordinal;transaction_uuid;model_id;release;primary_evidence_sha256;origin_evidence_sha256;class_evidence_sha256;lineage_evidence_sha256|:cursor;:transaction;:model;:release;:primary;:origin;:class;:lineage
E+1|INSERT|source_rows|row_ordinal;transaction_uuid;model_id;release;primary_evidence_sha256;origin_evidence_sha256;class_evidence_sha256;lineage_evidence_sha256;created_generation|:cursor;:transaction;:model;:release;:primary;:origin;:class;:lineage;:g+1
E+2|INSERT|row_state|row_ordinal;coarse_state;fine_state;attempt_generation;abort_generation;economic_charge_bytes;generation;protected_code|:cursor;A2;row-normal-0;0;0;0;:g+1;null
E+3|CAS|row_slots|row_ordinal=:cursor;state=free;allocation_operation_uuid=null;source_transaction_uuid=null;allocation_attempts=0;generation=1|state=occupied;source_transaction_uuid=:transaction;generation=2
E+4|CAS|protocol_meta|id=1;state=bootstrap;bootstrap_phase=b4-import;bootstrap_row_cursor=:cursor;generation=:g;source_row_count=:src;evidence_count=:ec;source_evidence_owner_count=:seoc|bootstrap_row_cursor=:cursor+1;generation=:g+1;source_row_count=INC(1);evidence_count=INC(E);source_evidence_owner_count=INC(1)

generic-begin
0|INSERT|operations|operation_uuid;scope;registry_ordinal;row_ordinal;allocation_attempt;fixed_family;phase;open_slot;authorization_sha256;base_generation;maximum_charge_bytes;charge_consumed;charge_released;charge_abandoned;cancel_requested;finish_sha256|:operation;:scope;:registry;:row-or-null;:allocation-attempt-or-null;:family-or-null;open;1;:authorization;:g;:maximum-charge;0;0;0;0;null
1..K|INSERT|operation_external_intents|operation_uuid;intent_ordinal;kind;evidence_kind;root_kind;file_type;relative_path;path_sha256;byte_length;content_sha256;identity_sha256|:operation;:intent-ordinal;:intent-kind;:evidence-kind;:root-kind;:file-type;:path;:path-sha;:length-or-null;:content-sha-or-null;:identity-sha-or-null
K+1|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;0;begin;:g;:g+1;null;:authorization;0;selected;:begin-sha
K+2|CAS|protocol_meta|id=1;state=ready;generation=:g;operation_count=:oc;transition_count=:tc;intent_count=:ic;open_operation_count=0;wal_reserved_bytes=0|generation=:g+1;operation_count=INC(1);transition_count=INC(1);intent_count=INC(K);open_operation_count=1;wal_reserved_bytes=:declared-remaining-reserve

allocation-begin-addition
A0|CAS|row_slots|row_ordinal=:row;state=free;allocation_operation_uuid=null;source_transaction_uuid=null;allocation_attempts=:attempt;generation=:row-generation|state=allocating;allocation_operation_uuid=:operation;generation=:row-generation+1

generic-progress
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state-or-fixed_state|:domain-primary-key;:manifest-coarse-from;:manifest-fine-from;generation=:domain-generation|:manifest-coarse-to;:manifest-fine-to;generation=:domain-generation+1;:manifest-counter-setters
3..2+E|INSERT|evidence_objects|evidence_sha256;kind;root_kind;relative_path;path_sha256;byte_length;content_sha256;device_id;file_id;file_type;mode;owner_uid;group_gid;link_count;mtime_seconds;mtime_nanoseconds;ctime_seconds;ctime_nanoseconds;birthtime_seconds;birthtime_nanoseconds;user_flags;system_flags;identity_sha256;created_generation|:direct-evidence-fields
3+E..2+E+S|SPECIAL|:manifest-special-table|:manifest-special-columns-and-old-predicate|:manifest-special-values
3+E+S|CAS|protocol_meta|id=1;state=ready;generation=:g;transition_count=:tc;evidence_count=:ec;open_operation_count=1;wal_reserved_bytes=:remaining;:special-counters-old|generation=:g+1;transition_count=INC(1);evidence_count=INC(E);wal_reserved_bytes=:after-progress-reserve;:special-counters-new

generic-finish
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;2;finish;:g;:g+1;:progress-sha;:authorization;0;:terminal-outcome;:finish-sha
1|CAS|operations|operation_uuid=:operation;phase=open;authorization_sha256=:authorization;charge_consumed=:consumed;charge_released=:released;charge_abandoned=:abandoned;finish_sha256=null|phase=:terminal-outcome;open_slot=null;finish_sha256=:finish-sha
2|CAS|protocol_meta|id=1;state=ready;generation=:g;transition_count=:tc;open_operation_count=1;wal_reserved_bytes=:remaining|generation=:g+1;transition_count=INC(1);open_operation_count=0;wal_reserved_bytes=0

allocation-success-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|INSERT|evidence_objects|all Appendix-A columns|primary direct evidence
3|INSERT|evidence_objects|all Appendix-A columns|origin direct evidence
4|INSERT|evidence_objects|all Appendix-A columns|class direct evidence
5|INSERT|evidence_objects|all Appendix-A columns|lineage direct evidence
6|INSERT|source_evidence_owners|complete source tuple;four evidence SHAs|typed source evidence owner
7|INSERT|source_rows|row_ordinal;transaction_uuid;model_id;release;four evidence SHAs;created_generation|selected source tuple
8|INSERT|row_state|row_ordinal;coarse_state;fine_state;attempt_generation;abort_generation;economic_charge_bytes;generation;protected_code|row;A2;row-normal-76;0;0;consumed;successor;null
9|CAS|row_slots|exact allocating row/operation/attempt/generation|occupied;operation null;source transaction;generation+1
10|CAS|protocol_meta|exact generation/counts/open=1/reserve|generation+1;source+1;source-owner+1;evidence+4;transition+1;reserve after progress

allocation-cancel-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;0;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;scope=allocation;phase=open;open_slot=1;authorization_sha256=:authorization;cancel_requested=0;charge_consumed=0;charge_released=0;charge_abandoned=0|cancel_requested=1
2|CAS|protocol_meta|exact generation/transition/open/reserve|generation+1;transition+1;reserve after progress

staging-register-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|evidence_objects|all Appendix-A columns|direct staging receipt
4|INSERT|staging_receipt_owners|complete source/artifact/operation tuple;receipt_evidence_sha256|typed staging receipt owner
5|INSERT|staging_sources|transaction_uuid;row_ordinal;model_id;release;artifact_sha256;operation_uuid;operation_row_ordinal;source_token_sha256;receipt_evidence_sha256;state;generation;protected_code|exact selected source/artifact/operation/token/receipt;registered;successor;null
6|CAS|protocol_meta|exact generation/evidence/staging-owner/staging/open/reserve|generation+1;evidence+1;staging-owner+1;staging+1;transition+1;reserve after progress

custody-verified-pending-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|evidence_objects|all Appendix-A columns|direct root evidence
4|INSERT|evidence_objects|all Appendix-A columns|direct custody receipt evidence
5|INSERT|custody_evidence_owners|complete source/artifact/generation/operation tuple;root and receipt evidence|typed custody evidence owner
6|INSERT|custody_events|row;transaction;model;release;artifact;generation;state;predecessor-generation;predecessor;root;receipt;operation;operation-row;operation-scope;operation-registry;reason;event SHA|selected source tuple;1;verified;null;null;selected root/receipt;creating row operation/scope/ordinal;null reason
7|INSERT|custody_current|row;transaction;model;release;artifact;custody generation;event SHA|same exact custody tuple including generation
8|INSERT-IF-ABSENT-OR-CAS-IF-PRESENT|catalog_slots|exact model/release with active tuple preserved and pending null|same active tuple;pending exact source/custody/operation/binding tuple;generation+1
9|CAS|protocol_meta|exact generation/evidence/custody-owner/custody/catalog/open/reserve|generation+1;evidence+2;custody-owner+1;custody+1;catalog+0-or-1;transition+1;reserve after progress

initial-activation-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|custody_evidence_owners|complete pending source/artifact/next-generation/creating-operation tuple;existing root and receipt evidence|typed activation owner
4|INSERT|custody_events|full pending source tuple;artifact;next generation;active;predecessor generation/event;existing root/receipt;creating operation UUID/row/scope/registry;initial-activation;event SHA|exact values
5|CAS|custody_current|full pending source tuple/artifact/old generation/event|next generation/active event
6|CAS|catalog_slots|model/release;all active null;full pending tuple;generation|pending tuple becomes active byte-for-byte;pending all null;generation+1
7|CAS|protocol_meta|exact generation/custody-owner/custody/open/reserve|generation+1;custody-owner+1;custody+1;transition+1;reserve after progress

replacement-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|custody_evidence_owners|complete incumbent source/artifact/next-generation/creating-operation tuple;existing root and receipt evidence|typed incumbent release owner
4|INSERT|custody_events|full incumbent source tuple;artifact;next generation;released;predecessor generation/event;existing root/receipt;creating operation UUID/row/scope/registry;replacement;event SHA|exact values
5|CAS|custody_current|full incumbent tuple/artifact/old generation/event|next generation/released event
6|INSERT|custody_evidence_owners|complete replacement source/artifact/next-generation/creating-operation tuple;existing root and receipt evidence|typed replacement activation owner
7|INSERT|custody_events|full replacement source tuple;artifact;next generation;active;predecessor generation/event;existing root/receipt;creating operation UUID/row/scope/registry;replacement;event SHA|exact values
8|CAS|custody_current|full replacement tuple/artifact/old generation/event|next generation/active event
9|CAS|catalog_slots|model/release;full incumbent active tuple;full replacement pending tuple;generation|replacement tuple becomes active byte-for-byte;pending all null;generation+1
10|CAS|protocol_meta|exact generation/custody-owner/custody/open/reserve|generation+1;custody-owner+2;custody+2;transition+1;reserve after progress

allocation-aborted-finish-full
0|INSERT|transitions|finish aborted row|exact progress/auth/generation
1|CAS|operations|exact open allocation/cancel/charges/open_slot=1|aborted;finish SHA;open_slot null;charge release exact
2|CAS|row_slots|exact allocating row/operation/attempt/generation|free when attempt<7 else exhausted;operation null;attempt+1;generation+1
3|CAS|protocol_meta|exact generation/transition/open=1/reserve|generation+1;transition+1;open=0;reserve=0

gc-enqueue (4 changes)
0|INSERT|gc_candidates|row_ordinal;transaction_uuid;model_id;release;artifact_sha256;state;eligible_round;gc_lifecycle_generation;custody_generation;custody_event_sha256;manifest_cursor;delete_phase;active_attempt_ordinal;active_check_generation;helper_operation_uuid;successful_quanta;failure_count;result_count;last_event_sha256|:row;:transaction;:model;:release;:artifact;queued;:round;1;:custody-generation;:custody-event;null;null;null;null;null;0;0;0;:event-1-sha
1|INSERT|gc_events|row_ordinal;transaction_uuid;model_id;release;artifact_sha256;custody_generation;custody_event_sha256;event_generation;predecessor_sha256;state;eligible_round;manifest_cursor;delete_phase;attempt_ordinal;checking_event_generation;helper_operation_uuid;result_role;result_evidence_sha256;gc_event_sha256|:row;:transaction;:model;:release;:artifact;:custody-generation;:custody-event;1;null;queued;:round;null;null;null;null;null;null;null;:event-1-sha
2|CAS|gc_meta|id=1;maximum_round=:old-round;generation=:gc-generation|maximum_round=:round;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_candidate_count=:gcc;gc_event_count=:gec;open_operation_count=0;wal_reserved_bytes=0|generation=:g+1;gc_candidate_count=INC(1);gc_event_count=INC(1)

gc-checking-advance (4 changes)
0|INSERT|gc_events|full selected source/custody tuple;event_generation=:check-generation;predecessor=:old-event;state=checking;eligible_round=:new-round;manifest_cursor=:start-cursor;delete_phase=:start-phase;attempt_ordinal=:attempt;checking_event_generation=:check-generation;helper_operation_uuid=:derived-helper;result fields null;event SHA=:check-event
1|CAS|gc_candidates|full source/custody tuple;last_event=:old-event;state=:eligible-state;eligible_round=:old-round;all cursor/attempt/check/helper/count fields exact|last_event=:check-event;state=checking;eligible_round=:new-round;cursor=:start-cursor;phase=:start-phase;active_attempt=:attempt;active_check_generation=:check-generation;helper=:derived-helper;counts unchanged
2|CAS|gc_meta|id=1;maximum_round=:old-maximum;generation=:gc-generation|maximum_round=:new-round;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec;open_operation_count=0;wal_reserved_bytes=0|generation=:g+1;gc_event_count=INC(1)

gc-result-advance (6 changes)
0|INSERT|evidence_objects|all Appendix-A columns|direct validated deterministic gc_result_v1
1|INSERT|gc_evidence_owners|complete candidate custody tuple;helper_operation_uuid=:helper;semantic_role=gc-result;evidence_sha256=:result-evidence|typed result owner
2|INSERT|gc_events|full selected source/custody tuple;event_generation=:check-generation+1;predecessor=:check-event;state=:result-state;eligible_round=:new-round;manifest_cursor=:end-cursor;delete_phase=:end-phase;attempt_ordinal=:attempt;checking_event_generation=:check-generation;helper_operation_uuid=:helper;result_role=gc-result;result_evidence_sha256=:result-evidence;gc_event_sha256=:result-event
3|CAS|gc_candidates|full checking tuple including check event/start cursor/start phase/attempt/check generation/helper and old counters|last_event=:result-event;state=:result-state;eligible_round=:new-round;cursor/phase/attempt/check/helper are result values or all null iff terminal done/protected;successful_quanta=INC(:success-0-or-1);failure_count=INC(:failure-0-or-1);result_count=INC(1)
4|CAS|gc_meta|id=1;maximum_round=:old-maximum;generation=:gc-generation|maximum_round=:new-round;generation=:gc-generation+1
5|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec;evidence_count=:ec;gc_evidence_owner_count=:geoc;open_operation_count=0;wal_reserved_bytes=0|generation=:g+1;gc_event_count=INC(1);evidence_count=INC(1);gc_evidence_owner_count=INC(1)

gc-first-over-protection (5 changes)
0|INSERT|evidence_objects|all Appendix-A columns with kind=gc-first-over-control|direct validated gc_first_over_control_v1 at deterministic path
1|INSERT|gc_evidence_owners|complete terminal candidate custody tuple;helper_operation_uuid=:control-helper;semantic_role=gc-first-over-control;evidence_sha256=:control-evidence|typed control owner
2|INSERT|gc_events|full selected source/custody tuple;event_generation=50;predecessor_sha256=:event-49;state=protected;eligible_round=:unchanged-round;cursor/phase/attempt/check null;helper_operation_uuid=:control-helper;result_role=gc-first-over-control;result_evidence_sha256=:control-evidence;gc_event_sha256=:event-50
3|CAS|gc_candidates|full source/custody tuple;last_event_sha256=:event-49;state=:terminal-state;eligible_round=:round;successful_quanta=:success;failure_count=:failure;result_count=:results;all active cursor/attempt/check/helper null|last_event_sha256=:event-50;state=protected;eligible_round=:round;counts unchanged;all active fields null
4|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec;evidence_count=:ec;gc_evidence_owner_count=:geoc;open_operation_count=0;wal_reserved_bytes=0|generation=:g+1;gc_event_count=INC(1);evidence_count=INC(1);gc_evidence_owner_count=INC(1)
~~~

For generic progress, `row_state-or-fixed_state` is resolved by `scope`, never
by a caller-provided table name. `SPECIAL` is legal only when the expanded
registry line names one of the literal special templates above.
The manifest line stores every descriptor digest, charge operand, replay
digest, and typed protection code. Labels such as `all Appendix-A columns` are
not runtime wildcards: the manifest compiler replaces them with the one
schema-derived, ordinal-preserving column list and rejects a schema hash change.
`INSERT-IF-ABSENT-OR-CAS-IF-PRESENT` is resolved by a read under the same
`BEGIN IMMEDIATE`; exactly one displayed statement executes and the untouched
active tuple is still an exact CAS predicate. Named full templates replace
generic progress. Descriptor count must equal the registered change count
before execution.

The normalized manifest then includes these closed external effects:

| external template | authorized action | progress proof |
|---|---|---|
| none | no external call | zero intent rows |
| four-existing-source-evidence | direct-open four preexisting R4/R22 evidence paths | four exact evidence rows |
| create-directory | exclusive no-follow mkdir beneath transaction root | direct directory identity evidence |
| create-regular | exclusive temp/write/fsync/rename/parent-fsync | direct regular evidence |
| staging-register | daemon-derived canonical staging path and root receipt | staging_sources plus receipt evidence |
| custody-copy | daemon C0-C7 root-owned copy, two content passes, hardening | root and custody receipt direct evidence |
| replacement-switch | no filesystem action; exact selected pending custody required | catalog/custody nine-row CAS |
| legacy-inspect-readonly | direct-open a manifest-named R4 evidence file | exact evidence or protected; never create |

Every template binds root kind, path bytes and raw byte count, path digest,
length/null, content digest/null, full identity digest, evidence kind, operation
UUID, registry digest, manifest digest, base generation, and maximum charge in
operation authorization. Protection uses the same finish commit and never
performs a second external action.

## Appendix D — complete standalone external codecs

No external codec inherits an unspecified earlier default. `tuple_v1` is ASCII
domain, byte `00`, `u32be(column-count)`, then the columns in the displayed
order. Tags and payloads are exact: null `00`; u63 `01 || u64be(value)`; bool
`02 || 00|01`; text `03 || u32be(raw-byte-count) || NFC-UTF8`; bytes
`04 || u32be(raw-byte-count) || raw-bytes`; UUID
`05 || 16 RFC-4122-network-order bytes`; SHA `06 || 32 bytes`. Lengths are
validated before allocation. Negative/overflow integers, non-NFC text, NUL,
invalid UTF-8, unknown tags, alternate nulls, floats, maps, arrays, trailing
bytes, and fields not listed below reject.

The path digest is always
`SHA256(ASCII("macprovider-relative-path-v1") || 00 ||
u64be(raw-path-byte-count) || raw-path-bytes)`. The file-identity digest is
SHA-256 of tuple domain `macprovider-r22/file-identity` with columns in this
order: `device_id:u63,file_id:u63,file_type:text,mode:u63,owner_uid:u63,
group_gid:u63,link_count:u63,byte_length:u63-or-null,mtime_seconds:u63,
mtime_nanoseconds:u63,ctime_seconds:u63,ctime_nanoseconds:u63,
birthtime_seconds:u63,birthtime_nanoseconds:u63,user_flags:u63,
system_flags:u63`. These are the only path and identity digest targets.

### `custody_receipt_v1`

Tuple domain: `macprovider-r22/custody-receipt-v1`. Direct path:
`receipts/<artifact-hex>/<operation-uuid>.custody-v1`.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | schema | text | no | literal `custody_receipt_v1` |
| 2 | daemon_protocol_version | u63 | no | literal 1 |
| 3 | operation_uuid | uuid | no | selected operation |
| 4 | model_id | text | no | selected signed catalog model |
| 5 | release | text | no | selected signed catalog release |
| 6 | artifact_sha256 | sha | no | SPEC-001 artifact/tree digest |
| 7 | root_relative_path | bytes | no | canonical custody path |
| 8 | root_path_sha256 | sha | no | path digest above |
| 9 | manifest_sha256 | sha | no | SPEC-001 canonical manifest bytes |
| 10 | entry_count | u63 | no | measured, 0...4,096 |
| 11 | canonical_bytes | u63 | no | measured raw total |
| 12 | content_pass_1_sha256 | sha | no | equals artifact_sha256 |
| 13 | content_pass_2_sha256 | sha | no | equals artifact_sha256 |
| 14 | identity_transcript_sha256 | sha | no | custody-entry accumulator below |
| 15 | root_identity_sha256 | sha | no | file-identity digest above |

### `custody-entry`

Tuple domain: `macprovider-r22/custody-entry`. The transcript seed is
`SHA256(ASCII("macprovider-custody-identity-transcript-v1") || 00)`; for each
entry in ascending raw relative-path bytes it becomes
`SHA256(previous || u32be(entry-tuple-byte-count) || entry-tuple)`.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | relative_path | bytes | no | canonical raw relative bytes |
| 2 | file_type | text | no | `regular` or `directory` |
| 3 | mode | u63 | no | captured stat mode |
| 4 | owner_uid | u63 | no | captured stat UID |
| 5 | group_gid | u63 | no | captured stat GID |
| 6 | link_count | u63 | no | literal 1 for regular files |
| 7 | byte_length | u63 | yes, iff directory | raw regular-file bytes |
| 8 | mtime_seconds | u63 | no | captured stat |
| 9 | mtime_nanoseconds | u63 | no | 0...999,999,999 |
| 10 | ctime_seconds | u63 | no | captured stat |
| 11 | ctime_nanoseconds | u63 | no | 0...999,999,999 |
| 12 | birthtime_seconds | u63 | no | captured stat |
| 13 | birthtime_nanoseconds | u63 | no | 0...999,999,999 |
| 14 | user_flags | u63 | no | captured stat |
| 15 | system_flags | u63 | no | includes final `SF_IMMUTABLE` |
| 16 | content_sha256 | sha | yes, iff directory | SHA-256 raw regular bytes |
| 17 | identity_sha256 | sha | no | file-identity digest above |

### `gc_result_v1`

Tuple domain: `macprovider-r22/gc-result-v1`. Direct path:
`gc-results/<artifact-hex>/<attempt-ordinal>-<checking-generation>-<helper-uuid>.gc-v1`.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | schema | text | no | literal `gc_result_v1` |
| 2 | daemon_protocol_version | u63 | no | literal 1 |
| 3 | helper_operation_uuid | uuid | no | section 8 deterministic UUID |
| 4 | artifact_sha256 | sha | no | selected SPEC-001 artifact |
| 5 | custody_generation | u63 | no | selected 1...8 |
| 6 | base_custody_event_sha256 | sha | no | selected custody event identity |
| 7 | gc_lifecycle_generation | u63 | no | literal 1 |
| 8 | attempt_ordinal | u63 | no | 1...24 |
| 9 | checking_event_generation | u63 | no | selected 2...49 |
| 10 | start_phase | text | no | `flags|entries|root|fsync` |
| 11 | start_cursor | u63 | no | 0...4,096 |
| 12 | end_phase | text | no | `flags|entries|root|fsync|complete` |
| 13 | end_cursor | u63 | no | legal monotonic successor |
| 14 | entries_processed | u63 | no | 0...256 |
| 15 | path_bytes_processed | u63 | no | 0...8 MiB |
| 16 | syscalls_processed | u63 | no | 0...1,024 |
| 17 | outcome | text | no | `progress|done|protected|blocked-kernel-io` |
| 18 | root_identity_before_sha256 | sha | no | selected direct root identity |
| 19 | root_identity_after_sha256 | sha | yes | null only per section 10 truth table |

### `gc_first_over_control_v1`

Tuple domain `macprovider-r22/gc-first-over-control-v1`; direct path
`gc-controls/<artifact-hex>/<control-helper>.first-over-v1`.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | schema | text | no | literal `gc_first_over_control_v1` |
| 2 | daemon_protocol_version | u63 | no | literal 1 |
| 3 | control_helper_uuid | uuid | no | first16 SHA of this domain, artifact, custody generation/event, and event-49 SHA |
| 4 | artifact_sha256 | sha | no | selected artifact |
| 5 | custody_generation | u63 | no | selected 1...8 |
| 6 | custody_event_sha256 | sha | no | selected custody event |
| 7 | predecessor_gc_event_sha256 | sha | no | exact event 49 |
| 8 | successful_quanta | u63 | no | stored 0...16 |
| 9 | failure_count | u63 | no | stored 0...8 |
| 10 | result_count | u63 | no | stored 0...24, unchanged |
| 11 | reason | text | no | literal `attempt-budget-exhausted` |
| 12 | database_identity_sha256 | sha | no | section 10 authority identity |

### `staging_source_receipt_v1`

Tuple domain: `macprovider-r22/staging-source-receipt-v1`. Direct path:
`staging-authorizations/<provider-uid>/<transaction-uuid>.source-v1`.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | schema | text | no | literal `staging_source_receipt_v1` |
| 2 | daemon_protocol_version | u63 | no | literal 1 |
| 3 | provider_uid | u63 | no | authenticated audit-token UID |
| 4 | transaction_uuid | uuid | no | selected row transaction |
| 5 | source_token | bytes | no | exactly 32 daemon-random bytes |
| 6 | model_id | text | no | selected signed catalog model |
| 7 | release | text | no | selected signed catalog release |
| 8 | artifact_sha256 | sha | no | SPEC-001 artifact/tree digest |
| 9 | manifest_sha256 | sha | no | SPEC-001 canonical manifest bytes |
| 10 | source_relative_path | bytes | no | daemon-derived canonical path |
| 11 | source_path_sha256 | sha | no | path digest above |
| 12 | entry_count | u63 | no | measured, 0...4,096 |
| 13 | canonical_bytes | u63 | no | measured raw total |
| 14 | identity_transcript_sha256 | sha | no | custody-entry accumulator |
| 15 | source_root_identity_sha256 | sha | no | file-identity digest above |

### `custody_operation_v1`

Tuple domain `macprovider-r22/custody-operation-v1`; direct path is the exact
intent leaf in section 6.2. Columns are: `schema:text` literal; version u63=1;
operation UUID; row u63; transaction UUID; model/release text; artifact and
manifest SHA; staging-receipt and source-token SHA; temp-root, temp-receipt,
final-root, and final-receipt path SHA; entry cursor u63 0...4096; flag cursor
u63 0...4096; receipt-byte cursor u63; phase text in C0...C7; prior-record SHA
nullable only at C0; and record SHA computed over the tuple with that last field
null. A progress record must name the exact prior record and one legal successor.
Path bytes never appear implicitly; each path SHA uses the registered constant
leaf bytes and the Appendix D path preimage.

### `serving_pin_v1`

The daemon signs deterministic Ed25519 over the tuple domain
`macprovider-r22/serving-pin-unsigned-v1` and fields 1...23 below. The serialized
pin uses domain `macprovider-r22/serving-pin-v1` and appends fields 24...25.
The install creates one daemon signing key in the System Keychain as
non-exportable where supported, otherwise a root-owned 0600 operator-state file
outside worktrees; the signed installer receipt pins its public key and key ID.
The app validates the daemon XPC audit token, designated requirement/team/bundle,
installer receipt, key ID, and signature. Rotation requires an approved
installer receipt containing old/new public keys and an overlap generation.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | schema | text | no | literal `serving_pin_v1` |
| 2 | daemon_protocol_version | u63 | no | literal 1 |
| 3 | permit_uuid | uuid | no | daemon random per request |
| 4 | request_uuid | uuid | no | authenticated request |
| 5 | model_id | text | no | selected model |
| 6 | release | text | no | selected release |
| 7 | catalog_generation | u63 | no | selected snapshot generation |
| 8 | row_ordinal | u63 | no | selected row |
| 9 | transaction_uuid | uuid | no | selected source transaction |
| 10 | artifact_sha256 | sha | no | selected artifact |
| 11 | custody_generation | u63 | no | selected generation |
| 12 | custody_event_sha256 | sha | no | selected event |
| 13 | provider_uid | u63 | no | audit-token UID |
| 14 | provider_pid | u63 | no | audit-token PID |
| 15 | provider_pidversion | u63 | no | audit token/process identity |
| 16 | provider_cdhash | sha | no | authenticated code hash |
| 17 | worker_pid | u63 | no | spawned child |
| 18 | worker_pidversion | u63 | no | spawned child identity |
| 19 | worker_cdhash | sha | no | required worker code hash |
| 20 | boot_session_uuid | uuid | no | `kern.bootsessionuuid` canonical UUID |
| 21 | issued_continuous_ns | u63 | no | mach continuous clock |
| 22 | deadline_continuous_ns | u63 | no | issued + at most 15 minutes |
| 23 | channel_nonce_sha256 | sha | no | SHA-256 exact 32-byte first frame |
| 24 | daemon_key_id | text | no | trusted installer receipt key ID |
| 25 | signature | bytes | no | exactly 64 Ed25519 bytes |

The XPC response contains exactly one socket FD. Any extra/missing/nonsocket FD,
wrong peer, wrong 32-byte first frame, signature/key/audit mismatch, replayed
permit/request, boot-session change, deadline expiry, or catalog recheck drift
closes the socket and starts supervised worker termination. The daemon keeps a
bounded used-permit cache through the deadline; a duplicate exact response may
complete the original handshake once, but cannot start a second worker.

### `serving_worker_v1`

Tuple domain `macprovider-r22/serving-worker-v1`; direct path
`serving-workers/<permit-uuid>.worker-v1`. It contains schema/version,
permit UUID, SHA-256 of the complete pin, artifact/custody generation/event,
worker PID/pidversion/cdhash, process-group ID, boot-session UUID, issued/deadline
continuous nanoseconds, state `launching|running|terminating|unreaped`, prior
record SHA nullable only at launch, and record SHA with itself null. It is
prefix-written/fsynced/renamed/parent-fsynced before model open and removed only
after exact reap plus parent fsync.

### `request_outcome_v1`

The byte-stable retry-exhausted response uses tuple domain
`macprovider-r22/request-outcome-unsigned-v1` for fields 1...19 and domain
`macprovider-r22/request-outcome-v1` for all 21 fields.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | schema | text | no | literal `request_outcome_v1` |
| 2 | daemon_protocol_version | u63 | no | literal 1 |
| 3 | outcome | text | no | literal `retry_exhausted` |
| 4 | operation_uuid | uuid | no | generation-seven terminal operation |
| 5 | row_ordinal | u63 | no | selected row |
| 6 | transaction_uuid | uuid | no | selected source transaction |
| 7 | model_id | text | no | selected model |
| 8 | release | text | no | selected release |
| 9 | abort_generation | u63 | no | literal 8 |
| 10 | catalog_generation | u63 | no | exact read generation |
| 11 | finish_sha256 | sha | no | stored A8 finish transition |
| 12 | charge_consumed | u63 | no | stored terminal value |
| 13 | charge_released | u63 | no | stored terminal value |
| 14 | charge_abandoned | u63 | no | stored terminal value |
| 15 | schema_sha256 | sha | no | protocol meta |
| 16 | registry_sha256 | sha | no | protocol meta |
| 17 | semantic_manifest_sha256 | sha | no | protocol meta |
| 18 | database_identity_sha256 | sha | no | section 10 authority identity |
| 19 | request_sha256 | sha | no | exact canonical caller request |
| 20 | daemon_key_id | text | no | trusted key ID |
| 21 | signature | bytes | no | exact Ed25519 signature |

The daemon authenticates the XPC caller, directly validates the V5 database and
stored A8 row through its captured directory FD, and deterministically signs
the unsigned tuple. Ed25519 produces identical bytes for the same tuple/key.
This read/sign path performs no SQLite or filesystem mutation. Any request,
row, database identity, stored charge, key, signature, or caller-code mismatch
fails closed without returning a terminal outcome.
## Appendix E — reproducible Swift callsite inventory

The inventory input is every sorted regular `.swift` file beneath
`phase3-binary/Sources/macprovider-cli` and
`phase3-binary/app/Sources/Malibu`; Tests, `.build`, generated sources, and all
other roots are excluded. The frozen parser is `swiftc -frontend -dump-parse`
from swift-driver 1.148.6 / Apple Swift 6.3.3
(`swiftlang-6.3.3.1.3 clang-2100.1.1.101`). For each file the inventory tool first requires `-dump-parse` success and
extracts declaration kinds, names, and source ranges after removing unstable
`decl_context` addresses. Its bundled byte lexer recognizes identifiers,
ordinary/raw/multiline string literals, line comments, and nested block comments;
it emits only target identifiers outside comments/strings and target string
literal values after Swift escape decoding. The enclosing declaration is the
smallest AST declaration range containing the token. It emits LF-terminated
records:

~~~text
relative-path|declaration-or-target-kind|start-line:start-column|enclosing-declaration|name-or-decoded-literal
~~~

Records cover type/function/init/deinit/subscript/variable declarations and the
exact target identifiers listed below, plus the exact UTF-8 literals `active.json`, `format.json`, `progress.json`,
`maintenance.json`, `pending.json`, `source.json`,
`bootstrap-intent-v1.tmp`, `bootstrap-intent-v1`,
`catalog-state.sqlite3`, `catalog-state.sqlite3-journal`,
`catalog-state.sqlite3-wal`, `catalog-state.sqlite3-shm`, `catalog-read.lock`,
`--read-lock-fd`, and `--read-lifetime-fd`, plus symbols
`captureIndexReceipt`, `recaptureIndexReceipt`, `adoptVerifiedStaging`,
`gcInactive`, `reserveOperation`, `ModelCatalogTransactionStore`,
`MalibuTransactionFiles`, `MalibuTransactionPayload`, and
`MalibuTransactionRequest`. Sorting is raw UTF-8 relative-path bytes, then
numeric source position, record kind, and raw UTF-8 value bytes. Duplicate
records are retained. Output is NFC UTF-8, LF only,
with no CR or trailing whitespace. The implementation PR must check in this
manifest and generator before source edits; independent regeneration must match
its SHA. Any file-set, parser-version, grammar, source, or literal-list change
reopens the plan gate. At the recorded worktree state the exact sorted file-set manifest contains 191
paths, has SHA-256
`ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`, and every
file passes the pinned `-dump-parse` command. This is a file-set checkpoint, not
the required generated declaration/target manifest. Earlier regex counts and
hashes are expressly superseded.

The following migration matrix is complete for the inspected tree; private
helpers remain behind the named owner.

| current file | exact authority-bearing declarations/calls |
|---|---|
| ModelCatalogTransactionStorage.swift | `prepareProjectionStore`; `ModelTransactionDirectory.current/scoped/child/metadata/openFile/read/write/writeWithPublicationOutcome/entries`; `validateCurrent/validateName` |
| ModelCatalogTransactionRetention.swift | `retentionDirectory`; `initializeRetention`; `initializeLegacyRetention`; `decodeActiveIndex`; `captureIndexReceipt`; `recaptureIndexReceipt`; `decodeRetentionRecord`; `snapshotIndex`; `activeReceiptGeneration`; `validateActiveReceiptMembership`; `recoverAllocations`; `reserveOperation`; `maintainRetention`; `retireOne`; `reserveCleanup`; `cleanupRecordsFromIndex`; `captureCompleteCleanupInventory`; `indexCompletedEvaluation`; `prepareRecommendationIndex`; `indexedRecommendation`; `makeModelCatalogRecoveries`; both `makeCompleteModelCatalogRecoveries` overloads |
| ModelCatalogTransactionMigration.swift | `migrationDirectory`; `migrationFile`; `migrationIndexEvidence`; `migrationCapture`; `migrationOrigin`; `validateMigration`; `captureMigrationCompletion`; `migrationCompletion`; `recaptureMigrationProgress`; `initializeBindingMigration` |
| ModelCatalogTransactionReservationMigration.swift | `reservationRoot`; `reservationChild`; `reservationFile`; `reservationClass`; `initialQueued`; `captureReservationAuthority`; `validateReservationIndexShape`; `reservationMigrationSource`; `publishExactImmutable`; `captureReservationCompletion`; `captureReservationMigrationCompletion`; `sourceForReservationIndex`; `progressForReservationIndex`; `reservationCutover`; `reservationClassifyOne`; `receiptDirectory`; `reservationReceiptDirectoryExists`; `publishReservationMetadata`; `recoverReservationPublication`; `recoverReservationPublicationIfNeeded`; `publishReservationDeparture`; `finalizeReservationMigration`; `recoverReservationFinalizing`; `initializeReservationMigration`; `initializeRetentionForActiveEntry` |
| ModelCatalogTransactionEvidence.swift | `ModelTransactionFileEvidence.validate/compactWitness`; `ModelTransactionActiveReceipt.validateLocked`; `ModelTransactionOriginalEvidence.validateProspective/validateLocked`; `captureActiveReceipt`; `commit`; `evidence` |
| ModelCatalogTransactionBindings.swift | `ModelCatalogTransactionBinding.allocated/validate/validateFiles/validateProspective/requireMutable`; `captureProvenance`; `commitEvaluationSuccess`; `recoverBoundEvaluationSuccess` |
| ModelCatalogTransactionArchive.swift | `ModelCatalogTransactionRetirementProof.validate`; `captureRetirementProof`; `validateOriginalBindingEvidence` |
| ModelCatalogTransactions.swift | `ModelCatalogTransactionStore.forConfig/forContext/secure/locked/ownerLock/stagingURL/recordURL/load/cleanupRecords/readPrivate/writePrivate/append/evaluationSuccessTerminal/reserve/validatedCommittedResult/latestCleanup/update/retryBeforeMutation/check/cleanup/reconcile/validatedPreparationSeal/result`; `ModelCatalogTransactionRunner.run/prepare/recommend`; every transaction CLI `run`; `modelCatalogTransactionSetup`; `runModelCatalogTransaction`; `modelCatalogTransactionRead`; `makeModelCatalogLocalActions`; `makeCompleteModelCatalogLocalActions`; `modelCatalogAdoptionAction`; `prepareCompleteModelCatalogRecommendationIndexes`; `modelCatalogDiscoveryMatcher` |
| ModelsSubcommand.swift / ModelCatalogReadCommand.swift | `prepareProjectionStore` callers and every catalog read/action construction call |
| DurableModelArtifactStore.swift | `adoptVerifiedStaging`; `gcInactive`; `MACPROVIDER_MODEL_ARTIFACT_ROOT` staging-root resolution |
| MacProviderCLI.swift | both direct `adoptVerifiedStaging` calls |
| AutotuneRecommend.swift | direct `adoptVerifiedStaging` call |
| app/ModelManagement/ModelCatalogRead.swift | `MalibuCatalogRead.arguments`; `MalibuCatalogReadRunner.run/openLock/execute`; `MalibuModelCLI.catalogReadIsBusy/cancelCatalogRead/readCatalog`; `catalog-read.lock`; child fd 199/200 arguments and descriptor duplication. The lock/FDs serialize and bound snapshot transport only; after B8 they carry no catalog/custody authority and the child receives only V5 snapshot APIs. |
| app/ModelManagement/ModelManagement.swift | `MalibuModelCLIRunning.readCatalog/cancelCatalogRead/catalogReadIsBusy`; `ModelManagementStore.runCatalogRead/refreshCatalogEconomics/stopCatalogVerification`; pending cache loads. These consume typed snapshots and restore UI orchestration only; cache/nonce/busy state cannot select catalog, custody, identity, pricing, or admission truth. |
| app/ModelTransactionControl.swift | `MalibuTransactionFiles` pending.json, executable/snapshot/retired payload paths, control/metadata locks, authorization and bounded process launch; these remain non-authoritative app orchestration caches and receive only V5 responses after B8 |
| app/ModelTransactionPayload.swift | scan/copy/remove of app executable payloads; transport only, never custody/catalog/economics authority and never a direct custody-root writer |
| app/ModelTransactionRequest.swift | cancellation and bounded resource lifecycle; routes cancellation to the V5 operation or terminal read-only outcome and cannot mint a transition/receipt/refund |

The frozen literal bypass inventory additionally includes every production
occurrence of `active.json`, `progress.json`, `maintenance.json`, reservation
sidecar leaf names, `captureIndexReceipt`, `recaptureIndexReceipt`,
`adoptVerifiedStaging`, and `gcInactive`. The implementation slice records the normalized manifest
and hash before source work, then requires every occurrence after B8 to be
absent or mapped to one exact pre-B8-only `R4MigrationReader` branch. Line
numbers are deliberately not authority because concurrent BYOM work can move
them; syntax-qualified file/type/function identity is authority.
