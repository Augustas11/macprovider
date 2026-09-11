# Build 1 reservation search progress addendum R23

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R23 replaces R22 as the reservation, retention, custody, serving-lifetime, and
garbage-collection design candidate. It is reviewed with test specification
R29. This revision deliberately reduces the SQLite design to one broker-owned
connection in rollback-journal mode; it adds a fixed 32-slot serving supervisor
index, byte-exact one-request framing, component-confined provider staging, and
one catalog-binding preimage. Every conflicting R22 SQLite/WAL/VACUUM, serving,
staging, digest, registry-count, generation-50, or migration statement is
withdrawn. R22's finite source/state/charge/custody/GC contracts remain only
where R23 restates them.

The frozen failed-review input is
`docs/product-roadmap/build-1/reviews/reservation-search-progress-r22-plan-sol.md`
with SHA-256
`b5f316a49005bbc77b573544c40786ee3ecfc561a1414a2dd395d02f5324bed9`.
The exact failed-review commit is
`748bd44a122d862c1fea5ca1d7f07b9f85a30b1b`; it reports 0 Critical, 7 High,
and 4 Medium findings. The worktree contains unrelated Build 1 implementation
work. R23 changes no source, test, SPEC, release, deployment, or operator-secret
file.

The source inventory for this revision was taken at worktree HEAD
`748bd44a122d862c1fea5ca1d7f07b9f85a30b1b` with fetched `origin/main`
`7c0aad111e44cb320641bcefae3bf56851e9aaaa`. Dirty source was inspected as
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
and sidecars are the only authority. After selection, only the R23 database is
authority. No runtime dual read, fallback, reconstruction, sidecar write,
directory scan, mutable selector, custom carrier, or promoted root is permitted.
The fixed `catalog-authority.lock` is exclusion metadata only and never catalog
state, evidence, selection, or reconstruction authority.

Current implementation ownership was reinspected. The R4 authority is spread
across ModelCatalogTransactionRetention.swift,
ModelCatalogTransactionReservationMigration.swift,
ModelCatalogTransactionMigration.swift, ModelCatalogTransactionEvidence.swift,
ModelCatalogTransactionBindings.swift, ModelCatalogTransactionArchive.swift,
and ModelCatalogTransactions.swift. Direct artifact adoption is called by
MacProviderCLI.swift and AutotuneRecommend.swift; DurableModelArtifactStore.swift
owns current user-space adoption and enumerating GC. AutotuneDB.swift proves
only that SQLite3 is already linked; its pathname open is not sufficient for
R23.

SPEC-001 and SPEC-044 must be amended and approved before source implementation.
R23 grants no model identity, pricing, admission, settlement, reward,
enforcement, deployment, release, or production authority.

## 2. SQLite file and open protocol

### 2.1 One owner, one connection, rollback journal only

`CatalogAuthorityBrokerV5` is a provider-UID launch agent reached only through
an authenticated XPC protocol. From open until shutdown it owns exactly one
SQLite connection, one main-database FD, and one FD for the distinct leaf
`catalog-authority.lock`. App, CLI, snapshot, custody, serving, and GC callers
receive copied typed values over XPC; they never receive a SQLite handle, VFS
file FD, pager snapshot, or duplicated lock FD. The broker serializes every
request. No second connection, read pool, child connection, attached database,
forked connection, or shared cache is legal.

Before SQLite open, the broker opens `catalog-authority.lock` beneath the
captured retirement-directory FD with
`O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC`, validates regular file, mode 0600, link
count one, owner UID, device and inode, and takes nonblocking `flock(LOCK_EX)`.
That FD is opened once, never duplicated, and closed only after the SQLite
connection and every request have closed. A second broker must fail before
SQLite open. This is an open-file-description lock on a separate inode; closing
the main or journal FD cannot release it. Fork generation is recorded before
open and checked on every callback; a child rejects all access.

`MacProviderDirectoryVFS` uses public `sqlite3_vfs` and version-1
`sqlite3_io_methods`. Registration captures the validated retirement-directory
FD and maps only synthetic main identity
`/__macprovider_catalog_v5__/catalog-state.sqlite3` and its `-journal` suffix to
byte-exact leaves through `openat`, `fstatat`, and `unlinkat`. WAL, SHM,
super-journal, TEMP_DB, null name, URI/query, separator, dot, and unknown names
return a deterministic error. The main file is the only VFS file retaining an
exclusive `flock` for its whole connection lifetime; SQLite logical lock levels
are monotonically checked in process. Journal is a different inode and never
owns a record lock. This design does not call traditional `fcntl` byte locks or
xShm methods and does not depend on sibling-close POSIX semantics.

Each file object implements checked `pread` zero-fill/SHORT_READ, `pwrite`,
`ftruncate`, `fsync` plus `F_FULLFSYNC`, `fstat`, sector/device characteristics,
and the exact required file controls. Main creation is
`O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC` mode 0600 only when bootstrap
supplies CREATE and an initial no-create open returned ENOENT. Existing main and
journal omit CREATE; `O_TRUNC` is never used. `xWrite` and `xTruncate` reject a
main end above 536,870,912 bytes and a journal end above 67,108,864 bytes before
writing. Captured directory and leaves are revalidated before/after recovery,
commit, sync, and delete.

A C oracle must first reproduce R22's failure: a traditional `fcntl` conflict
is blocked before a sibling close and succeeds after it although the locking
and master FDs remain. The R23 prototype must then prove that closing arbitrary
main/journal siblings cannot release either the separate authority `flock` or
the main-file lifetime `flock`; a second broker and second connection remain
rejected through open, journal creation/deletion, commit, recovery, close,
fork, and crash.

### 2.2 Exact runtime profile and executable maintenance policy

Bootstrap opens READWRITE|CREATE|FULLMUTEX through the named VFS. Selected
runtime opens READWRITE|FULLMUTEX with CREATE absent. Both set page_size 4096
before schema creation, journal_mode DELETE, synchronous FULL, foreign_keys ON,
trusted_schema OFF, recursive_triggers OFF, secure_delete ON, locking_mode
EXCLUSIVE, busy_timeout 0, max_page_count 131072, application_id 1297109587,
and user_version 23. The broker enables SQLITE_DBCONFIG_DEFENSIVE, disables
extensions, verifies the single-connection invariant, and requires SQLite 3.37+
plus exact qualified library identity. Startup rejects `-wal` or `-shm`,
recovers a hot rollback journal before reads, and requires journal absence after
recovery. Missing selected main is an authority failure.

The authorizer denies ATTACH, DETACH, all caller PRAGMA mutation after open,
VACUUM, schema mutation after B3, triggers, views, virtual tables, and extension
calls. There is no qualification exception and no copied-fixture VACUUM path.
Physical qualification measures the reachable as-grown database produced by
all legal transactions and crash recoveries. `VACUUM` and its internal
`vacuum_<random>` schema actions are expected to return `SQLITE_AUTH`; no R23
claim depends on them. Full `integrity_check` and `foreign_key_check` run after
candidate recovery, journal recovery, startup, and maintenance while mutation
readiness is unavailable.

## 3. Deterministic bootstrap and selection

B0 freezes the selected R4 `active.json` bytes and each directly referenced
primary/origin/class/lineage file under the old lock. It derives `bootstrap_id`
and candidate path with R23 tuple domains. SHA operands are raw 32-byte values;
source rows encode ordinal, transaction UUID, model, release, and all four
evidence tuples in active-index order. No enumeration, random UUID, timestamp,
JSON reserialization, or host integer enters identity.

The final `bootstrap-intent-v1` is the first durable object. It binds
bootstrap/source/schema/registry/manifest/directory digests, application ID
1297109587, page size 4096, schema version 23, journal mode DELETE, and broker
protocol 1. Prefix-resumable temp write, fsync, rename, and directory fsync
precede main creation.

B3 creates Appendix A atomically, inserts the one `protocol_meta` row, all 495
registry rows, six fixed-state rows, 1,024 row slots, one GC meta row, and
exactly 32 fixed serving slots. B4 imports one source row per transaction. Before
`BEGIN IMMEDIATE` it direct-validates the source tuple at
`bootstrap_row_cursor`, its four evidence SHAs, and one of 16 literal
missing-evidence masks. The transaction inserts missing evidence in role order,
the typed owner, source row, row state, changes the slot free→occupied, and
CASes cursor/counts/generation. Exact changes are `5+popcount(mask)`. Zero/two
CAS rows, changed bytes, wrong mask, cursor skip, or count disagreement rolls
back.

The remaining steps never convert journal modes:

1. B5 commits `b5-import-complete`, closes, recovers a hot journal, runs both
   integrity checks, proves `journal_mode=delete`, and proves journal absence.
2. B6 commits `b6-delete-ready`, closes/reopens through the same VFS, repeats
   checks, and proves no WAL/SHM leaf exists.
3. B6a deletes the exact matching intent and fsyncs the candidate directory.
4. B7 renames candidate to final, fsyncs the parent, opens final directly, and
   commits `ready` plus exact format SHA.
5. B8 prefix-writes/fsyncs `format.json.tmp-v5`, renames over `format.json`,
   fsyncs `.retention-v2`, reopens final, and releases the old lock. Only that
   final parent fsync selects V5.

The directly addressed recovery states are:

| state | legal leaves | database predicate | unique successor |
|---|---|---|---|
| E0 | empty candidate | captured candidate identity | publish intent |
| E1 | prefix temp intent | exact expected prefix; no main | complete intent |
| E2 | final intent | exact intent; no main/journal | create main |
| E3 | intent+main; optional hot journal | zero header or complete B3 predecessor/successor | recover/run B3 |
| I(n), 0≤n<R | intent+main; optional hot journal | schema complete; exact cursor/count n; rows 0..<n complete | recover/run B4(n) |
| I(R) | intent+main; optional hot journal | every import and counter exact | B5 |
| P5 | intent+main; no journal | b5-import-complete | B6 |
| P6 | intent+main; no journal; no WAL/SHM | b6-delete-ready | delete intent |
| P6a | candidate main only | b6-delete-ready | rename final |
| P7 | final main; candidate absent; R4 fence | b6-delete-ready | commit ready |
| P7r | final main; R4 fence | ready and format SHA exact | write temp format |
| P8p | final plus prefix temp format | exact expected prefix | complete temp |
| P8f | final plus full fsynced temp | exact bytes/hash | rename format |
| P8r | final plus exact V5 format | parent-fsync durability unknown | fsync/reopen |
| S | same as P8r | parent fsync/reopen succeed | V5 selected |

Final is checked before candidate; both present protects. Only listed leaves are
accepted. A hot journal is recovered and removed before leaving E3/I. The
intent is never removed while journal recovery remains. Malformed header,
partial schema, row/count mismatch, unexpected leaf, wrong prefix, identity
drift, WAL/SHM, or mismatched format protects without deleting unknown data.
Rollback may remove only exact E0/E1; all later recovery is forward-only.

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
new R23 row. Cancellation after allocation begin but before progress takes the
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
`operations.open_slot=1` admits one open authority mutation. Begin increments
`open_operation_count` zero→one; finish decrements one→zero. There is no WAL
reservation column. Before each commit the VFS requires journal absence or
completes hot-journal recovery; each transaction is capped at 12 changed rows
and the journal VFS hard limit is 64 MiB.

One mutation unit has one authorization and three generation-CAS commits. Begin
binds maximum charge; progress assigns consumed bytes; finish assigns the
remainder once to released only for allocation-A1 or row-A2 abort, or abandoned
for A3+ protection. Terminal components equal maximum. Replay changes zero and
returns the stored transition.

Appendix C is literal. A named special progress template replaces generic
progress and cannot compose with it. Exact counts are:

| template | ordered row effects | exact changes |
|---|---|---:|
| generic begin K=0 | operation, begin transition, meta/open | 3 |
| allocation begin K=4 | operation, four intents, begin transition, row-slot CAS, meta/open | 8 |
| generic progress E | progress transition, operation CAS, row/fixed CAS, E evidence, meta | 4+E |
| allocation success progress | transition, operation, four evidence, source owner/source/row state, slot, meta | 11 |
| allocation cancel progress | transition, operation cancel CAS, meta | 3 |
| staging register progress | transition, operation, row state, receipt evidence, receipt owner, staging source, meta | 7 |
| custody verified/pending progress | transition, operation, row state, two evidence, custody owner/event/current, catalog, meta | 10 |
| initial activation progress | transition, operation, row state, custody owner/event/current, catalog, meta | 8 |
| replacement progress | transition, operation, row state, two custody owners, two events/currents, catalog, meta | 11 |
| generic finish | finish transition, terminal operation, meta/open | 3 |
| allocation-aborted finish | finish transition, terminal operation, row-slot CAS, meta/open | 4 |

Every statement except the explicitly listed evidence inserts changes exactly
one row. The descriptor compiler asserts bind count/order/types, statement and
total changes, old/new counters, and the 12-row ceiling before execution.

### 5.2 One machine-readable registry expansion

`registry_sha256` covers LF-terminated expanded Appendix B records.
`semantic_manifest_sha256` covers normalized Appendix C plus mapping records.
Production dispatch is generated only from those bytes; an independent author
expander must fail on any disagreement. For this exact revision the Appendix B
body (bytes after its heading through the byte before Appendix C's heading) is
`a8b2ba52cc55c66da33af305c6251308615a132235cf12da7617bcdd7b8e1bb8` and the corresponding Appendix C body is
`c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6`. These values are recomputed after every byte change; the implementation
does not accept an author-supplied alternative.

The allocation record is
`allocation|0|allocation|0|allocate-row|free|A2|free|row-normal-76|allocation|four-existing-source-evidence|source-set|allocation|8|10|10|3|3|12`.
Row ordinals 0...75 are imported-proof 3/4/4/4/3/12. Ordinals 76...109 and
110...173 follow Appendix B. The four special mappings are literal and exact:

| registry transition | Appendix C template | progress count |
|---|---|---:|
| prepared-adoption-record | staging-register-progress-full | 7 |
| activation-record | custody-progress-full | 10 |
| checkpoint-record with no incumbent | initial-activation-progress-full | 8 |
| checkpoint-record with incumbent | replacement-progress-full | 11 |

No names `six-row-staging`, `nine-row-custody`, `seven-row-activation`, or
`nine-row-replacement` are legal. Abort receipt progress is 5. All 128 recovery
fixed entries carry one `legacy-inspect-readonly` intent and counts 4/4/3;
other fixed entries have no intent and counts 3/4/3. Expansion must yield
allocation 1, row 174, fixed 320, exactly 128 recovery intents, and
`32S+16R+128=49,280` intents at S=R=1,024.

Charge rules are closed: zero; allocation; exact A3 directory; exact A5 evidence
bytes; SPEC-governed adoption lifecycle; and A1/A2 release. SQLite page or
journal bytes are never economic bytes.

## 6. Catalog, custody, and serving representation

Four typed owner tables make generic evidence non-substitutable.
`source_evidence_owners`, `staging_receipt_owners`,
`custody_evidence_owners`, and `gc_evidence_owners` bind every consumer to the
complete source, artifact, generation, event, operation scope/ordinal, helper,
and semantic role displayed in Appendix A. Each consumer has one composite FK
to its typed parent; each parent has scalar evidence and source/operation FKs.
`custody_current`, active/pending catalog tuples, and GC tuples include custody
generation and event. A splice either fails an FK or the startup semantic
oracle before use.

There is exactly one catalog-binding construction. Its domain is
`macprovider-r23/catalog-binding-v1` and its `tuple_v1` fields, in order, are:

1. schema text literal `catalog_binding_v1`;
2. model_id NFC text;
3. release NFC text;
4. artifact_sha256 raw SHA;
5. custody_generation u63;
6. custody_event_sha256 raw SHA;
7. row_ordinal u63;
8. transaction_uuid UUID;
9. creating_operation_uuid UUID.

`binding_sha256` is SHA-256 of those bytes. Appendix D, manifest compiler,
bootstrap importer, catalog writer, startup, serving, replacement, and GC use
that same function and one golden-vector file. No second domain, omitted field,
or reordered preimage is registered.

### 6.1 Fixed serving slots and one-request lifetime

Appendix A precreates exactly 32 `serving_slots` rows. A free slot has only
ordinal and positive generation; allocating the lowest free slot retains its current
generation and atomically writes state `prepared`, permit UUID, request UUID,
`request_sha256`, complete catalog/custody tuple, catalog binding, provider audit
identity, deterministic worker-record path SHA, boot session, issue/deadline,
and operation generation **before spawn**. Permit/request UUIDs are unique among
nonfree slots. Every restart queries these 32 rows; directory enumeration is
forbidden.

The deterministic root-owned record is
`serving-workers/<slot-ordinal>-<slot-generation>-<permit-uuid>.worker-v1`.
A prepared row can have no process identity. After `posix_spawn`, the original
daemon prefix-publishes `serving_worker_v1` with PID, pidversion, start time,
cdhash, process group, heartbeat sequence/time, pin digest, and shared-lock
identity, then CASes the same SQL slot to `running`. Crash before either write
remains discoverable from the prepared slot and exact path.

The worker receives one shared per-artifact `flock` FD, a parent-death pipe,
and its socket; the provider receives only its socket and signed pin. On a
prepared recovery with no record, the replacement daemon first tries an
exclusive artifact lock. Success prevents any late worker from obtaining the
shared lock and permits the slot to close. If it cannot acquire, it polls only
the deterministic record and leaves the slot `quarantined` if identity cannot
be proven. No enumeration or optimistic release occurs.

The original parent may `waitpid` its child. A replacement daemon **never**
claims reap ownership. It validates public `proc_pidinfo(PROC_PIDTBSDINFO)`
PID/pidversion/start/status plus `proc_pidpath`, code-signing identity, boot UUID,
record heartbeat chain, and `kill(pid,0)`. It signals only an exact matching
process group. Closure requires both (a) observed process absent, PID identity
changed, or public status zombie and (b) successful exclusive acquisition of
the exact artifact lock. `ECHILD` is expected and not used as evidence. A
permission, identity, heartbeat, kill, kernel-I/O, or lock ambiguity transitions
the slot to `quarantined`; the artifact remains unavailable through verified
reboot recovery.

The signed pin includes request SHA and slot ordinal/generation. The daemon
accepts the complete canonical request bytes, capped at 1,048,576, before slot
allocation. `request_sha256=SHA256(request bytes)`; the worker accepts exactly
one `serving_request_v1` frame after the 32-byte nonce. The frame is u32be total
length followed by canonical tuple fields: schema/version, permit UUID, slot
ordinal/generation, request UUID, request SHA, and opaque request bytes. Length,
digest, pin, slot, and worker identity must match. The caller then
`shutdown(SHUT_WR)`. Partial frame, early EOF, trailing byte, second frame,
oversize, different request bytes, or write after half-close terminates without
inference. Cancellation is a separately authenticated XPC call bound to permit,
slot generation, request UUID/SHA; it cannot carry request bytes or a new FD.

Worker output is zero or more bounded `serving_response_chunk_v1` frames
(sequence 0...65535, chunk <=1 MiB, cumulative <=64 MiB) followed by exactly one
`serving_completion_v1` frame binding permit, slot generation, request UUID/SHA,
chunk count, output SHA, outcome enum, and finish time. EOF before completion,
a second completion, output after completion, or sequence/digest mismatch fails.
The slot becomes free only after terminal outcome publication, process/lock
closure proof, record removal/fsync, and one CAS that nulls all fields and
increments slot generation. Old pins then fail even within their 15-minute
clock deadline. The 33rd nonfree slot rejects before spawn.

### 6.2 Directly addressable custody publication

The root daemon creates only these leaves from the authorized operation:

~~~text
custody-operations/<operation-uuid>.intent-v1
custody-operations/<operation-uuid>.intent-v1.next
custody-tmp/<artifact-hex>-<operation-uuid>.root-v1
custody-tmp/<artifact-hex>-<operation-uuid>.receipt-v1.tmp
artifacts/<artifact-hex>.root-v1
receipts/<artifact-hex>/<operation-uuid>.custody-v1
~~~

`custody_operation_v1` binds source receipt/token, source/operation tuple,
artifact/manifest, exact path digests, copy/flag/receipt cursors, phase, and
prior SHA. First intent publication precedes temp creation; each update uses
`.next`, predecessor SHA, rename, and parent fsync. One custody operation is
open globally.

States C0 intent; C1 copy cursor 0...4096; C2 first-pass tree fsynced; C3
hardening cursor; C4 full direct recapture and second content pass; C5 receipt
prefix; C6a final root/temp receipt; C6b final root/final receipt; C7 SQL
acknowledgment have one successor each. Before C4, source drift cancels by
removing only exact manifest temp entries in reverse order. After either final
rename, recovery is forward-only. Intent removal occurs only after exact
root/receipt evidence and event commit. Every open, rename, delete, and recapture
uses captured parent FDs, `openat`/`renameat`/`unlinkat`, no-follow, exact
identity, and no enumeration.

## 7. Component-confined staging-source handoff

The logical source is
`~/Library/Application Support/Malibu/ProviderStaging/v1/<transaction-uuid>/`,
derived from the authenticated provider UID. The root daemon accepts no caller
path or directory FD. Starting with a captured `/` FD, it resolves the account
home through `getpwuid_r`, canonicalizes absolute UTF-8 components, and opens
each component through its parent with
`openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`. Empty, `.`, `..`, slash,
NUL, symlink, mount crossing, and noncanonical component bytes reject.

The home and every staging ancestor must be owned by the provider or root under
an explicit per-component policy, not group/other writable, on the captured home
`st_dev`, and stable in device/inode/birthtime/ctime/mode/UID before and after
the walk. The transaction leaf UUID must equal the selected source transaction.
Every manifest directory is opened through its captured parent with the same
rules. Every regular entry uses
`openat(O_RDONLY|O_NOFOLLOW|O_CLOEXEC)`, must be provider-owned, mode without
setuid/setgid or group/other write, `st_nlink=1`, same device, regular type, and
stable size/device/inode/birthtime/mtime/ctime/mode/UID before and after each
read. Entry names are the manifest's canonical relative byte components only.

Registration performs two complete manifest-order passes and compares the full
identity/content transcript; custody copy performs the same pre/post transcript
and must equal registration. Ancestor rename does not redirect captured FDs;
ancestor replacement at the canonical path is detected by a final root-to-leaf
rewalk and identity comparison. Any mutation, hard link, symlink, bind/mount
crossing, owner/mode change, leaf replacement, or path mismatch cancels before
custody publication.

The root-owned receipt
`staging-authorizations/<uid>/<transaction-uuid>.source-v1` binds provider UID,
all ancestor identities, source transaction/model/release/artifact/manifest,
operation UUID/row, random 32-byte source token SHA, entry transcript, and exact
staging-receipt evidence owner. The custody intent stores this closed reference
before copy. It remains until C7 or audited prepublication cancellation;
cleanup uses SQL/intent references only. An override may be copied into this
canonical tree by unprivileged preparation, but the daemon never consumes the
override path.

## 8. Restart-safe bounded GC

Each quantum helper is
`UUID(first16(SHA256(tuple_v1(domain="macprovider-r23/gc-attempt-v1", artifact_sha256, custody_generation, custody_event_sha256, gc_lifecycle_generation=1, attempt_ordinal, checking_event_generation, start_phase, start_cursor))))`.
Attempt is 1...24; checking generation is next 2...49. Candidate and event store
every input. Retry derives the same UUID; distinct quanta cannot collide by
registry predicate. Each quantum is capped at 256 entries, 8 MiB manifest/path
bytes, 1,024 syscalls, or six seconds.

Enqueue is event 1. At most sixteen successful and eight failed checking/result
pairs consume events through 49. Each result increments result_count once and
exactly one success/failure counter. Normal deletion requires the exclusive
artifact lock and every serving slot for the artifact free. Ambiguous worker or
kernel I/O selects protected/quarantined and retains custody.

The first request beyond the attempt budget is exactly the five-statement
`gc-first-over-protection` transaction in Appendix C. Its candidate CAS predicate
is literal: exact source/custody tuple; `last_event_sha256=:event49`;
`state IN('deleting','blocked-kernel-io')`; `eligible_round=:round`;
`successful_quanta=16`; `failure_count=8`; `result_count=24`;
`manifest_cursor=:cursor` and `delete_phase=:phase` are non-null legal successors;
`active_attempt_ordinal=24`; `active_check_generation=48`; and
`helper_operation_uuid=:attempt24-helper` equals event 48/49's stored helper.
It sets only last event and state protected. The protocol-meta CAS literally
requires `gc_event_count<=51199`, `evidence_count<=49279`,
`gc_evidence_owner_count<=25599`, generation exact, state ready,
open_operation_count zero, and then increments exactly those three counters and
generation by one. Event generation is literal 50 with predecessor event 49.
Exact replay finds the same control evidence/event and candidate protected and
returns bytes with zero changes. Generation 51, wrong cursor/phase/helper,
counts other than 16/8/24, wrong state, or a first-over
counter rolls back.

Result paths are direct:
`gc-results/<artifact-hex>/<attempt>-<checking-generation>-<helper>.gc-v1`.
No SQLite transaction spans deletion. Crash resumes from the stored tuple and
path. Bounds per artifact are 16 success, 8 failure, 24 result evidence, one
control evidence, and 50 events.

## 9. Bounded lifetime and emergency space

SQLite's reviewed 4,096-byte rollback-journal format is the only physical
carrier. Logical caps do not assume rows per page. For R=1,024 the maxima are:

| object | maximum rows |
|---|---:|
| protocol_meta / gc_meta | 1 each |
| transition_registry | 495 |
| fixed_state | 6 |
| row_slots | 1,024 |
| serving_slots | exactly 32 fixed rows |
| source_rows / row_state / verification_state / staging_sources / custody_current / catalog_slots / gc_candidates | R each |
| operations | 174R+8,192+320 = 186,688 |
| operation_external_intents | 32,768+16R+128 = 49,280 |
| transitions | 560,064 |
| evidence_objects | 48R+128 = 49,280 |
| source/staging/custody/GC typed owners | R / R / 8R / 25R |
| custody_events | 8R |
| gc_events | 50R = 51,200 |

All persistent tables are in Appendix A and bounded by CHECK, fixed bootstrap
rows, unique slots, protocol counters, or generation/ordinal ranges. External
state is one custody intent, its one temp root/receipt, at most two intent leaves,
one directly addressed record per nonfree serving slot, and one direct GC result
per active candidate. Serving records cannot exceed 32 because a record requires
a preallocated SQL slot. Closed slot reuse increments generation. GC result and
custody records are reclaimed only through their SQL owner state; protected
objects consume their bounded slot rather than creating another row.

Main is capped by `max_page_count=131072` and VFS end 536,870,912. New begin is
rejected at 114,688 pages, preserving 16,384 pages (64 MiB) for already-open
finish/protection/recovery. Approval requires the **reachable as-grown** maximum
fixture, populated via every legal DML template with maximum-width values and
crash/recovery fragmentation, to remain <=448 MiB before the reserve. VACUUM is
forbidden and cannot be used to pass.

Rollback journal is capped at 67,108,864 bytes by VFS `xWrite`/`xTruncate` before
any crossing write. With serialized commits of <=12 changed rows, the
qualification oracle measures the worst journal delta for every template and
requires <=16 MiB; the 64-MiB cap remains the emergency hard stop. Before each
mutation the broker requires no hot journal, at least 134,217,728 free bytes,
main pages <=114,688 for new work, and zero other open operation. A hot journal
on startup is recovered with mutation disabled. An oversized inherited journal
may be read only for recovery; failure to recover below the hard cap protects.
No reader can retain a journal because no second connection exists.

Every table and index is filled to maximum, every first-over is attempted, and
integrity/FK checks plus `fstat` run after every crash/reopen. A different
SQLite version, page size, filesystem, OS, hardware profile, VFS, or legal
schema reopens physical qualification.

## 10. Canonical scalar, null, digest, and reference registries

Appendix D defines standalone `tuple_v1`. Database INTEGER is u63 except
`cancel_requested` bool; TEXT is NFC without NUL; `_uuid` BLOB is UUID;
`_sha256` and bootstrap_id BLOB are SHA; `relative_path` and `tail` are bytes.
A column matching zero or multiple rules fails generation. SQL NULL maps only to
tuple null where Appendix A permits. Evidence, transition, custody-event, and
GC-event identities hash domain `macprovider-r23/<table>` plus every DDL column
in order with the identity column encoded null.

The closed SHA registry is: bootstrap/source/format as section 3; appendices as
normalized raw LF bytes; file identity/path/content as Appendix D; artifact and
manifest per SPEC-001; authorization as the expanded descriptor plus all
parameters/intents/charge; reference fields as their exact stored FK or direct
record identity; `source_token_sha256` as SHA-256 of the exact 32-byte token;
request SHA as SHA-256 of opaque request bytes; response/output SHA as SHA-256 of
ordered raw chunk payload bytes; and catalog binding **only** as section 6's
nine-field `macprovider-r23/catalog-binding-v1` tuple. The string
`macprovider-r23/catalog-binding` without `-v1` is invalid.

Appendix D is the complete external registry for `custody_receipt_v1`,
`custody-entry`, `gc_result_v1`, `gc_first_over_control_v1`,
`staging_source_receipt_v1`, `custody_operation_v1`, `serving_pin_v1`,
`serving_worker_v1`, `serving_request_v1`, `serving_response_chunk_v1`,
`serving_completion_v1`, `serving_cancel_v1`, and `request_outcome_v1`.
No implicit field is allowed. Path lengths are byte lengths.

GC result roots obey:

| outcome | start | end | before | after |
|---|---|---|---|---|
| progress | non-complete | legal successor | SHA | SHA |
| done | flags/entries/root/fsync | complete | SHA | null |
| protected | any | same/legal successor | SHA | SHA |
| blocked-kernel-io | non-complete | same | SHA | null |

Other combinations reject. Independent minimum/maximum/null/order/digest golden
vectors are required.

## 11. Complete Swift migration matrix

All new code is owned behind CatalogAuthorityV5. R4MigrationReader is the only
type allowed to decode legacy names, and only before B8 or while validating the
deterministic unselected candidate. The cutover matrix is normative. Every lock, lifetime FD, child argument, and
cache below is classified; transport objects never become authority:

| current owner/symbol group | R23 owner/interface | before B8 | after B8 / forbidden bypass proof |
|---|---|---|---|
| Retention.retentionDirectory, initializeRetention | CatalogAuthorityFactory.open | R4 read or bootstrap | V5 only; no active.json write |
| captureIndexReceipt, recaptureIndexReceipt, snapshotIndex | CatalogAuthorityV5.readSnapshot | R4 receipt | one serialized broker snapshot RPC |
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
| ModelCatalogTransactionStore.forConfig/forContext, secure, locked, ownerLock | CatalogAuthorityFactory/CatalogAuthorityV5 | R4 root/lock | broker XPC only; broker owns captured directory FD and sole SQLite connection |
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
manifest, source transcript, staging/custody evidence, serving-slot state, and rollback-journal recovery state.

Metrics expose schema/registry/manifest versions, page/journal/counter headroom,
operation/transition/fixed/row/serving-slot state, replay, SQLite/VFS result, custody/source
capability, artifact state, GC round/cursor/helper/process-lock outcome, and protection
reason. They expose no paths, model bytes, source bytes, secrets, tokens, or
private keys.

Non-goals remain network admission, pricing authority, settlement, rewards,
economic activation, deployment, release, production enforcement, custom
carriers, custom B+ trees, general privileged file copying, and claiming
physical qualification from fixtures.

## 13. R22 finding disposition

| finding | exact R23 correction | R29 proof |
|---|---|---|
| H1 | one broker/connection, version-1 rollback VFS, distinct lifetime `flock`; no `fcntl`, WAL, SHM, or sibling-close reliance | R29-02 |
| H2 | 32 fixed SQL serving slots exist before spawn and directly derive every permit record after empty-memory restart | R29-06/08 |
| H3 | replacement uses public process identity/status plus exclusive-lock disappearance; `ECHILD` is expected and never treated as reap proof | R29-08 |
| H4 | pin includes request SHA and slot generation; one bounded request, chunk, completion, cancel, EOF, half-close protocol is byte-exact | R29-08/12 |
| H5 | root-to-leaf component `openat` confinement, UID/mode/link/device/identity predicates, two passes, rewalk and copy-time race checks | R29-08 |
| H6 | one nine-field `macprovider-r23/catalog-binding-v1` domain/preimage in every producer and consumer | R29-06/12 |
| H7 | registry maps exact Appendix C names/counts 7/10/8/11; author expander and digest checks reject old names/counts | R29-05 |
| M1 | VACUUM has no exception and is outside the physical claim; restrictive authorizer must deny it and as-grown fixture must pass | R29-02/11 |
| M2 | Appendix A digest is regenerated from exact R23 LF bytes after DDL validation | R29-01/06 |
| M3 | both CLI `ModelCatalogRead.swift` and `ModelTransactionContext.swift` read-lock/lifetime/path consumers are explicit in matrix/inventory | R29-12 |
| M4 | generation-50 candidate/meta predicates state literal count sums, active-null fields, and exact first-over bounds | R29-05/09 |

No finding is downgraded, waived, or answered by weaker acceptance. The plan
gate remains closed until an independent GPT-5.6 Sol review reports zero
Critical, High, and Medium findings for the exact R23/R29 hashes.

## Appendix A — normalized authoritative DDL

Normalization removes CR and trailing whitespace and retains exactly one LF
after each SQL statement. No trigger or view exists.

~~~sql
PRAGMA application_id=1297109587;
PRAGMA user_version=23;
CREATE TABLE protocol_meta(id INTEGER PRIMARY KEY CHECK(id=1),schema_version INTEGER NOT NULL CHECK(schema_version=23),bootstrap_id BLOB NOT NULL CHECK(length(bootstrap_id)=32),source_index_sha256 BLOB NOT NULL CHECK(length(source_index_sha256)=32),source_rows_sha256 BLOB NOT NULL CHECK(length(source_rows_sha256)=32),candidate_directory_identity_sha256 BLOB NOT NULL CHECK(length(candidate_directory_identity_sha256)=32),schema_sha256 BLOB NOT NULL CHECK(length(schema_sha256)=32),registry_sha256 BLOB NOT NULL CHECK(length(registry_sha256)=32),semantic_manifest_sha256 BLOB NOT NULL CHECK(length(semantic_manifest_sha256)=32),format_sha256 BLOB CHECK(format_sha256 IS NULL OR length(format_sha256)=32),state TEXT NOT NULL CHECK(state IN('bootstrap','ready','protected')),bootstrap_phase TEXT CHECK(bootstrap_phase IS NULL OR bootstrap_phase IN('b3-schema','b4-import','b5-import-complete','b6-delete-ready','b7-ready')),bootstrap_row_cursor INTEGER NOT NULL CHECK(bootstrap_row_cursor BETWEEN 0 AND 1024),generation INTEGER NOT NULL CHECK(generation>=1),source_row_count INTEGER NOT NULL CHECK(source_row_count BETWEEN 0 AND 1024),operation_count INTEGER NOT NULL CHECK(operation_count BETWEEN 0 AND 186688),transition_count INTEGER NOT NULL CHECK(transition_count BETWEEN 0 AND 560064),intent_count INTEGER NOT NULL CHECK(intent_count BETWEEN 0 AND 49280),evidence_count INTEGER NOT NULL CHECK(evidence_count BETWEEN 0 AND 49280),source_evidence_owner_count INTEGER NOT NULL CHECK(source_evidence_owner_count BETWEEN 0 AND 1024),staging_receipt_owner_count INTEGER NOT NULL CHECK(staging_receipt_owner_count BETWEEN 0 AND 1024),custody_evidence_owner_count INTEGER NOT NULL CHECK(custody_evidence_owner_count BETWEEN 0 AND 8192),gc_evidence_owner_count INTEGER NOT NULL CHECK(gc_evidence_owner_count BETWEEN 0 AND 25600),staging_source_count INTEGER NOT NULL CHECK(staging_source_count BETWEEN 0 AND 1024),custody_event_count INTEGER NOT NULL CHECK(custody_event_count BETWEEN 0 AND 8192),catalog_slot_count INTEGER NOT NULL CHECK(catalog_slot_count BETWEEN 0 AND 1024),gc_candidate_count INTEGER NOT NULL CHECK(gc_candidate_count BETWEEN 0 AND 1024),gc_event_count INTEGER NOT NULL CHECK(gc_event_count BETWEEN 0 AND 51200),open_operation_count INTEGER NOT NULL CHECK(open_operation_count BETWEEN 0 AND 1),journal_hard_limit_bytes INTEGER NOT NULL CHECK(journal_hard_limit_bytes=67108864),page_limit INTEGER NOT NULL CHECK(page_limit=131072),begin_page_limit INTEGER NOT NULL CHECK(begin_page_limit=114688),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((state IN('bootstrap','ready') AND protected_code IS NULL)OR(state='protected' AND protected_code IS NOT NULL)),CHECK((state='bootstrap' AND bootstrap_phase IS NOT NULL AND format_sha256 IS NULL)OR(state='ready' AND bootstrap_phase='b7-ready' AND format_sha256 IS NOT NULL)OR state='protected')) STRICT;
CREATE TABLE serving_slots(slot_ordinal INTEGER PRIMARY KEY CHECK(slot_ordinal BETWEEN 0 AND 31),slot_generation INTEGER NOT NULL CHECK(slot_generation>=1),state TEXT NOT NULL CHECK(state IN('free','prepared','running','terminating','quarantined')),permit_uuid BLOB UNIQUE CHECK(permit_uuid IS NULL OR length(permit_uuid)=16),request_uuid BLOB UNIQUE CHECK(request_uuid IS NULL OR length(request_uuid)=16),request_sha256 BLOB CHECK(request_sha256 IS NULL OR length(request_sha256)=32),model_id TEXT CHECK(model_id IS NULL OR length(model_id) BETWEEN 1 AND 512),release TEXT CHECK(release IS NULL OR length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB CHECK(artifact_sha256 IS NULL OR length(artifact_sha256)=32),custody_generation INTEGER CHECK(custody_generation IS NULL OR custody_generation BETWEEN 1 AND 8),custody_event_sha256 BLOB CHECK(custody_event_sha256 IS NULL OR length(custody_event_sha256)=32),row_ordinal INTEGER,transaction_uuid BLOB CHECK(transaction_uuid IS NULL OR length(transaction_uuid)=16),catalog_binding_sha256 BLOB CHECK(catalog_binding_sha256 IS NULL OR length(catalog_binding_sha256)=32),creating_operation_uuid BLOB CHECK(creating_operation_uuid IS NULL OR length(creating_operation_uuid)=16),provider_uid INTEGER CHECK(provider_uid IS NULL OR provider_uid BETWEEN 0 AND 2305843009213693951),provider_pid INTEGER CHECK(provider_pid IS NULL OR provider_pid BETWEEN 1 AND 2305843009213693951),provider_pidversion INTEGER CHECK(provider_pidversion IS NULL OR provider_pidversion BETWEEN 0 AND 2305843009213693951),provider_cdhash BLOB CHECK(provider_cdhash IS NULL OR length(provider_cdhash)=32),record_path_sha256 BLOB CHECK(record_path_sha256 IS NULL OR length(record_path_sha256)=32),boot_session_uuid BLOB CHECK(boot_session_uuid IS NULL OR length(boot_session_uuid)=16),issued_continuous_ns INTEGER CHECK(issued_continuous_ns IS NULL OR issued_continuous_ns BETWEEN 0 AND 2305843009213693951),deadline_continuous_ns INTEGER CHECK(deadline_continuous_ns IS NULL OR deadline_continuous_ns BETWEEN 0 AND 2305843009213693951),worker_pid INTEGER CHECK(worker_pid IS NULL OR worker_pid BETWEEN 1 AND 2305843009213693951),worker_pidversion INTEGER CHECK(worker_pidversion IS NULL OR worker_pidversion BETWEEN 0 AND 2305843009213693951),worker_start_seconds INTEGER CHECK(worker_start_seconds IS NULL OR worker_start_seconds BETWEEN 0 AND 2305843009213693951),worker_start_nanoseconds INTEGER CHECK(worker_start_nanoseconds IS NULL OR worker_start_nanoseconds BETWEEN 0 AND 999999999),worker_cdhash BLOB CHECK(worker_cdhash IS NULL OR length(worker_cdhash)=32),process_group_id INTEGER CHECK(process_group_id IS NULL OR process_group_id BETWEEN 1 AND 2305843009213693951),heartbeat_sequence INTEGER CHECK(heartbeat_sequence IS NULL OR heartbeat_sequence BETWEEN 0 AND 2305843009213693951),heartbeat_continuous_ns INTEGER CHECK(heartbeat_continuous_ns IS NULL OR heartbeat_continuous_ns BETWEEN 0 AND 2305843009213693951),last_record_sha256 BLOB CHECK(last_record_sha256 IS NULL OR length(last_record_sha256)=32),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256) REFERENCES custody_current(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(creating_operation_uuid,row_ordinal) REFERENCES operations(operation_uuid,row_ordinal),CHECK((state='free' AND permit_uuid IS NULL AND request_uuid IS NULL AND request_sha256 IS NULL AND model_id IS NULL AND release IS NULL AND artifact_sha256 IS NULL AND custody_generation IS NULL AND custody_event_sha256 IS NULL AND row_ordinal IS NULL AND transaction_uuid IS NULL AND catalog_binding_sha256 IS NULL AND creating_operation_uuid IS NULL AND provider_uid IS NULL AND provider_pid IS NULL AND provider_pidversion IS NULL AND provider_cdhash IS NULL AND record_path_sha256 IS NULL AND boot_session_uuid IS NULL AND issued_continuous_ns IS NULL AND deadline_continuous_ns IS NULL AND worker_pid IS NULL AND worker_pidversion IS NULL AND worker_start_seconds IS NULL AND worker_start_nanoseconds IS NULL AND worker_cdhash IS NULL AND process_group_id IS NULL AND heartbeat_sequence IS NULL AND heartbeat_continuous_ns IS NULL AND last_record_sha256 IS NULL AND protected_code IS NULL)OR(state!='free' AND permit_uuid IS NOT NULL AND request_uuid IS NOT NULL AND request_sha256 IS NOT NULL AND model_id IS NOT NULL AND release IS NOT NULL AND artifact_sha256 IS NOT NULL AND custody_generation IS NOT NULL AND custody_event_sha256 IS NOT NULL AND row_ordinal IS NOT NULL AND transaction_uuid IS NOT NULL AND catalog_binding_sha256 IS NOT NULL AND creating_operation_uuid IS NOT NULL AND provider_uid IS NOT NULL AND provider_pid IS NOT NULL AND provider_pidversion IS NOT NULL AND provider_cdhash IS NOT NULL AND record_path_sha256 IS NOT NULL AND boot_session_uuid IS NOT NULL AND issued_continuous_ns IS NOT NULL AND deadline_continuous_ns>issued_continuous_ns AND ((worker_pid IS NULL AND worker_pidversion IS NULL AND worker_start_seconds IS NULL AND worker_start_nanoseconds IS NULL AND worker_cdhash IS NULL AND process_group_id IS NULL AND heartbeat_sequence IS NULL AND heartbeat_continuous_ns IS NULL AND last_record_sha256 IS NULL)OR(worker_pid IS NOT NULL AND worker_pidversion IS NOT NULL AND worker_start_seconds IS NOT NULL AND worker_start_nanoseconds IS NOT NULL AND worker_cdhash IS NOT NULL AND process_group_id IS NOT NULL AND heartbeat_sequence IS NOT NULL AND heartbeat_continuous_ns IS NOT NULL AND last_record_sha256 IS NOT NULL)) AND ((state IN('running','terminating') AND worker_pid IS NOT NULL)OR(state='prepared' AND worker_pid IS NULL)OR state='quarantined') AND ((state='quarantined' AND protected_code IS NOT NULL)OR(state!='quarantined' AND protected_code IS NULL))))) STRICT;
CREATE UNIQUE INDEX idx_serving_nonfree_permit ON serving_slots(permit_uuid) WHERE state!='free';
CREATE INDEX idx_serving_artifact_state ON serving_slots(artifact_sha256,state) WHERE state!='free';
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
`70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f`.

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
K+2|CAS|protocol_meta|id=1;state=ready;generation=:g;operation_count=:oc;transition_count=:tc;intent_count=:ic;open_operation_count=0|generation=:g+1;operation_count=INC(1);transition_count=INC(1);intent_count=INC(K);open_operation_count=1

allocation-begin-addition
A0|CAS|row_slots|row_ordinal=:row;state=free;allocation_operation_uuid=null;source_transaction_uuid=null;allocation_attempts=:attempt;generation=:row-generation|state=allocating;allocation_operation_uuid=:operation;generation=:row-generation+1

generic-progress
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state-or-fixed_state|:domain-primary-key;:manifest-coarse-from;:manifest-fine-from;generation=:domain-generation|:manifest-coarse-to;:manifest-fine-to;generation=:domain-generation+1;:manifest-counter-setters
3..2+E|INSERT|evidence_objects|evidence_sha256;kind;root_kind;relative_path;path_sha256;byte_length;content_sha256;device_id;file_id;file_type;mode;owner_uid;group_gid;link_count;mtime_seconds;mtime_nanoseconds;ctime_seconds;ctime_nanoseconds;birthtime_seconds;birthtime_nanoseconds;user_flags;system_flags;identity_sha256;created_generation|:direct-evidence-fields
3+E..2+E+S|SPECIAL|:manifest-special-table|:manifest-special-columns-and-old-predicate|:manifest-special-values
3+E+S|CAS|protocol_meta|id=1;state=ready;generation=:g;transition_count=:tc;evidence_count=:ec;open_operation_count=1;:special-counters-old|generation=:g+1;transition_count=INC(1);evidence_count=INC(E);:special-counters-new

generic-finish
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;2;finish;:g;:g+1;:progress-sha;:authorization;0;:terminal-outcome;:finish-sha
1|CAS|operations|operation_uuid=:operation;phase=open;authorization_sha256=:authorization;charge_consumed=:consumed;charge_released=:released;charge_abandoned=:abandoned;finish_sha256=null|phase=:terminal-outcome;open_slot=null;finish_sha256=:finish-sha
2|CAS|protocol_meta|id=1;state=ready;generation=:g;transition_count=:tc;open_operation_count=1|generation=:g+1;transition_count=INC(1);open_operation_count=0

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
10|CAS|protocol_meta|exact generation/counts/open=1|generation+1;source+1;source-owner+1;evidence+4;transition+1

allocation-cancel-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;0;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;scope=allocation;phase=open;open_slot=1;authorization_sha256=:authorization;cancel_requested=0;charge_consumed=0;charge_released=0;charge_abandoned=0|cancel_requested=1
2|CAS|protocol_meta|exact generation/transition/open=1|generation+1;transition+1

staging-register-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|evidence_objects|all Appendix-A columns|direct staging receipt
4|INSERT|staging_receipt_owners|complete source/artifact/operation tuple;receipt_evidence_sha256|typed staging receipt owner
5|INSERT|staging_sources|transaction_uuid;row_ordinal;model_id;release;artifact_sha256;operation_uuid;operation_row_ordinal;source_token_sha256;receipt_evidence_sha256;state;generation;protected_code|exact selected source/artifact/operation/token/receipt;registered;successor;null
6|CAS|protocol_meta|exact generation/evidence/staging-owner/staging/open=1|generation+1;evidence+1;staging-owner+1;staging+1;transition+1

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
9|CAS|protocol_meta|exact generation/evidence/custody-owner/custody/catalog/open=1|generation+1;evidence+2;custody-owner+1;custody+1;catalog+0-or-1;transition+1

initial-activation-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|custody_evidence_owners|complete pending source/artifact/next-generation/creating-operation tuple;existing root and receipt evidence|typed activation owner
4|INSERT|custody_events|full pending source tuple;artifact;next generation;active;predecessor generation/event;existing root/receipt;creating operation UUID/row/scope/registry;initial-activation;event SHA|exact values
5|CAS|custody_current|full pending source tuple/artifact/old generation/event|next generation/active event
6|CAS|catalog_slots|model/release;all active null;full pending tuple;generation|pending tuple becomes active byte-for-byte;pending all null;generation+1
7|CAS|protocol_meta|exact generation/custody-owner/custody/open=1|generation+1;custody-owner+1;custody+1;transition+1

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
10|CAS|protocol_meta|exact generation/custody-owner/custody/open=1|generation+1;custody-owner+2;custody+2;transition+1

allocation-aborted-finish-full
0|INSERT|transitions|finish aborted row|exact progress/auth/generation
1|CAS|operations|exact open allocation/cancel/charges/open_slot=1|aborted;finish SHA;open_slot null;charge release exact
2|CAS|row_slots|exact allocating row/operation/attempt/generation|free when attempt<7 else exhausted;operation null;attempt+1;generation+1
3|CAS|protocol_meta|exact generation/transition/open=1|generation+1;transition+1;open=0

gc-enqueue (4 changes)
0|INSERT|gc_candidates|row_ordinal;transaction_uuid;model_id;release;artifact_sha256;state;eligible_round;gc_lifecycle_generation;custody_generation;custody_event_sha256;manifest_cursor;delete_phase;active_attempt_ordinal;active_check_generation;helper_operation_uuid;successful_quanta;failure_count;result_count;last_event_sha256|:row;:transaction;:model;:release;:artifact;queued;:round;1;:custody-generation;:custody-event;null;null;null;null;null;0;0;0;:event-1-sha
1|INSERT|gc_events|row_ordinal;transaction_uuid;model_id;release;artifact_sha256;custody_generation;custody_event_sha256;event_generation;predecessor_sha256;state;eligible_round;manifest_cursor;delete_phase;attempt_ordinal;checking_event_generation;helper_operation_uuid;result_role;result_evidence_sha256;gc_event_sha256|:row;:transaction;:model;:release;:artifact;:custody-generation;:custody-event;1;null;queued;:round;null;null;null;null;null;null;null;:event-1-sha
2|CAS|gc_meta|id=1;maximum_round=:old-round;generation=:gc-generation|maximum_round=:round;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_candidate_count=:gcc;gc_event_count=:gec;open_operation_count=0|generation=:g+1;gc_candidate_count=INC(1);gc_event_count=INC(1)

gc-checking-advance (4 changes)
0|INSERT|gc_events|full selected source/custody tuple;event_generation=:check-generation;predecessor=:old-event;state=checking;eligible_round=:new-round;manifest_cursor=:start-cursor;delete_phase=:start-phase;attempt_ordinal=:attempt;checking_event_generation=:check-generation;helper_operation_uuid=:derived-helper;result fields null;event SHA=:check-event
1|CAS|gc_candidates|full source/custody tuple;last_event=:old-event;state=:eligible-state;eligible_round=:old-round;all cursor/attempt/check/helper/count fields exact|last_event=:check-event;state=checking;eligible_round=:new-round;cursor=:start-cursor;phase=:start-phase;active_attempt=:attempt;active_check_generation=:check-generation;helper=:derived-helper;counts unchanged
2|CAS|gc_meta|id=1;maximum_round=:old-maximum;generation=:gc-generation|maximum_round=:new-round;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec;open_operation_count=0|generation=:g+1;gc_event_count=INC(1)

gc-result-advance (6 changes)
0|INSERT|evidence_objects|all Appendix-A columns|direct validated deterministic gc_result_v1
1|INSERT|gc_evidence_owners|complete candidate custody tuple;helper_operation_uuid=:helper;semantic_role=gc-result;evidence_sha256=:result-evidence|typed result owner
2|INSERT|gc_events|full selected source/custody tuple;event_generation=:check-generation+1;predecessor=:check-event;state=:result-state;eligible_round=:new-round;manifest_cursor=:end-cursor;delete_phase=:end-phase;attempt_ordinal=:attempt;checking_event_generation=:check-generation;helper_operation_uuid=:helper;result_role=gc-result;result_evidence_sha256=:result-evidence;gc_event_sha256=:result-event
3|CAS|gc_candidates|full checking tuple including check event/start cursor/start phase/attempt/check generation/helper and old counters|last_event=:result-event;state=:result-state;eligible_round=:new-round;cursor/phase/attempt/check/helper are result values or all null iff terminal done/protected;successful_quanta=INC(:success-0-or-1);failure_count=INC(:failure-0-or-1);result_count=INC(1)
4|CAS|gc_meta|id=1;maximum_round=:old-maximum;generation=:gc-generation|maximum_round=:new-round;generation=:gc-generation+1
5|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec;evidence_count=:ec;gc_evidence_owner_count=:geoc;open_operation_count=0|generation=:g+1;gc_event_count=INC(1);evidence_count=INC(1);gc_evidence_owner_count=INC(1)

gc-first-over-protection (5 changes)
0|INSERT|evidence_objects|all Appendix-A columns with kind=gc-first-over-control|direct validated gc_first_over_control_v1 at deterministic path
1|INSERT|gc_evidence_owners|complete terminal candidate custody tuple;helper_operation_uuid=:control-helper;semantic_role=gc-first-over-control;evidence_sha256=:control-evidence|typed control owner
2|INSERT|gc_events|full selected source/custody tuple;event_generation=50;predecessor_sha256=:event-49;state=protected;eligible_round=:unchanged-round;cursor/phase/attempt/check null;helper_operation_uuid=:control-helper;result_role=gc-first-over-control;result_evidence_sha256=:control-evidence;gc_event_sha256=:event-50
3|CAS|gc_candidates|full source/custody tuple;last_event_sha256=:event-49;state IN(deleting,blocked-kernel-io);eligible_round=:round;successful_quanta=16;failure_count=8;result_count=24;manifest_cursor=:cursor;delete_phase=:phase;active_attempt_ordinal=24;active_check_generation=48;helper_operation_uuid=:attempt24-helper|last_event_sha256=:event-50;state=protected;eligible_round/counts unchanged;manifest_cursor/delete_phase/active_attempt_ordinal/active_check_generation/helper_operation_uuid all null
4|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec AND :gec<=51199;evidence_count=:ec AND :ec<=49279;gc_evidence_owner_count=:geoc AND :geoc<=25599;open_operation_count=0|generation=:g+1;gc_event_count=:gec+1;evidence_count=:ec+1;gc_evidence_owner_count=:geoc+1

serving-prepare (2 changes)
0|CAS|serving_slots|slot_ordinal=:lowest-free;slot_generation=:sg;state=free;every nullable column null|state=prepared;slot_generation unchanged;complete permit/request/catalog/custody/provider/path/boot/time tuple;worker and record fields null
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-running (2 changes)
0|CAS|serving_slots|slot/slot-generation/state=prepared and exact complete base tuple;worker fields null|state=running;exact worker PID/pidversion/start/cdhash/process-group/heartbeat/record SHA
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-terminating (2 changes)
0|CAS|serving_slots|exact slot generation/base/worker/last-record tuple;state=running|state=terminating;exact successor record SHA
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-quarantine-prepared (2 changes)
0|CAS|serving_slots|exact slot generation/base tuple;state=prepared;all worker/heartbeat/record columns null|state=quarantined;same null worker tuple;protected_code=:code
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-quarantine-running (2 changes)
0|CAS|serving_slots|exact slot generation/base/worker/last-record tuple;state=running|state=quarantined;same worker/record tuple;protected_code=:code
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-quarantine-terminating (2 changes)
0|CAS|serving_slots|exact slot generation/base/worker/last-record tuple;state=terminating|state=quarantined;same worker/record tuple;protected_code=:code
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

Before a worker-bearing serving-free template, the broker directly validates
the root-owned terminal worker record and signed completion containing the exact
public process observation and exclusive-lock acquisition receipt; its SHA is
the displayed terminal-record column. A prepared slot can free only while the
broker continuously holds the exclusive artifact lock, proving no inherited
worker lock exists. These are mandatory compiler preconditions, not SQL
predicates. A quarantined-empty free additionally requires a recorded verified
reboot epoch.

serving-free-prepared (2 changes)
0|CAS|serving_slots|exact slot generation/base tuple;state=prepared;all worker/heartbeat/record columns null|slot_generation=:sg+1;state=free;every nullable column null
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-free-running (2 changes)
0|CAS|serving_slots|exact slot generation/base/worker/terminal-record tuple;state=running|slot_generation=:sg+1;state=free;every nullable column null
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-free-terminating (2 changes)
0|CAS|serving_slots|exact slot generation/base/worker/terminal-record tuple;state=terminating|slot_generation=:sg+1;state=free;every nullable column null
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-free-quarantined-empty (2 changes)
0|CAS|serving_slots|exact slot generation/base/protection;state=quarantined;all worker columns null|slot_generation=:sg+1;state=free;every nullable column null
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1

serving-free-quarantined-worker (2 changes)
0|CAS|serving_slots|exact slot generation/base/worker/terminal-record/protection tuple;state=quarantined|slot_generation=:sg+1;state=free;every nullable column null
1|CAS|protocol_meta|id=1;state=ready;generation=:g;open_operation_count=0|generation=:g+1
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
| four-existing-source-evidence | direct-open four preexisting R4/R23 evidence paths | four exact evidence rows |
| create-directory | exclusive no-follow mkdir beneath transaction root | direct directory identity evidence |
| create-regular | exclusive temp/write/fsync/rename/parent-fsync | direct regular evidence |
| staging-register | daemon-derived canonical staging path and root receipt | staging_sources plus receipt evidence |
| custody-copy | daemon C0-C7 root-owned copy, two content passes, hardening | root and custody receipt direct evidence |
| replacement-switch | no filesystem action; exact selected pending custody required | catalog/custody eleven-row CAS |
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
SHA-256 of tuple domain `macprovider-r23/file-identity` with columns in this
order: `device_id:u63,file_id:u63,file_type:text,mode:u63,owner_uid:u63,
group_gid:u63,link_count:u63,byte_length:u63-or-null,mtime_seconds:u63,
mtime_nanoseconds:u63,ctime_seconds:u63,ctime_nanoseconds:u63,
birthtime_seconds:u63,birthtime_nanoseconds:u63,user_flags:u63,
system_flags:u63`. These are the only path and identity digest targets.

### `custody_receipt_v1`

Tuple domain: `macprovider-r23/custody-receipt-v1`. Direct path:
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

Tuple domain: `macprovider-r23/custody-entry`. The transcript seed is
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

Tuple domain: `macprovider-r23/gc-result-v1`. Direct path:
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

Tuple domain `macprovider-r23/gc-first-over-control-v1`; direct path
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

Tuple domain: `macprovider-r23/staging-source-receipt-v1`. Direct path:
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
| 16 | operation_uuid | uuid | no | exact authorized row operation |
| 17 | row_ordinal | u63 | no | exact selected source row |
| 18 | ancestor_count | u63 | no | canonical root-to-source components, 1...32 |
| 19 | ancestor_identity_transcript_sha256 | sha | no | ordered component identities and policy |
| 20 | second_pass_transcript_sha256 | sha | no | exact independent second pass |

### `catalog_binding_v1`

Domain and nine fields are exactly section 6. `binding_sha256` is not encoded as
an input field; it is SHA-256 of the tuple. The one golden vector fixes raw bytes
for minimum and maximum legal text/u63 values. No other catalog-binding codec is
registered.

### `custody_operation_v1`

Tuple domain `macprovider-r23/custody-operation-v1`; direct path is the exact
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

Unsigned domain `macprovider-r23/serving-pin-unsigned-v1`; serialized domain
`macprovider-r23/serving-pin-v1`. Fields 1...27 are signed; 28...29 follow.

| # | field | type | exact target |
|---:|---|---|---|
| 1 | schema | text | `serving_pin_v1` |
| 2 | daemon_protocol_version | u63 | 1 |
| 3 | permit_uuid | uuid | random unique permit |
| 4 | serving_slot_ordinal | u63 | 0...31 |
| 5 | serving_slot_generation | u63 | allocated generation |
| 6 | request_uuid | uuid | authenticated request |
| 7 | request_sha256 | sha | exact opaque request bytes |
| 8-9 | model_id, release | text | selected catalog key |
| 10 | catalog_generation | u63 | selected snapshot |
| 11 | row_ordinal | u63 | selected row |
| 12 | transaction_uuid | uuid | selected source |
| 13 | artifact_sha256 | sha | selected artifact |
| 14 | custody_generation | u63 | selected custody |
| 15 | custody_event_sha256 | sha | selected event |
| 16 | catalog_binding_sha256 | sha | section 6 preimage |
| 17-19 | provider_uid, provider_pid, provider_pidversion | u63 | audit-token identity |
| 20 | provider_cdhash | sha | authenticated caller |
| 21-22 | worker_pid, worker_pidversion | u63 | spawned identity |
| 23 | worker_cdhash | sha | approved worker code |
| 24 | boot_session_uuid | uuid | canonical boot UUID |
| 25-26 | issued_continuous_ns, deadline_continuous_ns | u63 | deadline ≤ issue+15 min |
| 27 | channel_nonce_sha256 | sha | exact 32-byte nonce |
| 28 | daemon_key_id | text | installer-pinned key |
| 29 | signature | bytes | 64-byte Ed25519 over unsigned tuple |

The System Keychain/root-state signing-key, installer receipt, audit-token,
rotation, and nonexportability requirements from R22 remain. Every listed field
is independently checked against the SQL serving slot and direct worker record.

### `serving_worker_v1`

Domain `macprovider-r23/serving-worker-v1`; direct path is the slot-derived path
in section 6. Fields are schema/version; slot ordinal/generation; permit and
request UUID/SHA; full artifact/custody/catalog binding; pin SHA; worker
PID/pidversion/start seconds/nanoseconds/cdhash/process group; boot UUID;
heartbeat sequence/continuous time; shared-lock file identity SHA; state
`running|terminating|quarantined`; prior record SHA nullable only on first
record; and record SHA computed with itself null. Publication is prefix temp,
fsync, rename, parent fsync. Each heartbeat is one successor with sequence +1.

### `serving_request_v1`

Wire is exactly `u32be(payload_length)` followed by one canonical `tuple_v1`
with domain `macprovider-r23/serving-request-v1`. Frame payload length is 1...1,100,000
and equals all following bytes. Opaque request bytes are 0...1,048,576. Tuple fields are schema text; protocol u63=1;
permit UUID; slot ordinal/generation u63; request UUID; request SHA; and opaque
request bytes. The digest must equal SHA-256 of the opaque bytes. No bytes may
follow before caller `shutdown(SHUT_WR)`.

### `serving_response_chunk_v1`

Each frame is `u32be(tuple_length)` plus domain
`macprovider-r23/serving-response-chunk-v1`; length ≤1,048,576 plus fixed tuple
overhead. Fields: schema/version; permit UUID; slot ordinal/generation; request
UUID/SHA; sequence u63 0...65535; raw chunk bytes; chunk SHA. Cumulative chunk
bytes are ≤67,108,864.

### `serving_completion_v1`

One terminal frame uses the same u32be envelope and domain
`macprovider-r23/serving-completion-v1`. Fields: schema/version; permit UUID;
slot ordinal/generation; request UUID/SHA; chunk count u63; output byte count
u63; output SHA over ordered raw chunks; outcome text
`complete|cancelled|failed|expired|quarantined`; completion continuous ns;
worker-record SHA; daemon key ID; 64-byte Ed25519 signature over the preceding
fields with unsigned domain `macprovider-r23/serving-completion-unsigned-v1`.

### `serving_cancel_v1`

Authenticated XPC tuple domain `macprovider-r23/serving-cancel-v1`; fields are
schema/version; permit UUID; slot ordinal/generation; request UUID/SHA; provider
UID/PID/pidversion/cdhash from the current audit token; and continuous time. It
contains no FD, payload, alternative identity, or model selector.

### `request_outcome_v1`

The byte-stable retry-exhausted response uses tuple domain
`macprovider-r23/request-outcome-unsigned-v1` for fields 1...19 and domain
`macprovider-r23/request-outcome-v1` for all 21 fields.

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
`catalog-state.sqlite3-wal`, `catalog-state.sqlite3-shm`, `catalog-authority.lock`, `serving-workers`, `catalog-read.lock`,
`--read-lock-fd`, and `--read-lifetime-fd`, plus symbols
`captureIndexReceipt`, `recaptureIndexReceipt`, `adoptVerifiedStaging`,
`gcInactive`, `reserveOperation`, `ModelCatalogTransactionStore`,
`MalibuTransactionFiles`, `MalibuTransactionPayload`, and
`MalibuTransactionRequest`, `ModelCatalogReadOptions`,
`ModelCatalogReadBudget`, `ModelCatalogReadEvents`, `ModelCatalogReadLease`,
`ModelTransactionControlLease`, `readLockFD`, `readLifetimeFD`, `controlLockFD`,
`controlLifetimeFD`, `transactionContextFD`, and `flock`. Sorting is raw UTF-8 relative-path bytes, then
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
| ModelCatalogRead.swift | `ModelCatalogReadMode`, `ModelCatalogReadError`, `ModelCatalogReadOptions` including `readLockFD`/`readLifetimeFD`, `ModelCatalogReadBudget`, `ModelCatalogReadEvents.start/complete/fail/emit`, and all read-mode entrypoints become broker snapshot RPC consumers; fd 199/200 remain child transport/lifetime only and never SQLite or custody authority |
| ModelTransactionContext.swift | `PreparedModelTransactionContext`, `BoundModelTransactionContext`, `ModelTransactionContextLoader`, `TransactionContextFiles`, `ModelCatalogReadLease.start`, `ModelTransactionControlLease.start`, all `flock` comparisons, lifetime pipes, ancestor/path identity, projection/store root validation become pre-B8 compatibility or transport checks; after B8 only the broker owns catalog locking and these FDs cannot keep a SQLite snapshot, serving permit, custody lock, or catalog generation alive |
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
