# Reservation search progress — corrective addendum R9

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R8 plan gate. Its frozen inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r8.md` | `45514011e40023e57c2a9cd96c01e3d79f40b5578c76469c2c1f0d2d93946789` |
| `test-spec-r14-reservation-r8-corrections.md` | `8db9e33879ac17cc5373ceee0788a5249633541736d095a79d4f93c03fbb4422` |
| `reviews/reservation-search-progress-r8-plan-sol.md` | `4c853a5322c050350bcf000cc29a0e2f95c72f633f35beb9e7b2f4e592c05bf3` |

The independent R8 verdict was FAIL, 0 Critical / 4 High / 0 Medium / 0 Low.
This addendum closes R8-PLAN-H1 through H4. It is paired with
`test-spec-r15-reservation-r9-corrections.md`. Both exact documents require a
fresh independent zero-Critical/High/Medium plan gate before implementation.

## 1. Governing relationship

R4 through R8 remain governing except for these exact replacements:

1. Sections 2–4 replace R8 section 5.2–5.3. No activation session, journal
   lock, directory descriptor, `DIR *`, `flock`, continuation token, or secret
   key survives an invocation.
2. Section 5 replaces R8's A0–A6 allocation machine and its allocation
   admission schema. An empty materialization directory is selected authority,
   not an observation between states.
3. Section 6 replaces R8's abort successor maximum, refund arithmetic, and all
   quota consequences that used 323,584 bytes.
4. Section 7 adds the exact closed encodings, paths, digest domains, generation
   rules, and publication order for activation work.

Every other R4–R8 correction remains mandatory, including the one-time
`genesis-v2` boundary; target-local inductive retirement successors; full graph
validation only at genesis and the two named phase transitions; the global
allocating-intent gate; exact allocation-generation equality; origin and
primary-first rules; same-owner stabilization; rollback and queued-cancel
protection; frozen finalizing membership; content-addressed install, settlement,
retirement, and abort lineage; strict direct paths and decoders; actual-prior-
binary fencing; byte-equal pre-capture and strict post-capture identity; no
global publication gate; no wrapper bypass; no deletion of retained authority;
and real-death recovery.

All inherited limits remain: eight seconds per invocation with no nested
renewal, 256 soft descriptors, four simultaneously live reservation
descriptors, ten ordinary direct reads/decodes, 3,383,296 ordinary reservation
authority bytes, 1,024 selected rows, 1 MiB inherited documents, 65,536-byte
tree pages, and 16,384-byte roots and abort receipts. No dependency is added.

## 2. Executable activation ownership

Activation is a sequence of independent CLI/app invocations. The durable
selected projection owns it through one closed `activation` object. That object
has exactly:

```text
schema = "model_catalog_retirement_v1_activation.v1"
activationUUID
state = "capturing_names" | "capturing_rows" | "merging" |
        "building" | "verifying" | "ready"
activationGeneration
priorActiveIndexSHA256
migrationSourceSHA256
formatFenceSHA256
configuredRootPathSHA256
initialPathReceiptSHA256
nameCaptureRootSHA256
rowWorkRootSHA256
sortedRunSHA256
treeWorkRootSHA256
verificationRootSHA256
checkpointSHA256
```

All fields are present. SHA fields not yet produced are `null`. Generation zero
is selected before any capture work. Each successor increments
`activationGeneration` by exactly one and may fill only the next fields allowed
by the state order above. No transition may clear or replace a non-null digest.
The active index and selected state projection bind the same activation UUID,
generation, state, checkpoint digest, and aggregate root.

Selection of generation zero is the durable compatible-writer exclusion fence.
Every transaction-root mutation route, including old supported routes, must
first read the mandatory format fence and selected activation state. While the
state is not `ready` or genesis-selected, it rejects before mutation. Heartbeat,
status, and read-only control do not acquire the activation lock and remain
available.

Every activation invocation uses one new caller-owned eight-second budget. It:

1. acquires the activation `flock` nonblocking;
2. reads and validates the selected activation and checkpoint;
3. resolves the configured root from `/` one component at a time with
   `openat(..., O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` and records the path
   receipt in section 3;
4. performs one bounded phase slice, with bulk reads and content-addressed
   writes outside the journal lock;
5. acquires the journal lock only to re-resolve the path, recapture the selected
   activation/index/projection/fence, and perform one checkpoint or activation
   CAS; and
6. closes every file/directory descriptor, `DIR *`, and lock before returning.

Cancellation, thrown error, deadline, or process death releases kernel locks
and descriptors. There is no process-memory key. A later CLI invocation or app-
launched `Process` resumes solely from selected hashes and direct immutable
objects. It receives a new eight-second budget because it is a new caller; no
helper renews the budget of the prior invocation.

The activation `flock` is held only during one invocation and never substitutes
for the selected logical fence. The journal lock is never held during directory
enumeration, certificate/origin reads, sorting, merge, page construction, or
tree verification. The final genesis CAS may use only already verified digests
and bounded metadata recapture.

## 3. Exact root pathname and namespace identity

`configuredRootPathSHA256` is
`SHA256("macprovider-root-path-v1\0" || utf8ByteLength-u32be || absoluteUTF8Path)`.
The path must be absolute, normalized, contain no empty, `.` or `..` component,
and round-trip byte-identically through the filesystem representation.

Each resolution emits a canonical path receipt at:

```text
.reservation-migration/retirement/v1/activation/<activationUUID>/path-receipts/<sha256>.json
```

Schema `model_catalog_retirement_v1_path_receipt.v1` contains exactly `schema`,
`activationUUID`, `configuredRootPathSHA256`, `components`, `rootNamespaceSHA256`,
and `capturedAt`. `components` is ordered from `/` through the transaction root.
`rootNamespaceSHA256` is non-null only for the initial and final complete
namespace scans and is explicit null for metadata-only per-invocation receipts.
Each component contains exactly `ordinal`, `name`, `deviceID`, `fileID`,
`fileType`, `mode`, `ownerUID`, `groupGID`, `linkCount`, `modifySeconds`,
`modifyNanoseconds`, `changeSeconds`, and `changeNanoseconds`. The root component
uses name `/`; later names are the exact normalized UTF-8 path components.
The four time fields are non-null only for the final transaction-root component
and explicit null for `/` and intermediate parents, so unrelated parent
directory traffic cannot invalidate activation. Other numeric fields are safe
unsigned integers. Non-null nanoseconds are `0...999,999,999`.
`fileType` is exactly `directory`. `deviceID` and `fileID` are the portable
`st_dev` and `st_ino` identities from `fstat`; mode/owner/link and POSIX
modification/change times prevent accepting a type, protection, or intervening
directory mutation. The pathname identities, not timestamps alone, detect
rename/replacement.

`rootNamespaceSHA256` is computed by a complete no-follow namespace-only scan.
Every direct entry is encoded as
`nameLength-u16be || rawUTF8Name || fileType-u8 || deviceID-u64be ||
fileID-u64be`; records are sorted by raw UTF-8 name bytes. The digest is
`SHA256("macprovider-retirement-v1-namespace-v1\0" || count-u64be || records)`.
`fileType-u8` is regular file `0x01` or directory `0x02`; every other type is
invalid.
Unsafe names, invalid UTF-8, symlinks, hard links where forbidden, nonregular
certificate paths, duplicate normalized names, or an entry whose identity
changes between `readdir` and `openat` fail the scan.

This is the only root change predicate. No `st_gen`, timestamp, directory size,
`telldir` cookie, or unnamed platform token is authority. Every invocation must
re-resolve the full component chain and require byte-equal component identities
to the initial selected receipt. The initial name-capture invocation and final
verification invocation also recalculate the complete namespace hash. Genesis
requires the final component chain and namespace hash to equal the initial
selected values. Renaming/replacing the root pathname, any parent component, or
any direct entry therefore fails even if an old directory FD still names the
detached directory or replacement bytes are equal.

The namespace-only maximum fixture must finish below eight seconds. That scan
does not decode bodies and may use bounded external name blocks. Failure to
complete the measured valid maximum within the existing deadline blocks the
implementation; it does not raise the deadline or retain an FD across calls.

## 4. Durable capture and process-restart progress

The first complete namespace scan externally sorts all accepted name records by
UUID, partitions that one global stream into canonical name blocks, and emits a
name-capture root. Nothing is selected until EOF, all blocks are durable, the path is
re-resolved, and a second namespace hash in the same invocation equals the
first. Process death before selection leaves only unreferenced content-addressed
objects; the next invocation restarts that namespace-only scan.

After `nameCaptureRootSHA256` is selected, all later work uses its exact ordered
names by direct `openat` lookup. Each row-capture invocation processes the next
consecutive bounded name range. For every `<uuid>.retired` certificate it opens
the named regular file no-follow, records portable file identity before and
after read, validates canonical v1 bytes, opens and validates the exact named
origin, and emits a row work block. The block is selected by a checkpoint CAS
only after file fsync and containing-directory fsync. Death before the CAS
repeats that range; equal content-addressed files are reused and unequal
collisions fail.

`nextNameOrdinal` in the selected checkpoint is authority because the complete
name list is already immutable and content-addressed; it is not a filesystem
cursor. On restart a new process opens the named capture root and blocks by
digest and directly resumes that ordinal. No `DIR *`, `telldir`, session key,
or prior deadline is needed.

Merge, tree build, and verification use the same rule: one invocation consumes
the exact input objects named by the selected checkpoint, emits one bounded set
of immutable outputs, then publishes one generation. A checkpoint never asserts
work that is not already fsynced. A process may reuse an existing output only
after independently deriving the same canonical bytes and digest.

Verification is two-part. Bounded row-verification calls reopen every captured
certificate and origin by exact name, compare portable identity and canonical
digest to the captured row, verify membership in the built tree, and advance a
durable verification root. The final invocation performs the complete pathname
resolution and namespace-only recapture, validates the terminal verification
root/count/transcript, and publishes the resulting path receipt. It then takes
the journal lock and performs only bounded metadata work: re-resolves every path
component, requires its full identity/time tuple to equal that just-published
receipt, and recaptures the selected activation/index/projection/fence, tree
root, and all capacity counters before the one genesis CAS. It does not scan the
namespace under the journal lock. Any mismatch invalidates all unselected
activation work; no partial root becomes authority.

## 5. Closed allocation materialization and abort machine

R8's admission gains exactly these fields after `materializedChargeBytes`:
`materializationPhase`, `materializationDirectoryPathSHA256`, and
`materializationDirectoryIdentity`. The complete admission schema otherwise
retains R8's exact fields and order-independent canonical object semantics.
`materializationPhase` is exactly `none`, `row_selected`, `directory_intent`,
`directory_empty`, `primary`, `origin`, `class`, or `lineage`.
`materializationDirectoryPathSHA256` is null for `none` and `row_selected`, and
otherwise is the hash of the exact normalized direct path
`.reservation-migration/lineage/<proposedTransactionUUID>` using the path digest
domain from section 3. `materializationDirectoryIdentity` is null through
`directory_intent`; afterward it contains exactly `deviceID`, `fileID`,
`fileType: "directory"`, `mode`, `ownerUID`, `groupGID`, and `linkCount`.

The only legal states are:

| State | Selected authority and disk facts | Only legal successor |
|---|---|---|
| A0 absent | No admission, row, success directory/body, or abort key | A1 reserve |
| A1 reserved | Admission state `reserved`, phase `none`; row/directory/bodies absent | A2 or A7 |
| A2 row-selected | Admission state `materializing`, phase `row_selected`; exact allocating row; directory/bodies absent | A3 or A7 |
| A3 directory-intent | Same row; phase `directory_intent` binds exact path; directory is absent or exact empty | Create/fsync exact directory, then A4 |
| A4 directory-empty | Phase `directory_empty`; exact selected portable directory identity; directory exists and is empty | A5 primary only |
| A5 materializing-prefix | Phase `primary`, `origin`, `class`, or `lineage`; exact ordered prefix exists in the bound directory lineage | Next exact body or A6 |
| A6 active | Complete primary/origin/class/lineage and active row; admission removed by success CAS | Ordinary active authority |
| A7 aborting | R8 abort intent; admission retained, optional row `allocation_aborting`; all success directories/bodies absent | Materialize exact abort objects, then A8 |
| A8 aborted | No admission/allocating row; selected abort tree contains exact receipt | Idempotent terminal result |

A2→A3 is a selected CAS before `mkdir`. It binds the only permitted directory
path and changes no charge. Recovery from A3 accepts only absence or one empty,
no-follow directory with the required mode/owner. It exclusive-creates the
directory if absent, fsyncs it and its parent, captures its portable identity,
then selects A4. Death after intent, after mkdir, after directory fsync, or after
parent fsync therefore remains unambiguously A3 and can only finish A4. A wrong,
nonempty, replaced, symlinked, hard-linked, or extra directory is protected and
is never deleted.

Refund is legal only from A1 or A2 through A7. Selection of A3 permanently
commits to forward materialization even while the directory is still absent.
One byte, A3, A4, or any A5 prefix makes abort/refund illegal. A7/A8 otherwise
retain R8's rooted receipt, page, root, one-refund, replay, race, and global-gate
rules, with their labels shifted from A4/A6.

## 6. Correct abort cascade, quota, and 1 GiB feasibility

The abort insertion algorithm is unchanged: 65 leaf rows split 32/33; 257
children split 128/129; a split top creates a two-child new top. At the admitted
37,449-row bound, the maximum legal successor creates two leaves and three
internal pages. This occurs when a height-two top splits and creates a new top,
or when a level-one page splits under an existing height-three top. The
37,449-row bound cannot overflow that height-three top, so four or more new
internal pages are impossible under the frozen quota.

The exact maximum is:

| Retained abort object | Maximum charge |
|---|---:|
| receipt, `F(16,384)` | 20,480 |
| receipt UUID directory | 4,096 |
| two leaves, `2 * F(65,536)` | 139,264 |
| three internal pages, `3 * F(65,536)` | 208,896 |
| root envelope, `F(16,384)` | 20,480 |
| **maximum retained abort charge** | **393,216** |

The exact successor maxima are:

| Old shape and overflow | Leaves | Internal pages | Maximum retained charge |
|---|---:|---:|---:|
| empty/height one, no split | 1 | 0 | 114,688 |
| height one, leaf split/new top | 2 | 1 | 253,952 |
| height two, no leaf split | 1 | 1 | 184,320 |
| height two, leaf split/no internal split | 2 | 1 | 253,952 |
| height two, leaf and top split/new top | 2 | 3 | 393,216 |
| height three, no leaf split | 1 | 2 | 253,952 |
| height three, leaf split/no level-one split | 2 | 2 | 323,584 |
| height three, leaf and level-one split | 2 | 3 | 393,216 |

Before A7 the implementation derives the exact canonical receipt, every changed
page, and root, records each digest/path/`F(length)`, and sets
`retainedAbortChargeBytes` to their actual sum plus the one directory charge.
The 393,216 maximum is reserved by the existing 581,632-byte mutually exclusive
allocation admission. The A7→A8 refund is exactly
`581,632 - retainedAbortChargeBytes`: at maximum retention it is 188,416; at the
minimum 28,672 retention it is 552,960. Gross charge never changes; refunded and
net charged bytes change once at A8.

All corrected fixed values are:

| Bundle | Exact maximum charge |
|---|---:|
| retirement-v2 certificate/path/root | 303,104 |
| allocation abort receipt/path/root | 393,216 |
| successful post-complete allocation lifecycle | 581,632 |
| unclassified source closure | 696,320 |
| completed projection + install | 1,073,152 |
| active index + two state slots | 3,158,016 |

The declared quota remains
`roundUp4096(max(1,073,741,824, activationMaterializedBytes +
activationReservedRemainingBytes + finalizationReserve))`, where
`finalizationReserve` is 1,073,152 and activation reserved remainder uses the
303,104 retirement and 696,320 source-closure figures. Activation work receipts,
blocks, manifests, checkpoints, and replacement temporaries are included in
`Wpeak`, not silently omitted from disk inventory; after genesis only unselected
work may be removed.

For exactly 1 GiB of post-baseline headroom:

```text
floor(1,073,741,824 / 581,632) = 1,846, remainder 49,152
1,024 prepaid v2 retirements + 1,846 later successes = 2,870 v2 rows
floor(1,073,741,824 / 28,672) = 37,449 aborts, remainder 4,096
floor(1,073,741,824 / 393,216) = 2,730 maximum-charge aborts,
  remainder 262,144
```

For every mixed history with `S` successful later allocations and abort actual
charges `Ai`, feasibility is exactly
`S*581,632 + sum(Ai) <= available logical headroom`. Thus `S <= 1,846`, every
abort closes within its already admitted 581,632 bytes, v2 stays height two,
and abort stays height three. The selected equations remain:

```text
grossChargedBytes - refundedBytes == chargedBytes
materializedBytes + reservedRemainingBytes + spentSlackBytes == chargedBytes
chargedBytes <= quotaBytes
```

For every immutable write, `Wpeak` is the rounded encoded extent plus the
inherited 4,096-byte create/metadata allowance and any newly created directory;
`Uafter` removes only that write's permanent charge. Therefore a maximum page
write uses 69,632 bytes of `Wpeak`, a maximum receipt/root uses 20,480, and the
receipt directory uses 4,096. The inherited
`availableCapacity >= 536,870,912 + Wpeak + Uafter` test remains exact.

## 7. Closed activation work formats

All documents below use R8 canonical JSON and SHA-256 content addressing.
Unknown, duplicate, omitted, noncanonical, unsafe-integer, wrong-type, trailing,
or over-limit bytes are invalid. Every listed field is present. Nullable fields
are explicitly `null`. UUIDs/digests use R8's lowercase forms.

### 7.1 Direct paths and limits

```text
.reservation-migration/retirement/v1/activation/<activationUUID>/names/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/rows/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/runs/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/work-roots/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/verification/<sha256>.json
.reservation-migration/retirement/v1/checkpoints/active.json
.reservation-migration/retirement/v1/checkpoints/slot-0.json
.reservation-migration/retirement/v1/checkpoints/slot-1.json
```

Name blocks, row blocks, run manifests, work roots, verification blocks, and
checkpoint slots are at most 1,048,576 canonical bytes. The selector is at most
16,384 bytes. A filename digest must equal the canonical file bytes.

### 7.2 Name and row blocks

Schema `model_catalog_retirement_v1_name_block.v1` contains exactly `schema`,
`activationUUID`, `blockOrdinal`, `entryCount`, `firstUUID`, `lastUUID`,
`previousBlockSHA256`, and `entries`. Each entry contains exactly `uuid`, `name`,
`deviceID`, `fileID`, `mode`, `ownerUID`, `groupGID`, and `linkCount`. Blocks have
1–4,096 entries in strict UUID order. `name` must equal `<uuid>.retired`.
`blockOrdinal` starts at zero; `previousBlockSHA256` is null only at zero and
otherwise names ordinal minus one. First/last/count equal the entries.

Schema `model_catalog_retirement_v1_row_block.v1` contains exactly `schema`,
`activationUUID`, `blockOrdinal`, `sourceNameBlockSHA256`, `sourceFirstOrdinal`,
`sourceLastOrdinal`, `rowCount`, `firstUUID`, `lastUUID`,
`previousRowBlockSHA256`, and `rows`. Each row contains exactly `uuid`,
`certificateSHA256`, `originSHA256`, `certificateIdentity`, and `originIdentity`.
Each identity contains exactly `deviceID`, `fileID`, `fileType: "regular"`,
`mode`, `ownerUID`, `groupGID`, `linkCount`, and `byteLength`. Blocks contain the
next 1–4,096 source names, preserve their strict UUID order, and form one closed
ordinal chain.

### 7.3 Runs, work roots, and digest chains

Schema `model_catalog_retirement_v1_run_manifest.v1` contains exactly `schema`,
`activationUUID`, `runKind`, `mergePass`, `runOrdinal`, `creationOrdinal`,
`inputRunSHA256s`, `rowBlockSHA256s`, `rowCount`, `firstUUID`, `lastUUID`, and
`rowsSHA256`. `runKind` is `capture` or `merge`. Capture runs have merge pass
zero, exactly one row block, and empty inputs. Merge pass `p>0` has 1–32 inputs
from pass `p-1`, ordered by `(firstUUID, creationOrdinal, manifestSHA256)`, and
outputs consecutive row blocks of at most 4,096 strict UUID-sorted rows.
`creationOrdinal` is the safe unsigned ordinal reserved by the predecessor
checkpoint before work begins; retry of that checkpoint reuses the same
ordinal. `runOrdinal` starts at zero independently within each pass.

`rowsSHA256` is:

```text
SHA256("retirement-v1-rows-v1\0" || rowCount-u64be ||
       for each row in UUID order:
       uuid-16bytes || certificateSHA256-32bytes || originSHA256-32bytes)
```

Schema `model_catalog_retirement_v1_work_root.v1` contains exactly `schema`,
`activationUUID`, `workKind`, `workGeneration`, `previousWorkRootSHA256`,
`pathReceiptSHA256`, `inputRootSHA256`, `orderedObjectSHA256s`, `objectCount`,
`rowCount`, `firstUUID`, `lastUUID`, and `transcriptSHA256`. `workKind` is
`names`, `rows`, `runs`, or `tree`. Generation starts at zero for names and
increments once for every selected successor across all kinds.
`orderedObjectSHA256s` names all directly consumable blocks/manifests/pages in
their canonical ordinal or tree-construction order. `inputRootSHA256` is null
only for names. `previousWorkRootSHA256` is null only at generation zero.

`transcriptSHA256` is:

```text
SHA256("retirement-v1-work-root-v1\0" || workKind-u8 ||
       workGeneration-u64be || previous-or-32-zero-bytes ||
       input-or-32-zero-bytes || objectCount-u64be || rowCount-u64be ||
       ordered object digests as 32 raw bytes)
```

The `workKind-u8` codes are names `0x01`, rows `0x02`, runs `0x03`, and tree
`0x04`; no other value is valid.

The tree root orders leaves left-to-right, then internal pages by ascending
level and left-to-right range, then the root envelope. Its `transcriptSHA256`
therefore commits to the exact complete page/root construction, not only the
top digest.

Schema `model_catalog_retirement_v1_verification_block.v1` contains exactly
`schema`, `activationUUID`, `blockOrdinal`, `treeWorkRootSHA256`,
`sourceRowBlockSHA256`, `verifiedRowCount`, `firstUUID`, `lastUUID`,
`previousVerificationSHA256`, and `verificationSHA256`. Its final digest is:

```text
SHA256("retirement-v1-verify-v1\0" || previous-or-32-zero-bytes ||
       sourceRowBlockSHA256-32bytes || verifiedRowCount-u64be ||
       firstUUID-16bytes || lastUUID-16bytes)
```

### 7.4 Checkpoint schema, phases, and publication

The selector schema `model_catalog_retirement_v1_checkpoint_selector.v2`
contains exactly `schema`, `activationUUID`, `selectedSlot`,
`checkpointGeneration`, `checkpointSHA256`, `activationGeneration`,
`priorActiveIndexSHA256`, `migrationSourceSHA256`, and `formatFenceSHA256`.

Each slot schema `model_catalog_retirement_v1_checkpoint.v2` contains exactly:

```text
schema, activationUUID, checkpointGeneration, previousCheckpointSHA256,
activationGeneration, activationState, priorActiveIndexSHA256,
migrationSourceSHA256, formatFenceSHA256, initialPathReceiptSHA256,
latestPathReceiptSHA256, nameCaptureRootSHA256, rowWorkRootSHA256,
sortedRunSHA256, treeWorkRootSHA256, verificationRootSHA256,
nextNameOrdinal, nextRowBlockOrdinal, mergePass, nextRunOrdinal,
nextCreationOrdinal, builderLevel, nextTreeObjectOrdinal,
nextVerificationOrdinal, terminalRowCount
```

The generation starts at zero and increments by exactly one. The previous digest
is null only at zero. `activationState` equals the selected activation state.
The five phase-result SHA fields become non-null in the order names, rows, sorted
run, tree, verification; later fields cannot be non-null before earlier fields.
`initialPathReceiptSHA256` and `latestPathReceiptSHA256` are always non-null.
Cursor/nullability is exactly:

| `activationState` | Required non-null cursors | Required null cursors |
|---|---|---|
| `capturing_names` | none | all eight cursor fields |
| `capturing_rows` | `nextNameOrdinal`, `nextRowBlockOrdinal`, `nextCreationOrdinal` | `mergePass`, `nextRunOrdinal`, `builderLevel`, `nextTreeObjectOrdinal`, `nextVerificationOrdinal` |
| `merging` | `mergePass`, `nextRunOrdinal`, `nextCreationOrdinal` | `nextNameOrdinal`, `nextRowBlockOrdinal`, `builderLevel`, `nextTreeObjectOrdinal`, `nextVerificationOrdinal` |
| `building` | `builderLevel`, `nextTreeObjectOrdinal` | `nextNameOrdinal`, `nextRowBlockOrdinal`, `mergePass`, `nextRunOrdinal`, `nextCreationOrdinal`, `nextVerificationOrdinal` |
| `verifying` | `nextVerificationOrdinal` | the other seven cursor fields |
| `ready` | none | all eight cursor fields |

All non-null cursor fields are safe unsigned integers. `rowWorkRootSHA256` may
be null in `capturing_rows` only when `nextNameOrdinal` and
`nextRowBlockOrdinal` are both zero; after the first captured range it is
non-null. `terminalRowCount` is null in `capturing_names` and
`capturing_rows`, then non-null and immutable from `merging` onward. There is no
MAC or secret-key field.

For each checkpoint publication, write canonical bytes to the inactive slot's
same-directory temporary, fsync the file, rename over the inactive slot, fsync
`checkpoints/`, write/fsync/rename/fsync `active.json`, then under the journal
lock CAS the selected activation to the same checkpoint digest and generation.
Until the activation CAS, the new selector/slot is an unselected candidate.
After activation CAS, it is the only checkpoint authority. Crash recovery
chooses the checkpoint named by the selected activation, validates its selector,
slot digest, generation, previous link, and every referenced immutable object;
it never chooses merely the highest file generation. If `active.json` names an
unselected candidate after a crash, recovery first republishes a selector for
the checkpoint digest named by the selected activation; it does not overwrite
either slot until that selected record is directly found and validated.

Immutable work publication is create temporary, write canonical bytes, fsync,
exclusive rename/link to the digest path, fsync the containing directory, then
publish the successor checkpoint. Existing digest paths are reused only after
byte equality. Tree publication remains leaves, internal levels bottom-up, root
envelope, tree work root, verification chain, final path/namespace recapture,
then genesis state slot and active-index selection.

The following phase transitions are exhaustive:

```text
capturing_names: checkpoint 0 -> selected complete name root
capturing_rows:  nextNameOrdinal advances; terminal selects row root/count
merging:         one deterministic run group per generation; terminal selects one run
building:        one bounded leaf/node/root batch per generation; terminal selects tree root
verifying:       nextVerificationOrdinal advances; terminal selects verification root
ready:           no work cursor; final recapture and genesis CAS only
```

A generation skip, alternate predecessor, changed frozen binding, non-null
future field, null required field, out-of-range cursor, unfsynced object, object
not named by the work root, or path whose digest differs from its bytes is
protected before selection.

## 8. Acceptance and stop conditions

Migration order is unchanged except that R9 activation ownership, codecs, and
R15 fixtures replace the held R8 session. Readers and writers for the new
formats land in one unshippable slice. No source/test implementation starts
until the R9/R15 plan gate reports zero Critical, High, and Medium findings.

Emit all retained R8 metrics plus invocation generation/state, path receipt and
namespace hash mismatch, capture/work/checkpoint generation, creation ordinal,
restart/reuse, empty-directory phase, abort successor shape, and actual/max
retained abort charge. Logs contain identifiers and digests, never bodies or
secrets.

Stop on a lock/FD/key surviving a call; journal lock held during bulk work;
process-local-only progress; resumed filesystem cursor; root/path replacement
accepted; ambiguous work/checkpoint bytes; unselected or unfsynced progress
used; empty directory outside selected state; refund from A3 or later; fewer
than three internal pages charged for a legal cascade; retained abort charge
above 393,216 or hidden after admission; incorrect 1 GiB arithmetic; authority
deletion; raised deadline/FD/input limit; omitted prior correction; stale
evidence; or a skipped, interrupted, or timed-out command reported as passing.
Physical MLX, signed release/feed, deployment, enforcement, settlement, and
economic activation remain outside this proposal.
