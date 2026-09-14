# Reservation search progress — corrective addendum R11

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R10 plan gate. Its frozen inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r10.md` | `4b82dd1e0fd849f1472fff86e1f5cd8c5f9bd966946c91b21d8951ca5d17c407` |
| `test-spec-r16-reservation-r10-corrections.md` | `2f0397aed4699f90a2a75abf6acf63f0d088fdadd00399f969d57913fcdf6168` |
| `reviews/reservation-search-progress-r10-plan-sol.md` | `677ee0df66c9d0351c6ab6d9a3b315772686de20109045185bdba3f9edf569af` |

The independent R10 verdict was FAIL, 0 Critical / 6 High / 2 Medium / 0
Low. This addendum closes R10-PLAN-H1 through H6 and R10-PLAN-M1/M2. It is
paired with `test-spec-r17-reservation-r11-corrections.md`. Both exact
documents require a fresh independent zero-Critical/High/Medium plan gate
before implementation.

## 1. Governing relationship and reconciliation

R4 through R10 remain governing except for these exact replacements:

1. Sections 2 and 3 replace R10 sections 2.2, 3.2, and the route/lock language
   in sections 1, 2.2, 3.3, and 6.2. Bootstrap identity is deterministic;
   activation locking is bounded to selector CAS; and route classes are closed.
2. Sections 4 through 6 replace R10 sections 4 and 5. Every unbounded work
   collection is paged, validation is incremental and rooted, empty history is
   legal, and level-zero tree progress has an exact row cursor.
3. Section 7 replaces R10's selected activation-work accounting. Every selected
   object or adopted authority has an intent-before-materialization transition,
   an exact inventory entry, and a recoverable charge transition.
4. Section 8 replaces the undefined “materialization manifest” phrase in R10
   section 7.2 with closed inline allocation-admission v3 authority.
5. Section 9 replaces R16's same-invocation whole-history validation only where
   that would be unbounded. It preserves R10's complete file witnesses, two
   verification passes, path re-resolution, ctime coverage, and no-follow reads
   as incrementally selected work behind the format fence.

R10's exact source witness, root-relative path digest, A3–A6 suffixes,
4,096-byte directory transfer, abort actual-charge arithmetic, quota formula,
free-space floor, body/document limits, no authority deletion, prior-binary
fence, sole `genesis-v2`, target-local publication, primary-first departure,
same-owner stabilization, queued cancellation, rollback protection, and
content-addressed settlement/retirement lineage remain mandatory.

The current merged baseline is `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The already inspected
`914f7caf..1d2c930b` comparison added BYOM artifact-identity work but no commit
to the four reservation implementation files named by R10. R11 therefore
remains a plan for the cumulative uncommitted R4 reservation slice. Before
implementation, fetch origin and reopen the gate if any path under transaction
retention, evidence, reservation migration, storage, SPEC authority, or the
active external decision-path branch has changed. No merged BYOM digest cache
is transaction, activation, pricing, or settlement authority.

## 2. Recoverable pre-format bootstrap

### 2.1 Deterministic activation identity

There is no activation-directory scan and no “highest UUID” rule. With the
existing old format still authoritative, a caller under the journal lock
captures these canonical bytes and values:

```text
priorFormatSHA256
priorActiveIndexSHA256
migrationSourceSHA256
configuredRootPathSHA256
activationLockIdentityCanonicalBytes
```

It computes:

```text
bootstrapSeed = SHA256(
  "macprovider-retirement-v1-bootstrap-v1\0" ||
  priorFormatSHA256-32 || priorActiveIndexSHA256-32 ||
  migrationSourceSHA256-32 || configuredRootPathSHA256-32 ||
  u32be(lockIdentityByteCount) || activationLockIdentityCanonicalBytes)
```

The activation UUID is the first 16 seed bytes after setting RFC 9562 version
8 and variant bits, rendered as lowercase canonical UUID. This derivation is
the only pre-v4 selector. A digest collision that presents unequal frozen input
bytes at the same derived path is protected, not adopted or overwritten.

The direct paths remain R10 section 2.1. A retry derives one path from the
currently selected old tuple and directly validates it. Zero candidate objects
means create. One complete byte-equal candidate set means reuse. An incomplete
set means create only absent suffixes after validating every present prefix.
An unequal object at a required direct path is protected. Other activation UUID
directories are never enumerated, selected, deleted, or counted as authority.
They can be zero, one, or arbitrarily many without changing the outcome or the
number of reads. If old index/source/configured-root bytes change before v4,
the derivation changes and the new tuple uses its own path; the old candidate
remains unselected, nonauthoritative physical inventory.

### 2.2 Bootstrap publication and death recovery

The activation lock is created and identity-frozen under the journal lock. The
caller releases both locks before candidate object writes. Cooperative callers
derive the same UUID and may only exclusive-create or byte-equal reuse the same
generation-zero checkpoint, activation, storage inventory root, and selector
candidate. Each candidate write uses create, file fsync, and containing-
directory fsync. No candidate is authority yet.

The final bootstrap CAS acquires the activation flock nonblocking, then the
journal lock, and performs only bounded metadata and direct-file work. It
revalidates the exact old format/index/source/configured-root tuple, lock path
and identity, deterministic UUID, all bootstrap candidate bytes, exact storage
accounting, and available-capacity equation. It then publishes the canonical
stable selector, fsyncs its directory, publishes v4 format, and fsyncs
`.retention-v2`. The activation and journal locks are released before return.

Death before the v4 format rename leaves old authority selected. Recovery
re-derives and completes or reuses the same equal candidate suffix. Death after
format rename selects the one selector named by v4. A changed tuple derives a
new path; an unequal same-path candidate, changed lock identity, v4 naming a
non-derived UUID, or selected incomplete generation zero is protected. No
cleanup is required for progress, and no unselected object becomes authority.

## 3. Route classes, mutation fence, and lock scope

The implementation must expose one shared pre-mutation classifier used by the
CLI, Malibu bridge, transaction store, retention publisher, migration helper,
and any wrapper. It has exactly three route classes:

1. **Activation authority.** The new reservation-activation continuation and
   genesis functions may mutate only the R10 activation subtree, v4 format,
   inactive v2 projection slot, and v5 index. They require the exact derived v4
   selector, stable or pending selector state allowed by section 7, and the
   phase-specific CAS witnesses. No other route may claim this class.
2. **Ordinary catalog authority.** Allocation/reservation, class or left
   publication, departure, retirement, finalization, migration initialization
   or completion, catalog adoption, committed-result publication, cleanup that
   changes catalog authority, and their app/HTTP wrappers reject before their
   first authority write while v4 is pre-genesis. After genesis they validate
   the five R10 activation bindings from v5/v2 under their existing target-local
   journal CAS. They never acquire `activation.lock`.
3. **Operational/read-only.** Transaction record heartbeat and cancellation,
   status, result, catalog reads, and readiness observation may access only
   their existing operational paths. They cannot write format, projection,
   index, source, retirement, allocation, publication, or activation authority
   and never acquire `activation.lock`.

The implementation inventory in R17 must name the concrete production symbols,
including `ModelCatalogTransactionStore.reserve`, `update`, `reconcile`, and
`cleanup`; `ModelCatalogRetentionStore.publishReservationDeparture` and every
allocation/publication/retirement/finalization entry; reservation and binding
migration initialization/completion; evidence `commit`; and the CLI/app bridge
entrypoints that call them. Newly introduced activation/genesis symbols are the
only class-1 entries. Any discovered authority writer absent from that table
reopens the plan gate.

`activation.lock` is not a cross-call or bulk-work gate. It is held only for:

```text
bounded bootstrap final CAS
bounded stable-selector -> pending-intent CAS
bounded pending-intent -> stable-successor CAS
bounded ready -> genesis CAS
```

It is released before source reads, hashing, sorting, merge, tree construction,
verification, and candidate file writes. The journal lock is nested inside the
activation flock only for those bounded CAS sections. A helper can recover a
selected pending intent; ownership is the intent bytes, not a process or held
lock. Heartbeat, cancellation, status, and reads remain live throughout. After
genesis no production route opens the activation lock.

## 4. Closed selected schemas

R10 selector v1 becomes
`model_catalog_retirement_v1_activation_selector.v2` with exactly:

```text
schema, selectorRevision, activationUUID,
selectedActivationGeneration, selectedActivationSHA256,
selectedCheckpointSHA256, state, priorActiveIndexSHA256,
migrationSourceSHA256, formatFenceSHA256,
activationStorageRootSHA256, activationQuotaBytes,
activationChargedBytes, activationMaterializedBytes,
activationWorkReservedBytes, activationLifecycleReservedBytes,
activationSpentSlackBytes, activationHistoryAccumulatorSHA256,
activationHistoryLeafCount, pendingWriteIntent
```

`selectorRevision` starts at zero and increments by one for every selected
intent or stable successor. `pendingWriteIntent` is explicit null in a stable
selector. In an intent selector, the selected activation/checkpoint generation
and all terminal/progress fields remain the prior stable pair; only revision,
accounting, and the non-null intent change.

R10 activation v2 becomes v3 by adding exactly
`priorActivationStorageRootSHA256`,
`priorActivationHistoryAccumulatorSHA256`, and
`priorActivationHistoryLeafCount`. R10 checkpoint v3 becomes v4 by replacing
every flat collection field described in section 5 with its sequence-root
digest and by adding the same three **prior** storage/history bindings,
`currentNameScanRootSHA256`, `currentNameSortRootSHA256`,
`verificationPass`, `nextStorageVerificationOrdinal`, and
`storageVerificationTranscriptSHA256`, `storageVerificationTargetRootSHA256`,
`storageVerificationTargetEntryCount`, and
`storageVerificationTargetMaterializedBytes`. The candidate activation/checkpoint bind
the selected prior stable storage and history values. Only the successor
selector binds the candidate storage root and successor history accumulator.
This one-way edge avoids a digest cycle: the candidate storage root can
inventory the activation/checkpoint digests, while neither candidate contains
that new root's digest.

An activation-history accumulator is a binary Merkle mountain range over leaves:

```text
H("macprovider-activation-history-leaf-v1\0" || generation-u64be ||
  activationSHA256-32 || checkpointSHA256-32 || storageRootSHA256-32)
```

Its peak list has at most 53 digests under the inherited safe-integer ceiling.
The selector's accumulator digest is the domain-separated leaf count plus
ordered height/digest peaks. A stable successor appends the prior stable triple.
Restart
validates the current stable triple, the one immediate predecessor named by it,
and the accumulator append proof; it does not traverse generation zero. A
missing historical object is protected when directly audited or dereferenced,
and every such object remains charged and named by storage inventory. The
completed incremental storage-verification transcript at `ready` proves every
inventory entry selected before that phase; the final ready control objects are
validated directly during genesis.

## 5. Paged work collections and grandfathered scale

### 5.1 One persistent sequence format

Every collection that R10 represented as an unbounded array uses a persistent
content-addressed sequence tree. Direct paths are:

```text
.../activation/<uuid>/sequences/leaves/<sha256>.json
.../activation/<uuid>/sequences/nodes/<sha256>.json
.../activation/<uuid>/sequences/roots/<sha256>.json
```

Schema `model_catalog_activation_sequence_root.v1` contains exactly:

```text
schema, activationUUID, collectionKind, entrySchema,
leafCapacity, fanout, entryCount, height, firstOrdinal, lastOrdinal,
topPageSHA256, transcriptSHA256
```

`leafCapacity` is 16 and `fanout` is 256. Empty is uniquely count/height zero
with null ordinals/top page and the domain-separated empty transcript.
Nonempty ordinals are zero and `entryCount-1`. A leaf contains exactly
`schema`, activation UUID, collection kind, level zero, first/last ordinal,
entry count, entries, and transcript. Each closed kind-specific entry is at
most 3,072 canonical bytes. Leaves contain exactly 16 entries except the final
1–16. An internal node contains the same header and 1–256 child entries, each
exactly `firstOrdinal`, `lastOrdinal`, `entryCount`, and `pageSHA256`. All
interior nodes are full except the right frontier. Every page is at most 65,536
bytes and every root at most 16,384 bytes.

Append replaces only the right-edge path, retaining old pages. The old root and
new closed entry determine one byte-exact successor. A caller validates the
root plus at most one page per level for append or ordinal lookup; it never
loads the collection. Replace, skip, duplicate, overlap, alternate packing,
wrong collection kind, or a non-right-edge append is protected.

### 5.2 Replaced R10 collection fields

The name-capture root names one `name-block` sequence root. The row-work root
names separate `row-block` and `capture-run` sequence roots. The run-work root
names `input-run`, `completed-merge-group`, and `output-run` sequence roots.
The tree-build root names `current-level-input`, `completed-level`, and
`current-level-page` sequence roots. The verification-work root names
`row-verification-block` and `storage-verification-block` sequence roots. R10's
counts, boundaries, transcripts, phase bindings, ordering, and append-only
rules remain, but no root embeds the entries themselves.

Name discovery is also resumable. Closed
`model_catalog_retirement_v1_name_scan_root.v1` contains the frozen directory
identity/time witness, `nextDirectoryOffset`, `nextRecordSentinelSHA256`, raw
entry count, raw-name-block sequence root, EOF flag, and scan transcript. On
the supported macOS filesystem profile, production uses the public
`getattrlistbulk(2)` interface on a fresh no-follow FD, seeks to the selected
directory offset, and requires the first canonical returned attribute record to
match the selected sentinel before consuming at most 32 records. It stores the
next kernel directory offset plus a one-record lookahead sentinel,
then closes the FD. At EOF, raw name blocks are externally sorted by the same
rooted merge-group protocol into the final name-block sequence; duplicate or
invalid names fail. No selected cursor is derived from lexical rescanning,
`telldir`, directory enumeration order, or process memory.

This offset is accepted only when a mandatory startup qualification on the
actual containing volume proves `getattrlistbulk` close/reopen/seek
continuation over unchanged
directory identity across real child death at the first, middle, block, and EOF
offsets. The qualification also inserts/deletes/renames an entry and requires
directory witness/sentinel rejection. If the mounted filesystem/kernel does
not preserve the tested `getattrlistbulk` offset contract, activation is
blocked as unsupported before v4 selection; implementation may not rescan an
unbounded prefix, claim progress, hold an FD across calls, or weaken the
deadline. This is a named local/hardware qualification blocker, not a passed
compatibility claim.

Name and row blocks contain exactly 32 entries/rows except the final 1–32,
subject to the inherited document limit; every entry has a separately enforced
1,024-byte canonical maximum, so a full block remains bounded. A legacy/test
run block with 1–4,096 rows remains readable for recovery, but new R11 work
emits 32-row blocks. Run manifest v1 becomes
`model_catalog_retirement_v1_run_manifest.v2` and
replaces `inputRunSHA256s` and `rowBlockSHA256s` with their sequence-root
digests and counts. Its merge input may have at most 32 entries, but its output
row-block sequence has no total-count assumption. Every R10 work-root previous
link remains an audit link; current behavior is proved by the current sequence
roots and cursors, not a full predecessor traversal.

An in-progress merge group is itself closed
`model_catalog_retirement_v1_merge_group_work.v1` containing exactly `schema`,
activation UUID, merge pass/group and creation ordinals, the 1–32 input-run
digests, one cursor per input (`rowBlockOrdinal`, `rowOrdinal`, `exhausted`),
the current canonical head row or null for each input, output-row-block sequence
root, output row count/boundaries, duplicate-detection predecessor UUID, and
rolling transcript. One step opens at most one input descriptor at a time,
selects at most 32 merged rows, publishes one complete output block, and updates
all consumed cursors/heads. Only after every input is exhausted may a separate
successor publish the run manifest and completed-group entry. Thus a high-pass
32-input group never has to read or emit its full output in one invocation.

### 5.3 Maximum scale proof and bounded validation

The inherited safe-integer/source-charge ceiling remains 439,804,651,110 rows.
It implies exactly these upper bounds:

```text
name, row, or capture blocks = ceil(439,804,651,110 / 32) = 13,743,895,348
32-way merge passes = 7
merge output runs across all passes <= 443,351,466
64-row tree leaves = 6,871,947,674
256-way higher pages by level = 26,843,546; 104,858; 410; 2; 1
all tree pages <= 6,898,896,491
```

A sequence with 13,743,895,348 entries uses five page levels at leaf capacity
16/fanout 256; its root remains 16,384 bytes. The generic codec supports the
full safe `2^53-1` entry count in at most eight page levels, covering storage
inventory/control growth without assuming it equals row count. A lookup/append
therefore touches at most eight sequence pages. The inventory/history counters
use safe UInt64 while every canonical numeric field remains at or below
2^53−1. Exceeding a stated bound is protected before write.

Every activation invocation selects at most one intent containing sixteen or
fewer permanent entries, processes at most one 32-row source block, one
32-input merge step of at most 32 output rows, one complete 64-row leaf, one
256-child internal page, or one 32-row verification block, and touches at most
160 direct activation-authority objects including sequence paths. It holds at most four FDs simultaneously and
no FD, key, iterator, lock, or cursor across calls. Each invocation retains the
eight-second deadline without renewal.

Restart validates direct v4/selector/current activation/current checkpoint/
current storage root, one immediate history append, and only the sequence paths
needed by that invocation. Phase completion is accepted only from counts,
boundaries, sequence transcripts, and completed incremental verification roots.
It never walks every predecessor or every collection during one call. Missing,
corrupt, or substituted content on a demanded path is protected. Full semantic
validation occurs as selected, restartable verification work and must complete
before `ready`; genesis revalidates its terminal roots and the final ready
control suffix, not the entire history in one call.

## 6. Empty history and exact tree cursor

### 6.1 Empty terminal authority

`rowCaptureRootSHA256` is defined to equal the final selected row-work-root
digest for both empty and nonempty histories. It is never an alias for a
sequence root. A zero-name capture publishes canonical empty row-block and
capture-run sequences and a row-work root with row count zero, null first/last
UUID, and zero cursors.

The canonical empty `run_manifest.v2` has `runKind: "empty"`, merge pass,
run ordinal, and creation ordinal zero; canonical empty input-run and row-block
sequence roots; both counts and row count zero; null first/last UUID; and the
domain-separated zero-row `rowsSHA256`. It is the one legal
`sortedRunSHA256`. `merging` selects that run without a group, then a separate
successor enters `building`. Building selects the inherited canonical empty v1
retirement root without a page. Verification selects canonical empty row and
storage verification sequences; storage verification still covers activation
inventory. The state then reaches `ready` normally. There is no phase skip and
no alternate empty page/run encoding.

### 6.2 Level-zero cursor

Tree-build root v1 becomes v2. At level zero it contains exactly these cursor
fields and the R11 sequence roots:

```text
nextInputBlockOrdinal, nextInputRowOrdinal, nextGlobalRowOrdinal,
currentLevelInputSequenceRootSHA256, currentLevelPageSequenceRootSHA256,
completedLevelSequenceRootSHA256, nextTreeObjectOrdinal
```

Above level zero, the first two fields are null and
`nextGlobalRowOrdinal` is replaced by `nextInputPageOrdinal`. No partial leaf is
selected. One invocation reads from the exact block/row cursor across as many
consecutive row blocks as needed to form one complete 64-row leaf, or the final
1–63-row leaf at EOF. Its page entry binds start/end block and row positions,
first/last global row ordinals, row count, boundaries, page ordinal, and digest.
The successor cursor is the first unconsumed position. Crash before selector
success reuses the unselected byte-equal page; crash after success resumes only
the suffix. A cursor into the middle of a 4,096-row block and a leaf spanning
two blocks are therefore unambiguous.

Above level zero, one invocation consumes one consecutive group of at most 256
child entries and advances `nextInputPageOrdinal`. Final short pages and the
inherited noncollapsed one-child rule remain. Page, completed-level, root-
envelope, and phase transitions each receive separate selected successors.

## 7. Selected activation storage and exact accounting

### 7.1 Inventory batches

Schema `model_catalog_activation_storage_root.v1` is a content-addressed batch
root at `.../activation/<uuid>/storage/<sha256>.json`. It contains exactly:

```text
schema, activationUUID, inventoryGeneration, previousStorageRootSHA256,
batchEntryCount, batchEntries, cumulativeEntryCount,
cumulativeDirectoryCount, cumulativeMaterializedBytes,
selfCanonicalLength, selfChargeBytes,
historyLeafCount, historyMMRPeaks, historyTranscriptSHA256
```

There are 0–16 entries. A file entry contains exactly `relativePath`,
`objectKind`, `storageClass`, `sha256`, `canonicalLength`, `chargeBytes`,
`deviceID`, `fileID`, `mode`, `ownerUID`, `groupGID`, and `linkCount`. A
directory entry has null digest/length and charge 4,096 with the same identity.
`storageClass` is `activation-created`, `adopted-v1-authority`, or
`fixed-control`. Activation-created and adopted files have a non-null digest
and actual canonical length. A fixed mutable direct control file has null
digest, its governed maximum canonical length, and the fixed `F(maximum)`
charge; its current bytes are instead bound by the selector/format CAS. All
paths are canonical root-relative paths and unique across the chain. Other
file charge is exact `F(canonicalLength)`.

`selfCanonicalLength` equals the final canonical byte length and
`selfChargeBytes = F(selfCanonicalLength)`. Encoding iterates the two numeric
fields from zero until bytes/charge reach the unique fixed point; failure to
converge in four iterations is invalid. Cumulative materialized bytes add all
batch charges plus self charge. The MMR appends the previous root digest and
has at most 53 peaks. Thus the current root commits prior batches without a
flat array, while the current batch and transition remain bounded.

The stable selector's storage root is authoritative. Predecessor roots and all
named objects remain retained and charged. Unselected temporaries may be
removed only after proving no stable or pending selector names them. Selected
authority, including prior progress generations, is never deleted.

### 7.2 Pending write intent and equations

`pendingWriteIntent` contains exactly:

```text
intentUUID, intentKind, candidateActivationGeneration,
candidateActivationSHA256, candidateCheckpointSHA256,
candidateStorageRootSHA256, entries, plannedChargeBytes,
lifecycleReserveDeltaBytes, expectedPriorSelectorSHA256,
expectedPriorStorageRootSHA256, wpeakBytes
```

`intentUUID` is deterministically derived from the prior selector digest and
canonical intent body. `intentKind` is `create`, `adopt`, or `genesis-control`.
There are 1–16 entries, each byte-equal to the candidate storage-root batch.
Create entries bind exact path/digest/length/charge before create. Adopt entries
bind a preexisting R10 full witness and exact charge and permit no write.
Genesis-control covers the final ready activation/checkpoint/storage suffix.
`plannedChargeBytes` equals the sum of all entry charges plus the candidate
storage root's exact self charge; the root is not duplicated as its own entry.

The stable pre-genesis equation is:

```text
activationMaterializedBytes + activationWorkReservedBytes +
activationLifecycleReservedBytes + activationSpentSlackBytes
  == activationChargedBytes
activationChargedBytes <= activationQuotaBytes
```

Stable selectors have zero work reserve. The stable-to-intent CAS, before any
named create, performs exactly:

```text
activationChargedBytes += plannedChargeBytes + lifecycleReserveDeltaBytes
activationWorkReservedBytes += plannedChargeBytes
activationLifecycleReservedBytes += lifecycleReserveDeltaBytes
materialized and spentSlack unchanged
```

The quota becomes
`roundUp4096(max(1 GiB, activationChargedBytes + finalizationReserve))`.
Available capacity must satisfy R10's exact floor using candidate `Wpeak` and
post-CAS reserved remainder. After intent selection, only its absent/equal
candidate suffix may be created or adopted. The intent-to-stable CAS reopens
and validates every entry and performs exactly:

```text
activationMaterializedBytes += plannedChargeBytes
activationWorkReservedBytes -= plannedChargeBytes
charged, lifecycle reserve, and spentSlack unchanged
```

The candidate storage root includes the new activation/checkpoint and every
permanent work/root/page/directory/adopted object plus its own exact charge.
The fixed direct selector extent, activation lock, format, and already existing
mutable control files are inventoried once in bootstrap. Atomic selector
temporaries are Wpeak only. No selected byte is outside the counters.

Thrown error, cancellation, timeout, ENOSPC, EDQUOT, or death after intent
leaves the exact reserve and resumes the same suffix. Repeating either CAS is
idempotent. An unequal object, counter delta, inventory root, or selector base
is protected with no refund or deletion. `ready` requires null intent, zero
work reserve, completed storage verification, and exact physical/logical
inventory. Genesis copies materialized/lifecycle-reserved/slack/charged/quota
into v2 capacity and adds no discretionary admission. Later projection
accounting continues under R10/R7.

## 8. Closed allocation body authority

Allocation admission v2 becomes
`model_catalog_allocation_admission.v3` with exactly:

```text
schema, reservationID, operationUUID, proposedTransactionUUID,
allocationGeneration, createdAt, tupleSHA256, initialPrimarySHA256,
originSHA256, classSHA256, genesisLineageSHA256, successChargeBytes,
materializedChargeBytes, materializationPhase,
materializationDirectoryRelativePath, materializationDirectoryPathSHA256,
materializationDirectoryChargeBytes, materializationDirectoryIdentity,
primaryRelativePath, primaryCanonicalLength, primaryChargeBytes,
originRelativePath, originCanonicalLength, originChargeBytes,
classRelativePath, classCanonicalLength, classChargeBytes,
lineageRelativePath, lineageCanonicalLength, lineageChargeBytes,
state, abortReceiptSHA256, abortSuccessorRootSHA256, abortReason
```

The directory/body path, digest, length, and charge fields are non-null while
the admission is selected in A1–A7. `materializationDirectoryIdentity` retains
R10 nullability: null through `directory_intent` and on the A1/A2 abort branch,
then non-null only after `directory_durable`. A6 success and A8 abort remove the
admission, so no terminal standalone v3 encoding exists. The directory path is
the exact R10 section 7.1 string and charge 4,096. Body paths are canonical descendants of
that directory with the existing fixed filenames; they cannot be absolute,
contain traversal, or name another UUID. `initialPrimarySHA256`, `originSHA256`,
`classSHA256`, and `genesisLineageSHA256` are the body digests for their
corresponding path/length/charge triples. Each length equals the canonical body
byte count and each charge equals `F(length)`. Their sum plus fixed tranche/
slack fields equals the frozen 581,632 admission; no new file or dependency is
added.

Each A3/A5 intent selects the already present v3 bindings for its one next
directory/body. Recovery derives path, expected bytes, and exact transfer only
from selected admission v3. Caller arguments, directory enumeration, mutable
catalog state, and a nonexistent external manifest are never authority. The
intent/durable order, no-follow identity checks, A3→A4 directory transfer,
ordered primary/origin/class/lineage writes, A6 slack, and A7/A8 rules remain
exactly R10.

## 9. Incremental verification, compatibility, and acceptance

Name capture and row capture retain every R10 file witness and before/read/
after/path validation. The v4 fence prevents every cooperative catalog writer
other than the activation engine from changing source authority. Verification
has pass `rows-1`, `rows-2`, then `storage`; each pass is a sequence of at most
32-row or 64-inventory-entry blocks with exact ordinal, rolling transcript,
namespace, source-witness, and sequence-root bindings. Pass 2 directly reopens
every source by name and repeats descriptor-before/read/descriptor-after/path-
after. A changed byte, identity field, ctime, namespace, name, inode, or path
fails before selecting that block. Completion requires both row transcripts
equal the selected row-capture transcript. Entry to `storage` targets the
current stable storage root, entry count, materialized total, and MMR. Each
storage generation verifies up to 64 target entries and advances the target to
the stable prior storage root bound by its candidate checkpoint. Its own
selected successor adds no more than 16 entries, so the live unverified tail
decreases by at least 48. When the live tail is at most 16 entries, a
`storage-close` intent freezes those exact tail entries plus its candidate
control suffix; the final bounded CAS directly validates at most 32 entries and
selects `ready`. The storage transcript must then equal the selected inventory
count/MMR/materialized total at that CAS. There is no self-referential
requirement to inventory a verification statement inside the statement it
verifies, and no unverified selected predecessor is left behind `ready`.

After pass 2, genesis under the bounded activation/journal CAS re-resolves the
configured path and current namespace, validates the ready roots and final
control suffix, and writes the sole v2/v5 genesis. It does not reread all bodies
in one call. Out-of-band tampering remains protected when a demanded direct
path differs from its selected content/witness; the product does not treat an
unverified path as current authority. This preserves the R9-H3 witness and
race boundary while making grandfathered histories resumable.

Implementation is one unshippable compatibility slice: all v4/v2/v3/v4/new
page and admission codecs, readers, writers, route classifiers, and migrations
land together. The actual prior binary must reject v4 before mutation. No
partial reader, fallback rewrite, v1/v2 admission ambiguity, or deletion-based
rollback is allowed. Rollback before v4 selection continues on old authority;
after v4 selection the only supported recovery is forward completion. After
genesis old selected authority remains protected historical evidence.

Emit selector revision/state, deterministic activation UUID, current phase and
sequence roots, bounded read/page/FD counters, pending intent kind/delta,
storage materialized/reserved/lifecycle/slack/quota counters, verification pass
and ordinal, and protected mismatch class. Never log bodies, private source
bytes, or secrets.

Stop on nondeterministic orphan adoption; activation-directory scan; missing
zero-row path; a cursor that cannot identify an in-block row; a flat unbounded
array; whole-history validation in one invocation; object creation before a
selected intent; uncharged selected control/work bytes; body intent without v3
path/length/charge; activation flock across bulk work or after genesis;
ordinary catalog mutation before genesis; activation-engine rejection by its
own fence; weakened ctime/path/source validation; raised deadline, FD, body,
page, document, or quota limits; changed abort arithmetic; stale pre-`1d2c930b`
assumption; authority deletion; or skipped, interrupted, timed-out, or
zero-selected evidence reported as passing. Physical MLX, signed feed/release,
deployment, enforcement, settlement, and economic activation remain outside
this corrective proposal.
