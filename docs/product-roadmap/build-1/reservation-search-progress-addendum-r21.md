# Build 1 reservation search progress addendum R21

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R21 replaces R20 as the reservation, retention, custody, and garbage-collection
design candidate. It is reviewed with test specification R27. R21 preserves
R20's deletion of the custom carrier/B+ tree design, the finite SHA-256 oracle,
the root-owned custody boundary, direct evidence references, A1/A2-only refund,
A3+ forward completion, and the physical qualification gate. Every conflicting
R20 schema, count, state, bootstrap, SQLite-open, registry, GC, source-handoff,
or migration statement is withdrawn.

The frozen failed-review input is
docs/product-roadmap/build-1/reviews/reservation-search-progress-r20-plan-sol.md
with SHA-256
a9f0f5258fba1d517f30b7f6d25cca1d2f44d5cf16a79b5481b0dd072e8e3e95.
The superseded R20/R26 artifact hashes are
f11d0a0668df172c4001e0ce5da76eba815ba28cdba26bd11abf1fadcd6690a1 and
9da8907a304901528d476ff3fb02b82df4e5d83f5c583b78ee0ee70e3966a352.
The worktree contains unrelated Build 1 implementation work. R21 changes no
source, test, SPEC, release, deployment, or operator-secret file.

The source inventory for this revision was taken at worktree HEAD
`3a0b5e1011dedc0414c18b8a8c102d01f969f70a` with fetched `origin/main`
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
and sidecars are the only authority. After selection, only the R21 database is
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
R21.

SPEC-001 and SPEC-044 must be amended and approved before source implementation.
R21 grants no model identity, pricing, admission, settlement, reward,
enforcement, deployment, release, or production authority.

## 2. SQLite file and open protocol

### 2.1 Directory-bound VFS

R21 requires a reviewed BoundDirectorySQLiteVFS shim over SQLite's unix VFS.
The shim receives an already-open retirement-directory descriptor. For the
main database and every auxiliary open it accepts only these byte-exact leaf
names:

~~~text
catalog-state.sqlite3
catalog-state.sqlite3-journal
catalog-state.sqlite3-wal
catalog-state.sqlite3-shm
~~~

It rejects absolute paths, separators, dot components, URI parameters,
temporary filenames, super-journals, symlinks, non-regular files, link count
other than one, wrong owner or mode, and a device different from the opened
retirement directory. The retirement descriptor is opened through the
validated ancestor chain with `O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`.
For any SQLite leaf, xOpen first uses `openat(directoryFD, leaf,
O_RDWR|O_NOFOLLOW|O_CLOEXEC)`. Only when that returns `ENOENT` and SQLite's
call includes `SQLITE_OPEN_CREATE` may it retry once with
`O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, mode 0600. It never uses
`O_TRUNC`, follows a link, or retries a different leaf. Existing recovery files
therefore open without `O_EXCL`; creation is race-free. `SQLITE_OPEN_NOFOLLOW`
is also present in every sqlite3_open_v2 call. The shim revalidates the directory
descriptor against every ancestor descriptor and the no-follow pathname chain
before and after open, WAL recovery, checkpoint, and commit. SQLite cannot
re-resolve an attacker-swapped ancestor.

The implementation must be a small C target in phase3-binary, use the linked
SQLite ABI, and expose no general filesystem API. It must pass SQLite's
relevant locking, crash, WAL, and short-read tests plus the R27 race matrix.
Failure to implement or qualify the VFS keeps R21 disabled.

### 2.2 Two connection profiles

The bootstrap-candidate profile alone uses:

~~~text
SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX |
SQLITE_OPEN_NOFOLLOW
journal_mode=DELETE while constructing
allowed leaves: main, journal
~~~

After the source rows and registry are committed, the candidate is converted
to WAL, checkpointed TRUNCATE, closed, and reopened through the same
directory-bound VFS. From that point the bootstrap-resume and selected profile
uses:

~~~text
SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
journal_mode=WAL
allowed leaves: main, wal, shm
~~~

The DELETE journal must be absent before the WAL-ready transaction. The ready
transaction therefore occurs in WAL mode and can never create a rollback
journal. CREATE is forbidden after the first candidate xOpen. A missing
selected main database is an authority failure, never an implicit create.

Every profile sets page_size 4096 before schema construction, synchronous FULL,
foreign_keys ON, trusted_schema OFF, recursive_triggers OFF, secure_delete ON,
busy_timeout 0, wal_autocheckpoint 4096, journal_size_limit 67108864,
max_page_count 131072, application_id 1297109587, and user_version 21. It uses
SQLITE_DBCONFIG_DEFENSIVE, disables extensions, and requires SQLite 3.37 or
later. The selected database directory is provider-owned mode 0700; main is
0600. The VFS, rather than pathname validation alone, binds WAL/SHM to it.

Full integrity_check and foreign_key_check run after candidate recovery, after
WAL recovery, at provider startup, and during maintenance while mutation
readiness is unavailable. Per transaction, the code verifies schema/registry/
manifest digests, pragmas, affected foreign keys, exact statement changes, and
the 64-MiB emergency reserve.

## 3. Deterministic bootstrap and selection

B0 reads the selected R4 format, active index, and every directly referenced
primary/origin/class/lineage (R4 left) file under the old journal lock. It computes:

~~~text
bootstrap_id = lowercase-hex(SHA256(
  ASCII("macprovider-r21-bootstrap-v1") || 0x00 ||
  source_index_sha256 || source_rows_sha256 ||
  schema_sha256 || registry_sha256 || semantic_manifest_sha256))
candidate path =
  .retention-v2/.reservation-migration/retirement/v2-bootstrap/<bootstrap_id>/
~~~

`source_index_sha256` is SHA-256 of the exact selected `active.json` bytes.
`source_rows_sha256` begins with
`ASCII("macprovider-r21-source-rows-v1") || 00 || u32be(row-count)` and appends,
in active-index order, `u32be(tuple-byte-count) || tuple`, where tuple_v1 domain
`macprovider-r21/bootstrap-source-row` contains exactly row ordinal, transaction
UUID, model ID, release, and the evidence SHA, root kind, relative-path bytes,
path SHA, length/null, content SHA/null, and complete file-identity fields for
primary, origin, class, and lineage in that order. The final digest is SHA-256
of this complete byte string. R4 JSON numbers/strings are first accepted by the
existing strict decoder, then encoded into these typed tuples; JSON
reserialization is forbidden. Appendix D defines tuple_v1. This is the complete
bootstrap encoding and admits no platform integer, path character count, map
order, or human default.

All digest operands are raw 32-byte values. No UUID or random component appears
in the path. The path is directly derivable again from selected R4 authority;
bootstrap never enumerates v2-bootstrap.

The exact sequence is:

1. B0 validate and hash all R4 inputs, row count at most 1,024, lock and ancestor
   identity, page/free-space ceiling, and absence of a v5 fence.
2. B1 derive the candidate path and fixed final `retirement/v2` path. Under the
   old lock, direct-open final first, then candidate, or create candidate mode
   0700 exclusively. An existing candidate is accepted only in one pre-B3 state
   from the table below. Empty state E0 has no trusted payload: the opened
   directory's descriptor/path/ancestor identity is captured and immediately
   bound into the expected intent bytes. States E1+ must match those bytes.
   Both paths present, an unlisted leaf, a non-prefix temporary intent, or any
   identity mismatch protects. Nothing is found by enumeration.
3. B1a publish `bootstrap-intent-v1.tmp` using `openat` with
   `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, mode 0600. Its exact bytes are
   tuple_v1 domain `macprovider-r21/bootstrap-intent-v1` over bootstrap ID,
   source/schema/registry/manifest digests, candidate directory identity,
   application ID, page size, and schema version. After each bounded write the
   file is a byte-exact prefix; resume writes from its verified length. Fsync,
   rename to `bootstrap-intent-v1`, and fsync candidate. No main file is created
   before the final intent exists. The intent columns are exactly:
   `bootstrap_id:sha, source_index_sha256:sha, source_rows_sha256:sha,
   schema_sha256:sha, registry_sha256:sha, semantic_manifest_sha256:sha,
   candidate_directory_identity_sha256:sha, application_id:u63,
   page_size:u63, schema_version:u63`, in that order. No timestamp, random UUID,
   pathname string, host scalar, or optional field is encoded.
4. B2 create catalog-state.sqlite3 with the bootstrap profile. If the main file
   exists, CREATE is omitted and recovery starts from its selected SQL phase.
5. B3 create Appendix A in one rollback-journal transaction, insert
   protocol_meta state bootstrap, six fixed_state
   rows, 1,024 row_slots, gc_meta, and the complete registry.
6. B4 import each R4 row and its direct evidence in source order, mark the same
   row_slot occupied, and preserve its coarse materialization state. Imported
   fine state is the unique manifest state proven by its R4 evidence; ambiguous
   or impossible evidence protects.
7. B5 commit, fsync, quick_check, integrity_check, foreign_key_check, close,
   delete the exact intent only after its fields equal protocol_meta, fsync, and
   remove/verify absence of the rollback journal.
8. B6 reopen the candidate, switch to WAL, checkpoint TRUNCATE, close, and
   verify the candidate contains only main or the exact recoverable WAL/SHM.
9. B7 rename the deterministic candidate directory to retirement/v2, fsync its
   parent, reopen through the selected profile, compute the exact format JCS
   from the final database identity, and commit format_sha256 plus state ready
   in WAL.
10. B8 checkpoint, fsync/close, write and fsync format.json.tmp-v5, atomically
   replace the R4 format with v5, fsync .retention-v2, and release the old lock.

Only the B8 parent-directory fsync selects R21. Before it, R4 remains authority
and the one deterministic candidate resumes. After it, R21 never reads R4 for
authority. Concurrent processes serialize on the existing R4 lock before B8
and SQLite after B8. Death at every open, statement, journal, rename, WAL,
checkpoint, database fsync, format write, or directory fsync has one directly
derivable predecessor or successor.

The pre-B3 leaf/header state table is exhaustive:

| state | exact leaves | direct predicates | recovery |
|---|---|---|---|
| E0 | none | candidate mode/owner/link/device and opened ancestor identities exact | publish intent from current B0 bytes |
| E1 | `bootstrap-intent-v1.tmp` | size 0...N and bytes equal the expected N-byte intent prefix; main absent | append suffix, fsync, rename |
| E2 | `bootstrap-intent-v1` | exact N bytes/digest/identity; main and journal absent | enter B2 |
| E3 | intent plus main | main size zero, or page-aligned valid SQLite header with page size 4096, application ID 0 or selected ID, and no committed user object | reopen without CREATE and run B3 |
| E4 | intent plus main and journal | main/journal pass SQLite hot-journal predicates and intent/directory identities remain exact | let SQLite recover; result must be E3 or E5 |
| E5 | intent plus main, optional journal | recovery yields exactly zero user objects or all Appendix A objects with protocol_meta matching the intent; any strict subset after recovery rejects | rerun atomic B3 or enter B4 |
| E6 | main only | complete Appendix A plus matching protocol_meta at phase b5-delete-verified; no journal | enter B6 |

The directory validator permits the two intent names only before E6 and the
SQLite VFS never opens them. It permits main/journal only in E2...E5. A malformed
SQLite header, non-page-aligned nonzero main, non-hot unexpected journal,
committed partial schema, second temp/final intent, or unexpected byte is a
typed bootstrap conflict. E0/E1 cleanup can remove only an exact verified
prefix temporary intent in this deterministic unselected directory; it never
deletes an unequal candidate. This closes death after mkdir, intent create,
every intent write/fsync/rename, main create/header write, every DDL statement,
journal sync, and B3 commit.

The v5 format is the canonical JCS object with exactly these keys and values:
`bootstrapID` lowercase SHA hex, `databaseDirectoryIdentitySHA256` lowercase
file-identity SHA hex, `databaseLeaf` literal `catalog-state.sqlite3`,
`registrySHA256`, `schemaSHA256`, and `semanticManifestSHA256` lowercase SHA
hex, and integer `version` 5. `format_sha256` hashes those exact UTF-8 JCS bytes.
It never contains a database-content digest, so storing `format_sha256` in the
database is not circular. Any missing/extra key, alternate leaf, wrong scalar,
identity drift, or digest mismatch rejects before SQLite authority is used.

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
new R21 row. Cancellation after allocation begin but before progress takes the
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
charges, and literal outcome `retry_exhausted_v1`. It performs no operation,
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
| allocation success progress | progress transition, operation CAS, four evidence, source row, row state, row-slot CAS, meta | 10 |
| allocation cancel progress | progress transition, operation cancel CAS, meta | 3 |
| staging register progress | progress transition, operation CAS, row-state CAS, receipt evidence, staging-source insert, meta | 6 |
| custody verified/pending progress | progress transition, operation CAS, row-state CAS, root+receipt evidence, custody event, custody-current, exactly one catalog insert-or-CAS, meta | 9 |
| initial activation progress | progress transition, operation CAS, row-state CAS, active custody event, custody-current CAS, catalog-slot CAS, meta | 7 |
| replacement progress | progress transition, operation CAS, row-state CAS, incumbent event/current, replacement event/current, catalog-slot CAS, meta | 9 |
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

## 6. Catalog and custody representation

catalog_slots has one row per model_id/release. Its active tuple and pending
tuple each contain artifact digest, custody event digest, source row, binding
digest, and operation UUID, with an all-null/all-non-null CHECK. There is at
most one pending replacement per catalog slot. No separate binding rows need
two state updates.

Ownership is enforced by composite foreign keys, rather than reconstructed in
Swift. `row_slots(row,transaction)` selects `source_rows`; staging copies carry
row, transaction, model, and release; custody events/current carry those four
plus artifact and event; each custody event separately stores the creating
operation's own row ordinal so a replacement operation may release an incumbent
without falsifying either owner; catalog active/pending tuples carry the same
source identity plus their creating row operation; GC candidates/events carry the full
custody tuple. Each parent exposes one matching UNIQUE key. All-null catalog
tuples are allowed, all-non-null tuples must resolve exactly. Substituting any
transaction, model, release, row, artifact, event, or operation makes the DML
fail `SQLITE_CONSTRAINT_FOREIGNKEY` in the same transaction. Because SQLite has
no trusted SHA function, the manifest compiler computes each catalog binding
digest from exactly those FK-bound columns before insert/CAS, and startup plus
every serving/replacement/GC read recomputes it from the selected row. A digest
mismatch protects before use; arbitrary stored 32-byte values are never accepted
by length alone.

custody_events is append-only and custody_current selects one event per
artifact. A replacement switch uses the exact nine-row transaction in section
5.1. The catalog slot changes only if every incumbent and pending field matches
the operation authorization. A crash selects the entire old slot or entire new
slot. Serving first reads the complete active source/custody tuple in a read
transaction and closes that transaction. It then asks the custody daemon for a
`serving_pin_v1` bound to model, release, catalog generation, row ordinal,
transaction UUID, artifact SHA, custody-event SHA, authenticated process audit
identity, absolute 15-minute supported-profile deadline, and deterministic
per-artifact lock identity. The daemon direct-revalidates the tuple, opens the
root-owned per-artifact lock leaf, takes a shared `flock`, and returns a
duplicated lock FD plus the signed tuple. The provider reopens a short SQLite
snapshot after pin acquisition; a changed active tuple closes the FD and retries
before MLX opens any file.

The provider retains the shared-lock FD through every lazy MLX file access and
the complete request, and closes it on completion, cancellation, or deadline.
Process death releases its duplicate in the kernel; daemon death does not close
the provider's duplicate. GC must acquire an exclusive lock on the identical
leaf before checking or deleting. Replacement may publish a new active tuple
while an old request is pinned, but old custody deletion remains blocked until
all old pins close. SQLite transactions never span inference. New pins and
requests longer than the supported deadline reject with a typed capability
error; renewal is not supported by this revision.

The root-owned com.malibu.macprovider.custody daemon remains mandatory. It owns
the final artifact, receipt, GC-result, staging-authorization, and per-artifact
lock namespaces. Final regular files are root:wheel 0444, directories 0555,
and descendants carry SF_IMMUTABLE after publication. A provider UID cannot
clear flags, mutate, rename, unlink, or link them. Absence or failed physical
qualification returns trusted_custody_unavailable and prevents pending/active
catalog state.

The daemon's custody operation is the following closed freshness sequence:

1. C0 direct-validate the root-owned staging receipt and token, then create one
   root-owned mode-0700 temporary directory beneath the configured custody root.
2. C1 copy every manifest entry through no-follow descriptors while hashing the
   raw bytes and capturing the complete source identity before and after each
   copy. Any source drift aborts before publication.
3. C2 recompute the complete SPEC-001 artifact/tree digest, manifest digest,
   signed model/release identity, counts, and byte totals, then fsync every
   output file and directory.
4. C3 chmod/chown descendants before parents, set `SF_IMMUTABLE` descendants
   before parents, fsync, and close every source descriptor.
5. C4 reopen the completed root and every entry in canonical raw-path order;
   recapture every identity/flag field, recompute the manifest and identity
   transcript, and hash all bytes a second time from the root-owned copy.
6. C5 write and fsync `custody_receipt_v1` beneath its deterministic root-owned
   temporary path with both content pass digests and the final identity
   transcript.
7. C6 rename the temporary directory and receipt to their artifact/operation
   digest-derived final names, fsync both parents, direct-reopen and fully
   recapture both, then return their direct evidence references.

Cancellation before C6 removes only that daemon-owned temporary object after
clearing flags it set. Cancellation or caller death after C6 leaves an
inactive, complete object; replay derives and revalidates the same paths. The
SQLite progress commit direct-validates C6 root and receipt evidence, then the
activation transaction asks the daemon to perform a read-only full recapture
under the per-artifact lock before changing `catalog_slots`. Serving repeats a
direct root/receipt/flag check before MLX open. A provider assertion, digest by
itself, earlier pass, or receipt without the selected database references never
grants custody or adoption.

## 7. Closed staging-source handoff

Trusted custody supports one canonical handoff namespace:

~~~text
~/Library/Application Support/Malibu/ProviderStaging/v1/<transaction-uuid>/
~~~

The daemon derives the home directory from the authenticated audit-token UID
and getpwuid_r, requires the installer-configured provider UID, opens each
ancestor without following links, and requires the staging root to be on the
provider home volume. Console and headless launchd providers are supported only
when their UID is the root-owned configured provider UID. Cross-user access is
always rejected.

Trusted adoption does not consume MACPROVIDER_MODEL_ARTIFACT_ROOT directly.
When that override points elsewhere, the unprivileged preparation path may
copy and verify into the canonical handoff; if it cannot, preparation remains
local but adoption returns trusted_custody_source_unsupported. The daemon never
accepts an arbitrary path or file descriptor.

The first XPC call is registerStagingSource with transaction UUID, signed
catalog envelope, model/release, artifact/tree digest, manifest digest, and
entry/count limits. The daemon derives the path, performs a full no-follow
identity and content pass, and writes a root-owned
staging_source_receipt_v1 at:

~~~text
staging-authorizations/<uid>/<transaction-uuid>.source-v1
~~~

The receipt contains a daemon-generated 32-byte source token and the complete
source identity transcript. staging_sources stores a direct evidence reference
to that receipt. The copy call contains only transaction UUID and source token.
The daemon direct-opens its receipt, authenticates UID, operation, catalog,
expiry-free selected generation, and source identity, then recaptures staging
before/during copy. The token cannot be minted or redirected by the provider.
A stale, replaced, cross-mount, cross-user, mismatched-config, or replayed
source protects without catalog adoption. Root-owned receipt deletion occurs
only after selected custody completion or audited cancellation.

## 8. Restart-safe bounded GC

gc_candidates states are queued, checking, deleting, blocked-kernel-io, done,
or protected. The fairness index includes queued, checking, and deleting.
Every checking row contains a deterministic helper UUID:

~~~text
UUID(first 16 bytes of SHA256(
  ASCII("macprovider-r21-gc-helper-v1") || artifact_sha256 ||
  custody_event_sha256 || u64be(gc_lifecycle_generation)))
~~~

A parent selects the oldest eligible candidate, appends a checking event, moves
it to the tail, commits, and closes SQLite. A later process may select checking.
It first direct-opens the deterministic result path. If a valid result exists,
it commits that result. Otherwise it asks the daemon to acquire the
per-artifact lock nonblocking with the same helper UUID. Busy means the
original child is still authoritative; the reclaimer makes no event and moves
to another candidate. Lock acquisition means no child survives, so the daemon
resumes from the selected cursor and direct custody evidence. Duplicate calls
with the same helper UUID are byte-identical and cannot repeat a durably
deleted prefix.

The lifecycle accounting is executable: enqueue consumes event 1. Each of at
most 16 successful 256-entry quanta consumes a checking event and one result
event, including the final `done` result, for 32 more. Each of at most eight
claim/recovery failures likewise consumes checking plus failure-result, for 16
more. Thus the full permitted history ends at generation 49. Generation 50 is
reserved solely for the first-over `protected` control event; it does not
increment `result_count`. Generation 51 is rejected by DDL. `successful_quanta<=16`, `failure_count<=8`, and
`result_count<=24` are independently stored and CAS-checked. At 1,024 artifacts
the global bound is `50R = 51,200` events. An artifact digest has one GC
lifecycle and cannot be readopted after done; identical bytes reuse a still
present object or return `artifact_retired` after deletion.

The daemon child processes at most 256 entries, 8 MiB path/manifest bytes,
1,024 syscalls, or six seconds. The supervisor kills at six seconds and waits
one second. No SQLite connection/global lock is held. An unreaped kernel-I/O
child selects blocked-kernel-io, keeps the artifact honestly busy, and removes
host GC/adoption qualification while unrelated work and heartbeat continue.
No lock-release claim is made for an unreaped process.

Enqueue, claim, result, cursor, fairness, and terminal updates use the exact
DML in Appendix C and the deferred candidate-last-event foreign key. Death
after any checking commit is recoverable by the rules above.

## 9. Bounded lifetime and emergency space

R21 has no custom carrier, packed slot, B+ tree, promoted root, or application
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
| verification_state | R |
| staging_sources | R |
| custody_events | 8R |
| custody_current | R |
| catalog_slots | R |
| gc_candidates | R |
| gc_events | 50R |
| gc_meta | 1 |

At S=R=1,024 this is 186,688 operations, 560,064 transitions, at most
49,280 intents, 49,280 evidence objects, 8,192 custody events, and 51,200 GC
events. The evidence ceiling is 48R+128: at most four source/allocation rows,
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
`macprovider-r21/<table>` and every DDL column in order, with its own identity
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
digests hash tuple domain `macprovider-r21/catalog-binding` over
model, release, artifact, row, source transaction UUID, custody-event SHA, and
creating operation UUID; source_token_sha256 hashes the exact
32-byte daemon token. A field outside this registry or a digest resolved by
search rather than its stored foreign-key/direct-path reference rejects.

daemon_protocol_version is u63. Every path length is the raw byte length, never
Unicode scalar or character count. Relative paths are canonical UTF-8 bytes.
Appendix D is the complete external column/type/null/digest registry for
custody_receipt_v1, custody-entry, gc_result_v1, and
staging_source_receipt_v1. No field outside Appendix D is accepted.

gc_result root identity truth table is exact:

| outcome | start phase | end phase | before root | after root |
|---|---|---|---|---|
| progress | any non-complete | any legal successor | SHA required | SHA required |
| done | flags/entries/root/fsync | complete | SHA required | null |
| protected | any | same or legal successor | SHA required | SHA required |
| blocked-kernel-io | any non-complete | same | SHA required | null |

Every phase/outcome combination outside that table rejects. Golden minimum,
maximum, null, reordered, unknown-enum, byte-count, and digest-target vectors
are required in R27.

## 11. Complete Swift migration matrix

All new code is owned behind CatalogAuthorityV5. R4MigrationReader is the only
type allowed to decode legacy names, and only before B8 or while validating the
deterministic unselected candidate. The cutover matrix is normative:

| current owner/symbol group | R21 owner/interface | before B8 | after B8 / forbidden bypass proof |
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

## 13. R20 finding disposition

| finding | required R21 correction | R27 proof |
|---|---|---|
| H1 | intent-first deterministic E0-E6 bootstrap covers every pre-metadata crash state | R27-03 |
| H2 | standalone, ordered allocation/staging/custody/activation/replacement manifests with corrected 10/3/6/9/7/9 row counts | R27-05 |
| H3 | all and only the 128 recovery entries use one read-only intent; exact `32S+16R+128` formula | R27-04 |
| H4 | composite foreign keys bind every staging/custody/catalog/GC row to source and creating operation | R27-06 |
| H5 | 1+32+16=49 permitted GC events, event 50 first-over protection, 51 rejected | R27-09 |
| H6 | shared daemon-issued serving pin spans all lazy MLX reads and excludes GC | R27-08 |
| H7 | VFS hard-stops WAL writes/truncates at 64 MiB; one open operation and 48-MiB reservation make recovery bounded | R27-10 |
| M1 | materialization cursor is capped at 32 in DDL and first-over tests | R27-04/11 |
| M2 | syntax-aware reproducible CLI+app inventory includes the three omitted ModelTransaction files | R27-12 |
| M3 | post-generation-seven abort is a registered byte-stable, zero-write terminal outcome | R27-07 |

The inherited carrier-packing concern remains closed by deletion: Appendix A
uses SQLite pages and R27-11 measures the full database and indexes without a
row-per-page assumption. No finding is downgraded, waived, or converted into a
weaker acceptance claim.

## Appendix A — normalized authoritative DDL

Normalization removes CR and trailing whitespace and retains exactly one LF
after each SQL statement. No trigger or view exists.

~~~sql
PRAGMA application_id=1297109587;
PRAGMA user_version=21;
CREATE TABLE protocol_meta(id INTEGER PRIMARY KEY CHECK(id=1),schema_version INTEGER NOT NULL CHECK(schema_version=21),bootstrap_id BLOB NOT NULL CHECK(length(bootstrap_id)=32),source_index_sha256 BLOB NOT NULL CHECK(length(source_index_sha256)=32),source_rows_sha256 BLOB NOT NULL CHECK(length(source_rows_sha256)=32),candidate_directory_identity_sha256 BLOB NOT NULL CHECK(length(candidate_directory_identity_sha256)=32),schema_sha256 BLOB NOT NULL CHECK(length(schema_sha256)=32),registry_sha256 BLOB NOT NULL CHECK(length(registry_sha256)=32),semantic_manifest_sha256 BLOB NOT NULL CHECK(length(semantic_manifest_sha256)=32),format_sha256 BLOB CHECK(format_sha256 IS NULL OR length(format_sha256)=32),state TEXT NOT NULL CHECK(state IN('bootstrap','ready','protected')),bootstrap_phase TEXT CHECK(bootstrap_phase IS NULL OR bootstrap_phase IN('b3-schema','b4-import','b5-delete-verified','b6-wal','b7-ready')),bootstrap_row_cursor INTEGER NOT NULL CHECK(bootstrap_row_cursor BETWEEN 0 AND 1024),generation INTEGER NOT NULL CHECK(generation>=1),source_row_count INTEGER NOT NULL CHECK(source_row_count BETWEEN 0 AND 1024),operation_count INTEGER NOT NULL CHECK(operation_count BETWEEN 0 AND 186688),transition_count INTEGER NOT NULL CHECK(transition_count BETWEEN 0 AND 560064),intent_count INTEGER NOT NULL CHECK(intent_count BETWEEN 0 AND 49280),evidence_count INTEGER NOT NULL CHECK(evidence_count BETWEEN 0 AND 49280),staging_source_count INTEGER NOT NULL CHECK(staging_source_count BETWEEN 0 AND 1024),custody_event_count INTEGER NOT NULL CHECK(custody_event_count BETWEEN 0 AND 8192),catalog_slot_count INTEGER NOT NULL CHECK(catalog_slot_count BETWEEN 0 AND 1024),gc_candidate_count INTEGER NOT NULL CHECK(gc_candidate_count BETWEEN 0 AND 1024),gc_event_count INTEGER NOT NULL CHECK(gc_event_count BETWEEN 0 AND 51200),open_operation_count INTEGER NOT NULL CHECK(open_operation_count BETWEEN 0 AND 1),wal_reserved_bytes INTEGER NOT NULL CHECK(wal_reserved_bytes BETWEEN 0 AND 50331648),wal_hard_limit_bytes INTEGER NOT NULL CHECK(wal_hard_limit_bytes=67108864),begin_wal_limit_bytes INTEGER NOT NULL CHECK(begin_wal_limit_bytes=16777216),page_limit INTEGER NOT NULL CHECK(page_limit=131072),begin_page_limit INTEGER NOT NULL CHECK(begin_page_limit=114688),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((state IN('bootstrap','ready') AND protected_code IS NULL)OR(state='protected' AND protected_code IS NOT NULL)),CHECK((state='bootstrap' AND bootstrap_phase IS NOT NULL AND format_sha256 IS NULL)OR(state='ready' AND bootstrap_phase='b7-ready' AND format_sha256 IS NOT NULL)OR state='protected')) STRICT;
CREATE TABLE transition_registry(scope TEXT NOT NULL CHECK(scope IN('allocation','row','fixed')),ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 319),family TEXT NOT NULL CHECK(length(family) BETWEEN 1 AND 32),local_ordinal INTEGER NOT NULL CHECK(local_ordinal BETWEEN 0 AND 173),name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 128),coarse_from TEXT NOT NULL CHECK(length(coarse_from) BETWEEN 1 AND 32),coarse_to TEXT NOT NULL CHECK(length(coarse_to) BETWEEN 1 AND 32),fine_from TEXT NOT NULL CHECK(length(fine_from) BETWEEN 1 AND 128),fine_to TEXT NOT NULL CHECK(length(fine_to) BETWEEN 1 AND 128),effect_template TEXT NOT NULL CHECK(length(effect_template) BETWEEN 1 AND 64),external_template TEXT NOT NULL CHECK(length(external_template) BETWEEN 1 AND 64),required_evidence_kind TEXT CHECK(required_evidence_kind IS NULL OR length(required_evidence_kind) BETWEEN 1 AND 64),charge_rule TEXT NOT NULL CHECK(charge_rule IN('zero','allocation','a3-directory','a5-evidence','adoption-lifecycle','a1a2-release')),begin_changes INTEGER NOT NULL CHECK(begin_changes BETWEEN 3 AND 12),progress_changes_base INTEGER NOT NULL CHECK(progress_changes_base BETWEEN 4 AND 12),progress_changes_with_incumbent INTEGER NOT NULL CHECK(progress_changes_with_incumbent BETWEEN 4 AND 12),cancel_progress_changes INTEGER NOT NULL CHECK(cancel_progress_changes BETWEEN 3 AND 12),finish_changes INTEGER NOT NULL CHECK(finish_changes BETWEEN 3 AND 12),max_row_changes INTEGER NOT NULL CHECK(max_row_changes=12),CHECK((scope='allocation' AND ordinal=0 AND local_ordinal=0)OR(scope='row' AND ordinal BETWEEN 0 AND 173 AND local_ordinal=ordinal)OR(scope='fixed' AND ordinal BETWEEN 0 AND 319)),PRIMARY KEY(scope,ordinal),UNIQUE(scope,ordinal,family),UNIQUE(scope,family,local_ordinal),UNIQUE(scope,name)) STRICT, WITHOUT ROWID;
CREATE TABLE fixed_state(family TEXT PRIMARY KEY CHECK(family IN('source','merge','tree','verification','materialization','recovery')),current_local_ordinal INTEGER NOT NULL CHECK(current_local_ordinal BETWEEN 0 AND 128),fine_state TEXT NOT NULL CHECK(length(fine_state) BETWEEN 1 AND 128),status TEXT NOT NULL CHECK(status IN('active','complete','protected')),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((status='protected' AND protected_code IS NOT NULL)OR(status!='protected' AND protected_code IS NULL)),CHECK((family IN('source','tree','verification','materialization') AND current_local_ordinal<=32)OR(family='merge' AND current_local_ordinal<=64)OR family='recovery')) STRICT, WITHOUT ROWID;
CREATE TABLE row_slots(row_ordinal INTEGER PRIMARY KEY CHECK(row_ordinal BETWEEN 0 AND 1023),state TEXT NOT NULL CHECK(state IN('free','allocating','occupied','exhausted','retired')),allocation_operation_uuid BLOB CHECK(allocation_operation_uuid IS NULL OR length(allocation_operation_uuid)=16),source_transaction_uuid BLOB CHECK(source_transaction_uuid IS NULL OR length(source_transaction_uuid)=16),allocation_attempts INTEGER NOT NULL CHECK(allocation_attempts BETWEEN 0 AND 8),generation INTEGER NOT NULL CHECK(generation>=1),CHECK((state='free' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NULL AND allocation_attempts<8)OR(state='allocating' AND allocation_operation_uuid IS NOT NULL AND source_transaction_uuid IS NULL AND allocation_attempts<8)OR(state='occupied' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NOT NULL)OR(state='retired' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NOT NULL)OR(state='exhausted' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NULL AND allocation_attempts=8)),FOREIGN KEY(row_ordinal,source_transaction_uuid) REFERENCES source_rows(row_ordinal,transaction_uuid) DEFERRABLE INITIALLY DEFERRED) STRICT;
CREATE INDEX idx_free_row_slots ON row_slots(row_ordinal) WHERE state='free';
CREATE TABLE evidence_objects(evidence_sha256 BLOB PRIMARY KEY CHECK(length(evidence_sha256)=32),kind TEXT NOT NULL CHECK(length(kind) BETWEEN 1 AND 64),root_kind TEXT NOT NULL CHECK(root_kind IN('transaction-store','staging-store','custody-store')),relative_path BLOB NOT NULL CHECK(length(relative_path) BETWEEN 1 AND 512),path_sha256 BLOB NOT NULL CHECK(length(path_sha256)=32),byte_length INTEGER CHECK(byte_length IS NULL OR byte_length BETWEEN 0 AND 2305843009213693951),content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256)=32),device_id INTEGER NOT NULL CHECK(device_id BETWEEN 0 AND 2305843009213693951),file_id INTEGER NOT NULL CHECK(file_id BETWEEN 0 AND 2305843009213693951),file_type TEXT NOT NULL CHECK(file_type IN('regular','directory')),mode INTEGER NOT NULL CHECK(mode BETWEEN 0 AND 65535),owner_uid INTEGER NOT NULL CHECK(owner_uid BETWEEN 0 AND 2305843009213693951),group_gid INTEGER NOT NULL CHECK(group_gid BETWEEN 0 AND 2305843009213693951),link_count INTEGER NOT NULL CHECK(link_count=1),mtime_seconds INTEGER NOT NULL CHECK(mtime_seconds BETWEEN 0 AND 2305843009213693951),mtime_nanoseconds INTEGER NOT NULL CHECK(mtime_nanoseconds BETWEEN 0 AND 999999999),ctime_seconds INTEGER NOT NULL CHECK(ctime_seconds BETWEEN 0 AND 2305843009213693951),ctime_nanoseconds INTEGER NOT NULL CHECK(ctime_nanoseconds BETWEEN 0 AND 999999999),birthtime_seconds INTEGER NOT NULL CHECK(birthtime_seconds BETWEEN 0 AND 2305843009213693951),birthtime_nanoseconds INTEGER NOT NULL CHECK(birthtime_nanoseconds BETWEEN 0 AND 999999999),user_flags INTEGER NOT NULL CHECK(user_flags BETWEEN 0 AND 2305843009213693951),system_flags INTEGER NOT NULL CHECK(system_flags BETWEEN 0 AND 2305843009213693951),identity_sha256 BLOB NOT NULL CHECK(length(identity_sha256)=32),created_generation INTEGER NOT NULL CHECK(created_generation>=1),CHECK((file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL)OR(file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL)),UNIQUE(root_kind,relative_path),UNIQUE(device_id,file_id,birthtime_seconds,birthtime_nanoseconds)) STRICT, WITHOUT ROWID;
CREATE TABLE source_rows(row_ordinal INTEGER PRIMARY KEY REFERENCES row_slots(row_ordinal),transaction_uuid BLOB NOT NULL UNIQUE CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),primary_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),origin_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),class_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),lineage_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),created_generation INTEGER NOT NULL CHECK(created_generation>=1),UNIQUE(row_ordinal,transaction_uuid),UNIQUE(row_ordinal,transaction_uuid,model_id,release)) STRICT;
CREATE TABLE row_state(row_ordinal INTEGER PRIMARY KEY REFERENCES source_rows(row_ordinal),coarse_state TEXT NOT NULL CHECK(coarse_state IN('A2','A3','A4','A5','A6','A7','A8','protected')),fine_state TEXT NOT NULL CHECK(length(fine_state) BETWEEN 1 AND 128),attempt_generation INTEGER NOT NULL CHECK(attempt_generation BETWEEN 0 AND 7),abort_generation INTEGER NOT NULL CHECK(abort_generation BETWEEN 0 AND 8),economic_charge_bytes INTEGER NOT NULL CHECK(economic_charge_bytes BETWEEN 0 AND 2305843009213693951),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((coarse_state='protected' AND protected_code IS NOT NULL)OR(coarse_state!='protected' AND protected_code IS NULL))) STRICT;
CREATE TABLE operations(operation_uuid BLOB PRIMARY KEY CHECK(length(operation_uuid)=16),scope TEXT NOT NULL CHECK(scope IN('allocation','row','fixed')),registry_ordinal INTEGER NOT NULL,row_ordinal INTEGER REFERENCES row_slots(row_ordinal),allocation_attempt INTEGER CHECK(allocation_attempt IS NULL OR allocation_attempt BETWEEN 0 AND 7),fixed_family TEXT REFERENCES fixed_state(family),phase TEXT NOT NULL CHECK(phase IN('open','committed','aborted','protected')),open_slot INTEGER CHECK(open_slot IS NULL OR open_slot=1),authorization_sha256 BLOB NOT NULL UNIQUE CHECK(length(authorization_sha256)=32),base_generation INTEGER NOT NULL CHECK(base_generation>=1),maximum_charge_bytes INTEGER NOT NULL CHECK(maximum_charge_bytes BETWEEN 0 AND 2305843009213693951),charge_consumed INTEGER NOT NULL CHECK(charge_consumed BETWEEN 0 AND 2305843009213693951),charge_released INTEGER NOT NULL CHECK(charge_released BETWEEN 0 AND 2305843009213693951),charge_abandoned INTEGER NOT NULL CHECK(charge_abandoned BETWEEN 0 AND 2305843009213693951),cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN(0,1)),finish_sha256 BLOB CHECK(finish_sha256 IS NULL OR length(finish_sha256)=32),UNIQUE(operation_uuid,authorization_sha256),UNIQUE(operation_uuid,row_ordinal),FOREIGN KEY(scope,registry_ordinal) REFERENCES transition_registry(scope,ordinal),FOREIGN KEY(scope,registry_ordinal,fixed_family) REFERENCES transition_registry(scope,ordinal,family),FOREIGN KEY(operation_uuid,finish_sha256) REFERENCES transitions(operation_uuid,transition_sha256) DEFERRABLE INITIALLY DEFERRED,CHECK((scope='allocation' AND row_ordinal IS NOT NULL AND allocation_attempt IS NOT NULL AND fixed_family IS NULL)OR(scope='row' AND row_ordinal IS NOT NULL AND allocation_attempt IS NULL AND fixed_family IS NULL)OR(scope='fixed' AND row_ordinal IS NULL AND allocation_attempt IS NULL AND fixed_family IS NOT NULL)),CHECK((phase='open' AND finish_sha256 IS NULL AND open_slot=1)OR(phase!='open' AND finish_sha256 IS NOT NULL AND open_slot IS NULL)),CHECK((phase='open' AND charge_consumed+charge_released+charge_abandoned<=maximum_charge_bytes)OR(phase!='open' AND charge_consumed+charge_released+charge_abandoned=maximum_charge_bytes))) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX idx_one_open_operation ON operations(open_slot) WHERE open_slot=1;
CREATE UNIQUE INDEX idx_allocation_attempt ON operations(row_ordinal,allocation_attempt) WHERE scope='allocation';
CREATE UNIQUE INDEX idx_row_semantic_slot ON operations(row_ordinal,registry_ordinal) WHERE scope='row' AND registry_ordinal<110;
CREATE UNIQUE INDEX idx_row_abort_slot ON operations(row_ordinal,registry_ordinal) WHERE scope='row' AND registry_ordinal>=110;
CREATE UNIQUE INDEX idx_fixed_semantic_slot ON operations(fixed_family,registry_ordinal) WHERE scope='fixed';
CREATE TABLE operation_external_intents(operation_uuid BLOB NOT NULL REFERENCES operations(operation_uuid),intent_ordinal INTEGER NOT NULL CHECK(intent_ordinal BETWEEN 0 AND 3),kind TEXT NOT NULL CHECK(kind IN('directory','regular','existing-evidence','staging-source')),evidence_kind TEXT NOT NULL CHECK(length(evidence_kind) BETWEEN 1 AND 64),root_kind TEXT NOT NULL CHECK(root_kind IN('transaction-store','staging-store','custody-store')),file_type TEXT NOT NULL CHECK(file_type IN('regular','directory')),relative_path BLOB NOT NULL CHECK(length(relative_path) BETWEEN 1 AND 512),path_sha256 BLOB NOT NULL CHECK(length(path_sha256)=32),byte_length INTEGER CHECK(byte_length IS NULL OR byte_length BETWEEN 0 AND 2305843009213693951),content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256)=32),identity_sha256 BLOB CHECK(identity_sha256 IS NULL OR length(identity_sha256)=32),PRIMARY KEY(operation_uuid,intent_ordinal),CHECK((kind='directory' AND file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL AND identity_sha256 IS NULL)OR(kind='regular' AND file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL AND identity_sha256 IS NULL)OR(kind IN('existing-evidence','staging-source') AND identity_sha256 IS NOT NULL AND ((file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL)OR(file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL))))) STRICT, WITHOUT ROWID;
CREATE TABLE transitions(operation_uuid BLOB NOT NULL REFERENCES operations(operation_uuid),step_ordinal INTEGER NOT NULL CHECK(step_ordinal BETWEEN 0 AND 2),kind TEXT NOT NULL CHECK(kind IN('begin','progress','finish')),base_generation INTEGER NOT NULL CHECK(base_generation>=1),successor_generation INTEGER NOT NULL UNIQUE CHECK(successor_generation=base_generation+1),prior_transition_sha256 BLOB CHECK(prior_transition_sha256 IS NULL OR length(prior_transition_sha256)=32),authorization_sha256 BLOB NOT NULL CHECK(length(authorization_sha256)=32),charged_bytes INTEGER NOT NULL CHECK(charged_bytes BETWEEN 0 AND 2305843009213693951),outcome TEXT NOT NULL CHECK(outcome IN('selected','committed','aborted','protected')),transition_sha256 BLOB NOT NULL UNIQUE CHECK(length(transition_sha256)=32),PRIMARY KEY(operation_uuid,step_ordinal),UNIQUE(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,prior_transition_sha256) REFERENCES transitions(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,authorization_sha256) REFERENCES operations(operation_uuid,authorization_sha256),CHECK((kind='begin' AND step_ordinal=0 AND prior_transition_sha256 IS NULL AND outcome='selected')OR(kind='progress' AND step_ordinal=1 AND prior_transition_sha256 IS NOT NULL AND outcome='selected')OR(kind='finish' AND step_ordinal=2 AND prior_transition_sha256 IS NOT NULL AND outcome IN('committed','aborted','protected')))) STRICT, WITHOUT ROWID;
CREATE TABLE verification_state(row_ordinal INTEGER PRIMARY KEY REFERENCES source_rows(row_ordinal),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),verification_uuid BLOB NOT NULL CHECK(length(verification_uuid)=16),entry_cursor INTEGER NOT NULL CHECK(entry_cursor BETWEEN 0 AND 4096),bytes_completed INTEGER NOT NULL CHECK(bytes_completed BETWEEN 0 AND 2305843009213693951),h0 INTEGER NOT NULL CHECK(h0 BETWEEN 0 AND 4294967295),h1 INTEGER NOT NULL CHECK(h1 BETWEEN 0 AND 4294967295),h2 INTEGER NOT NULL CHECK(h2 BETWEEN 0 AND 4294967295),h3 INTEGER NOT NULL CHECK(h3 BETWEEN 0 AND 4294967295),h4 INTEGER NOT NULL CHECK(h4 BETWEEN 0 AND 4294967295),h5 INTEGER NOT NULL CHECK(h5 BETWEEN 0 AND 4294967295),h6 INTEGER NOT NULL CHECK(h6 BETWEEN 0 AND 4294967295),h7 INTEGER NOT NULL CHECK(h7 BETWEEN 0 AND 4294967295),total_byte_count INTEGER NOT NULL CHECK(total_byte_count BETWEEN 0 AND 2305843009213693951),tail BLOB NOT NULL CHECK(length(tail)<=63),manifest_sha256 BLOB NOT NULL CHECK(length(manifest_sha256)=32),generation INTEGER NOT NULL CHECK(generation>=1),CHECK(length(tail)=total_byte_count%64)) STRICT;
CREATE TABLE staging_sources(transaction_uuid BLOB PRIMARY KEY CHECK(length(transaction_uuid)=16),row_ordinal INTEGER NOT NULL UNIQUE,model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),source_token_sha256 BLOB NOT NULL UNIQUE CHECK(length(source_token_sha256)=32),receipt_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),state TEXT NOT NULL CHECK(state IN('registered','consumed','cancelled','protected')),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release) REFERENCES source_rows(row_ordinal,transaction_uuid,model_id,release),CHECK((state='protected' AND protected_code IS NOT NULL)OR(state!='protected' AND protected_code IS NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE custody_events(row_ordinal INTEGER NOT NULL,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL CHECK(custody_generation BETWEEN 1 AND 8),state TEXT NOT NULL CHECK(state IN('verified','active','released','abandoned','protected')),predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),root_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),receipt_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),operation_uuid BLOB NOT NULL CHECK(length(operation_uuid)=16),operation_row_ordinal INTEGER NOT NULL,reason TEXT CHECK(reason IS NULL OR reason IN('initial-activation','replacement','removed','cancelled','authority-corrupt','source-changed','evidence-changed','artifact-changed','custody-unavailable','custody-authorization-failed','storage-full','io-error','kernel-io-blocked','unsupported-filesystem','protocol-mismatch','retry-exhausted')),custody_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(custody_event_sha256)=32),PRIMARY KEY(artifact_sha256,custody_generation),UNIQUE(artifact_sha256,custody_event_sha256),UNIQUE(row_ordinal,custody_generation),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release) REFERENCES source_rows(row_ordinal,transaction_uuid,model_id,release),FOREIGN KEY(operation_uuid,operation_row_ordinal) REFERENCES operations(operation_uuid,row_ordinal),FOREIGN KEY(artifact_sha256,predecessor_sha256) REFERENCES custody_events(artifact_sha256,custody_event_sha256),CHECK((custody_generation=1 AND predecessor_sha256 IS NULL)OR(custody_generation>1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='verified' AND reason IS NULL)OR(state='active' AND reason IN('initial-activation','replacement'))OR(state='released' AND reason IN('replacement','removed'))OR(state='abandoned' AND reason='cancelled')OR(state='protected' AND reason IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE custody_current(row_ordinal INTEGER NOT NULL UNIQUE,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB PRIMARY KEY CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL,custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),UNIQUE(artifact_sha256,custody_event_sha256),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256) REFERENCES custody_events(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(artifact_sha256,custody_generation) REFERENCES custody_events(artifact_sha256,custody_generation)) STRICT, WITHOUT ROWID;
CREATE TABLE catalog_slots(model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),active_artifact_sha256 BLOB,active_custody_event_sha256 BLOB,active_row_ordinal INTEGER,active_transaction_uuid BLOB,active_binding_sha256 BLOB,active_operation_uuid BLOB,pending_artifact_sha256 BLOB,pending_custody_event_sha256 BLOB,pending_row_ordinal INTEGER,pending_transaction_uuid BLOB,pending_binding_sha256 BLOB,pending_operation_uuid BLOB,generation INTEGER NOT NULL CHECK(generation>=1),PRIMARY KEY(model_id,release),FOREIGN KEY(active_row_ordinal,active_transaction_uuid,model_id,release,active_artifact_sha256,active_custody_event_sha256) REFERENCES custody_current(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(pending_row_ordinal,pending_transaction_uuid,model_id,release,pending_artifact_sha256,pending_custody_event_sha256) REFERENCES custody_current(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(active_operation_uuid,active_row_ordinal) REFERENCES operations(operation_uuid,row_ordinal),FOREIGN KEY(pending_operation_uuid,pending_row_ordinal) REFERENCES operations(operation_uuid,row_ordinal),CHECK((active_artifact_sha256 IS NULL AND active_custody_event_sha256 IS NULL AND active_row_ordinal IS NULL AND active_transaction_uuid IS NULL AND active_binding_sha256 IS NULL AND active_operation_uuid IS NULL)OR(length(active_artifact_sha256)=32 AND length(active_custody_event_sha256)=32 AND active_row_ordinal IS NOT NULL AND length(active_transaction_uuid)=16 AND length(active_binding_sha256)=32 AND active_operation_uuid IS NOT NULL)),CHECK((pending_artifact_sha256 IS NULL AND pending_custody_event_sha256 IS NULL AND pending_row_ordinal IS NULL AND pending_transaction_uuid IS NULL AND pending_binding_sha256 IS NULL AND pending_operation_uuid IS NULL)OR(length(pending_artifact_sha256)=32 AND length(pending_custody_event_sha256)=32 AND pending_row_ordinal IS NOT NULL AND length(pending_transaction_uuid)=16 AND length(pending_binding_sha256)=32 AND pending_operation_uuid IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE gc_meta(id INTEGER PRIMARY KEY CHECK(id=1),maximum_round INTEGER NOT NULL CHECK(maximum_round BETWEEN 0 AND 2305843009213693951),generation INTEGER NOT NULL CHECK(generation>=1)) STRICT;
CREATE TABLE gc_candidates(row_ordinal INTEGER NOT NULL UNIQUE,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB PRIMARY KEY CHECK(length(artifact_sha256)=32),state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round BETWEEN 0 AND 2305843009213693951),gc_lifecycle_generation INTEGER NOT NULL CHECK(gc_lifecycle_generation=1),custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),manifest_cursor INTEGER CHECK(manifest_cursor BETWEEN 0 AND 4096),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),successful_quanta INTEGER NOT NULL CHECK(successful_quanta BETWEEN 0 AND 16),failure_count INTEGER NOT NULL CHECK(failure_count BETWEEN 0 AND 8),result_count INTEGER NOT NULL CHECK(result_count BETWEEN 0 AND 24),last_event_sha256 BLOB NOT NULL CHECK(length(last_event_sha256)=32),UNIQUE(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256) REFERENCES custody_current(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(artifact_sha256,last_event_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256) DEFERRABLE INITIALLY DEFERRED,CHECK((state IN('checking','deleting','blocked-kernel-io','protected') AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL)OR(state IN('queued','done') AND manifest_cursor IS NULL AND delete_phase IS NULL AND helper_operation_uuid IS NULL))) STRICT, WITHOUT ROWID;
CREATE INDEX idx_gc_fair ON gc_candidates(eligible_round,artifact_sha256) WHERE state IN('queued','checking','deleting');
CREATE TABLE gc_events(row_ordinal INTEGER NOT NULL,transaction_uuid BLOB NOT NULL CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL,custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),event_generation INTEGER NOT NULL CHECK(event_generation BETWEEN 1 AND 50),predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round BETWEEN 0 AND 2305843009213693951),manifest_cursor INTEGER CHECK(manifest_cursor IS NULL OR manifest_cursor BETWEEN 0 AND 4096),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),result_evidence_sha256 BLOB REFERENCES evidence_objects(evidence_sha256),gc_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(gc_event_sha256)=32),PRIMARY KEY(artifact_sha256,event_generation),UNIQUE(artifact_sha256,gc_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256) REFERENCES gc_candidates(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),FOREIGN KEY(artifact_sha256,predecessor_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256),FOREIGN KEY(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256) REFERENCES custody_events(row_ordinal,transaction_uuid,model_id,release,artifact_sha256,custody_event_sha256),CHECK((event_generation=1 AND predecessor_sha256 IS NULL)OR(event_generation>1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='queued' AND manifest_cursor IS NULL AND delete_phase IS NULL AND helper_operation_uuid IS NULL AND result_evidence_sha256 IS NULL)OR(state='checking' AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL AND result_evidence_sha256 IS NULL)OR(state IN('deleting','blocked-kernel-io','done','protected') AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL AND result_evidence_sha256 IS NOT NULL))) STRICT, WITHOUT ROWID;
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
6|INSERT|source_rows|row_ordinal;transaction_uuid;model_id;release;four evidence SHAs;created_generation|selected source tuple
7|INSERT|row_state|row_ordinal;coarse_state;fine_state;attempt_generation;abort_generation;economic_charge_bytes;generation;protected_code|row;A2;row-normal-76;0;0;consumed;successor;null
8|CAS|row_slots|exact allocating row/operation/attempt/generation|occupied;operation null;source transaction;generation+1
9|CAS|protocol_meta|exact generation/counts/open=1/reserve|generation+1;source+1;evidence+4;transition+1;reserve after progress

allocation-cancel-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;0;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;scope=allocation;phase=open;open_slot=1;authorization_sha256=:authorization;cancel_requested=0;charge_consumed=0;charge_released=0;charge_abandoned=0|cancel_requested=1
2|CAS|protocol_meta|exact generation/transition/open/reserve|generation+1;transition+1;reserve after progress

staging-register-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|evidence_objects|all Appendix-A columns|direct staging receipt
4|INSERT|staging_sources|transaction_uuid;row_ordinal;model_id;release;source_token_sha256;receipt_evidence_sha256;state;generation;protected_code|exact selected source tuple/token/receipt;registered;successor;null
5|CAS|protocol_meta|exact generation/evidence/staging/open/reserve|generation+1;evidence+1;staging+1;transition+1;reserve after progress

custody-verified-pending-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|evidence_objects|all Appendix-A columns|direct root evidence
4|INSERT|evidence_objects|all Appendix-A columns|direct custody receipt evidence
5|INSERT|custody_events|row;transaction;model;release;artifact;generation;state;predecessor;root;receipt;operation;operation-row;reason;event SHA|selected source tuple;1;verified;null;selected evidence;null reason
6|INSERT|custody_current|row;transaction;model;release;artifact;custody generation;event SHA|same exact custody tuple
7|INSERT-IF-ABSENT-OR-CAS-IF-PRESENT|catalog_slots|exact model/release with active tuple preserved and pending null|same active tuple;pending exact source/custody/operation/binding tuple;generation+1
8|CAS|protocol_meta|exact generation/evidence/custody/catalog/open/reserve|generation+1;evidence+2;custody+1;catalog+0-or-1;transition+1;reserve after progress

initial-activation-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|custody_events|full pending source tuple;artifact;next generation;active;predecessor;root;receipt;operation;operation-row;initial-activation;event SHA|exact values
4|CAS|custody_current|full pending source tuple/artifact/old generation/event|next generation/active event
5|CAS|catalog_slots|model/release;all active null;full pending tuple;generation|pending tuple becomes active byte-for-byte;pending all null;generation+1
6|CAS|protocol_meta|exact generation/custody/open/reserve|generation+1;custody+1;transition+1;reserve after progress

replacement-progress-full
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;open_slot=1;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state|row_ordinal=:row;coarse_state=:coarse-from;fine_state=:fine-from;attempt_generation=:attempt;abort_generation=:abort;economic_charge_bytes=:old-economic;generation=:row-generation|coarse_state=:coarse-to;fine_state=:fine-to;attempt_generation=:new-attempt;abort_generation=:new-abort;economic_charge_bytes=:new-economic;generation=:row-generation+1
3|INSERT|custody_events|full incumbent source tuple;artifact;next generation;released;predecessor;root;receipt;operation;operation-row;replacement;event SHA|exact values
4|CAS|custody_current|full incumbent tuple/artifact/old generation/event|next generation/released event
5|INSERT|custody_events|full replacement source tuple;artifact;next generation;active;predecessor;root;receipt;operation;operation-row;replacement;event SHA|exact values
6|CAS|custody_current|full replacement tuple/artifact/old generation/event|next generation/active event
7|CAS|catalog_slots|model/release;full incumbent active tuple;full replacement pending tuple;generation|replacement tuple becomes active byte-for-byte;pending all null;generation+1
8|CAS|protocol_meta|exact generation/custody/open/reserve|generation+1;custody+2;transition+1;reserve after progress

allocation-aborted-finish-full
0|INSERT|transitions|finish aborted row|exact progress/auth/generation
1|CAS|operations|exact open allocation/cancel/charges/open_slot=1|aborted;finish SHA;open_slot null;charge release exact
2|CAS|row_slots|exact allocating row/operation/attempt/generation|free when attempt<7 else exhausted;operation null;attempt+1;generation+1
3|CAS|protocol_meta|exact generation/transition/open=1/reserve|generation+1;transition+1;open=0;reserve=0

gc-enqueue
0|INSERT|gc_candidates|row_ordinal;transaction_uuid;model_id;release;artifact_sha256;state;eligible_round;gc_lifecycle_generation;custody_event_sha256;manifest_cursor;delete_phase;helper_operation_uuid;successful_quanta;failure_count;result_count;last_event_sha256|:row;:transaction;:model;:release;:artifact;queued;:round;1;:custody-event;null;null;null;0;0;0;:event-sha
1|INSERT|gc_events|row_ordinal;transaction_uuid;model_id;release;artifact_sha256;custody_event_sha256;event_generation;predecessor_sha256;state;eligible_round;manifest_cursor;delete_phase;helper_operation_uuid;result_evidence_sha256;gc_event_sha256|:row;:transaction;:model;:release;:artifact;:custody-event;1;null;queued;:round;null;null;null;null;:event-sha
2|CAS|gc_meta|id=1;maximum_round=:old-round;generation=:gc-generation|maximum_round=:round;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_candidate_count=:gcc;gc_event_count=:gec;open_operation_count=0;wal_reserved_bytes=0|generation=:g+1;gc_candidate_count=INC(1);gc_event_count=INC(1)

gc-advance
0|INSERT|gc_events|:all-event-columns|:selected-candidate-successor-values
1|CAS|gc_candidates|full source/custody tuple;last_event_sha256=:old-event;state=:old-state;eligible_round=:old-round;manifest_cursor=:old-cursor;delete_phase=:old-phase;helper_operation_uuid=:old-helper;successful_quanta=:old-success;failure_count=:old-failure;result_count=:old-results|last_event_sha256=:new-event;state=:new-state;eligible_round=:new-round;manifest_cursor=:new-cursor;delete_phase=:new-phase;helper_operation_uuid=:new-helper;successful_quanta=:new-success;failure_count=:new-failure;result_count=:new-results
2|CAS|gc_meta|id=1;maximum_round=:old-maximum;generation=:gc-generation|maximum_round=:new-maximum;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec;evidence_count=:ec;open_operation_count=0;wal_reserved_bytes=0|generation=:g+1;gc_event_count=INC(1);evidence_count=INC(:result-evidence-count)
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
| four-existing-source-evidence | direct-open four preexisting R4/R21 evidence paths | four exact evidence rows |
| create-directory | exclusive no-follow mkdir beneath transaction root | direct directory identity evidence |
| create-regular | exclusive temp/write/fsync/rename/parent-fsync | direct regular evidence |
| staging-register | daemon-derived canonical staging path and root receipt | staging_sources plus receipt evidence |
| custody-copy | daemon C0-C6 root-owned copy, two content passes, hardening | root and custody receipt direct evidence |
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
SHA-256 of tuple domain `macprovider-r21/file-identity` with columns in this
order: `device_id:u63,file_id:u63,file_type:text,mode:u63,owner_uid:u63,
group_gid:u63,link_count:u63,byte_length:u63-or-null,mtime_seconds:u63,
mtime_nanoseconds:u63,ctime_seconds:u63,ctime_nanoseconds:u63,
birthtime_seconds:u63,birthtime_nanoseconds:u63,user_flags:u63,
system_flags:u63`. These are the only path and identity digest targets.

### `custody_receipt_v1`

Tuple domain: `macprovider-r21/custody-receipt-v1`. Direct path:
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

Tuple domain: `macprovider-r21/custody-entry`. The transcript seed is
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

Tuple domain: `macprovider-r21/gc-result-v1`. Direct path:
`gc-results/<artifact-hex>/<event-generation>-<helper-uuid>.gc-v1`.

| # | column | type | null | exact value or target |
|---:|---|---|---|---|
| 1 | schema | text | no | literal `gc_result_v1` |
| 2 | daemon_protocol_version | u63 | no | literal 1 |
| 3 | helper_operation_uuid | uuid | no | deterministic section 8 UUID |
| 4 | artifact_sha256 | sha | no | selected SPEC-001 artifact |
| 5 | base_custody_event_sha256 | sha | no | selected custody event row identity |
| 6 | start_phase | text | no | `flags|entries|root|fsync` |
| 7 | end_phase | text | no | `flags|entries|root|fsync|complete` |
| 8 | start_cursor | u63 | no | 0...4,096 |
| 9 | end_cursor | u63 | no | legal monotonic successor |
| 10 | entries_processed | u63 | no | 0...256 |
| 11 | path_bytes_processed | u63 | no | 0...8 MiB |
| 12 | syscalls_processed | u63 | no | 0...1,024 |
| 13 | outcome | text | no | `progress|done|protected|blocked-kernel-io` |
| 14 | root_identity_before_sha256 | sha | no | file-identity digest above |
| 15 | root_identity_after_sha256 | sha | yes, iff done or blocked-kernel-io | section 10 truth table |

### `staging_source_receipt_v1`

Tuple domain: `macprovider-r21/staging-source-receipt-v1`. Direct path:
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
`catalog-state.sqlite3-wal`, and `catalog-state.sqlite3-shm`, plus symbols
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
