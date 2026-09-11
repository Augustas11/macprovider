# Build 1 reservation search progress addendum R19

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This docs-only revision responds to all nine High and one
Medium findings in
`reviews/reservation-search-progress-r18-plan-sol.md`. It is reviewed together
with `test-spec-r25-reservation-r19-corrections.md`. No source or test work is
authorized until a fresh independent native GPT-5.6 Sol review reports zero
Critical, High, and Medium findings for the exact two-file revision.

Frozen inputs are R18
`0926f4408fdf9f8287021d7b029858da01a83705b6f286fb6d707c2df8a5fc2b`,
R24 `9cb6eaf9d272d0ef8ed179a5b4b7e156d2b1351351a7dcb277aa8cf45415aaec`,
and its failed review
`7b675a364a61a24192094d8f6991779af87504bdf09928f9901011e3ab5faaaa`.
The inspected repository base is `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`; the worktree HEAD remains
`914f7cafcdbcfc1805a10f4f34167218341d5587`. The dirty implementation remains
the R4 array/scan design. Nothing described here is implemented.

The code grounding for this revision is
`ModelCatalogTransactionRetention.swift`: `retentionDirectory`,
`reserveOperation`, `loadActiveIndexLocked`, and the `active.json` writes;
`ModelCatalogTransactionRetentionTests.swift`: the current bounded scans,
crash subprocesses, tamper cases, and v2 format fixtures;
`DurableModelArtifactStore.swift`: `adoptVerifiedStaging` and the current
`contentsOfDirectory`/`removeItem` cleanup; and `AutotuneDB.swift`, which
already imports SQLite3 and supplies the in-repository linking precedent.
`specs/AUTHORITY.json` and `specs/CONFORMANCE.json` assign the affected phase-3
and catalog-economics behavior to SPEC-001 and SPEC-044. These are inspection
anchors, not evidence that R19 exists or passes.

## 1. Decision, authority, and limits

R19 withdraws the unimplemented R16-R18 selector, carrier, custom B+ tree,
lease-record, root-promotion, and custom GC-index designs in full. Their
version discriminators remain rejection-only tombstones. No `v7`, `v8`, or
`v9` selector may be emitted. R19 uses the SQLite3 library already linked by
`phase3-binary` and introduces no dependency.

The replacement is one private SQLite authority at:

```text
ModelTransactions/.retention-v2/.reservation-migration/retirement/v2/catalog-state.sqlite3
```

The database transaction is the only selected catalog/reservation/custody/GC
authority. There are no protocol carriers, local record references, promoted
roots, mutable JSON selector, separate operation lease, or authoritative
directory scan. SQLite indexes replace the proposed B+ trees. External files
are inputs or evidence selected by complete direct references stored in the
database; their bytes never become an alternate state authority.

R10's A0-A8 economic boundary remains normative: only A1/A2 may abort and
release unused reservation; A3 and later must complete forward with the full
admitted charge or protect. The exact 174 per-row and 320 fixed semantic
transition names from section 4 remain closed. R18's finite SHA split oracle is
retained with the corrected state codec in section 9. The product still admits
at most 1,024 source rows.

Before implementation, SPEC-001 and SPEC-044 must be amended to name the R19
SQLite authority, the privileged custody boundary, the migration fence, the
failure taxonomy, and the feature gate. Approval of this plan does not itself
amend a SPEC. Nothing here grants network admission, model identity, pricing,
settlement, rewards, enforcement, deployment, release, or physical
qualification.

## 2. Physical database contract

### 2.1 Files and SQLite configuration

The parent chain is existing-root-only, owned by the provider account, mode
0700, and opened component by component with `openat` plus `O_NOFOLLOW`. The
main database is mode 0600, a regular file with link count one. Its siblings
may only be:

```text
catalog-state.sqlite3
catalog-state.sqlite3-wal
catalog-state.sqlite3-shm
```

The v5 format fence remains at the existing exact path:

```text
ModelTransactions/.retention-v2/format.json
```

Unknown entries protect. The format file is immutable-by-protocol historical
evidence and is never rewritten after selection. SQLite owns WAL/SHM creation
and locking; application flock is forbidden for database mutations.

Every connection sets and verifies:

```text
PRAGMA page_size=4096                 -- before bootstrap schema creation
PRAGMA journal_mode=WAL               -- exact returned value "wal"
PRAGMA synchronous=FULL
PRAGMA foreign_keys=ON
PRAGMA trusted_schema=OFF
PRAGMA recursive_triggers=OFF
PRAGMA secure_delete=ON
PRAGMA busy_timeout=0
PRAGMA wal_autocheckpoint=4096
PRAGMA journal_size_limit=67108864
PRAGMA max_page_count=131072           -- 512 MiB main database ceiling
PRAGMA user_version=19
```

The connection enables `SQLITE_DBCONFIG_DEFENSIVE`, disables extension loading,
uses `SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX`, and rejects a SQLite runtime
older than 3.37 because STRICT tables are mandatory. Every connection validates
`page_size`, `max_page_count`, `user_version`, all connection pragmas, the
literal `sqlite_master` schema, meta/schema/registry digests, and affected-row
foreign keys before mutation. Full `integrity_check` and `foreign_key_check`
run after bootstrap, after WAL crash recovery, on provider startup, and during
explicit maintenance while mutation readiness is unavailable; they are not
repeated inside the eight-second control call. A mismatch sets
`protocol_meta.state='protected'` in the next otherwise-valid transaction when
possible; if the database cannot safely transact, the process returns
`catalog_authority_unavailable` and performs no external mutation.

The 512 MiB ceiling and 64 MiB WAL limit are product limits, not capacity
claims. `SQLITE_FULL`, `SQLITE_IOERR`, `SQLITE_CORRUPT`, or an inability to
checkpoint after a terminal operation is a typed failure and never a passed
transition. The product-shape test must show the exact R=1,024 fixture fits;
otherwise product admission is lowered by a reviewed SPEC change. The plan
does not increase either limit to make a test pass.

SQLite normally owns at most the main, WAL, and SHM descriptors. A direct
external-evidence validation may add one descriptor, producing the four-FD
control ceiling. Bootstrap uses rollback-journal mode temporarily and orders
source reads so the old journal lock, one source descriptor, main DB, and
rollback journal are the only simultaneous descriptors. The source descriptor
is closed before the next source is opened. The final conversion to WAL occurs
after the old source descriptors and rollback journal are closed.

### 2.2 Canonical values, row digest, and reference types

No R19 database row or external evidence codec uses JSON; the v5 selection
fence in section 3 is the sole JSON exception. SQLite integers are restricted
to `0...Int64.max`; booleans are integer 0 or 1. UUIDs are exactly 16-byte blobs
in RFC 4122 network order. SHA-256 values are exactly 32-byte blobs. Text is
valid NFC UTF-8, contains no NUL, and is bounded by its column rule. Relative
paths are UTF-8 blobs so SQLite collation cannot normalize them; they are
nonempty, at most 4,096 bytes, have no NUL, leading slash, empty component,
`.` or `..` component, and round-trip byte-identically through `openat`.

`tuple_v1(domain, columns...)` is the only row-digest codec. It is ASCII
`domain`, zero byte, `u32be(columnCount)`, then each column in declared order:

```text
null:  0x00
u63:   0x01 || u64be(value)
bool:  0x02 || one byte 0x00 or 0x01
text:  0x03 || u32be(byteCount) || NFC UTF-8
bytes: 0x04 || u32be(byteCount) || bytes
uuid:  0x05 || 16 bytes
sha:   0x06 || 32 bytes
```

Lengths are checked before allocation. There are no floats, dates, implicit
coercions, platform integers, maps, arrays, or alternate null encodings. A row
identity is `SHA256(tuple_v1("macprovider-r19/<table>", all columns in DDL
order, with the identity column represented in its declared position by
null))`. `transition_sha256`, `custody_event_sha256`, `gc_event_sha256`, and
`verification_chunks.chunk_sha256` use that rule. No other `*sha256` is
self-derived.

The DDL-to-tuple scalar registry is closed: INTEGER columns
`permanently_nonreusable` and `cancel_requested` are bool; every other INTEGER
is u63. A BLOB column ending `_uuid` is uuid, ending `_sha256` is sha, named
`relative_path`, ending `_relative_path`, or named `tail` is bytes; no other
BLOB name is legal. Every TEXT is text. SQL NULL maps only to the tuple null tag and only where sections 6-9
permit it. Schema construction fails if a column matches zero or two rules.

Every SHA field has exactly one target:

| exact field set | target |
|---|---|
| `evidence_objects.evidence_sha256`, `transitions.transition_sha256`, `verification_chunks.chunk_sha256`, `custody_events.custody_event_sha256`, `gc_events.gc_event_sha256` | tuple-v1 append-only row identity with only that identity column null |
| every `artifact_sha256` and `replacement_artifact_sha256` | current SPEC-001 artifact-tree SHA-256 |
| `protocol_meta.source_index_sha256`, `protocol_meta.source_rows_sha256`, `evidence_objects.content_sha256`, `operations.intended_content_sha256`, `verification_chunks.manifest_sha256` | raw bytes or canonical source transcript named by the row |
| `protocol_meta.format_sha256` | raw exact v5 format JCS bytes |
| `path_sha256` | `SHA256("macprovider-relative-path-v1\0" || u64be(path.count) || path)` |
| `identity_sha256` | SHA-256 of `tuple_v1("macprovider-r19/file-identity", device_id,file_id,file_type,mode,owner_uid,group_gid,link_count,byte_length,mtime_seconds,mtime_nanoseconds,ctime_seconds,ctime_nanoseconds,birthtime_seconds,birthtime_nanoseconds,user_flags,system_flags)` |
| `schema_sha256` | UTF-8 bytes of the normalized DDL in Appendix A |
| `registry_sha256` | UTF-8 bytes of the 494 expanded Appendix B registry lines, each in the eight-field format in section 5, joined by LF with one terminal LF |
| `source_rows.primary_evidence_sha256`, `origin_evidence_sha256`, `class_evidence_sha256`, `left_evidence_sha256`, `operations.intended_evidence_sha256`, `custody_events.root_evidence_sha256`, `receipt_evidence_sha256`, `drain_evidence_sha256`, `gc_events.result_evidence_sha256` | `evidence_objects.evidence_sha256` foreign-key identity |
| `operations.authorization_sha256`, every `transitions.authorization_sha256` | exact operation-authorization digest in section 5 |
| `catalog_bindings.binding_sha256` | `SHA256(tuple_v1("macprovider-r19/catalog-binding",model_id,release,artifact_sha256,source_row_ordinal,catalog_operation_uuid))`; stable across pending/active/released state updates |
| `operations.finish_sha256`, `transitions.prior_transition_sha256` | exact `transitions.transition_sha256` foreign-key identity |
| `verification_chunks.prior_chunk_sha256` | exact prior `verification_chunks.chunk_sha256` row identity |
| `custody_events.predecessor_sha256`, every `custody_event_sha256` reference | exact `custody_events.custody_event_sha256` foreign-key identity |
| `gc_candidates.last_event_sha256`, `gc_events.predecessor_sha256` | exact `gc_events.gc_event_sha256` foreign-key identity |

The normalized DDL is Appendix A with CR removed, trailing whitespace removed,
and exactly one LF after every displayed SQL line. Comments and surrounding
Markdown are excluded. Production embeds its expected `schema_sha256` and
`registry_sha256`; the independent test encoder transcribes the two appendices
and must produce the same values without importing production constants.

`evidence_objects` is the sole external reference type. A selected reference
is its `evidence_sha256` primary key and resolves to exact kind, canonical
relative path, path digest, length, raw content digest, and full immutable file
identity. Directory enumeration, digest-only lookup, guessed names, inode-only
lookup, and accepting a different file with the same content are forbidden.
Every use direct-opens the stored path beneath its declared root, compares
descriptor and no-follow pathname stat to all identity columns before and
after reading, enforces the length, hashes bytes, and revalidates the database
row in a new transaction before acting.

### 2.3 New external evidence codecs and direct paths

Existing SPEC-governed R4 primary/origin/class/left and preparation seal/
receipt files are immutable inputs: their existing strict decoder validates
their semantics before R19 records their raw content and complete identity.
R19 adds only two external byte codecs. Both use tuple-v1 and reject extra or
missing columns.

`custody_receipt_v1` has columns, in order:

```text
schema="custody_receipt_v1",daemon_protocol_version=1,operation_uuid,
model_id,release,artifact_sha256,root_relative_path,root_path_sha256,
manifest_sha256,entry_count,canonical_bytes,content_pass_1_sha256,
content_pass_2_sha256,identity_transcript_sha256,root_identity_sha256
```

Its direct path is
`receipts/<artifact-sha256-hex>/<operation-uuid>.custody-v1`; the root path is
`artifacts/<first-two-artifact-hex>/<artifact-sha256-hex>`. Counts are u63;
UUID and SHA values use their tuple tags; paths are canonical relative-path
bytes. `manifest_sha256` is the current SPEC-001 canonical manifest digest;
both content-pass digests are the current SPEC-001 artifact/tree digest and
must equal `artifact_sha256`; `root_identity_sha256` is the section 2.2
file-identity digest of the final root directory. All other values are
nonempty NFC text.

The identity transcript begins
`SHA256("macprovider-custody-identity-transcript-v1\0")`. For each manifest
entry in ascending raw relative-path bytes it replaces the accumulator with
`SHA256(accumulator || u32be(entryTuple.count) || entryTuple)`, where entryTuple
is tuple-v1 domain `macprovider-r19/custody-entry` and exact columns
`relative_path,file_type,mode,owner_uid,group_gid,link_count,byte_length,
mtime_seconds,mtime_nanoseconds,ctime_seconds,ctime_nanoseconds,
birthtime_seconds,birthtime_nanoseconds,user_flags,system_flags,
content_sha256,identity_sha256`. Directory byte length and content digest are
null; regular-file content digest is SHA-256 of its raw bytes. Every entry
identity digest uses the section 2.2 file-identity tuple. The final accumulator
is the receipt field. No entry list is stored in SQLite.

`gc_result_v1` has columns, in order:

```text
schema="gc_result_v1",daemon_protocol_version=1,helper_operation_uuid,
artifact_sha256,base_custody_event_sha256,start_phase,end_phase,start_cursor,
end_cursor,entries_processed,path_bytes_processed,syscalls_processed,outcome,
root_identity_before_sha256,root_identity_after_sha256
```

Its direct path is
`gc-results/<artifact-sha256-hex>/<event-generation>-<helper-operation-uuid>.gc-v1`.
Phase is `flags|entries|root|fsync|complete`; outcome is
`progress|done|protected|blocked-kernel-io`. Cursors and counters are u63. The
after-root identity is non-null only for progress/protected and null after the
root is durably removed or the child is unreaped. Every other column is
non-null. Both root-identity fields use the section 2.2 file-identity digest;
the base custody field is the exact selected `custody_event_sha256`. The file
is root-owned, immutable evidence; ownership is not a cryptographic signature.

## 3. Bootstrap and compatibility

### 3.1 Direct paths and selection

The existing R4 journal lock and source paths remain the only pre-fence
authority. Bootstrap creates a private sibling directory
`.retention-v2/.reservation-migration/retirement/v2-bootstrap/<migrationUUID>/`
under the old journal lock and uses
`catalog-state.sqlite3.tmp` inside it. The final directory
`.retention-v2/.reservation-migration/retirement/v2/` and final DB must be
absent. The selected `.retention-v2/format.json` must be the exact supported R4
format; B8 atomically replaces it with v5 after revalidating those same bytes.

The v5 `format.json` payload is the only R19 JSON object and uses the existing strict JCS
utility. It has exactly:

```text
schema="model_catalog_retention_format.v5"
database_relative_path=".reservation-migration/retirement/v2/catalog-state.sqlite3"
schema_sha256=<64 lowercase hex>
registry_sha256=<64 lowercase hex>
migration_uuid=<lowercase canonical UUID>
source_index_sha256=<64 lowercase hex>
source_rows_sha256=<64 lowercase hex>
database_device_id=<decimal u63>
database_file_id=<decimal u63>
database_file_type="regular"
database_mode=384
database_owner_uid=<decimal u63>
database_group_gid=<decimal u63>
database_link_count=1
database_birthtime_seconds=<decimal u63>
database_birthtime_nanoseconds=<decimal u63>
```

No field is nullable. It is written at the existing exact
`ModelTransactions/.retention-v2/format.json` path and is bounded by the
current 4,096-byte format-file limit. `format_sha256=SHA256(exact format JCS)`
is stored in `protocol_meta` before selection; the format contains no self
digest. The governing SPEC amendment must reserve v5 and require every earlier
binary to reject it before write.

Those database fields are its stable locator identity. Every connection
compares descriptor and no-follow pathname device, inode, type, mode, owner,
group, link count and birth time. Database size, mtime and ctime are expected
to change under SQLite and are not locator fields; SQLite page/WAL integrity
and transactional checks govern their contents.

### 3.2 Exact bootstrap sequence

Bootstrap performs these steps under the old journal lock:

```text
B0 validate R4 format/index, all source primary/origin/class/left evidence,
   compute exact source index/row transcripts, old lock identity, row count
   <=1,024, and free-space ceiling
B1 mkdir and fsync the exact private bootstrap directory
B2 create temp DB in DELETE journal mode, page size 4096, user_version 19
B3 execute Appendix A in one transaction; insert meta state bootstrap and
   gc_meta(id=1,generation=1,minimum_round=0,maximum_round=0)
B4 stream rows in source-ordinal order, one source FD at a time; insert the
   exact source_rows/row_state/evidence_objects rows; compute source transcript
B5 insert registry rows, leave meta bootstrap/generation 1, commit, fsync DB,
   run quick_check and foreign_key_check, close DB and rollback journal
B6 rename bootstrap directory to exact retirement/v2; fsync retirement parent
B7 reopen final DB by no-follow path, verify identity/source/schema/registry,
   construct exact format JCS, store its SHA and set meta ready in one commit,
   convert to WAL, checkpoint TRUNCATE, close, fsync DB and v2 directory
B8 write exclusive `.retention-v2/format.json.tmp-v5`, fsync, rename to exact
   `.retention-v2/format.json`, fsync `.retention-v2`, then release the old
   journal lock
```

Only B8 selects R19. Before B8, R4 is authoritative and an exact unselected v2
candidate may be reused after full database, source, path, identity, and
registry validation. Any unequal candidate protects and requires operator
repair; it is never deleted automatically. After the B8 directory fsync, R19
is authoritative. A missing/drifted DB or format, invalid SQLite recovery,
failed integrity/foreign-key/schema check, or source mismatch returns protected
without falling back to R4. No selected database is recreated from old JSON.

The bootstrap database is a legal complete authority: it has no operation,
lease, transition, custody, GC candidate, or GC event requiring a bootstrap
exception. Its initialized singleton GC metadata is ordinary state. Its
only generation is `protocol_meta.generation=1`; every imported row has
`created_generation=1`. There are no genesis receipts and no null ordinary
authorization to invent.

## 4. One executable mutation and accounting graph

### 4.1 Literal three-commit semantic transition

Each of the 174 row and 320 fixed registry entries is one independent semantic
transition operation. It has exactly three selected SQLite commits:

```text
begin:    BEGIN IMMEDIATE validates the registry slot and domain predecessor,
          inserts one open operation plus its begin transition, and commits
progress: BEGIN IMMEDIATE revalidates operation/registry/predecessor, inserts
          its progress transition, applies the one named semantic transition,
          changes at most the named domain rows, and commits
finish:   BEGIN IMMEDIATE revalidates the selected progress, atomically closes
          the budget and operation, inserts its finish transition with outcome
          committed|aborted|protected, and commits
```

Begin is reserve plus open; finish is close plus terminal. There is no separate
`reserve-open`, `closing-*`, lease removal, selector, pending, or continuation
mutation. Crash before any COMMIT selects none of that commit; crash after its
durable COMMIT selects all of it. SQLite recovery decides this.

A semantic slot can be selected at most once for its source row, or once
globally for fixed scope, enforced by the partial unique indexes in Appendix A.
A caller supplies `operation_uuid,scope,source_row_ordinal,registry_ordinal,
registry_name,expected_generation,expected_predecessor_state`. Begin requires
the exact registry row and domain state. A stale caller, replay with different
bytes, state skip, wrong scope, or second opener fails before external mutation.
An exact replay of begin/progress/finish returns the already-selected successor
and makes no second debit. SQLite serializes concurrent writers; no process,
PID, time, expiry, heartbeat, or renewable lease is authority.

For a step with an external filesystem effect, begin is the sole narrow
authorization for that exact evidence descriptor/path/digest and progress is
the commit that validates the completed effect. No external mutation occurs
before begin. A caller dying after begin leaves one open operation that any
compatible caller must resume; no other row operation can open. Cancellation
arriving after begin does not erase that authorization: the exact semantic
transition reaches progress/finish or protects, then A1/A2 may enter its named
abort path while A3+ continues forward. This keeps a filesystem effect from
being orphaned behind a fictitious rollback.

Transitions contain no opaque payload. External body, artifact, manifest,
source block, legacy tree page, or receipt bytes cannot be embedded. They are
selected only through `evidence_objects`, `source_rows`, `catalog_bindings`, or
`custody_events`. Progress changes at most eight rows: its transition insert,
operation update, one row-state or catalog binding, one evidence/custody row,
one current-head row, and protocol-meta generation. Begin changes four rows;
finish changes five. A trigger, cascade, or hidden mutation is forbidden;
`total_changes` must equal the registry-generated expected count before COMMIT.

### 4.2 Capacity and charge accounting

The single capacity interpretation is:

```text
semanticSlots(R)          = 174*R + 320
operationRows(R)         <= 174*R + 320
selectedTransactions(R) <= 3*(174*R + 320) = 522*R + 960
R=1,024: semanticSlots=178,496; selectedTransactions<=535,488
```

This is a conservative lifetime ceiling: mutually exclusive abort generations
or failure branches leave slots unused, but no unnamed transition exists and no
slot can be reused. `maximum_steps=3` for every operation. Begin consumes one
step, progress two, and finish three. No step release is needed because every
started operation always selects its terminal third commit; if recovery cannot
do so it selects protected as that third commit. Unstarted semantic slots have
no operation or counter row.

Database metadata pages are provider protocol overhead and are never presented
as artifact bytes or charged to the provider/model. `charged_bytes` and the
operation charge counters mean only the exact governed A0-A8 economic byte
delta: zero for non-materialization metadata, the selected directory charge for
A3, the exact direct evidence-object length for an A5 body, and the current
SPEC-governed artifact/lifecycle delta for adoption. Each registry entry has one
closed charge rule generated with Appendix B; no SQLite page/WAL byte is mixed
into it. A1/A2 abort releases the exact unused pre-A3 lifecycle reserve. A3+
forward completion records unmaterialized remainder as abandoned-and-charged,
not released, retaining the full admitted economic charge.

Before begin, SQLite must report at least 64 pages below `max_page_count`, WAL
checkpoint must succeed, and the containing volume must have at least 64 MiB
available beyond the current main/WAL sizes. These are admission guards, not
reserved or billed bytes. The eight-row/no-payload transaction bound is measured
at maximum shape; if any legal transition can require more than 64 new pages,
that transition/host is feature-gated. `SQLITE_FULL`, `SQLITE_IOERR`, failed
checkpoint, or a page/volume limit race rolls the commit back and selects no
product/economic successor.

Every finish requires `steps_consumed=3`, `steps_released=0`,
`steps_abandoned=0`, and:

```text
charge_consumed + charge_released + charge_abandoned = maximum_charge_bytes
```

Counters are monotonic u63. Exact replay does not change them. Overflow or
inequality prevents the commit. Protection is a separately valid third commit
when the database remains writable; otherwise the caller reports authority
unavailable without claiming a selected protected row.

## 5. Closed transition registry and state rules

Appendix B is normative. It is an ordered LF-delimited registry, not prose to
be interpreted. Each generated line is
`scope|ordinal|name|allowed-from|allowed-to|charge-rule|max-payload|max-row-changes`.
Ranges expand in ascending order and products are left-major. Expansion must
yield exactly 174 row and 320 fixed entries with no duplicate name/ordinal.
The expanded rows are inserted at bootstrap and runtime joins by scope,
ordinal and name.

`charge-rule` is `zero` except for these literal names:

```text
A3-directory-publication-receipt -> a3-directory
A5-<primary|origin|class|lineage>-publication-receipt -> a5-evidence
prepared-adoption-record -> adoption-lifecycle
abort-<0...7>-publish-abort-receipt -> a1a2-release
```

No name can match two rules. A3+ finish applies the section 4.2
abandoned-and-charged remainder from selected row state; it is a terminal
accounting equality, not another registry charge.

For row ordinals 0...109, allowed state is `row-normal-<n>` to
`row-normal-<n+1>`. Their coarse A-state changes only at literal `phase-A*`
entries. Abort ordinal `110+8*g+s` uses `row-abort-<g>-<s>` to
`row-abort-<g>-<s+1>` for slots 1...7. Slot zero instead uses the sole literal
predecessor `coarse-A1-or-A2-and-abort-generation-<g>` and successor
`row-abort-<g>-1`. No registry row has two predecessors, and no normal
transition accepts an abort state. For fixed ordinal n, state is `fixed-<n>` to `fixed-<n+1>`.
`row_state.fine_state` and `abort_generation` store these values; bootstrap
starts rows at `row-normal-0` and abort generation zero. An aborted retry may
start only after an explicit product action restores A1/A2 while incrementing
abort generation in the preceding selected terminal transition; generation
eight protects. A3-A6 cancellation sets the operation disposition
`forward-only` and only the remaining normal successors are legal. A protected
row cannot reopen or release charge.

`operation_authorization_sha256` is
`SHA256(tuple_v1("macprovider-r19/operation-authorization",
operation_uuid,scope,source_row_ordinal,registry_ordinal,registry_name,
expected_predecessor_state,external_intent_kind,intended_evidence_sha256,
intended_root_kind,intended_relative_path,intended_path_sha256,
intended_byte_length,intended_content_sha256,base_generation,maximum_steps=3,
maximum_charge_bytes,protocol_meta.registry_sha256))`. Every begin, progress and
finish row stores it, the prior transition SHA, expected base generation, and
successor generation. The database foreign keys plus tuple digest bind the
exact provider-local scope, workflow, source row, transaction UUID, limits,
and registry digest. It has no PID, time, expiry, owner, or renewable field.

## 6. Standalone schema, null, enum, and reference closure

Appendix A is the full authoritative schema. STRICT tables, explicit CHECKs,
foreign keys, and the following closure rules are normative:

1. `protocol_meta` has exactly one row. `protected_code` is null iff state is
   bootstrap or ready. `format_sha256` is null only in bootstrap and is
   required in ready/protected. Source hashes are always non-null.
2. `source_rows.allocation_generation` is non-null iff provenance is
   allocated. `left_evidence_sha256` is non-null iff permanently_nonreusable=1.
3. An operation's `source_row_ordinal` is non-null iff scope=row. It is open iff
   finish SHA is null. Cancel is informational; only the state rule in section
   5 controls abort versus forward-only. Its external intent is exactly one
   DDL branch: none, a future directory, a future regular file, or one already
   selected evidence row. Progress must insert or bind bytes matching every
   intended field.
4. A transition's prior SHA is null only for begin. Finish is the only terminal
   kind. Progress uses exactly the registry ordinal/name for the next step.
5. `evidence_objects.byte_length` is null only for a directory. Content SHA is
   null only for a directory. All identity fields are always present; byte
   length zero is distinct from null.
6. `custody_events` references a predecessor iff generation >1. Exact state
   reference matrix is in section 7. `artifact_current` must select the same
   artifact and generation.
7. Verification continuation words are u32 despite SQLite's u63 storage. Tail
   and total-count rules are section 9. A chunk predecessor is null only for
   ordinal zero.
8. `catalog_bindings` is the only authoritative model-to-artifact mapping.
   Pending/active binding must equal the selected `artifact_current` custody
   event and matching model/release/artifact/source operation. At most one
   pending and at most one active binding exist; replacement may hold one of
   each. Protected code is non-null iff protected.
9. GC predecessor is null only for its first event. A candidate in deleting
   has a manifest cursor and helper operation UUID; queued/done do not. Every
   candidate directly references the selected current custody event and its
   last event. The candidate/event cycle is inserted or advanced in one
   transaction through the deferred last-event foreign key. Event state is
   closed: queued has no cursor/phase/helper/result; checking has a cursor,
   phase, and helper but no result; deleting, blocked, done, and protected have
   all four. Candidate checking/deleting/blocked/protected has cursor, phase,
   and helper; queued/done has none. Only queued/deleting is selectable.
10. Every BLOB length, enum, null branch, relation, and maximum has both a DDL
   CHECK where SQLite can express it and an application pre-update validator.
   The independent validator runs the same cross-row invariants after every
   crash recovery. Unknown tables, columns, indexes, triggers, or views make
   the schema digest differ and protect.

No R16-R18 record/reference/null rule survives implicitly. The only codecs are
SQLite's documented file format, Appendix A logical rows, tuple-v1 digests, the
single fixed JCS format fence, and raw external evidence bytes.

## 7. Trusted artifact custody and final freshness

### 7.1 Required privilege boundary

User-owned `UF_IMMUTABLE` is explicitly insufficient: its owner can clear it.
Trusted adoption is disabled unless a separately reviewed, signed, root-owned
`com.malibu.macprovider.custody` launch daemon is installed and reports the
exact protocol version/capability. The daemon owns a configured custody root,
mode 0755, and final artifact/evidence descendants as `root:wheel`; regular
files are 0444, directories 0555, have link count one for files, and carry
`SF_IMMUTABLE` after publication. The provider account cannot chown, clear the
system flag, write, rename, unlink, or link those objects.

The daemon accepts only XPC clients satisfying the pinned MacProvider code
requirement and the invoking console provider UID. Requests contain a closed
operation enum plus model ID, release, 32-byte catalog artifact digest, and
lowercase transaction UUID. They never contain arbitrary absolute paths, file
descriptors, shell text, or deletion paths. The daemon derives every staging,
final, receipt, and lock path beneath its compiled/configured custody root,
uses `openat/O_NOFOLLOW`, rejects mount/device escape and hard links, and logs
only digests/counts/error codes. It has no network access and reads no operator
secret. Installation, signing, notarization, XPC authorization, and lifecycle
require their own SPEC/security review before the capability can be enabled.

If the daemon is absent, incompatible, fails authorization, or the volume
cannot enforce root ownership plus `SF_IMMUTABLE`, preparation may remain a
local staged result but `adoptionEligible=false` with
`trusted_custody_unavailable`. No SQLite pending/active state may be written.
This is a named Build 1 qualification blocker, not a successful journey.

### 7.2 Copy, verification, receipt, and adoption order

The privileged daemon performs one artifact transaction:

```text
C0 create a root-owned mode-0700 temp beneath custody root; source is user
   staging only
C1 copy each manifest entry through no-follow descriptors while hashing raw
   bytes; capture source identity before/after each copy and reject drift
C2 compare complete current SPEC-001 artifact/tree digest and signed catalog
   identity; fsync every output file and directory
C3 chmod/chown descendants, then directories; set SF_IMMUTABLE descendants
   before parents; fsync; close all source descriptors
C4 reopen root and every entry in canonical manifest order, verify full
   identity/flags, recompute manifest and identity transcript, and hash bytes
   again from the final root-owned copy
C5 write and fsync root-owned `custody_receipt_v1` at the digest-derived temp
   path, containing artifact/model/release/transaction, manifest/count/bytes,
   every final identity transcript, both content-pass digests, daemon protocol
   version and final relative path
C6 rename temp directory and receipt to their digest-derived final names,
   fsync both parents, reopen/revalidate them, and return their direct refs
```

Cancellation before C6 removes only the daemon-owned exact temp after clearing
its own flags. Cancellation or caller death after C6 leaves an inactive,
complete root and receipt; recovery direct-opens their deterministic paths and
returns the same references. A conflicting candidate, source drift, catalog
drift, unsupported file type, symlink, mount crossing, hard link, sparse/hole
policy violation, xattr policy violation, or identity mismatch protects the
candidate and never grants eligibility.

The CLI inserts `evidence_objects` rows for the root directory and custody
receipt after direct validation, then appends custody state `verified`. The
adoption call takes one SQLite `BEGIN IMMEDIATE`, revalidates the current
custody row and both direct evidence references, asks the daemon to revalidate
the still root-owned/immutable final tree without changing it, and only then
atomically selects `pending-adoption` custody plus the exact catalog row. The
daemon boundary makes the final C4-to-SQLite interval non-revocable by the
same-user adversary. Serving direct-opens the selected root/receipt and checks
identity/flags before MLX open.

`custody_events` has this exact non-null matrix:

| state | root | receipt | catalog operation | replacement | drain | reason |
|---|---|---|---|---|---|---|
| verified | required | required | null | null | null | null |
| pending-adoption | required | required | required open | null | null | null |
| active | required | required | required committed | null | null | null |
| replacement-pending | required | required | incumbent committed | required | null | null |
| released | required | required | last committed | nullable | required | replaced/removed |
| abandoned-verified | required | required | null | null | null | cancelled |
| protected | required | required | nullable | nullable | nullable | typed nonempty |

The receipt is always a complete `evidence_objects` reference; a bare digest is
illegal. Every successor references the preceding custody event identity, so
recovery and serving are direct and acyclic. SQLite commit supplies the current
head atomically through `artifact_current`; there are no external head files.

## 8. Bounded authoritative GC

GC authority is the indexed `gc_candidates`, `gc_events`, and `gc_meta` tables.
`idx_gc_fair` orders queued or between-quantum deleting work by
`(eligible_round,artifact_sha256)`; selection is one indexed query and never walks a linked list or artifact
directory. Enqueue, claim, cursor advance, completion, and fairness-round
advance are each one SQLite transaction. Every event stores the exact prior and custody event plus the state-applicable
cursor, daemon operation UUID, and result defined below. A failed commit
selects none; exact replay returns the selected event.

One parent invocation:

1. opens SQLite, claims at most one eligible candidate, increments its round,
   appends a checking event, commits, and closes every DB descriptor;
2. spawns one short-lived daemon child dedicated to that artifact; the child
   takes only that artifact's root-owned lock and direct-opens the custody,
   catalog, receipt, drain, manifest, and path references;
3. processes at most 256 manifest entries, 8 MiB of manifest/path bytes, 1,024
   syscalls, or six seconds, whichever is first; it clears flags and deletes in
   reverse depth only for the exact root-owned object;
4. returns a root-owned tuple-v1 result file at the deterministic evidence
   path; parent reopens SQLite and atomically advances the cursor or
   terminal state after direct validation.

No SQLite connection or global lock is held while filesystem work runs.
Adoption and serving never wait on GC metadata. `eligible_round` is a monotonic
FIFO ticket: enqueue and every incomplete successful quantum assign
`maximum_round+1` in the same transaction and advance `gc_meta.maximum_round`.
Selection takes the smallest ticket and digest. Thus a candidate cannot receive
a second quantum before every candidate already queued ahead of it is claimed
or becomes ineligible; new candidates join the tail and cannot starve the
snapshot. Overflow protects. The `(eligible_round,artifact_sha256)` index
proves O(log N) selection for 10,000 candidates.

The daemon supervisor sends SIGKILL at six seconds and waits one second. A
fixture child blocked in a real FIFO `read(2)` while holding the artifact flock
must die, reap, and release the lock within seven seconds. On a supported local
APFS volume, fault-injected metadata operations must meet the same bound. If a
child cannot be reaped because the kernel keeps it in uninterruptible I/O, the
candidate becomes `blocked-kernel-io`, the artifact lock remains honestly busy,
no replacement child is launched, unrelated artifacts and provider heartbeat
continue, and that filesystem/host loses GC and trusted-adoption qualification.
R19 does not promise lock release for a kernel that cannot reap a killed
process.

Before each deletion quantum the child revalidates current custody is released,
catalog has no active/pending reference, drain is complete, receipt/root
identity matches, and no serving descriptor is registered. Unexpected name,
identity, link, symlink, mount, cursor, or evidence drift publishes protected
without deletion. Death at every clear/unlink/fsync/result/SQL-commit boundary
resumes only the selected reverse-depth prefix.

## 9. Closed SHA-256 continuation codec

`sha256_continuation_v1` is a tuple-v1 logical object with declared columns in
this order: `h0,h1,h2,h3,h4,h5,h6,h7,total_byte_count,tail`. Each `h` is
0...`2^32-1` and encoded u63; `total_byte_count` is 0...Int64.max and includes
all bytes represented by the chaining words plus tail; tail is bytes length
0...63 and `tail.count == total_byte_count mod 64`. When total count is zero,
tail is empty and the words are exactly
`6a09e667,bb67ae85,3c6ef372,a54ff53a,510e527f,9b05688c,1f83d9ab,
5be0cd19` in big-endian word meaning. For nonzero count below 64 the words also remain the
initial constants. For count at least 64, words are the state after exactly
`total_byte_count-tail.count` input bytes. A continuation is never accepted
after final padding. Finalization appends SHA-256 padding using
`total_byte_count*8`; total count is therefore bounded to
`0...2,305,843,009,213,693,951`. Clone copies all
words/count/tail; serialization is network byte order through tuple-v1.

The R18 finite oracle is retained exactly. For each length
`0,1,55,56,63,64,65,64MiB-1,64MiB,64MiB+1`, B contains in-range unique sorted
values from 0, length, 55/56/63/64/65 plus or minus 0/1, each 1-MiB and 64-MiB
multiple plus or minus 0/1, and 256 deterministic SHA-derived offsets. The
known set has 1,676 split completions and about 43.8678 GiB of aggregate suffix
compression, below 4,096 completions, 96 GiB, 64 MiB writable extra RSS, and
30 minutes on recorded hardware. Tests cover `2^32-1` and `2^32` words,
tail/count incongruence, non-IV zero/sub-block state, byte-order swaps, count
overflow, padding boundaries, every state-bit mutation, and one-shot equality.

## 10. Failure, recovery, observability, and rollout

Typed user-facing states are `catalog_busy`, `catalog_full`,
`catalog_authority_unavailable`, `catalog_protected`, `migration_required`,
`trusted_custody_unavailable`, `trusted_custody_authorization_failed`,
`artifact_changed`, `artifact_verification_incomplete`,
`gc_blocked_kernel_io`, `cancelled_before_commit`, and
`cancelled_after_commit_model_active`. Busy is retryable and never success.
Protected is sticky until an audited repair; automatic reconstruction from old
files or directory enumeration is forbidden.

Metrics expose schema/registry version, DB page/WAL bytes, operation phase and
step, measured/reserved/consumed/released/abandoned counters, transition replay,
SQLite result code, custody capability/version, artifact state, recapture
duration/FD count, GC queue/round/cursor, child deadline/reap outcome, and
protection reason. They contain no model bytes, paths, provider secrets, source
payload, or private keys.

Implementation slices after plan and SPEC approval are:

1. Appendix A schema, tuple codec, registry generator, independent fixtures;
2. R4-to-R19 bootstrap, v5 fence, prior-binary rejection, crash matrix;
3. operation/accounting transaction engine and all Appendix B transitions;
4. A1/A2 abort, A3+ forward-only recovery, typed cancellation;
5. privileged custody daemon SPEC/security implementation and physical
   qualification; until then trusted adoption remains disabled;
6. SQL-indexed GC and supervised-child qualification;
7. targeted/full Swift, Malibu Xcode, CLI/app bridge, max-shape, physical MLX,
   compatibility, governance, and independent Sol audit gates.

Rollback may remove an exact unselected bootstrap candidate before B8. After
B8 there is no rollback to R4; compatible code completes, protects, or reports
unavailable. Database backup/restore is operator repair and must preserve
identity, schema, registry, source transcript, and custody evidence.

## 11. R18 finding disposition

| finding | R19 correction | R25 proof |
|---|---|---|
| H1 five mutations funded as three | every named semantic transition has exactly begin/progress/finish; begin combines reserve/open and finish combines close/terminal; `3*(174R+320)` is the sole graph | R25-04 |
| H2 impossible terminal-carrier packing | carrier design withdrawn; bounded SQLite transaction changes <=8 rows and no opaque payload | R25-05 |
| H3 illegal bootstrap control records | one complete SQL bootstrap commit with no lease/genesis exception | R25-03 |
| H4 unreachable pending state | SQLite atomic commits; no pending/continuation persisted state | R25-04 |
| H5 incomplete codec | complete DDL, tuple scalar/null/digest/reference registry, exact transition grammar | R25-02 |
| H6 invalid SHA continuation | u32 words, count/tail/IV/byte-order/finalization invariants | R25-09 |
| H7 receipt not directly addressable | custody event selects full `evidence_objects` reference and SQL current head | R25-06 |
| H8 same-owner freshness race | root-owned daemon copies, rehashes, hardens and recaptures final bytes; absent capability blocks adoption | R25-06 |
| H9 mutable/unbounded GC index | transactional SQL index, immutable event rows, direct custody refs, O(log N) fairness selection | R25-08 |
| M1 blocked call outlives lock deadline | per-artifact daemon child, kill/reap proof, no DB/global lock, explicit uninterruptible-I/O qualification failure | R25-08 |

## Appendix A — normalized authoritative DDL

The following SQL lines, from `PRAGMA application_id` through the last index,
are the complete normalized DDL. There are no triggers or views.

```sql
PRAGMA application_id=1297109587;
CREATE TABLE protocol_meta(id INTEGER PRIMARY KEY CHECK(id=1),schema_version INTEGER NOT NULL CHECK(schema_version=19),schema_sha256 BLOB NOT NULL CHECK(length(schema_sha256)=32),registry_sha256 BLOB NOT NULL CHECK(length(registry_sha256)=32),format_sha256 BLOB CHECK(format_sha256 IS NULL OR length(format_sha256)=32),state TEXT NOT NULL CHECK(state IN('bootstrap','ready','protected')),generation INTEGER NOT NULL CHECK(generation>=1),source_row_count INTEGER NOT NULL CHECK(source_row_count BETWEEN 0 AND 1024),source_index_sha256 BLOB NOT NULL CHECK(length(source_index_sha256)=32),source_rows_sha256 BLOB NOT NULL CHECK(length(source_rows_sha256)=32),page_limit INTEGER NOT NULL CHECK(page_limit=131072),protected_code TEXT CHECK(protected_code IS NULL OR protected_code IN('authority-corrupt','source-changed','evidence-changed','artifact-changed','custody-unavailable','custody-authorization-failed','storage-full','io-error','kernel-io-blocked','unsupported-filesystem','protocol-mismatch','retry-exhausted')),CHECK((state IN('bootstrap','ready') AND protected_code IS NULL)OR(state='protected' AND protected_code IS NOT NULL)),CHECK((state='bootstrap' AND format_sha256 IS NULL)OR(state IN('ready','protected') AND format_sha256 IS NOT NULL))) STRICT;
CREATE TABLE transition_registry(scope TEXT NOT NULL CHECK(scope IN('row','fixed')),ordinal INTEGER NOT NULL CHECK(ordinal>=0),name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 128),allowed_from TEXT NOT NULL CHECK(length(allowed_from) BETWEEN 1 AND 84),allowed_to TEXT NOT NULL CHECK(length(allowed_to) BETWEEN 1 AND 84),charge_rule TEXT NOT NULL CHECK(charge_rule IN('zero','a3-directory','a5-evidence','adoption-lifecycle','a1a2-release')),max_payload_bytes INTEGER NOT NULL CHECK(max_payload_bytes=0),max_row_changes INTEGER NOT NULL CHECK(max_row_changes BETWEEN 1 AND 8),PRIMARY KEY(scope,ordinal),UNIQUE(scope,name),UNIQUE(scope,ordinal,name,allowed_from)) STRICT, WITHOUT ROWID;
CREATE TABLE evidence_objects(evidence_sha256 BLOB PRIMARY KEY CHECK(length(evidence_sha256)=32),kind TEXT NOT NULL CHECK(kind IN('source-primary','source-origin','source-class','source-left','preparation-seal','preparation-receipt','custody-root','custody-receipt','drain-receipt','gc-result')),root_kind TEXT NOT NULL CHECK(root_kind IN('transaction-store','custody-store')),relative_path BLOB NOT NULL CHECK(length(relative_path) BETWEEN 1 AND 4096),path_sha256 BLOB NOT NULL CHECK(length(path_sha256)=32),byte_length INTEGER CHECK(byte_length>=0),content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256)=32),device_id INTEGER NOT NULL CHECK(device_id>=0),file_id INTEGER NOT NULL CHECK(file_id>=0),file_type TEXT NOT NULL CHECK(file_type IN('regular','directory')),mode INTEGER NOT NULL CHECK(mode BETWEEN 0 AND 4095),owner_uid INTEGER NOT NULL CHECK(owner_uid>=0),group_gid INTEGER NOT NULL CHECK(group_gid>=0),link_count INTEGER NOT NULL CHECK(link_count>=1),mtime_seconds INTEGER NOT NULL CHECK(mtime_seconds>=0),mtime_nanoseconds INTEGER NOT NULL CHECK(mtime_nanoseconds BETWEEN 0 AND 999999999),ctime_seconds INTEGER NOT NULL CHECK(ctime_seconds>=0),ctime_nanoseconds INTEGER NOT NULL CHECK(ctime_nanoseconds BETWEEN 0 AND 999999999),birthtime_seconds INTEGER NOT NULL CHECK(birthtime_seconds>=0),birthtime_nanoseconds INTEGER NOT NULL CHECK(birthtime_nanoseconds BETWEEN 0 AND 999999999),user_flags INTEGER NOT NULL CHECK(user_flags>=0),system_flags INTEGER NOT NULL CHECK(system_flags>=0),identity_sha256 BLOB NOT NULL CHECK(length(identity_sha256)=32),created_generation INTEGER NOT NULL CHECK(created_generation>=1),CHECK((file_type='directory' AND byte_length IS NULL AND content_sha256 IS NULL)OR(file_type='regular' AND byte_length IS NOT NULL AND content_sha256 IS NOT NULL)),UNIQUE(root_kind,relative_path),UNIQUE(device_id,file_id,birthtime_seconds,birthtime_nanoseconds)) STRICT, WITHOUT ROWID;
CREATE TABLE source_rows(source_row_ordinal INTEGER PRIMARY KEY CHECK(source_row_ordinal BETWEEN 0 AND 1023),transaction_uuid BLOB NOT NULL UNIQUE CHECK(length(transaction_uuid)=16),provenance TEXT NOT NULL CHECK(provenance IN('allocated','legacy_snapshot','protected_snapshot')),allocation_generation TEXT CHECK(allocation_generation IS NULL OR length(allocation_generation) BETWEEN 1 AND 128),primary_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),origin_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),class_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),left_evidence_sha256 BLOB REFERENCES evidence_objects(evidence_sha256),permanently_nonreusable INTEGER NOT NULL CHECK(permanently_nonreusable IN(0,1)),created_generation INTEGER NOT NULL CHECK(created_generation>=1),CHECK((provenance='allocated' AND allocation_generation IS NOT NULL)OR(provenance!='allocated' AND allocation_generation IS NULL)),CHECK((permanently_nonreusable=1 AND left_evidence_sha256 IS NOT NULL)OR(permanently_nonreusable=0 AND left_evidence_sha256 IS NULL))) STRICT;
CREATE TABLE row_state(source_row_ordinal INTEGER PRIMARY KEY REFERENCES source_rows(source_row_ordinal),state TEXT NOT NULL CHECK(state IN('A0','A1','A2','A3','A4','A5','A6','A7','A8','protected')),fine_state TEXT NOT NULL CHECK(length(fine_state) BETWEEN 1 AND 64),abort_generation INTEGER NOT NULL CHECK(abort_generation BETWEEN 0 AND 8),state_generation INTEGER NOT NULL CHECK(state_generation>=1),economic_charge_bytes INTEGER NOT NULL CHECK(economic_charge_bytes>=0),protected_code TEXT CHECK(protected_code IS NULL OR protected_code IN('authority-corrupt','source-changed','evidence-changed','artifact-changed','custody-unavailable','custody-authorization-failed','storage-full','io-error','kernel-io-blocked','unsupported-filesystem','protocol-mismatch','retry-exhausted')),CHECK((state='protected' AND protected_code IS NOT NULL)OR(state!='protected' AND protected_code IS NULL))) STRICT;
CREATE TABLE operations(operation_uuid BLOB PRIMARY KEY CHECK(length(operation_uuid)=16),scope TEXT NOT NULL CHECK(scope IN('row','fixed')),source_row_ordinal INTEGER REFERENCES source_rows(source_row_ordinal),registry_ordinal INTEGER NOT NULL CHECK(registry_ordinal>=0),registry_name TEXT NOT NULL CHECK(length(registry_name) BETWEEN 1 AND 128),expected_predecessor_state TEXT NOT NULL CHECK(length(expected_predecessor_state) BETWEEN 1 AND 64),external_intent_kind TEXT NOT NULL CHECK(external_intent_kind IN('none','directory','regular','existing-evidence')),intended_evidence_sha256 BLOB REFERENCES evidence_objects(evidence_sha256),intended_root_kind TEXT CHECK(intended_root_kind IS NULL OR intended_root_kind IN('transaction-store','custody-store')),intended_relative_path BLOB CHECK(intended_relative_path IS NULL OR length(intended_relative_path) BETWEEN 1 AND 4096),intended_path_sha256 BLOB CHECK(intended_path_sha256 IS NULL OR length(intended_path_sha256)=32),intended_byte_length INTEGER CHECK(intended_byte_length IS NULL OR intended_byte_length>=0),intended_content_sha256 BLOB CHECK(intended_content_sha256 IS NULL OR length(intended_content_sha256)=32),phase TEXT NOT NULL CHECK(phase IN('open','committed','aborted','protected')),disposition TEXT NOT NULL CHECK(disposition IN('normal','forward-only')),authorization_sha256 BLOB NOT NULL UNIQUE CHECK(length(authorization_sha256)=32),base_generation INTEGER NOT NULL CHECK(base_generation>=1),current_generation INTEGER NOT NULL CHECK(current_generation>=base_generation),maximum_steps INTEGER NOT NULL CHECK(maximum_steps=3),steps_consumed INTEGER NOT NULL CHECK(steps_consumed BETWEEN 1 AND 3),steps_released INTEGER NOT NULL CHECK(steps_released BETWEEN 0 AND 3),steps_abandoned INTEGER NOT NULL CHECK(steps_abandoned BETWEEN 0 AND 3),maximum_charge_bytes INTEGER NOT NULL CHECK(maximum_charge_bytes>=0),charge_consumed INTEGER NOT NULL CHECK(charge_consumed>=0),charge_released INTEGER NOT NULL CHECK(charge_released>=0),charge_abandoned INTEGER NOT NULL CHECK(charge_abandoned>=0),cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN(0,1)),finish_sha256 BLOB CHECK(finish_sha256 IS NULL OR length(finish_sha256)=32),UNIQUE(operation_uuid,authorization_sha256),FOREIGN KEY(scope,registry_ordinal,registry_name,expected_predecessor_state) REFERENCES transition_registry(scope,ordinal,name,allowed_from),FOREIGN KEY(operation_uuid,finish_sha256) REFERENCES transitions(operation_uuid,transition_sha256),UNIQUE(operation_uuid,scope,registry_ordinal,registry_name),CHECK((external_intent_kind='none' AND intended_evidence_sha256 IS NULL AND intended_root_kind IS NULL AND intended_relative_path IS NULL AND intended_path_sha256 IS NULL AND intended_byte_length IS NULL AND intended_content_sha256 IS NULL)OR(external_intent_kind='directory' AND intended_evidence_sha256 IS NULL AND intended_root_kind IS NOT NULL AND intended_relative_path IS NOT NULL AND intended_path_sha256 IS NOT NULL AND intended_byte_length IS NULL AND intended_content_sha256 IS NULL)OR(external_intent_kind='regular' AND intended_evidence_sha256 IS NULL AND intended_root_kind IS NOT NULL AND intended_relative_path IS NOT NULL AND intended_path_sha256 IS NOT NULL AND intended_byte_length IS NOT NULL AND intended_content_sha256 IS NOT NULL)OR(external_intent_kind='existing-evidence' AND intended_evidence_sha256 IS NOT NULL AND intended_root_kind IS NULL AND intended_relative_path IS NULL AND intended_path_sha256 IS NULL AND intended_byte_length IS NULL AND intended_content_sha256 IS NULL)),CHECK((scope='row' AND source_row_ordinal IS NOT NULL AND registry_ordinal<174)OR(scope='fixed' AND source_row_ordinal IS NULL AND registry_ordinal<320)),CHECK((phase='open' AND finish_sha256 IS NULL)OR(phase!='open' AND finish_sha256 IS NOT NULL)),CHECK(steps_consumed+steps_released+steps_abandoned<=3),CHECK(charge_consumed+charge_released+charge_abandoned<=maximum_charge_bytes)) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX idx_open_row_operation ON operations(source_row_ordinal) WHERE phase='open' AND scope='row';
CREATE UNIQUE INDEX idx_row_semantic_slot ON operations(source_row_ordinal,registry_ordinal) WHERE scope='row';
CREATE UNIQUE INDEX idx_open_fixed_operation ON operations(scope) WHERE phase='open' AND scope='fixed';
CREATE UNIQUE INDEX idx_fixed_semantic_slot ON operations(registry_ordinal) WHERE scope='fixed';
CREATE TABLE transitions(operation_uuid BLOB NOT NULL,step_ordinal INTEGER NOT NULL CHECK(step_ordinal BETWEEN 0 AND 2),kind TEXT NOT NULL CHECK(kind IN('begin','progress','finish')),scope TEXT NOT NULL CHECK(scope IN('row','fixed')),registry_ordinal INTEGER NOT NULL,registry_name TEXT NOT NULL,base_generation INTEGER NOT NULL CHECK(base_generation>=1),successor_generation INTEGER NOT NULL UNIQUE CHECK(successor_generation=base_generation+1),prior_transition_sha256 BLOB CHECK(prior_transition_sha256 IS NULL OR length(prior_transition_sha256)=32),authorization_sha256 BLOB NOT NULL,charged_bytes INTEGER NOT NULL CHECK(charged_bytes>=0),outcome TEXT NOT NULL CHECK(outcome IN('selected','committed','aborted','protected')),transition_sha256 BLOB NOT NULL UNIQUE CHECK(length(transition_sha256)=32),PRIMARY KEY(operation_uuid,step_ordinal),UNIQUE(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,prior_transition_sha256) REFERENCES transitions(operation_uuid,transition_sha256),FOREIGN KEY(operation_uuid,authorization_sha256) REFERENCES operations(operation_uuid,authorization_sha256),FOREIGN KEY(operation_uuid,scope,registry_ordinal,registry_name) REFERENCES operations(operation_uuid,scope,registry_ordinal,registry_name),FOREIGN KEY(scope,registry_ordinal) REFERENCES transition_registry(scope,ordinal),FOREIGN KEY(scope,registry_name) REFERENCES transition_registry(scope,name),CHECK((kind='begin' AND step_ordinal=0 AND prior_transition_sha256 IS NULL AND outcome='selected')OR(kind='progress' AND step_ordinal=1 AND prior_transition_sha256 IS NOT NULL AND outcome='selected')OR(kind='finish' AND step_ordinal=2 AND prior_transition_sha256 IS NOT NULL AND outcome IN('committed','aborted','protected')))) STRICT, WITHOUT ROWID;
CREATE TABLE verification_chunks(artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),verification_uuid BLOB NOT NULL CHECK(length(verification_uuid)=16),chunk_ordinal INTEGER NOT NULL CHECK(chunk_ordinal>=0),prior_chunk_sha256 BLOB CHECK(prior_chunk_sha256 IS NULL OR length(prior_chunk_sha256)=32),entry_first INTEGER NOT NULL CHECK(entry_first>=0),entry_count INTEGER NOT NULL CHECK(entry_count BETWEEN 1 AND 4096),bytes_completed INTEGER NOT NULL CHECK(bytes_completed>=0),h0 INTEGER NOT NULL CHECK(h0 BETWEEN 0 AND 4294967295),h1 INTEGER NOT NULL CHECK(h1 BETWEEN 0 AND 4294967295),h2 INTEGER NOT NULL CHECK(h2 BETWEEN 0 AND 4294967295),h3 INTEGER NOT NULL CHECK(h3 BETWEEN 0 AND 4294967295),h4 INTEGER NOT NULL CHECK(h4 BETWEEN 0 AND 4294967295),h5 INTEGER NOT NULL CHECK(h5 BETWEEN 0 AND 4294967295),h6 INTEGER NOT NULL CHECK(h6 BETWEEN 0 AND 4294967295),h7 INTEGER NOT NULL CHECK(h7 BETWEEN 0 AND 4294967295),total_byte_count INTEGER NOT NULL CHECK(total_byte_count BETWEEN 0 AND 2305843009213693951),tail BLOB NOT NULL CHECK(length(tail)<=63),manifest_sha256 BLOB NOT NULL CHECK(length(manifest_sha256)=32),chunk_sha256 BLOB NOT NULL UNIQUE CHECK(length(chunk_sha256)=32),PRIMARY KEY(artifact_sha256,verification_uuid,chunk_ordinal),UNIQUE(artifact_sha256,verification_uuid,chunk_sha256),FOREIGN KEY(artifact_sha256,verification_uuid,prior_chunk_sha256) REFERENCES verification_chunks(artifact_sha256,verification_uuid,chunk_sha256),CHECK((chunk_ordinal=0 AND prior_chunk_sha256 IS NULL)OR(chunk_ordinal>0 AND prior_chunk_sha256 IS NOT NULL)),CHECK(length(tail)=total_byte_count%64)) STRICT, WITHOUT ROWID;
CREATE TABLE custody_events(artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL CHECK(custody_generation>=1),state TEXT NOT NULL CHECK(state IN('verified','pending-adoption','active','replacement-pending','released','abandoned-verified','protected')),predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),root_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),receipt_evidence_sha256 BLOB NOT NULL REFERENCES evidence_objects(evidence_sha256),catalog_operation_uuid BLOB REFERENCES operations(operation_uuid),replacement_artifact_sha256 BLOB CHECK(replacement_artifact_sha256 IS NULL OR length(replacement_artifact_sha256)=32),drain_evidence_sha256 BLOB REFERENCES evidence_objects(evidence_sha256),reason TEXT CHECK(reason IS NULL OR reason IN('replaced','removed','cancelled','authority-corrupt','source-changed','evidence-changed','artifact-changed','custody-unavailable','custody-authorization-failed','storage-full','io-error','kernel-io-blocked','unsupported-filesystem','protocol-mismatch','retry-exhausted')),custody_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(custody_event_sha256)=32),PRIMARY KEY(artifact_sha256,custody_generation),UNIQUE(artifact_sha256,custody_event_sha256),UNIQUE(artifact_sha256,custody_generation,custody_event_sha256),FOREIGN KEY(artifact_sha256,predecessor_sha256) REFERENCES custody_events(artifact_sha256,custody_event_sha256),CHECK((custody_generation=1 AND predecessor_sha256 IS NULL)OR(custody_generation>1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='verified' AND catalog_operation_uuid IS NULL AND replacement_artifact_sha256 IS NULL AND drain_evidence_sha256 IS NULL AND reason IS NULL)OR(state='pending-adoption' AND catalog_operation_uuid IS NOT NULL AND replacement_artifact_sha256 IS NULL AND drain_evidence_sha256 IS NULL AND reason IS NULL)OR(state='active' AND catalog_operation_uuid IS NOT NULL AND replacement_artifact_sha256 IS NULL AND drain_evidence_sha256 IS NULL AND reason IS NULL)OR(state='replacement-pending' AND catalog_operation_uuid IS NOT NULL AND replacement_artifact_sha256 IS NOT NULL AND drain_evidence_sha256 IS NULL AND reason IS NULL)OR(state='released' AND catalog_operation_uuid IS NOT NULL AND drain_evidence_sha256 IS NOT NULL AND reason IN('replaced','removed'))OR(state='abandoned-verified' AND catalog_operation_uuid IS NULL AND replacement_artifact_sha256 IS NULL AND drain_evidence_sha256 IS NULL AND reason='cancelled')OR(state='protected' AND reason IS NOT NULL))) STRICT, WITHOUT ROWID;
CREATE TABLE artifact_current(artifact_sha256 BLOB PRIMARY KEY CHECK(length(artifact_sha256)=32),custody_generation INTEGER NOT NULL,custody_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(custody_event_sha256)=32),UNIQUE(artifact_sha256,custody_event_sha256),FOREIGN KEY(artifact_sha256,custody_generation,custody_event_sha256) REFERENCES custody_events(artifact_sha256,custody_generation,custody_event_sha256)) STRICT, WITHOUT ROWID;
CREATE TABLE catalog_bindings(binding_sha256 BLOB PRIMARY KEY CHECK(length(binding_sha256)=32),model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 512),release TEXT NOT NULL CHECK(length(release) BETWEEN 1 AND 128),artifact_sha256 BLOB NOT NULL CHECK(length(artifact_sha256)=32),source_row_ordinal INTEGER NOT NULL REFERENCES source_rows(source_row_ordinal),catalog_operation_uuid BLOB NOT NULL REFERENCES operations(operation_uuid),custody_event_sha256 BLOB NOT NULL,state TEXT NOT NULL CHECK(state IN('pending','active','released','protected')),created_generation INTEGER NOT NULL CHECK(created_generation>=1),protected_code TEXT CHECK(protected_code IS NULL OR protected_code IN('authority-corrupt','source-changed','evidence-changed','artifact-changed','custody-unavailable','custody-authorization-failed','storage-full','io-error','kernel-io-blocked','unsupported-filesystem','protocol-mismatch','retry-exhausted')),FOREIGN KEY(artifact_sha256,custody_event_sha256) REFERENCES custody_events(artifact_sha256,custody_event_sha256),CHECK((state='protected' AND protected_code IS NOT NULL)OR(state!='protected' AND protected_code IS NULL))) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX idx_one_pending_binding ON catalog_bindings((1)) WHERE state='pending';
CREATE UNIQUE INDEX idx_one_active_binding ON catalog_bindings((1)) WHERE state='active';
CREATE TABLE gc_meta(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL CHECK(generation>=1),minimum_round INTEGER NOT NULL CHECK(minimum_round>=0),maximum_round INTEGER NOT NULL CHECK(maximum_round>=minimum_round)) STRICT;
CREATE TABLE gc_candidates(artifact_sha256 BLOB PRIMARY KEY,state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round>=0),custody_event_sha256 BLOB NOT NULL,manifest_cursor INTEGER CHECK(manifest_cursor>=0),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),last_event_sha256 BLOB NOT NULL CHECK(length(last_event_sha256)=32),FOREIGN KEY(artifact_sha256,custody_event_sha256) REFERENCES artifact_current(artifact_sha256,custody_event_sha256),FOREIGN KEY(artifact_sha256,last_event_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256) DEFERRABLE INITIALLY DEFERRED,CHECK((state IN('checking','deleting','blocked-kernel-io','protected') AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL)OR(state IN('queued','done') AND manifest_cursor IS NULL AND delete_phase IS NULL AND helper_operation_uuid IS NULL))) STRICT, WITHOUT ROWID;
CREATE INDEX idx_gc_fair ON gc_candidates(eligible_round,artifact_sha256) WHERE state IN('queued','deleting');
CREATE TABLE gc_events(artifact_sha256 BLOB NOT NULL REFERENCES gc_candidates(artifact_sha256),event_generation INTEGER NOT NULL CHECK(event_generation>=1),predecessor_sha256 BLOB CHECK(predecessor_sha256 IS NULL OR length(predecessor_sha256)=32),custody_event_sha256 BLOB NOT NULL,state TEXT NOT NULL CHECK(state IN('queued','checking','deleting','blocked-kernel-io','done','protected')),eligible_round INTEGER NOT NULL CHECK(eligible_round>=0),manifest_cursor INTEGER CHECK(manifest_cursor>=0),delete_phase TEXT CHECK(delete_phase IS NULL OR delete_phase IN('flags','entries','root','fsync','complete')),helper_operation_uuid BLOB CHECK(helper_operation_uuid IS NULL OR length(helper_operation_uuid)=16),result_evidence_sha256 BLOB REFERENCES evidence_objects(evidence_sha256),gc_event_sha256 BLOB NOT NULL UNIQUE CHECK(length(gc_event_sha256)=32),PRIMARY KEY(artifact_sha256,event_generation),UNIQUE(artifact_sha256,gc_event_sha256),FOREIGN KEY(artifact_sha256,predecessor_sha256) REFERENCES gc_events(artifact_sha256,gc_event_sha256),FOREIGN KEY(artifact_sha256,custody_event_sha256) REFERENCES custody_events(artifact_sha256,custody_event_sha256),CHECK((event_generation=1 AND predecessor_sha256 IS NULL)OR(event_generation>1 AND predecessor_sha256 IS NOT NULL)),CHECK((state='queued' AND manifest_cursor IS NULL AND delete_phase IS NULL AND helper_operation_uuid IS NULL AND result_evidence_sha256 IS NULL)OR(state='checking' AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL AND result_evidence_sha256 IS NULL)OR(state IN('deleting','blocked-kernel-io','done','protected') AND manifest_cursor IS NOT NULL AND delete_phase IS NOT NULL AND helper_operation_uuid IS NOT NULL AND result_evidence_sha256 IS NOT NULL))) STRICT, WITHOUT ROWID;
```

## Appendix B — exact transition registry grammar

Each `emit` appends one registry line. For zero-based emitted ordinal `n`,
allowed state is assigned by section 5 and charge rule by its literal mapping.
Every line has `max-payload=0|max-row-changes=8`. Coarse A-state changes are separately
validated from the literal phase names in section 5.

```text
ROW, in this exact order:
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

FIXED, in this exact order:
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
```

The words `carrier-*` and `selector-*` inside retained recovery transition names
are historical event labels only. Their R19 action is inspect/migrate/reject
legacy evidence; they cannot create a carrier or selector object.
