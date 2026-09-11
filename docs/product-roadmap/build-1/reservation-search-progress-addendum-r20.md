# Build 1 reservation search progress addendum R20

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R20 replaces R19 as the reservation, retention, custody, and garbage-collection
design candidate. It is reviewed with test specification R26. R20 preserves
R19's deletion of the custom carrier/B+ tree design, the finite SHA-256 oracle,
the root-owned custody boundary, direct evidence references, A1/A2-only refund,
A3+ forward completion, and the physical qualification gate. Every conflicting
R19 schema, count, state, bootstrap, SQLite-open, registry, GC, source-handoff,
or migration statement is withdrawn.

The frozen failed-review input is
docs/product-roadmap/build-1/reviews/reservation-search-progress-r19-plan-sol.md
with SHA-256
fba7ebfb0e2732b0c6b34af05709a4d1b83fc3e54dfde03a823179b22256ce7f.
The reviewed R19/R25 hashes are
bab5195f99d937b511b34e8fd3378d620480d670dda59f24f2306ccb848f179c and
a262e1be9717a49d6d26abc8f81b5463442aeca7979f56b003e8485dffbd7daf.
The worktree contains unrelated Build 1 implementation work. R20 changes no
source, test, SPEC, release, deployment, or operator-secret file.

The source inventory for this revision was taken at worktree HEAD
`2c688e5ad1a30b31a79e6c76d7db951c5fe28fc2` with fetched `origin/main`
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
and sidecars are the only authority. After selection, only the R20 database is
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
R20.

SPEC-001 and SPEC-044 must be amended and approved before source implementation.
R20 grants no model identity, pricing, admission, settlement, reward,
enforcement, deployment, release, or production authority.

## 2. SQLite file and open protocol

### 2.1 Directory-bound VFS

R20 requires a reviewed BoundDirectorySQLiteVFS shim over SQLite's unix VFS.
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
relevant locking, crash, WAL, and short-read tests plus the R26 race matrix.
Failure to implement or qualify the VFS keeps R20 disabled.

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
max_page_count 131072, application_id 1297109587, and user_version 20. It uses
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
  ASCII("macprovider-r20-bootstrap-v1") || 0x00 ||
  source_index_sha256 || source_rows_sha256 ||
  schema_sha256 || registry_sha256 || semantic_manifest_sha256))
candidate path =
  .retention-v2/.reservation-migration/retirement/v2-bootstrap/<bootstrap_id>/
~~~

`source_index_sha256` is SHA-256 of the exact selected `active.json` bytes.
`source_rows_sha256` begins with
`ASCII("macprovider-r20-source-rows-v1") || 00 || u32be(row-count)` and appends,
in active-index order, `u32be(tuple-byte-count) || tuple`, where tuple_v1 domain
`macprovider-r20/bootstrap-source-row` contains exactly row ordinal, transaction
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
2. B1 derive the candidate path and the fixed final `retirement/v2` path. Under
   the old lock, direct-open the final path first, then the candidate path, or
   exclusively create the candidate if both are absent. This handles death
   after B7 rename without enumeration. An existing path must match
   bootstrap_id, source, schema, registry, semantic manifest, directory
   identity, bootstrap phase, and allowed-name state exactly; otherwise
   protect. Both present is a conflict. No candidate is deleted automatically.
3. B2 create catalog-state.sqlite3 with the bootstrap profile. If the main file
   exists, CREATE is omitted and recovery starts from its selected SQL phase.
4. B3 create Appendix A, insert protocol_meta state bootstrap, six fixed_state
   rows, 1,024 row_slots, gc_meta, and the complete registry.
5. B4 import each R4 row and its direct evidence in source order, mark the same
   row_slot occupied, and preserve its coarse materialization state. Imported
   fine state is the unique manifest state proven by its R4 evidence; ambiguous
   or impossible evidence protects.
6. B5 commit, fsync, quick_check, integrity_check, foreign_key_check, close, and
   remove/verify absence of the rollback journal.
7. B6 reopen the candidate, switch to WAL, checkpoint TRUNCATE, close, and
   verify the candidate contains only main or the exact recoverable WAL/SHM.
8. B7 rename the deterministic candidate directory to retirement/v2, fsync its
   parent, reopen through the selected profile, compute the exact format JCS
   from the final database identity, and commit format_sha256 plus state ready
   in WAL.
9. B8 checkpoint, fsync/close, write and fsync format.json.tmp-v5, atomically
   replace the R4 format with v5, fsync .retention-v2, and release the old lock.

Only the B8 parent-directory fsync selects R20. Before it, R4 remains authority
and the one deterministic candidate resumes. After it, R20 never reads R4 for
authority. Concurrent processes serialize on the existing R4 lock before B8
and SQLite after B8. Death at every open, statement, journal, rename, WAL,
checkpoint, database fsync, format write, or directory fsync has one directly
derivable predecessor or successor.

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
new R20 row. Cancellation after allocation begin but before progress takes the
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
A request to abort after generation seven selects the protected branch without
a refund and cannot create a ninth abort receipt.

## 5. Exact mutation and semantic manifest

### 5.1 Three commits and exact DML templates

Every allocation, row, or fixed operation has exactly begin, progress, finish.
Each commit inserts its corresponding transition row. No lease, pending file,
continuation, fourth commit, trigger, cascade, or external state authority
exists. External work occurs only after a durable begin authorization and
before progress validation.

One mutation unit is one manifest-selected operation with one authorization,
three generation-CAS commits, and at most 12 changed SQL rows in any commit.
Begin binds `maximum_charge_bytes`; progress assigns every newly consumed byte
to `charge_consumed`; finish assigns the remainder exactly once to released
(only allocation A1 or row A2 abort) or abandoned (A3+ protection). An open
operation satisfies consumed+released+abandoned <= maximum; every terminal
operation must equal maximum. `transitions.charged_bytes` is exactly the
nonnegative increase in consumed charge in that commit. The operation finish
digest references its finish transition. Row_state economic_charge_bytes is
the checked sum of committed consumed deltas and changes in the same progress
CAS. Replay changes zero rows and returns the stored transition; any different
authorization, counter, charge operand, or evidence protects without a second
refund.

Appendix C is the complete DML template registry. Parameters are typed values
already bound by the operation authorization. Statements execute in displayed
order with every UPDATE carrying exact old-generation/state predicates. A
zero-row or over-row statement rolls back.

- generic-begin: insert operations; insert K operation_external_intents in
  ordinal order; insert begin transition; update protocol_meta. Changes 3+K.
- allocation-begin: generic-begin plus update one free row_slot. K=4; changes 8.
- generic-progress: insert progress transition; update operation; update exactly
  one row_state or fixed_state; insert E evidence rows; apply the manifest's
  special rows; update protocol_meta. Changes 4+E+special.
- allocation-progress: insert progress; update operation; insert four evidence;
  insert source_rows; insert row_state; update row_slots; update meta. Changes
  10.
- generic-finish: insert finish; update operation to committed/aborted/protected;
  update protocol_meta. Changes 3.
- allocation-cancel-progress: insert progress; set operation cancel_requested;
  update meta. Changes 3 and leaves the allocating slot selected.
- allocation-finish-aborted: insert finish; update operation; update the exact
  allocating row_slot from attempt `a` to `allocation_attempts=a+1` and either
  free for `a<7` or exhausted for `a=7`; update meta. Changes 4.
- replacement-progress: insert progress; update operation; insert incumbent
  released custody event; update incumbent custody_current; insert replacement
  active custody event; update replacement custody_current; update one
  catalog_slots row from exact active+pending pair to replacement active with
  pending null; update protocol_meta. Changes 8.

The maximum is 12 rows, reserved for manifest variants with up to four evidence
rows plus four special rows. No legal R20 operation may exceed it. Initial
activation is the same replacement template with null incumbent and has six
changes. Cancellation of a pending replacement updates only catalog_slots,
custody event/current for the replacement, transition, operation, and meta; the
active columns are compared and preserved byte-for-byte.

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
insert-or-CAS catalog pending row, for progress 9. Ordinal 109 checkpoint-record
uses replacement-switch/catalog-custody and has the exact
initial/switch branch in Appendix C. Together with the A3 receipt, four A5
publication receipts, prepared-adoption-record, and eight abort receipts, these
are exactly 16 external row entries. Every one of the 128 recovery-family fixed
entries uses legacy-inspect-readonly; all other fixed entries use none. Thus the
intent bound is exactly `32S + 16R + 128`, including four intents for each of
eight allocation attempts per slot.

Abort ordinals 110+8g+s use the graph in section 4.3. Slots 0...6 are
state-only. Slot 7 uses create-regular/abort-receipt/a1a2-release and progress
5. Fixed entries use their family ranges in section 4.2, family-local fine
states n to n+1, coarse fixed to fixed, and state-only except recovery names
containing external, directory, carrier, or selector, which use
legacy-inspect-readonly and can only validate/migrate/protect evidence. They
cannot create a legacy object.

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

custody_events is append-only and custody_current selects one event per
artifact. A replacement switch uses the exact eight-row transaction in section
5.1. The catalog slot changes only if every incumbent and pending field matches
the operation authorization. A crash selects the entire old slot or entire new
slot. Serving reads the active tuple once, joins custody_current and direct root
and receipt evidence in the same read transaction, then revalidates them before
MLX open.

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
  ASCII("macprovider-r20-gc-helper-v1") || artifact_sha256 ||
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

Each lifecycle permits at most 16 successful 256-entry quanta for the
4,096-entry artifact cap and at most eight claim/recovery failures. The 25th
nonterminal event protects. One terminal event makes 26 the per-lifecycle
maximum; R20 conservatively reserves 64 events per artifact for enqueue,
checks, results, and protection. An artifact digest has one GC lifecycle and
cannot be readopted after done; re-preparation of identical bytes reuses the
still-present active custody object before release or returns a typed
artifact_retired result after deletion.

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

R20 has no custom carrier, packed slot, B+ tree, promoted root, or application
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
| gc_events | 64R |
| gc_meta | 1 |

At S=R=1,024 this is 186,688 operations, 560,064 transitions, at most
49,280 intents, 49,280 evidence objects, 8,192 custody events, and 65,536 GC
events. The evidence ceiling is 48R+128: at most four source/allocation rows,
16 row-workflow rows, 25 GC result rows, three terminal/protection reserve rows
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
reserved exclusively for already-open finish/protection, GC result, and WAL
checkpoint work; new begin is rejected at 114,688 pages. The independent
maximum-shape loader must populate every maximum row with maximum-width legal
values and every declared index, VACUUM into 4,096-byte pages, then replay
worst-case WAL transactions. Approval requires main plus indexes at or below
448 MiB, WAL at or below 64 MiB, and each maximum 12-row transaction fitting
the emergency reserve. Failure does not permit a larger limit or smaller
acceptance fixture; R20 remains blocked pending a reviewed schema reduction.

## 10. Canonical scalar, null, digest, and reference registries

Appendix D defines `tuple_v1` without relying on R19. For database row digests,
every INTEGER is u63 except `cancel_requested`, which is bool; every TEXT is NFC
text; BLOB names ending `_uuid` are UUID; names ending `_sha256`, plus
`bootstrap_id`, are SHA; `relative_path` and `tail` are bytes. A schema column
matching zero or two rules fails construction. SQL NULL maps only to tuple null
and only where Appendix A permits it. A row identity is SHA-256 of tuple domain
`macprovider-r20/<table>` and every DDL column in order, with its own identity
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
digests hash tuple domain `macprovider-r20/catalog-binding` over
model,release,artifact,row,operation; source_token_sha256 hashes the exact
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
are required in R26.

## 11. Complete Swift migration matrix

All new code is owned behind CatalogAuthorityV5. R4MigrationReader is the only
type allowed to decode legacy names, and only before B8 or while validating the
deterministic unselected candidate. The cutover matrix is normative:

| current owner/symbol group | R20 owner/interface | before B8 | after B8 / forbidden bypass proof |
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

## 13. Finding disposition

| finding | R20 correction | R26 proof |
|---|---|---|
| H1 | six authoritative fixed_state families with local cursors | R26-04 |
| H2 | indexed 1,024 row_slots and allocation three-commit graph | R26-05 |
| H3 | reachable A1 allocation abort and A2 eight-generation row abort/retry graph | R26-06 |
| H4 | registry plus normalized semantic DML manifest and exact effect mapping | R26-07 |
| H5 | catalog_slots representation and exact six/eight-row activation/switch | R26-08 |
| H6 | deterministic source/schema/registry-bound bootstrap_id path | R26-03 |
| H7 | separate CREATE/DELETE candidate and no-CREATE/WAL selected profiles | R26-02/03 |
| H8 | SQLITE_OPEN_NOFOLLOW plus directory-bound openat VFS for main/WAL/SHM | R26-02 |
| H9 | checking is recoverable with deterministic helper/result and daemon lock | R26-10 |
| H10 | daemon-derived canonical source namespace and root-issued source token | R26-09 |
| M1 | hard maxima for every table plus 64-MiB emergency reserve and max loader | R26-11 |
| M2 | literal Appendix D scalar/null/digest tables and outcome truth table | R26-12 |
| M3 | complete API/callsite cutover matrix and static/runtime bypass gates | R26-13 |

The inherited R18 carrier-packing finding remains closed by deletion: Appendix
A uses native SQLite pages and R26-11 measures the full database and indexes
without assuming a carrier fanout. The inherited bootstrap-encoding ambiguity
is closed by section 3's literal tuple preimage and R26-03's independent byte
oracle.

## Appendix A — normalized authoritative DDL

Normalization removes CR and trailing whitespace and retains exactly one LF
after each SQL statement. No trigger or view exists.

~~~sql
PRAGMA application_id=1297109587;
CREATE TABLE protocol_meta(id INTEGER PRIMARY KEY CHECK(id=1),schema_version INTEGER NOT NULL CHECK(schema_version=20),bootstrap_id BLOB NOT NULL CHECK(length(bootstrap_id)=32),source_index_sha256 BLOB NOT NULL CHECK(length(source_index_sha256)=32),source_rows_sha256 BLOB NOT NULL CHECK(length(source_rows_sha256)=32),candidate_directory_identity_sha256 BLOB NOT NULL CHECK(length(candidate_directory_identity_sha256)=32),schema_sha256 BLOB NOT NULL CHECK(length(schema_sha256)=32),registry_sha256 BLOB NOT NULL CHECK(length(registry_sha256)=32),semantic_manifest_sha256 BLOB NOT NULL CHECK(length(semantic_manifest_sha256)=32),format_sha256 BLOB CHECK(format_sha256 IS NULL OR length(format_sha256)=32),state TEXT NOT NULL CHECK(state IN('bootstrap','ready','protected')),bootstrap_phase TEXT CHECK(bootstrap_phase IS NULL OR bootstrap_phase IN('b3-schema','b4-import','b5-delete-verified','b6-wal','b7-ready')),bootstrap_row_cursor INTEGER NOT NULL CHECK(bootstrap_row_cursor BETWEEN 0 AND 1024),generation INTEGER NOT NULL CHECK(generation>=1),source_row_count INTEGER NOT NULL CHECK(source_row_count BETWEEN 0 AND 1024),operation_count INTEGER NOT NULL CHECK(operation_count BETWEEN 0 AND 186688),transition_count INTEGER NOT NULL CHECK(transition_count BETWEEN 0 AND 560064),intent_count INTEGER NOT NULL CHECK(intent_count BETWEEN 0 AND 49280),evidence_count INTEGER NOT NULL CHECK(evidence_count BETWEEN 0 AND 49280),staging_source_count INTEGER NOT NULL CHECK(staging_source_count BETWEEN 0 AND 1024),custody_event_count INTEGER NOT NULL CHECK(custody_event_count BETWEEN 0 AND 8192),catalog_slot_count INTEGER NOT NULL CHECK(catalog_slot_count BETWEEN 0 AND 1024),gc_candidate_count INTEGER NOT NULL CHECK(gc_candidate_count BETWEEN 0 AND 1024),gc_event_count INTEGER NOT NULL CHECK(gc_event_count BETWEEN 0 AND 65536),page_limit INTEGER NOT NULL CHECK(page_limit=131072),begin_page_limit INTEGER NOT NULL CHECK(begin_page_limit=114688),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((state IN('bootstrap','ready') AND protected_code IS NULL)OR(state='protected' AND protected_code IS NOT NULL)),CHECK((state='bootstrap' AND bootstrap_phase IS NOT NULL AND format_sha256 IS NULL)OR(state='ready' AND bootstrap_phase='b7-ready' AND format_sha256 IS NOT NULL)OR state='protected')) STRICT;
CREATE TABLE transition_registry(scope TEXT NOT NULL CHECK(scope IN('allocation','row','fixed')),ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 319),family TEXT NOT NULL CHECK(length(family) BETWEEN 1 AND 32),local_ordinal INTEGER NOT NULL CHECK(local_ordinal BETWEEN 0 AND 173),name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 128),coarse_from TEXT NOT NULL CHECK(length(coarse_from) BETWEEN 1 AND 32),coarse_to TEXT NOT NULL CHECK(length(coarse_to) BETWEEN 1 AND 32),fine_from TEXT NOT NULL CHECK(length(fine_from) BETWEEN 1 AND 128),fine_to TEXT NOT NULL CHECK(length(fine_to) BETWEEN 1 AND 128),effect_template TEXT NOT NULL CHECK(length(effect_template) BETWEEN 1 AND 64),external_template TEXT NOT NULL CHECK(length(external_template) BETWEEN 1 AND 64),required_evidence_kind TEXT CHECK(required_evidence_kind IS NULL OR length(required_evidence_kind) BETWEEN 1 AND 64),charge_rule TEXT NOT NULL CHECK(charge_rule IN('zero','allocation','a3-directory','a5-evidence','adoption-lifecycle','a1a2-release')),begin_changes INTEGER NOT NULL CHECK(begin_changes BETWEEN 3 AND 12),progress_changes_base INTEGER NOT NULL CHECK(progress_changes_base BETWEEN 4 AND 12),progress_changes_with_incumbent INTEGER NOT NULL CHECK(progress_changes_with_incumbent BETWEEN 4 AND 12),cancel_progress_changes INTEGER NOT NULL CHECK(cancel_progress_changes BETWEEN 3 AND 12),finish_changes INTEGER NOT NULL CHECK(finish_changes BETWEEN 3 AND 12),max_row_changes INTEGER NOT NULL CHECK(max_row_changes=12),CHECK((scope='allocation' AND ordinal=0 AND local_ordinal=0)OR(scope='row' AND ordinal BETWEEN 0 AND 173 AND local_ordinal=ordinal)OR(scope='fixed' AND ordinal BETWEEN 0 AND 319)),PRIMARY KEY(scope,ordinal),UNIQUE(scope,ordinal,family),UNIQUE(scope,family,local_ordinal),UNIQUE(scope,name)) STRICT, WITHOUT ROWID;
CREATE TABLE fixed_state(family TEXT PRIMARY KEY CHECK(family IN('source','merge','tree','verification','materialization','recovery')),current_local_ordinal INTEGER NOT NULL CHECK(current_local_ordinal BETWEEN 0 AND 128),fine_state TEXT NOT NULL CHECK(length(fine_state) BETWEEN 1 AND 128),status TEXT NOT NULL CHECK(status IN('active','complete','protected')),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((status='protected' AND protected_code IS NOT NULL)OR(status!='protected' AND protected_code IS NULL)),CHECK((family IN('source','tree','verification') AND current_local_ordinal<=32)OR(family IN('merge','materialization') AND current_local_ordinal<=64)OR family='recovery')) STRICT, WITHOUT ROWID;
CREATE TABLE row_slots(row_ordinal INTEGER PRIMARY KEY CHECK(row_ordinal BETWEEN 0 AND 1023),state TEXT NOT NULL CHECK(state IN('free','allocating','occupied','exhausted','retired')),allocation_operation_uuid BLOB CHECK(allocation_operation_uuid IS NULL OR length(allocation_operation_uuid)=16),source_transaction_uuid BLOB CHECK(source_transaction_uuid IS NULL OR length(source_transaction_uuid)=16),allocation_attempts INTEGER NOT NULL CHECK(allocation_attempts BETWEEN 0 AND 8),generation INTEGER NOT NULL CHECK(generation>=1),CHECK((state='free' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NULL AND allocation_attempts<8)OR(state='allocating' AND allocation_operation_uuid IS NOT NULL AND source_transaction_uuid IS NULL AND allocation_attempts<8)OR(state='occupied' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NOT NULL)OR(state='retired' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NOT NULL)OR(state='exhausted' AND allocation_operation_uuid IS NULL AND source_transaction_uuid IS NULL AND allocation_attempts=8))) STRICT;
CREATE INDEX idx_free_row_slots ON row_slots(row_ordinal) WHERE state='free';
CREATE TABLE evidence_objects(evidence_sha256 BLOB PRIMARY KEY CHECK(length(evidence_sha256)=32),kind TEXT NOT NULL CHECK(length(kind) BETWEEN 1 AND 64),root_kind TEXT NOT NULL CHECK(root_kind IN('transaction-store','staging-store','custody-store')),relative_path BLOB NOT NULL CHECK(length(relative_path) BETWEEN 1 AND 512),path_sha256 BLOB NOT NULL CHECK(length(path_sha256)=32),byte_length INTEGER CHECK(byte_length IS NULL OR byte_length BETWEEN 0 AND 2305843009213693951),content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256)=32),device_id INTEGER NOT NULL CHECK(device_id BETWEEN 0 AND 2305843009213693951),file_id INTEGER NOT NULL CHECK(file_id BETWEEN 0 AND 2305843009213693951),file_type TEXT NOT NULL CHECK(file_type IN('regular','directory')),mode INTEGER NOT NULL CHECK(mode BETWEEN 0 AND 65535),owner_uid INTEGER NOT NULL CHECK(owner_uid BETWEEN 0 AND 2305843009213693951),group_gid INTEGER NOT NULL CHECK(group_gid BETWEEN 0 AND 2305843009213693951),link_count INTEGER NOT NULL CHECK(link_count=1),mtime_seconds INTEGER NOT NULL CHECK(mtime_seconds BETWEEN 0 AND 2305843009213693951),mtime_nanoseconds INTEGER NOT NULL CHECK(mtime_nanoseconds BETWEEN 0 AND 999999999),ctime_seconds INTEGER NOT NULL CHECK(ctime_seconds BETWEEN 0 AND 2305843009213693951),ctime_nanoseconds INTEGER NOT NULL CHECK(ctime_nanoseconds BETWEEN 0 AND 999999999),birthtime_seconds INTEGER NOT NULL CHECK(birthtime_seconds BETWEEN 0 AND 2305843009213693951),birthtime_nanoseconds INTEGER NOT NULL CHECK(birthtime_nanoseconds BETWEEN 0 AND 999999999),user_flags INTEGER NOT NULL CHECK(user_flags BETWEEN 0 AND 2305843009213693951),system_flags INTEGER NOT NULL CHECK(system_flags BETWEEN 0 AND 2305843009213693951),identity_sha256 BLOB NOT NULL CHECK(length(identity_sha256)=32),created_generation INTEGER NOT NULL CHECK(created_generation>=1),CHECK((file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL)OR(file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL)),UNIQUE(root_kind,relative_path),UNIQUE(device_id,file_id,birthtime_seconds,birthtime_nanoseconds)) STRICT, WITHOUT ROWID;
CREATE TABLE source_rows(row_ordinal INTEGER PRIMARY KEY REFERENCES row_slots(row_ordinal),transaction_uuid BLOB NOT NULL UNIQUE CHECK(length(transaction_uuid)=16),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),primary_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),origin_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),class_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),lineage_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),created_generation INTEGER NOT NULL CHECK(created_generation>=1)) STRICT;
CREATE TABLE row_state(row_ordinal INTEGER PRIMARY KEY REFERENCES source_rows(row_ordinal),coarse_state TEXT NOT NULL CHECK(coarse_state IN('A2','A3','A4','A5','A6','A7','A8','protected')),fine_state TEXT NOT NULL CHECK(length(fine_state) BETWEEN 1 AND 128),attempt_generation INTEGER NOT NULL CHECK(attempt_generation BETWEEN 0 AND 7),abort_generation INTEGER NOT NULL CHECK(abort_generation BETWEEN 0 AND 8),economic_charge_bytes INTEGER NOT NULL CHECK(economic_charge_bytes BETWEEN 0 AND 2305843009213693951),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((coarse_state='protected' AND protected_code IS NOT NULL)OR(coarse_state!='protected' AND protected_code IS NULL))) STRICT;
CREATE TABLE operations(operation_uuid BLOB PRIMARY KEY CHECK(length(operation_uuid)=16),scope TEXT NOT NULL CHECK(scope IN('allocation','row','fixed')),registry_ordinal INTEGER NOT NULL,row_ordinal INTEGER REFERENCES row_slots(row_ordinal),allocation_attempt INTEGER CHECK(allocation_attempt IS NULL OR allocation_attempt BETWEEN 0 AND 7),fixed_family TEXT REFERENCES fixed_state(family),phase TEXT NOT NULL CHECK(phase IN('open','committed','aborted','protected')),authorization_sha256 BLOB NOT NULL UNIQUE CHECK(length(authorization_sha256)=32),base_generation INTEGER NOT NULL CHECK(base_generation>=1),maximum_charge_bytes INTEGER NOT NULL CHECK(maximum_charge_bytes BETWEEN 0 AND 2305843009213693951),charge_consumed INTEGER NOT NULL CHECK(charge_consumed BETWEEN 0 AND 2305843009213693951),charge_released INTEGER NOT NULL CHECK(charge_released BETWEEN 0 AND 2305843009213693951),charge_abandoned INTEGER NOT NULL CHECK(charge_abandoned BETWEEN 0 AND 2305843009213693951),cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN(0,1)),finish_sha256 BLOB CHECK(finish_sha256 IS NULL OR length(finish_sha256)=32),UNIQUE(operation_uuid,authorization_sha256),FOREIGN KEY(scope,registry_ordinal) REFERENCES transition_registry(scope,ordinal),FOREIGN KEY(scope,registry_ordinal,fixed_family) REFERENCES transition_registry(scope,ordinal,family),FOREIGN KEY(operation_uuid,finish_sha256) REFERENCES transitions(operation_uuid,transition_sha256),CHECK((scope='allocation' AND row_ordinal IS NOT NULL AND allocation_attempt IS NOT NULL AND fixed_family IS NULL)OR(scope='row' AND row_ordinal IS NOT NULL AND allocation_attempt IS NULL AND fixed_family IS NULL)OR(scope='fixed' AND row_ordinal IS NULL AND allocation_attempt IS NULL AND fixed_family IS NOT NULL)),CHECK((phase='open' AND finish_sha256 IS NULL)OR(phase!='open' AND finish_sha256 IS NOT NULL)),CHECK((phase='open' AND charge_consumed+charge_released+charge_abandoned<=maximum_charge_bytes)OR(phase!='open' AND charge_consumed+charge_released+charge_abandoned=maximum_charge_bytes))) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX idx_open_row_operation ON operations(row_ordinal) WHERE phase='open' AND scope='row';
CREATE UNIQUE INDEX idx_open_allocation_operation ON operations(row_ordinal) WHERE phase='open' AND scope='allocation';
CREATE UNIQUE INDEX idx_allocation_attempt ON operations(row_ordinal,allocation_attempt) WHERE scope='allocation';
CREATE UNIQUE INDEX idx_row_semantic_slot ON operations(row_ordinal,registry_ordinal) WHERE scope='row' AND registry_ordinal<110;
CREATE UNIQUE INDEX idx_row_abort_slot ON operations(row_ordinal,registry_ordinal) WHERE scope='row' AND registry_ordinal>=110;
CREATE UNIQUE INDEX idx_fixed_semantic_slot ON operations(fixed_family,registry_ordinal) WHERE scope='fixed';
CREATE TABLE operation_external_intents(operation_uuid BLOB NOT NULL REFERENCES operations(operation_uuid),intent_ordinal INTEGER NOT NULL CHECK(intent_ordinal BETWEEN 0 AND 3),kind TEXT NOT NULL CHECK(kind IN('directory','regular','existing-evidence','staging-source')),evidence_kind TEXT NOT NULL CHECK(length(evidence_kind) BETWEEN 1 AND 64),root_kind TEXT NOT NULL CHECK(root_kind IN('transaction-store','staging-store','custody-store')),file_type TEXT NOT NULL CHECK(file_type IN('regular','directory')),relative_path BLOB NOT NULL CHECK(length(relative_path) BETWEEN 1 AND 512),path_sha256 BLOB NOT NULL CHECK(length(path_sha256)=32),byte_length INTEGER CHECK(byte_length IS NULL OR byte_length BETWEEN 0 AND 2305843009213693951),content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256)=32),identity_sha256 BLOB CHECK(identity_sha256 IS NULL OR length(identity_sha256)=32),PRIMARY KEY(operation_uuid,intent_ordinal),CHECK((kind='directory' AND file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL AND identity_sha256 IS NULL)OR(kind='regular' AND file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL AND identity_sha256 IS NULL)OR(kind IN('existing-evidence','staging-source') AND identity_sha256 IS NOT NULL AND ((file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL)OR(file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL))))) STRICT, WITHOUT ROWID;
CREATE TABLE transitions(operation_uuid BLOB NOT NULL REFERENCES operations(operation_uuid),step_ordinal INTEGER NOT NULL CHECK(step_ordinal BETWEEN 0 AND 2),kind TEXT NOT NULL CHECK(kind IN('begin','progress','finish')),base_generation INTEGER NOT NULL CHECK(base_generation>=1),successor_generation INTEGER NOT NULL UNIQUE CHECK(successor_generation=base_generation+1),prior_transition_sha256 BLOB CHECK(prior_transition_sha256 IS NULL OR length(prior_transition_sha256)=32),authorization_sha256 BLOB NOT NULL CHECK(length(authorization_sha256)=32),charged_bytes INTEGER NOT NULL CHECK(charged_bytes BETWEEN 0 AND 2305843009213693951),outcome TEXT NOT NULL CHECK(outcome IN('selected','committed','aborted','protected')),transition_sha256 BLOB NOT NULL UNIQUE CHECK(length(transition_sha256)=32),PRIMARY KEY(operation_uuid,step_ordinal),UNIQUE(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,prior_transition_sha256) REFERENCES transitions(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,authorization_sha256) REFERENCES operations(operation_uuid,authorization_sha256),CHECK((kind='begin' AND step_ordinal=0 AND prior_transition_sha256 IS NULL AND outcome='selected')OR(kind='progress' AND step_ordinal=1 AND prior_transition_sha256 IS NOT NULL AND outcome='selected')OR(kind='finish' AND step_ordinal=2 AND prior_transition_sha256 IS NOT NULL AND outcome IN('committed','aborted','protected')))) STRICT, WITHOUT ROWID;
CREATE TABLE verification_state(row_ordinal INTEGER PRIMARY KEY REFERENCES source_rows(row_ordinal),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),verification_uuid BLOB NOT NULL CHECK(length(verification_uuid)=16),entry_cursor INTEGER NOT NULL CHECK(entry_cursor BETWEEN 0 AND 4096),bytes_completed INTEGER NOT NULL CHECK(bytes_completed BETWEEN 0 AND 2305843009213693951),h0 INTEGER NOT NULL CHECK(h0 BETWEEN 0 AND 4294967295),h1 INTEGER NOT NULL CHECK(h1 BETWEEN 0 AND 4294967295),h2 INTEGER NOT NULL CHECK(h2 BETWEEN 0 AND 4294967295),h3 INTEGER NOT NULL CHECK(h3 BETWEEN 0 AND 4294967295),h4 INTEGER NOT NULL CHECK(h4 BETWEEN 0 AND 4294967295),h5 INTEGER NOT NULL CHECK(h5 BETWEEN 0 AND 4294967295),h6 INTEGER NOT NULL CHECK(h6 BETWEEN 0 AND 4294967295),h7 INTEGER NOT NULL CHECK(h7 BETWEEN 0 AND 4294967295),total_byte_count INTEGER NOT NULL CHECK(total_byte_count BETWEEN 0 AND 2305843009213693951),tail BLOB NOT NULL CHECK(length(tail)<=63),manifest_sha256 BLOB NOT NULL CHECK(length(manifest_sha256)=32),generation INTEGER NOT NULL CHECK(generation>=1),CHECK(length(tail)=total_byte_count%64)) STRICT;
CREATE TABLE staging_sources(transaction_uuid BLOB PRIMARY KEY CHECK(length(transaction_uuid)=16),row_ordinal INTEGER NOT NULL UNIQUE REFERENCES source_rows(row_ordinal),source_token_sha256 BLOB NOT NULL UNIQUE CHECK(length(source_token_sha256)=32),receipt_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),state TEXT NOT NULL CHECK(state IN('registered','consumed','cancelled','protected')),generation INTEGER NOT NULL CHECK(generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR length(protected_code) BETWEEN 1 AND 64),CHECK((state='protected' AND protected_code IS NOT NULL)OR(state!='protected' AND protected_code IS NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE custody_events(row_ordinal INTEGER NOT NULL REFERENCES source_rows(row_ordinal),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL CHECK(custody_generation BETWEEN 1 AND 8),state TEXT NOT NULL CHECK(state IN('verified','active','released','abandoned','protected')),predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),root_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),receipt_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),operation_uuid BLOB REFERENCES operations(operation_uuid),reason TEXT CHECK(reason IS NULL OR reason IN('initial-activation','replacement','removed','cancelled','authority-corrupt','source-changed','evidence-changed','artifact-changed','custody-unavailable','custody-authorization-failed','storage-full','io-error','kernel-io-blocked','unsupported-filesystem','protocol-mismatch','retry-exhausted')),custody_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(custody_event_sha256)=32),PRIMARY KEY(artifact_sha256,custody_generation),UNIQUE(artifact_sha256,custody_event_sha256),UNIQUE(row_ordinal,custody_generation),FOREIGN KEY(artifact_sha256,predecessor_sha256) REFERENCES custody_events(artifact_sha256,custody_event_sha256),CHECK((custody_generation=1 AND predecessor_sha256 IS NULL)OR(custody_generation>1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='verified' AND operation_uuid IS NOT NULL AND reason IS NULL)OR(state='active' AND operation_uuid IS NOT NULL AND reason IN('initial-activation','replacement'))OR(state='released' AND operation_uuid IS NOT NULL AND reason IN('replacement','removed'))OR(state='abandoned' AND operation_uuid IS NOT NULL AND reason='cancelled')OR(state='protected' AND reason IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE custody_current(row_ordinal INTEGER NOT NULL UNIQUE REFERENCES source_rows(row_ordinal),artifact_sha256 BLOB PRIMARY KEY CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL,custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),UNIQUE(artifact_sha256,custody_event_sha256),FOREIGN KEY(artifact_sha256,custody_generation) REFERENCES custody_events(artifact_sha256,custody_generation),FOREIGN KEY(artifact_sha256,custody_event_sha256) REFERENCES custody_events(artifact_sha256,custody_event_sha256)) STRICT, WITHOUT ROWID;
CREATE TABLE catalog_slots(model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),active_artifact_sha256 BLOB,active_custody_event_sha256 BLOB,active_row_ordinal INTEGER REFERENCES source_rows(row_ordinal),active_binding_sha256 BLOB,active_operation_uuid BLOB REFERENCES operations(operation_uuid),pending_artifact_sha256 BLOB,pending_custody_event_sha256 BLOB,pending_row_ordinal INTEGER REFERENCES source_rows(row_ordinal),pending_binding_sha256 BLOB,pending_operation_uuid BLOB REFERENCES operations(operation_uuid),generation INTEGER NOT NULL CHECK(generation>=1),PRIMARY KEY(model_id,release),FOREIGN KEY(active_artifact_sha256,active_custody_event_sha256) REFERENCES custody_current(artifact_sha256,custody_event_sha256),FOREIGN KEY(pending_artifact_sha256,pending_custody_event_sha256) REFERENCES custody_current(artifact_sha256,custody_event_sha256),CHECK((active_artifact_sha256 IS NULL AND active_custody_event_sha256 IS NULL AND active_row_ordinal IS NULL AND active_binding_sha256 IS NULL AND active_operation_uuid IS NULL)OR(length(active_artifact_sha256)=32 AND length(active_custody_event_sha256)=32 AND active_row_ordinal IS NOT NULL AND length(active_binding_sha256)=32 AND active_operation_uuid IS NOT NULL)),CHECK((pending_artifact_sha256 IS NULL AND pending_custody_event_sha256 IS NULL AND pending_row_ordinal IS NULL AND pending_binding_sha256 IS NULL AND pending_operation_uuid IS NULL)OR(length(pending_artifact_sha256)=32 AND length(pending_custody_event_sha256)=32 AND pending_row_ordinal IS NOT NULL AND length(pending_binding_sha256)=32 AND pending_operation_uuid IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE gc_meta(id INTEGER PRIMARY KEY CHECK(id=1),maximum_round INTEGER NOT NULL CHECK(maximum_round BETWEEN 0 AND 2305843009213693951),generation INTEGER NOT NULL CHECK(generation>=1)) STRICT;
CREATE TABLE gc_candidates(row_ordinal INTEGER NOT NULL UNIQUE REFERENCES source_rows(row_ordinal),artifact_sha256 BLOB PRIMARY KEY CHECK(length(artifact_sha256)=32),state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round BETWEEN 0 AND 2305843009213693951),gc_lifecycle_generation INTEGER NOT NULL CHECK(gc_lifecycle_generation=1),custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),manifest_cursor INTEGER CHECK(manifest_cursor BETWEEN 0 AND 4096),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),attempt_count INTEGER NOT NULL CHECK(attempt_count BETWEEN 0 AND 8),last_event_sha256 BLOB NOT NULL CHECK(length(last_event_sha256)=32),FOREIGN KEY(artifact_sha256,custody_event_sha256) REFERENCES custody_current(artifact_sha256,custody_event_sha256),FOREIGN KEY(artifact_sha256,last_event_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256) DEFERRABLE INITIALLY DEFERRED,CHECK((state IN('checking','deleting','blocked-kernel-io','protected') AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL)OR(state IN('queued','done') AND manifest_cursor IS NULL AND delete_phase IS NULL AND helper_operation_uuid IS NULL))) STRICT, WITHOUT ROWID;
CREATE INDEX idx_gc_fair ON gc_candidates(eligible_round,artifact_sha256) WHERE state IN('queued','checking','deleting');
CREATE TABLE gc_events(artifact_sha256 BLOB NOT NULL REFERENCES gc_candidates(artifact_sha256),event_generation INTEGER NOT NULL CHECK(event_generation BETWEEN 1 AND 64),predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),custody_event_sha256 BLOB NOT NULL CHECK(length(custody_event_sha256)=32),state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round BETWEEN 0 AND 2305843009213693951),manifest_cursor INTEGER CHECK(manifest_cursor IS NULL OR manifest_cursor BETWEEN 0 AND 4096),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),result_evidence_sha256 BLOB REFERENCES evidence_objects(evidence_sha256),gc_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(gc_event_sha256)=32),PRIMARY KEY(artifact_sha256,event_generation),UNIQUE(artifact_sha256,gc_event_sha256),FOREIGN KEY(artifact_sha256,predecessor_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256),FOREIGN KEY(artifact_sha256,custody_event_sha256) REFERENCES custody_events(artifact_sha256,custody_event_sha256),CHECK((event_generation=1 AND predecessor_sha256 IS NULL)OR(event_generation>1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='queued' AND manifest_cursor IS NULL AND delete_phase IS NULL AND helper_operation_uuid IS NULL AND result_evidence_sha256 IS NULL)OR(state='checking' AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL AND result_evidence_sha256 IS NULL)OR(state IN('deleting','blocked-kernel-io','done','protected') AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL AND result_evidence_sha256 IS NOT NULL))) STRICT, WITHOUT ROWID;
~~~

The normalized Appendix A bytes have SHA-256
`3887c7239fb9e2f008cc39795034dfcc1515e585ca0ff7b1b62b2a5e9948b77f`.

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
0|INSERT|operations|operation_uuid;scope;registry_ordinal;row_ordinal;allocation_attempt;fixed_family;phase;authorization_sha256;base_generation;maximum_charge_bytes;charge_consumed;charge_released;charge_abandoned;cancel_requested;finish_sha256|:operation;:scope;:registry;:row-or-null;:allocation-attempt-or-null;:family-or-null;open;:authorization;:g;:maximum-charge;0;0;0;0;null
1..K|INSERT|operation_external_intents|operation_uuid;intent_ordinal;kind;evidence_kind;root_kind;file_type;relative_path;path_sha256;byte_length;content_sha256;identity_sha256|:operation;:intent-ordinal;:intent-kind;:evidence-kind;:root-kind;:file-type;:path;:path-sha;:length-or-null;:content-sha-or-null;:identity-sha-or-null
K+1|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;0;begin;:g;:g+1;null;:authorization;0;selected;:begin-sha
K+2|CAS|protocol_meta|id=1;state=ready;generation=:g;operation_count=:oc;transition_count=:tc;intent_count=:ic|generation=:g+1;operation_count=INC(1);transition_count=INC(1);intent_count=INC(K)

allocation-begin-addition
A0|CAS|row_slots|row_ordinal=:row;state=free;allocation_operation_uuid=null;source_transaction_uuid=null;allocation_attempts=:attempt;generation=:row-generation|state=allocating;allocation_operation_uuid=:operation;generation=:row-generation+1

generic-progress
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;:charge-delta;selected;:progress-sha
1|CAS|operations|operation_uuid=:operation;phase=open;authorization_sha256=:authorization;base_generation=:base-generation;charge_consumed=:old-consumed;charge_released=:old-released;charge_abandoned=:old-abandoned|charge_consumed=:new-consumed;charge_released=:new-released;charge_abandoned=:new-abandoned;cancel_requested=:cancel
2|CAS|row_state-or-fixed_state|:domain-primary-key;:manifest-coarse-from;:manifest-fine-from;generation=:domain-generation|:manifest-coarse-to;:manifest-fine-to;generation=:domain-generation+1;:manifest-counter-setters
3..2+E|INSERT|evidence_objects|evidence_sha256;kind;root_kind;relative_path;path_sha256;byte_length;content_sha256;device_id;file_id;file_type;mode;owner_uid;group_gid;link_count;mtime_seconds;mtime_nanoseconds;ctime_seconds;ctime_nanoseconds;birthtime_seconds;birthtime_nanoseconds;user_flags;system_flags;identity_sha256;created_generation|:direct-evidence-fields
3+E..2+E+S|SPECIAL|:manifest-special-table|:manifest-special-columns-and-old-predicate|:manifest-special-values
3+E+S|CAS|protocol_meta|id=1;state=ready;generation=:g;transition_count=:tc;evidence_count=:ec;:special-counters-old|generation=:g+1;transition_count=INC(1);evidence_count=INC(E);:special-counters-new

generic-finish
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;2;finish;:g;:g+1;:progress-sha;:authorization;0;:terminal-outcome;:finish-sha
1|CAS|operations|operation_uuid=:operation;phase=open;authorization_sha256=:authorization;charge_consumed=:consumed;charge_released=:released;charge_abandoned=:abandoned;finish_sha256=null|phase=:terminal-outcome;finish_sha256=:finish-sha
2|CAS|protocol_meta|id=1;state=ready;generation=:g;transition_count=:tc|generation=:g+1;transition_count=INC(1)

allocation-progress-special
P0..P3|INSERT|evidence_objects|:all-evidence-columns|:primary,:origin,:class,:lineage in intent order
P4|INSERT|source_rows|row_ordinal;transaction_uuid;model_id;release;primary_evidence_sha256;origin_evidence_sha256;class_evidence_sha256;lineage_evidence_sha256;created_generation|:row;:transaction;:model;:release;:primary-sha;:origin-sha;:class-sha;:lineage-sha;:g+1
P5|INSERT|row_state|row_ordinal;coarse_state;fine_state;attempt_generation;abort_generation;economic_charge_bytes;generation;protected_code|:row;A2;row-normal-76;0;0;0;:g+1;null
P6|CAS|row_slots|row_ordinal=:row;state=allocating;allocation_operation_uuid=:operation;source_transaction_uuid=null;allocation_attempts=:attempt|state=occupied;allocation_operation_uuid=null;source_transaction_uuid=:transaction;generation=INC(1)
P7|CAS|protocol_meta|id=1;state=ready;generation=:g;source_row_count=:src;evidence_count=:ec;transition_count=:tc|generation=:g+1;source_row_count=INC(1);evidence_count=INC(4);transition_count=INC(1)

allocation-cancel-progress
0|INSERT|transitions|operation_uuid;step_ordinal;kind;base_generation;successor_generation;prior_transition_sha256;authorization_sha256;charged_bytes;outcome;transition_sha256|:operation;1;progress;:g;:g+1;:begin-sha;:authorization;0;selected;:cancel-progress-sha
1|CAS|operations|operation_uuid=:operation;scope=allocation;phase=open;authorization_sha256=:authorization;cancel_requested=0;charge_consumed=0;charge_released=0;charge_abandoned=0|cancel_requested=1
2|CAS|protocol_meta|id=1;state=ready;generation=:g;transition_count=:tc|generation=:g+1;transition_count=INC(1)

allocation-finish-aborted-special
F0|CAS|row_slots|row_ordinal=:row;state=allocating;allocation_operation_uuid=:operation;source_transaction_uuid=null;allocation_attempts=:attempt;generation=:row-generation|state=:free-if-attempt-lt-7-else-exhausted;allocation_operation_uuid=null;allocation_attempts=:attempt+1;generation=:row-generation+1

replacement-progress-special
R0|INSERT|custody_events|row_ordinal;artifact_sha256;custody_generation;state;predecessor_sha256;root_evidence_sha256;receipt_evidence_sha256;operation_uuid;reason;custody_event_sha256|:incumbent-row;:incumbent-artifact;:incumbent-generation+1;released;:incumbent-event;:incumbent-root;:incumbent-receipt;:operation;replacement;:released-event
R1|CAS|custody_current|row_ordinal=:incumbent-row;artifact_sha256=:incumbent-artifact;custody_generation=:incumbent-generation;custody_event_sha256=:incumbent-event|custody_generation=:incumbent-generation+1;custody_event_sha256=:released-event
R2|INSERT|custody_events|row_ordinal;artifact_sha256;custody_generation;state;predecessor_sha256;root_evidence_sha256;receipt_evidence_sha256;operation_uuid;reason;custody_event_sha256|:replacement-row;:replacement-artifact;:replacement-generation+1;active;:replacement-event;:replacement-root;:replacement-receipt;:operation;replacement;:active-event
R3|CAS|custody_current|row_ordinal=:replacement-row;artifact_sha256=:replacement-artifact;custody_generation=:replacement-generation;custody_event_sha256=:replacement-event|custody_generation=:replacement-generation+1;custody_event_sha256=:active-event
R4|CAS|catalog_slots|model_id=:model;release=:release;all-active-columns=:incumbent-tuple;all-pending-columns=:replacement-tuple;generation=:slot-generation|all-active-columns=:replacement-active-tuple;all-pending-columns=null;generation=:slot-generation+1

staging-register-special
S0|INSERT|staging_sources|transaction_uuid;row_ordinal;source_token_sha256;receipt_evidence_sha256;state;generation;protected_code|:transaction;:row;:source-token-sha;:receipt-evidence;registered;:g+1;null

custody-verified-special
C0|INSERT|custody_events|row_ordinal;artifact_sha256;custody_generation;state;predecessor_sha256;root_evidence_sha256;receipt_evidence_sha256;operation_uuid;reason;custody_event_sha256|:row;:artifact;1;verified;null;:root-evidence;:receipt-evidence;:operation;null;:verified-event
C1|INSERT|custody_current|row_ordinal;artifact_sha256;custody_generation;custody_event_sha256|:row;:artifact;1;:verified-event
C2a|INSERT-IF-ABSENT|catalog_slots|model_id;release;all-active-columns;all-pending-columns;generation|:model;:release;null;:verified-pending-tuple;:g+1
C2b|CAS-IF-PRESENT|catalog_slots|model_id=:model;release=:release;all-active-columns=:incumbent-active-tuple;all-pending-columns=null;generation=:slot-generation|all-active-columns=:same-incumbent-active-tuple;all-pending-columns=:verified-pending-tuple;generation=:slot-generation+1

initial-activation-special
I0|INSERT|custody_events|row_ordinal;artifact_sha256;custody_generation;state;predecessor_sha256;root_evidence_sha256;receipt_evidence_sha256;operation_uuid;reason;custody_event_sha256|:replacement-row;:replacement-artifact;:replacement-generation+1;active;:replacement-event;:replacement-root;:replacement-receipt;:operation;initial-activation;:active-event
I1|CAS|custody_current|row_ordinal=:replacement-row;artifact_sha256=:replacement-artifact;custody_generation=:replacement-generation;custody_event_sha256=:replacement-event|custody_generation=:replacement-generation+1;custody_event_sha256=:active-event
I2|CAS|catalog_slots|model_id=:model;release=:release;all-active-columns=null;all-pending-columns=:replacement-tuple;generation=:slot-generation|all-active-columns=:replacement-active-tuple;all-pending-columns=null;generation=:slot-generation+1

gc-enqueue
0|INSERT|gc_candidates|row_ordinal;artifact_sha256;state;eligible_round;gc_lifecycle_generation;custody_event_sha256;manifest_cursor;delete_phase;helper_operation_uuid;attempt_count;last_event_sha256|:row;:artifact;queued;:round;1;:custody-event;null;null;null;0;:event-sha
1|INSERT|gc_events|artifact_sha256;event_generation;predecessor_sha256;custody_event_sha256;state;eligible_round;manifest_cursor;delete_phase;helper_operation_uuid;result_evidence_sha256;gc_event_sha256|:artifact;1;null;:custody-event;queued;:round;null;null;null;null;:event-sha
2|CAS|gc_meta|id=1;maximum_round=:old-round;generation=:gc-generation|maximum_round=:round;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_candidate_count=:gcc;gc_event_count=:gec|generation=:g+1;gc_candidate_count=INC(1);gc_event_count=INC(1)

gc-advance
0|INSERT|gc_events|:all-event-columns|:selected-candidate-successor-values
1|CAS|gc_candidates|artifact_sha256=:artifact;last_event_sha256=:old-event;state=:old-state;eligible_round=:old-round;manifest_cursor=:old-cursor;delete_phase=:old-phase;helper_operation_uuid=:old-helper;attempt_count=:old-attempt|last_event_sha256=:new-event;state=:new-state;eligible_round=:new-round;manifest_cursor=:new-cursor;delete_phase=:new-phase;helper_operation_uuid=:new-helper;attempt_count=:new-attempt
2|CAS|gc_meta|id=1;maximum_round=:old-maximum;generation=:gc-generation|maximum_round=:new-maximum;generation=:gc-generation+1
3|CAS|protocol_meta|id=1;state=ready;generation=:g;gc_event_count=:gec;evidence_count=:ec|generation=:g+1;gc_event_count=INC(1);evidence_count=INC(:result-evidence-count)
~~~

For generic progress, `row_state-or-fixed_state` is resolved by `scope`, never
by a caller-provided table name. `SPECIAL` is legal only when the expanded
registry line names one of the literal special templates above.
The manifest line stores `E`, `S`, every special descriptor digest, exact
charge operands, replay digest, and typed protection code. The sum of the
displayed descriptors must equal the line's change count before execution.

The normalized manifest then includes these closed external effects:

| external template | authorized action | progress proof |
|---|---|---|
| none | no external call | zero intent rows |
| four-existing-source-evidence | direct-open four preexisting R4/R20 evidence paths | four exact evidence rows |
| create-directory | exclusive no-follow mkdir beneath transaction root | direct directory identity evidence |
| create-regular | exclusive temp/write/fsync/rename/parent-fsync | direct regular evidence |
| staging-register | daemon-derived canonical staging path and root receipt | staging_sources plus receipt evidence |
| custody-copy | daemon C0-C6 root-owned copy, two content passes, hardening | root and custody receipt direct evidence |
| replacement-switch | no filesystem action; exact selected pending custody required | catalog/custody eight-row CAS |
| legacy-inspect-readonly | direct-open a manifest-named R4 evidence file | exact evidence or protected; never create |

Every template binds root kind, path bytes and raw byte count, path digest,
length/null, content digest/null, full identity digest, evidence kind, operation
UUID, registry digest, manifest digest, base generation, and maximum charge in
operation authorization. Protection uses the same finish commit and never
performs a second external action.

## Appendix D — complete standalone external codecs

No external codec inherits an unspecified R19 default. `tuple_v1` is ASCII
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
SHA-256 of tuple domain `macprovider-r20/file-identity` with columns in this
order: `device_id:u63,file_id:u63,file_type:text,mode:u63,owner_uid:u63,
group_gid:u63,link_count:u63,byte_length:u63-or-null,mtime_seconds:u63,
mtime_nanoseconds:u63,ctime_seconds:u63,ctime_nanoseconds:u63,
birthtime_seconds:u63,birthtime_nanoseconds:u63,user_flags:u63,
system_flags:u63`. These are the only path and identity digest targets.

### `custody_receipt_v1`

Tuple domain: `macprovider-r20/custody-receipt-v1`. Direct path:
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

Tuple domain: `macprovider-r20/custody-entry`. The transcript seed is
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

Tuple domain: `macprovider-r20/gc-result-v1`. Direct path:
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

Tuple domain: `macprovider-r20/staging-source-receipt-v1`. Direct path:
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

## Appendix E — current Swift callsite inventory

This is the complete R20 migration inventory from the inspected dirty Swift
tree. Private parsing/stat helpers stay behind their listed owner; every
authority-bearing entry must appear in the section 11 cutover table and in the
syntax-aware post-B8 allowlist test. A newly added declaration or callsite is a
plan change and reopens the gate.

At the recorded worktree revision, whitespace-normalized function declarations
from `ModelCatalogTransaction*.swift`, sorted by filename and source order,
number 199 and hash to
`ee8c3d647aa4e06e32681de466a882f116edde3f2f440dc3c0a4fee1cda38373`.
The same normalization for filename, matched bypass literal, and containing
source line over the seven section 11 literals yields 68 matches and SHA-256
`2d15574a6dc9064501da011b2ec80e543f6a443fdf327b9efc6162fd8ad1a2b0`.
These are inspection checkpoints, not accepted post-implementation counts.

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

The frozen literal bypass inventory additionally includes every production
occurrence of `active.json`, `progress.json`, `maintenance.json`, reservation
sidecar leaf names, `captureIndexReceipt`, `recaptureIndexReceipt`,
`adoptVerifiedStaging`, and `gcInactive`. R26 records the normalized manifest
and hash before source work, then requires every occurrence after B8 to be
absent or mapped to one exact pre-B8-only `R4MigrationReader` branch. Line
numbers are deliberately not authority because concurrent BYOM work can move
them; syntax-qualified file/type/function identity is authority.
