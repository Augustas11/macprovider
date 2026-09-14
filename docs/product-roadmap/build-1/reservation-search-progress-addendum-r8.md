# Reservation search progress — corrective addendum R8

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R7 plan gate. Its frozen inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r7.md` | `fa1a9178b2d2779a79285ae4952867a4b78e8c6a64a56d55191472f83ff24293` |
| `test-spec-r13-reservation-r7-corrections.md` | `cdbb44bf913fa53c23c50fc10823996cc99422810a6b04258d3911a37ecdd225` |
| `reviews/reservation-search-progress-r7-plan-sol.md` | `8f1db48647e8b9ad497e964866a9e765e19f729181f699e5b8111dedbda8381f` |

The independent R7 verdict was FAIL, 0 Critical / 4 High / 1 Medium. This
addendum closes R7-PLAN-H1 through H4 and R7-PLAN-M1. It is paired with
`test-spec-r14-reservation-r8-corrections.md`. Both exact documents require a
fresh independent zero-Critical/High/Medium plan gate before implementation.

## 1. Governing relationship and retained corrections

R4, R5, R6, and R7 remain governing except for these exact replacements:

1. Sections 2 and 3 replace R7 sections 2.1–2.2 and 3 where they classify a
   newly selected ordinary retirement successor root as a full-validation
   activation event.
2. Section 4 replaces R7 section 5's allocation refund branch and adds rooted
   terminal abort evidence. R7's direct all-absent removal is forbidden.
3. Section 5 replaces R7 section 7 with closed page, root, checkpoint, stable
   enumeration, bulk-build, and incremental-update rules.
4. Section 6 replaces R7's retirement and lifecycle charge arithmetic in
   section 6. R7's 352,256-byte post-complete lifecycle and 466,944-byte source
   closure are no longer valid.
5. Section 7 replaces R7's ambiguous simultaneous maximum-admission shape.

Every other R4–R7 correction remains mandatory: one authenticated selected
projection; exact target and non-target preservation; global allocating-intent
gate and three-way allocation-generation equality; exact origin comparison;
primary-first departure; same-owner pending-publication stabilization;
permanent left/rollback rejection; queued-cancel busy; frozen finalizing
membership; content-addressed install and settled lineage; closed decoders and
direct paths; sequential actual-prior-binary owner fence; byte-equivalent
pre-capture identity and strict post-capture identity; no global publication
gate; no wrapper bypass; no authority deletion for space; and real-death
recovery.

All inherited object limits remain. Retirement-v2 remains at most 65,536 bytes,
the root envelope remains at most 16,384 bytes, and R8 tree pages are at most
65,536 bytes. Active index, state projection, source, progress, completed
projection, and all inherited 1 MiB inputs remain at 1,048,576 bytes. No input
is narrowed and no dependency is added.

The unchanged original deadline is eight seconds per ordinary operation and
per activation or phase-transition slice. No nested helper creates a new
deadline. Ordinary reservation work remains at no more than ten direct reads,
ten closed decodes, four simultaneously live reservation descriptors, and
3,383,296 reservation-authority body bytes. The soft FD limit is never raised.

## 2. One-time global activation versus ordinary root replacement

There is exactly one retirement-root activation event: `genesis-v2`. It occurs
after the actual-prior-binary mutation fence is durable and before any R8 writer
is enabled. Genesis constructs and fully validates the complete v1 tree and the
canonical empty v2 and allocation-abort roots, inventories their retained
bytes, and selects all three root envelopes with the first state-projection-v2
and active-index-v5 pair. A crash before that index selection leaves no R8 root
authoritative. A crash after selection has exactly the selected roots.

`validateReservationTransitionGraph` performs a global walk only for:

- `genesis-v2`, including the one-time retirement-root activation;
- classifying-to-finalizing; and
- finalizing-to-complete.

The two later phase transitions validate all selected retirement and abort-tree
pages plus every applicable named body against one unchanged captured aggregate
root. Their authenticated validation progress may span bounded slices. They do
not create a second root-activation category.

Every post-genesis retirement root is an **ordinary inductive successor**, not
an activation. `validateReservationOperation` starts from one already selected,
digest-valid projection. For retirement of target `T` it:

1. validates `T`'s selected row, terminal primary, origin, class, left, settled
   lineage, lifecycle tranche, and exact v2 certificate bytes;
2. validates a membership proof for `T` in `rowsRootSHA256` and a
   nonmembership proof for `T` in the selected v2 retirement tree;
3. opens and validates only the selected v2 search path defined in section 5;
4. derives the unique canonical successor pages and root envelope, preserving
   every untouched child digest and increasing the retirement count by one;
5. materializes only the certificate, changed path pages, and successor root;
   and
6. selects that root and consumes the target retirement tranche in the target
   CAS, followed by the distinct target-membership removal CAS already required
   by R7.

The target CAS revalidates the predecessor index/projection digest, generation,
aggregate root, target row and body descriptors, old root envelope, old path
digests, exact new-object digests, capacity amounts, and unchanged non-target
rows. It rejects a missing prior row, pre-existing target key, omitted or
changed sibling, count/range mismatch, alternate split, extra page, generation
skip, or any successor other than the section 5 algorithm. It never walks an
unrelated page or retirement body and never performs a full-tree validation.

The selected projection embeds the complete canonical fields of each root
envelope and its SHA-256. The archival envelope file must exist at its direct
content-addressed path before selection, but ordinary validation needs no
separate read of the already embedded old envelope. Detached pages or envelopes
cannot update a selected root.

## 3. Inductive selected-state rule

R7's inductive CAS theorem remains, with these exact additions. The projection
capacity object also binds `grossChargedBytes`, `refundedBytes`, and the selected
allocation-abort root. The aggregate root covers those fields and all three
embedded root envelopes. Every successor increments projection generation once
and applies exactly one row from this table:

| Transition | Permitted selected delta |
|---|---|
| retirement archive | One target tranche state/materialized count, one v2 successor root, no membership removal |
| retirement removal | Remove only the already archived target row; preserve the selected v2 root and consumed charge |
| allocation abort intent | Change the matching admission to `aborting`; if its allocating row exists, change only that row to `allocation_aborting` |
| allocation abort finalization | Select the exact abort-tree successor, remove the matching admission and optional allocating row, add one refund, and retain the rooted terminal abort receipt |

These deltas are mutually exclusive. In particular, root selection and target
membership removal are separate generations, and abort intent and abort
finalization are separate generations. Every other R7 transition remains
unchanged.

## 4. Closed capacity-reserve and allocation-abort state machine

The capacity arithmetic uses safe integers in `0...9,007,199,254,740,991` and
must satisfy at every selected projection:

```text
grossChargedBytes - refundedBytes == chargedBytes
materializedBytes + reservedRemainingBytes + spentSlackBytes == chargedBytes
chargedBytes <= quotaBytes
```

`grossChargedBytes` and `refundedBytes` are monotonic. `chargedBytes` can
decrease only in the abort-finalization CAS below. No retirement, publication,
successful allocation, cleanup, compaction, or operator action subtracts it.

An allocation admission has the closed schema
`model_catalog_allocation_admission.v2` with exactly: `schema`,
`reservationID`, `operationUUID`, `proposedTransactionUUID`,
`allocationGeneration`, `createdAt`, `tupleSHA256`, `initialPrimarySHA256`, `originSHA256`,
`classSHA256`, `genesisLineageSHA256`, `successChargeBytes`,
`materializedChargeBytes`, `state`, `abortReceiptSHA256`,
`abortSuccessorRootSHA256`, and `abortReason`. All fields are present. The last
three are `null` outside `aborting`. State is exactly `reserved`,
`materializing`, or `aborting`; terminal success is represented by the active
row and terminal abort by the rooted abort receipt, never by deleting
unexplained state. `createdAt` uses the inherited strict timestamp grammar and
never changes. `abortReason`, when non-null, is exactly
`allocation_recovery_all_absent`.

The only legal states and transitions are:

| State | Selected row/body facts | Legal next transition |
|---|---|---|
| A0 absent | No admission, allocating row, allocation body, or terminal abort key for this operation | Reserve A1 after exact search absence and full capacity admission |
| A1 reserved | Admission exists; row and all allocation bodies/directories are absent | Materialize A2, or publish abort intent A4 |
| A2 materializing-empty | Admission and exact `allocating` row exist; all allocation bodies and their per-UUID directories are absent | Create initial primary, or publish abort intent A4 |
| A3 materializing-prefix | Admission and row exist; a nonempty valid prefix of primary → origin → class → genesis-lineage exists | Complete only that exact ordered suffix |
| A4 aborting | Admission binds reason, receipt digest, and exact abort-tree successor; optional row is `allocation_aborting`; every allocation body/directory remains absent | Materialize only abort receipt/pages/root, then finalize A6 |
| A5 active | Exact complete body sequence and active row exist; success charge is consumed | Ordinary active authority; no allocation refund |
| A6 aborted | No admission or allocating row; selected abort tree contains the exact terminal receipt | Return the same terminal aborted result; no new UUID, charge, refund, or write |

The A1→A2 CAS creates the exact allocating row. After that CAS, an all-absent
observation is only an **eligibility predicate** for A2→A4. It never directly
removes the row, admission, or charge. A1 abort uses the same A4/A6 protocol.
Only the admission owner with byte-identical frozen digests may publish A4.
Wrong owner, reason, digest, generation, row phase, or successor root is
protected. One byte or one directory from the allocation sequence makes A4
illegal and forces A3 completion or a protected result.

A4 first selects the abort intent while charge is unchanged. It then
exclusive-creates/fsyncs the canonical
`model_catalog_allocation_abort.v1` receipt at:

```text
.reservation-migration/allocation-aborts/receipts/<operationUUID>/<sha256>.json
```

The receipt is at most 16,384 bytes and contains exactly `schema`,
`operationUUID`, `reservationID`, `proposedTransactionUUID`,
`allocationGeneration`, `createdAt`, `tupleSHA256`, `initialPrimarySHA256`,
`originSHA256`, `classSHA256`, `genesisLineageSHA256`, `reason`,
`grossChargeBytes`, `retainedAbortChargeBytes`, `refundBytes`,
and `predecessorProjectionSHA256`. Every identity, digest, timestamp, and reason
is copied from the already frozen admission. It is inserted into the append-only
allocation-abort tree from section 5.

The A4→A6 CAS verifies the receipt and every new page/root byte, selects the
successor abort root, removes only the exact admission and optional
`allocation_aborting` row, increments `refundedBytes` by
`successChargeBytes - retainedAbortChargeBytes`, and decrements `chargedBytes`
by the same amount. `retainedAbortChargeBytes` is the actual `F(length)` charge
of the receipt, new abort pages, root envelope, and receipt directory. Those
objects remain in `materializedBytes`. The difference is refunded, not slack.
Crash recovery is therefore exact:

- before A4 selection, A1/A2 remains and no refund occurred;
- after A4 selection but before any abort object, resume the named objects;
- after any abort object but before A6, reuse only byte-identical named objects
  and resume the same root;
- after A6, tree lookup returns the same terminal result and performs no
  mutation; and
- after any A3 body byte, abort/refund is permanently illegal.

The global allocation gate treats A1–A4 as unresolved and A5/A6 as terminal.
It never searches past A1–A4 or treats A2's body absence as candidate absence.

## 5. Deterministic retirement and abort trees

### 5.1 Canonical encoding and paths

All tree documents use canonical UTF-8 JSON: no BOM or insignificant
whitespace; object keys sorted by UTF-8 byte order; arrays retained in specified
order; integers in shortest unsigned decimal; lowercase 36-character UUIDs;
lowercase 64-character SHA-256; and explicit `null` for nullable fields. Unknown,
duplicate, omitted, noncanonical, unsafe-integer, or trailing bytes are invalid.
The content address is lowercase `SHA256(canonicalBytes)`.

Pages use these direct paths and a 65,536-byte canonical limit:

```text
.reservation-migration/retirement/v1/leaves/<sha256>.json
.reservation-migration/retirement/v1/nodes/<sha256>.json
.reservation-migration/retirement/v2/leaves/<sha256>.json
.reservation-migration/retirement/v2/nodes/<sha256>.json
.reservation-migration/allocation-aborts/leaves/<sha256>.json
.reservation-migration/allocation-aborts/nodes/<sha256>.json
```

Root envelopes use the corresponding `roots/<sha256>.json` directory and a
16,384-byte limit. Page schema is
`model_catalog_retirement_tree_page.v1`; root schema is
`model_catalog_retirement_tree_root.v1`. `treeKind` is exactly `retirement-v1`,
`retirement-v2`, or `allocation-abort-v1`.

A leaf contains exactly `schema`, `treeKind`, `level: 0`, and `rows`. A v1 row
contains exactly `uuid`, `certificateSHA256`, and `originSHA256`. A v2 row
contains exactly `uuid`, `certificateSHA256`, `originSHA256`, `classSHA256`,
`leftSHA256`, `lineageSHA256`, `lifecycleReservationID`, and
`capacityRecordSHA256`. An abort row contains exactly `operationUUID`,
`proposedTransactionUUID`, `receiptSHA256`, `refundBytes`, and
`retainedAbortChargeBytes`.

Rows are ordered by the parsed 16 UUID bytes, not locale text. Every leaf has
1–64 rows. An internal page contains exactly `schema`, `treeKind`, `level`, and
`children`; `level` is 1 or greater. Each child contains exactly `firstUUID`,
`lastUUID`, `rowCount`, and `childSHA256`. Children are ordered by first UUID,
have disjoint strictly increasing inclusive ranges, and number 1–256. All child
pages have `level - 1`; the parent count and boundary UUIDs equal the exact sum
and extremes of its children. The specified maximum v1 leaf is below 14 KiB,
maximum v2 leaf below 40 KiB, and maximum internal page below 55 KiB; the fixed
65,536-byte limit leaves no data-dependent capacity ambiguity.

A root envelope contains exactly `schema`, `treeKind`, `encodingVersion: 1`,
`leafCapacity: 64`, `fanout: 256`, `height`, `rowCount`, `firstUUID`,
`lastUUID`, and `topPageSHA256`. Empty is uniquely `height: 0`, `rowCount: 0`,
and three `null` boundary/page fields. Nonempty height is top-page level plus
one; all three boundary/page fields are non-null. No padding, alternate empty
page, short interior packing rule, or equivalent re-encoding is legal.

### 5.2 Deterministic v1 bulk build

After producing one strict UUID-sorted v1 row stream, partition rows from the
start into consecutive groups of exactly 64 except the final group of 1–64.
Encode one leaf per group. Partition the resulting child entries from the start
into consecutive groups of exactly 256 except the final group of 1–256, encode
the next level, and repeat until one top page remains. A one-child final node is
retained when produced; levels are never collapsed or repacked. Zero rows use
the canonical empty root. These rules alone determine byte-identical pages,
height, root, and paths for any v1 input.

The sorted stream is produced without an unbounded memory assumption. A live
activation session collects consecutive groups of at most 4,096 validated rows,
sorts each group by UUID, and writes canonical content-addressed work blocks.
It then performs deterministic stable 32-way merge passes: logical runs are
ordered by `(firstUUID, creationOrdinal)`, consecutive groups of at most 32 are
merged, duplicate UUIDs fail, and output is split every 4,096 rows. Passes
repeat until one run remains. The final run feeds the fixed 64/256 tree builder.
Work blocks are unselected temporaries, are included in activation `Wpeak`, and
may be removed only after genesis selects the root or the session is discarded.

### 5.3 Implementable stable-directory protocol and checkpoints

There is no claimed durable macOS continuation token. Before enumeration, the
activation process holds the journal lock, validates the mandatory-format
fence, opens the transaction root with
`O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`, and holds an exclusive `flock` on:

```text
.reservation-migration/retirement/v1/activation.lock
```

Every R8 mutation route acquires this protocol lock before any direct-root
mutation; the already validated prior-binary fence makes older supported routes
reject before mutation. The activation process retains the same directory FD,
`DIR *`, and lock FD until genesis selection. At session start and before and
after every slice it calls `fstat` on that directory FD and requires exact
equality of `st_dev`, `st_ino`, `st_gen`, `st_mode`, `st_uid`, `st_gid`,
`st_nlink`, `st_size`, `st_mtimespec`, and `st_ctimespec`. Entries are opened
relative to that FD with no-follow semantics and their identity/bytes are
validated before and after read. Any tuple change, invalid entry, read race, or
lost lock discards the session before selection.

Enumeration and a second verification pass use the same live `DIR *`. The first
pass builds the sorted stream. After its real EOF, `rewinddir` starts the second
pass; every validated row must have exact membership in the built tree, no
unmanifested `.retired` entry may exist, and the second count and transcript
must equal the first. Selection occurs under the still-held lock and unchanged
directory witness. Insert, delete, rename, repeated entry, skipped entry, false
EOF in either pass, changed body, or changed witness prevents selection.

Checkpoints use exactly:

```text
.reservation-migration/retirement/v1/checkpoints/active.json
.reservation-migration/retirement/v1/checkpoints/slot-0.json
.reservation-migration/retirement/v1/checkpoints/slot-1.json
```

The selector schema `model_catalog_retirement_v1_checkpoint_selector.v1`
contains exactly `schema`, `activationUUID`, `selectedSlot`,
`checkpointGeneration`, `checkpointSHA256`, `priorActiveIndexSHA256`,
`migrationSourceSHA256`, and `sessionKeySHA256`. A checkpoint slot, bounded by
1,048,576 bytes, contains exactly `schema`, `activationUUID`,
`checkpointGeneration`, `previousCheckpointSHA256`,
`priorActiveIndexSHA256`, `migrationSourceSHA256`, `formatFenceSHA256`,
`directoryWitness`, `phase`, `pass`, `entryOrdinal`, `lastRawName`,
`rowCount`, `transcriptSHA256`, `workRootSHA256`, `mergePass`, `mergeGroup`,
`builderFrontier`, and `macSHA256`. Phase is `collect`, `merge`, `build`, or
`verify`; all inapplicable fields are explicit `null`.

`directoryWitness` contains exactly `deviceID`, `fileID`, `generation`, `mode`,
`ownerUID`, `groupGID`, `linkCount`, `size`, `modifySeconds`,
`modifyNanoseconds`, `changeSeconds`, and `changeNanoseconds`, copied as safe
unsigned integers from the named `fstat` fields. `pass` is `first`, `second`, or
`null`; `entryOrdinal`, `rowCount`, `mergePass`, and `mergeGroup` are safe
unsigned integers or `null`; `lastRawName` is the last consumed filename or
`null`; and every SHA field is a lowercase digest or `null` only where its phase
does not yet have that value. `builderFrontier` is an array ordered by ascending
level. Each element contains exactly `level`, `partialRows`, and
`pendingChildren`; exactly level zero may have 0–63 canonical rows, and every
higher level has 0–255 canonical child entries and an empty `partialRows` array.

At session start a random 32-byte key exists only in process memory. The
selector stores its SHA-256; `macSHA256` is HMAC-SHA256 over the canonical slot
with that field set to `null`. Checkpoint generation starts at zero and each
dual-slot selector CAS increments exactly once and binds the previous selected
checkpoint digest. `builderFrontier` contains at most one partial 64-row leaf
and one ordered list of at most 255 child entries per level. The transcript is
`H("retirement-v1-scan-v1\0" || priorTranscript || ordinal-u64be ||
nameLength-u16be || rawName || certificateSHA256 || originSHA256)`.

The safe-integer quota and the retained v1 certificate charge bound v1 to
`floor(9,007,199,254,740,991 / 20,480) = 439,804,651,110` rows. The 64/256 tree
therefore has at most six page levels. `builderFrontier` has at most six level
entries; even six maximum child lists plus one maximum partial leaf remain below
the 1,048,576-byte checkpoint limit. A larger count is invalid before encoding.

The live `telldir` position is only an in-memory optimization and is never
serialized authority. A checkpoint is usable only by the same live process
while it holds the original FDs, key, lock, unchanged directory witness, and
matching selected generation. After process death the key and locks are gone;
all checkpoint slots and work are nonauthoritative and enumeration restarts at
entry zero. Content-addressed final tree pages may be reused only after being
re-derived byte-identically in the new session.

### 5.4 Deterministic ordinary insertion

V2 and abort trees are append-only and start at their canonical empty roots.
For a new key, descend by ordered inclusive ranges. A key between ranges follows
the immediate predecessor range; before the first or after the last follows the
first or last range. The reached leaf proves membership or the exact gap.

Insert into the sorted leaf. At 1–64 rows, encode one replacement leaf. At 65,
split deterministically into the first 32 and final 33 rows. Replace the parent
child with the one or two resulting entries. At 1–256 children, encode one
replacement node. At 257, split into the first 128 and final 129 children and
propagate. If the top page splits, create one new two-child top node and increase
height. No merge, rotation, borrowing, opportunistic packing, or whole-tree
rebuild is allowed. Unchanged children retain their exact digests.

## 6. Exact retained-byte charges and lifecycle reserve

R7's `F(M) = ceil(M / 4096) * 4096 + 4096` and directory charge `D = 4096`
remain. Activation inventories every v1 page/root and the three empty-tree roots
by actual canonical length. All tree directories are created and charged during
activation, so an ordinary tree update adds no directory charge for page/root
paths. Every immutable old page and root remains materialized and charged.

For R8 pages, `F(65,536) = 69,632`; for root envelopes and abort receipts,
`F(16,384) = 20,480`; and retirement-v2 remains `F(65,536) = 69,632`.

The v2 tree can never exceed height two. It starts empty. At genesis at most
1,024 active members own a prepaid retirement. Outside those prepaid closures,
the frozen quota supplies at most the 1 GiB minimum headroom for new successful
lifecycles. With the R8 lifecycle charge below, at most
`floor(1,073,741,824 / 581,632) = 1,846` later allocations can succeed. Thus at
most 2,870 v2 rows can be created, below one leaf level plus one 256-child node's
16,384-row capacity. A legal insertion therefore creates at most two replacement
leaves and one replacement internal node, plus one root envelope.

The exact worst-case retirement tranche is:

| Retained object | Maximum charge |
|---|---:|
| retirement-v2 certificate | 69,632 |
| new certificate UUID directory | 4,096 |
| up to two new leaf pages | 139,264 |
| up to one new internal page | 69,632 |
| one new root envelope | 20,480 |
| **retirement tranche** | **303,104** |

The maximum retained charge by legal successor shape is therefore exact:

| Selected old shape | New retained objects | Maximum charge |
|---|---|---:|
| empty or height-one without split | certificate, UUID directory, one leaf, root | 163,840 |
| height-one leaf split | certificate, UUID directory, two leaves, one node, root | 303,104 |
| height-two without leaf split | certificate, UUID directory, one leaf, one node, root | 233,472 |
| height-two leaf split | certificate, UUID directory, two leaves, one node, root | 303,104 |

For a nonsplitting successor, absent page slots and the difference between each
maximum and actual `F(canonicalLength)` become `spentSlackBytes`; they are not
reusable. `materializedChargeBytes` lists the actual certificate, directory,
each leaf, each node, and root charge separately before the consuming CAS.

The allocation-abort tree receives at most 37,449 rows in the 1 GiB minimum
headroom because every abort retains at least one positive receipt file, leaf,
root, and directory charge: `floor(1,073,741,824 / 28,672) = 37,449`. That is
below its height-three capacity of 4,194,304 rows. Its abort alternative creates
at most two leaves, two internal pages, one root, one receipt, and one directory,
for a maximum retained abort charge of 323,584 bytes. This is less than the
success lifecycle admission, so one admission covers exactly one mutually
exclusive success or abort closure.

The corrected post-complete allocation lifecycle is:

```text
allocation genesis: 77,824 + 4,096                      =  81,920
later left publication: 188,416 + 8,192                 = 196,608
retirement certificate/path/root:                       = 303,104
total success lifecycle admission:                      = 581,632 bytes
```

The corrected unclassified-source closure is
`204,800 + 188,416 + 303,104 = 696,320` bytes. Finalization remains 1,073,152
bytes and active index plus two slots remains 3,158,016 bytes. The quota remains
`roundUp4096(max(1 GiB, activationMaterializedBytes +
activationReservedRemainingBytes + finalizationReserve))`, now using these
corrected reserves and the actual complete tree inventory.

Before a retirement admission CAS, the implementation derives the exact
successor shape from the captured path and records every new object's canonical
length, `F(length)`, digest, and path in the tranche. Admission requires the
303,104-byte maximum even when that successor uses fewer bytes. Before each
write, `Wpeak` includes that write's rounded temporary/exclusive-create extent
and any newly created directory, while `Uafter` removes only that same write's
permanent charge. Previously created new path objects remain in
`materializedBytes`; they are not counted again in `Wpeak` or deleted after a
later failure. R7's 536,870,912-byte free-space floor and every ENOSPC/EDQUOT
ordering rule remain unchanged.

## 7. Legal maximum projections

The maximum-encoding gate uses separate mutually exclusive fixtures:

1. **Classifying publication maximum:** 1,024 active rows, every row in its
   maximum legal pending-publication representation, no shared admission.
2. **Reserved-allocation maximum:** 1,024 active rows and one maximum A1
   allocation admission with no allocating row and no finalization admission.
3. **Materializing-allocation maximum:** 1,023 maximum active rows, one maximum
   A2/A3 allocating row, its maximum allocation admission, and no finalization
   admission.
4. **Finalization maximum:** exactly 1,024 frozen, publication-settled rows and
   one maximum finalization admission, with no allocation admission or
   allocating row.
5. **Complete maximum:** 1,024 active rows with every per-row tranche at its
   maximum legal complete-phase representation and neither shared admission.

Each fixture includes maximum embedded v1, v2, and abort root envelopes and all
new capacity counters. Active index and projection must each remain at most
1,048,576 bytes without dropping any inherited field. A projection containing
both allocation and finalization admissions, 1,025 total active/allocating rows,
a pending publication in the finalization fixture, or a phase-illegal per-row
state is rejected rather than used as a maximum fixture.

## 8. Bounded operations, migration, and acceptance

At maximum ordinary retirement, direct reads are: active index, selected
projection, optional classifying progress, target primary, target origin,
target class, target left, target settled lineage, and at most two v2 path
pages—ten total. The maximum reservation-authority body bytes are
`3,145,728 + 16,384 + 32,768 + 16,384 + 16,384 + 131,072 = 3,358,720`, below
R6's 3,383,296 ceiling; the already-required target primary retains its inherited
separate limit. Reads and exclusive creates are sequential, and no more than
four reservation descriptors are live. A pending target publication is first
recovered in its own bounded operation; retirement does not combine the
predecessor/receipt read set with a tree update.

A v1 historical target lookup uses active index, selected projection, optional
progress, at most six v1 path pages, and the named v1 certificate—ten direct
reads. Genesis already validated the certificate's named origin and the v1 row
binds that origin digest; an ordinary historical lookup does not reopen the
origin merely to re-prove the globally frozen activation. Any operation that
needs the origin body schedules that dereference as its own bounded target step.

Migration order is: freeze source/executable hashes and prior mutation routes;
add all strict codecs and maximum-encoding fixtures; install the mandatory
format fence; start the held-lock activation session; collect/sort/build/verify
v1; inventory/precharge every retained object and corrected closure; select
genesis with v1, empty v2, and empty abort roots; add bounded incremental root
updates; add the closed allocation abort protocol; then enable phase transitions.
Readers and writers for the new formats land in the same unshippable slice.

Emit R7 metrics plus activation-session generation/phase/pass, directory witness
changes, checkpoint MAC/generation failure, enumeration restart, v1 run/merge
counts, changed/reused v2 pages, successor page bytes, retirement/abort tree
height, gross charge, refunds, retained abort charge, and allocation state.
Logs contain identifiers and digests, never session keys or body bytes.

Implementation is eligible for audit only after every R14 case and every
retained applicable R4/R11/R12/R13 case passes against one frozen source/test
manifest. Fresh independent plan review must precede any source/test edit, and
fresh complete-diff code, security, and architecture reviews must each report
zero Critical, High, and Medium findings before implementation acceptance.

Stop on full validation of an ordinary successor root; any uncharged retained
leaf/node/root; direct all-absent row removal; refund without rooted terminal
abort evidence; ambiguous page packing/split/order; resumed post-death directory
cursor; directory selection without the held exclusion lock and two equal
transcripts; simultaneous shared admissions; projection/page overflow; more than
ten ordinary reads, four live descriptors, 3,383,296 reservation bytes, or eight
seconds; raised limits; omitted prior correction; stale evidence; or a skipped,
interrupted, or timed-out command reported as passing. Physical MLX, signed
release/feed, deployment, enforcement, settlement, and economic activation
remain outside this proposal.
