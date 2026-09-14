# Reservation search progress — corrective addendum R10

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R9 plan gate. Its frozen planning inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r9.md` | `d8b48f6ebed050a3c5745dd30a3d5e8cb40621cf879e4b148e985c3f4b503c93` |
| `test-spec-r15-reservation-r9-corrections.md` | `f32b391f8dca8e5b68a85964eda76172b8d8de45f7d0825f9a011b8d5dae7ada` |
| `reviews/reservation-search-progress-r9-plan-sol.md` | `0d4b565998f80b7694b2d2fa5644290987c73d17fc1719fc6d2a81620c24f8d4` |

The independent R9 verdict was FAIL, 0 Critical / 5 High / 1 Medium / 0 Low.
This addendum closes R9-PLAN-H1 through H5 and R9-PLAN-M1. It is paired with
`test-spec-r16-reservation-r10-corrections.md`. Both exact documents require a
fresh independent zero-Critical/High/Medium plan gate before implementation.

## 1. Governing relationship and current-source reconciliation

R4 through R9 remain governing except for these exact replacements:

1. Sections 2–5 replace R9 sections 2–4 and 7. They define a selected
   pre-genesis authority without modifying the future v2 projection before
   genesis, a legal generation-zero pair, mutable checkpoint progress, and
   complete rooted merge/build/verification frontiers.
2. Section 6 replaces R9's source-name, row-identity, path-receipt, namespace,
   and final-recapture rules.
3. Section 7 replaces R9 section 5's A3–A6 materialization portion and defines
   the exact root-relative directory-path digest. R9's A0–A2 and A7–A8
   reservation/abort edges remain except where section 7 names their successor.
4. Section 8 replaces R9 section 6's abort **actual-charge** claims and the
   corresponding R15 fixtures. The 393,216-byte admission envelope remains.

Every other R4–R9 correction remains mandatory: the sole `genesis-v2` base
transition; target-local inductive retirement successors; full graph validation
only at genesis and the two named phase transitions; the global allocating-intent
gate; exact allocation-generation equality; primary-first origin/class/lineage
publication; same-owner stabilization; queued-cancel and rollback protection;
frozen finalizing membership; content-addressed install, settlement, retirement,
and abort lineage; strict direct paths and decoders; the actual-prior-binary
fence; no global publication gate; no wrapper bypass; no deletion of retained
authority; and real-death recovery.

The current merged source baseline is `origin/main` commit
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The exact
`914f7caf..1d2c930b` comparison was inspected. It contains BYOM v0.2 slices 3
and 4, including `BYOMArtifactDigest.swift`, SPEC-010 v1.8, and coordinator
admission binding. It contains no byte change to
`ModelCatalogTransactionRetention.swift`,
`ModelCatalogTransactionEvidence.swift`,
`ModelCatalogTransactionReservationMigration.swift`, or
`ModelCatalogTransactionStorage.swift`; therefore no separate reconciliation
plan precedes R10. The new GGUF path uses descriptor `fstat` before/after and a
final pathname re-resolution. R10 deliberately requires the stronger
device/inode/size/mode/owner/link/mtime/**ctime** witness below. The BYOM digest
cache is outside the transaction root, is advisory by its own contract, and is
never an activation, checkpoint, source-body, or genesis authority.

All inherited limits remain unchanged: eight seconds per invocation with no
nested renewal; soft FD limit 256; at most four simultaneously live reservation
descriptors; ten ordinary direct reads/decodes; 3,383,296 ordinary reservation
authority bytes; 1,024 selected rows; 1 MiB inherited documents; 65,536-byte
tree pages; 16,384-byte roots and abort receipts; the existing quota formula;
and the 536,870,912-byte free-space floor. No dependency is added.

## 2. Selected pre-genesis authority

### 2.1 Direct paths and safe opens

The pre-genesis control paths are exactly:

```text
.reservation-migration/retirement/v1/activation.lock
.reservation-migration/retirement/v1/activation/<activationUUID>/active.json
.reservation-migration/retirement/v1/activation/<activationUUID>/objects/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/checkpoints/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/path-receipts/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/names/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/rows/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/runs/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/run-roots/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/tree-roots/<sha256>.json
.reservation-migration/retirement/v1/activation/<activationUUID>/verification/<sha256>.json
```

All components are opened relative to the component-by-component no-follow
transaction-root resolution in section 6. A digest filename is lowercase and
must equal SHA-256 of the canonical bytes. The activation object, checkpoint,
path receipt, name/row/run/work objects, and selector are each at most 1 MiB;
`active.json` is additionally required to fit 16,384 bytes.

The lock is opened with
`openat(rootFD, path, O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0600)`. On first
creation the file and containing directory are fsynced before use. `fstat`
must show one regular link, owner UID equal to the effective UID, no group/other
permission, no ACL, and the exact device/inode/mode/owner/group/link identity
frozen in the format fence below. Every later invocation requires the same path
and identity before `flock(fd, LOCK_EX|LOCK_NB)`. Replacement of the lock path
is protected; an old detached locked inode never permits a second activation.
The FD and flock live for one invocation only.

### 2.2 Mandatory format fence

The one-time prior-binary fence selects closed
`model_catalog_retention.v4` at the existing direct `.retention-v2/format.json`
path. Its canonical limit remains 4,096 bytes. It contains exactly:

```text
schema
reservationMigrationID
reservationSourceSHA256
retirementActivationUUID
retirementActivationSelectorRelativePath
retirementActivationSelectorPathSHA256
retirementActivationLockIdentity
```

The selector relative path is exactly
`.reservation-migration/retirement/v1/activation/<activationUUID>/active.json`.
Its digest uses section 7.1. The lock identity contains exactly `deviceID`,
`fileID`, `fileType: "regular"`, `mode`, `ownerUID`, `groupGID`, and
`linkCount`. All fields are present and non-null. The SHA-256 of the exact v4
format bytes is `formatFenceSHA256` in every activation record.

The format delegates current pre-genesis selection to that one direct selector
path. This is the missing authority edge: the selector is not detached, and the
future v2 projection is not written early. Every compatible transaction-root
mutation route first decodes the v4 format, safe-opens the frozen lock path,
reads the direct selector and selected objects, and rejects before mutation
unless section 3.3 proves genesis selected. Heartbeat, status, and read-only
control remain available without the activation flock.

Before selecting v4, the implementation runs the actual supported prior binary
against an exact fixture and proves it rejects the unknown mandatory format
before write. The one-time bootstrap publication order is:

1. under the journal lock, create/validate/fsync the activation lock and
   activation directories, then release the journal lock while retaining only
   this invocation's activation flock;
2. capture the prior index/source/fence inputs and write/fsync the canonical
   generation-zero checkpoint and activation object at their digest paths;
3. write/fsync/rename/fsync the generation-zero `active.json` selector; it is
   still unselected because the v4 format is absent;
4. take the journal lock, revalidate the exact old format/index/source,
   selector bytes, lock identity, and absence of any competing activation;
5. write/fsync/rename `format.json`, fsync `.retention-v2`, and return.

Death before step 5 leaves the old graph and only unselected equal-reusable
objects. Death after the v4 rename selects exactly generation zero. The
one-time bootstrap is the only journal-lock-before-activation-lock ordering;
no selected activation exists then, so it cannot deadlock. Every later call
acquires the activation flock before the journal lock.

## 3. Activation objects, selector, and genesis

### 3.1 Closed schemas

Schema `model_catalog_retirement_v1_activation_selector.v1` contains exactly:

```text
schema, activationUUID, selectedActivationGeneration,
selectedActivationSHA256, selectedCheckpointSHA256, state,
priorActiveIndexSHA256, migrationSourceSHA256, formatFenceSHA256
```

Schema `model_catalog_retirement_v1_activation.v2` contains exactly:

```text
schema, activationUUID, activationGeneration, previousActivationSHA256,
state, priorActiveIndexSHA256, migrationSourceSHA256, formatFenceSHA256,
configuredRootPathSHA256, initialPathReceiptSHA256,
nameCaptureRootSHA256, rowCaptureRootSHA256, sortedRunSHA256,
treeWorkRootSHA256, verificationRootSHA256, currentCheckpointSHA256
```

`state` is exactly `capturing_names`, `capturing_rows`, `merging`, `building`,
`verifying`, or `ready`. Every field is present. Generation, previous link, and
`currentCheckpointSHA256` are progress authority. They necessarily change in a
successor. The five terminal result fields from `nameCaptureRootSHA256` through
`verificationRootSHA256` and `initialPathReceiptSHA256` are monotonic: null
until their phase completes, then non-null and byte-equal in every successor.
No rule treats a mutable progress pointer as an immutable terminal result.

Generation zero is legal and exact: state `capturing_names`; generation `0`;
`previousActivationSHA256`, `initialPathReceiptSHA256`, and all five terminal
results null; `currentCheckpointSHA256` non-null and naming checkpoint zero.
The selector, activation, and checkpoint repeat the same UUID, generation,
state, frozen inputs, and checkpoint digest.

### 3.2 Joint generation and selector CAS

Every selected successor increments activation and checkpoint generation by
exactly one. The activation object's previous digest names the selected prior
activation, and the checkpoint's previous digest names the selected prior
checkpoint. State either remains in the current phase or advances exactly one
phase. A phase advance fills its just-completed terminal result and initializes
the next phase's progress fields in the same checkpoint. No generation skip,
alternate predecessor, backward phase, cleared terminal result, or changed
frozen binding is legal.

One invocation performs at most one bounded successor:

1. acquire the activation flock and capture the exact v4 format, direct
   selector, selected activation, and selected checkpoint;
2. perform bulk reads and create/fsync all content-addressed work outside the
   journal lock;
3. write/fsync the successor checkpoint, then successor activation object, at
   their digest paths and fsync their containing directories;
4. prepare canonical successor selector bytes in the selector directory;
5. take the journal lock; re-resolve the transaction root; recapture the v4
   format, prior selector bytes, prior active index/source, lock identity, and
   every bounded CAS witness required by the phase;
6. require all captured bytes/digests unchanged, rename the prepared selector
   over `active.json`, fsync the selector directory, and return.

The direct selector rename is the only pre-genesis selection point after
bootstrap. A crash before rename selects the old pair. A crash after rename,
including before directory fsync, may leave old or candidate bytes after reboot;
recovery accepts only one complete canonical selector whose object/checkpoint
graph validates and continues from that graph. It never selects the highest
generation or an unreferenced object. Tests freeze the exact old, candidate,
and new bytes at write, file-fsync, rename, and directory-fsync boundaries.

### 3.3 Genesis remains the sole base transition

R7's active index is still `model_catalog_active_index.v5`, and its selected
projection is still `model_catalog_reservation_state_projection.v2`. Their
closed schemas each gain exactly these non-null genesis fields:

```text
retirementActivationUUID
retirementActivationSelectorSHA256
retirementActivationSHA256
retirementActivationCheckpointSHA256
retirementActivationFormatFenceSHA256
```

R7 section 2.1 is amended only to permit those fields in `genesis-v2`; its
inductive transition table is unchanged and remains exhaustive. No pre-genesis
selector generation is an active-index/projection transition. `ready` is the
terminal pre-genesis selector and is never updated after genesis.

The final invocation derives canonical v2 projection and v5 index bytes that
bind the exact ready selector bytes, ready activation object, ready checkpoint,
and v4 format. Under the journal lock it performs section 6's final second
witness recapture, writes/fsyncs/renames/fsyncs the inactive projection slot,
then selects the v5 index. If the index is pre-v5, the v4 format keeps all
mutation routes fenced. If v5 is selected, genesis has occurred only when its
projection and all five activation bindings match the still-direct ready
selector graph. Thus a crash before index selection is pre-genesis; a crash
after it is the one valid `genesis-v2` base case. No post-genesis format or
selector rewrite is needed.

## 4. Checkpoints and phase nullability

Checkpoint schema `model_catalog_retirement_v1_checkpoint.v3` contains exactly:

```text
schema, activationUUID, checkpointGeneration, previousCheckpointSHA256,
activationState, priorActiveIndexSHA256, migrationSourceSHA256,
formatFenceSHA256, configuredRootPathSHA256,
initialPathReceiptSHA256, latestPathReceiptSHA256,
nameCaptureRootSHA256, rowCaptureRootSHA256, sortedRunSHA256,
treeWorkRootSHA256, verificationRootSHA256,
currentRowWorkRootSHA256, currentRunWorkRootSHA256,
currentTreeBuildRootSHA256, currentVerificationWorkRootSHA256,
nextNameOrdinal, nextRowBlockOrdinal, mergePass, nextMergeGroupOrdinal,
nextCreationOrdinal, builderLevel, nextBuilderInputOrdinal,
nextTreeObjectOrdinal, nextVerificationOrdinal, terminalRowCount
```

Every field is present and every unused field is explicit null. Generation zero
has only the frozen fields and configured-root digest non-null. Initial/latest
path receipts become non-null together when name capture completes.

| State | Required progress | Terminal result completed by exit |
|---|---|---|
| `capturing_names` | no cursor or current work root | name/path receipt, then enter `capturing_rows` at ordinal zero |
| `capturing_rows` | name root; ordinals; optional current row root only at ordinal zero | row root/count and pass-zero run root, then enter `merging` |
| `merging` | row root; current run root; pass/group/creation ordinals | one sorted run, then enter `building` |
| `building` | sorted run; current tree-build root; level/input/object ordinals | complete tree work root, then enter `verifying` |
| `verifying` | tree root; current verification root and next ordinal | terminal verification root, then enter `ready` |
| `ready` | all terminal results; no cursor | none; final recapture and genesis only |

The current progress-root field for a phase may change only by naming an
immutable successor whose previous-root digest names the old root. Once a phase
finishes, that progress root freezes. Terminal result fields never substitute
for an incomplete frontier. `latestPathReceiptSHA256` may advance to the exact
receipt produced by an invocation; `initialPathReceiptSHA256` never changes.

Nullability is closed further as follows. In `capturing_rows`, the three row
cursors are zero and `currentRowWorkRootSHA256` is null together, or all
completed work is named by a non-null row root and the cursors equal that root.
On entry to `merging`, `currentRunWorkRootSHA256` names the complete pass-zero
capture-run set. On entry to `building`, `sortedRunSHA256` is non-null and a
generation-zero tree-build root is selected. On entry to `verifying`,
`treeWorkRootSHA256` is non-null and a generation-zero verification-work root
is selected. `ready` has all five terminal results non-null, all four current
work roots frozen non-null, and every cursor null. No other combination is
legal.

## 5. Complete rooted work frontiers

All arrays below are in the stated order and counts equal array lengths.
Objects use R8 canonical JSON, strict closed decoding, explicit nulls, safe
integers, and content-addressed direct paths.

### 5.1 Name and row roots

R9's name block becomes `model_catalog_retirement_v1_name_block.v2` with the
file witnesses in section 6. A closed
`model_catalog_retirement_v1_name_capture_root.v1` contains exactly `schema`,
`activationUUID`, `pathReceiptSHA256`, `orderedNameBlockSHA256s`, `blockCount`,
`entryCount`, `firstUUID`, `lastUUID`, `namespaceSHA256`, and
`sourceWitnessSHA256`.

For zero names, both ordered arrays are empty, counts are zero, and first/last
UUID are explicit null; for a nonempty root first/last are non-null and equal
the exact extremes. Row and run roots use the same zero/nonzero boundary.

Each row block becomes `model_catalog_retirement_v1_row_block.v2` and repeats
the full source witnesses. A selected
`model_catalog_retirement_v1_row_work_root.v1` contains exactly `schema`,
`activationUUID`, `workGeneration`, `previousRowWorkRootSHA256`,
`nameCaptureRootSHA256`, `orderedRowBlockSHA256s`,
`orderedCaptureRunSHA256s`, `nextNameOrdinal`, `nextRowBlockOrdinal`,
`nextCreationOrdinal`, `rowCount`, `firstUUID`, `lastUUID`, and
`transcriptSHA256`. Every capture successor appends exactly one consecutive row
block and its capture-run manifest. The root therefore names all prior selected
row work after process death.

### 5.2 Run and merge roots

`model_catalog_retirement_v1_run_work_root.v1` contains exactly:

```text
schema, activationUUID, workGeneration, previousRunWorkRootSHA256,
sourceRowWorkRootSHA256, mergePass, inputRunSHA256s, inputRunCount,
nextMergeGroupOrdinal, completedGroups, outputRunSHA256s, outputRunCount,
nextCreationOrdinal, rowCount, firstUUID, lastUUID, transcriptSHA256
```

Pass zero names all capture runs as inputs and has no completed group. For pass
`p > 0`, inputs are the prior pass outputs ordered by
`(firstUUID, creationOrdinal, manifestSHA256)`. Groups are the consecutive
partition of that frozen array into at most 32 inputs. Each `completedGroups`
entry contains exactly `groupOrdinal`, `firstInputOrdinal`, `lastInputOrdinal`,
`inputRunSHA256s`, `creationOrdinal`, `outputRunSHA256`, `rowCount`,
`firstUUID`, and `lastUUID`. Entries and `outputRunSHA256s` are append-only in
group order. One checkpoint may add exactly one completed group or advance a
completed pass. Pass advance makes the complete prior outputs the next inputs
and resets only the new root's group/output arrays. When one input remains, its
manifest digest becomes immutable `sortedRunSHA256`. Every completed group and
every output needed by the next process is thus selected by one root.

### 5.3 Tree-build roots

`model_catalog_retirement_v1_tree_build_root.v1` contains exactly:

```text
schema, activationUUID, workGeneration, previousTreeBuildRootSHA256,
sortedRunSHA256, currentLevel, currentInputKind,
currentInputSHA256s, currentInputCount, nextInputOrdinal,
completedLevels, currentLevelPages, nextTreeObjectOrdinal,
rootEnvelopeSHA256, rowCount, firstUUID, lastUUID, transcriptSHA256
```

`currentInputKind` is `row-blocks` at level zero and `pages` above it.
`currentInputSHA256s` is the complete frozen input for that level. Each
`currentLevelPages` entry contains exactly `pageOrdinal`, `level`,
`firstInputOrdinal`, `lastInputOrdinal`, `pageSHA256`, `rowCount`, `firstUUID`,
and `lastUUID`. One generation appends one bounded consecutive page batch. A
completed level moves its exact ordered page digests into one `completedLevels`
entry containing `level`, `pageCount`, `orderedPageSHA256s`, and `rowCount`,
then initializes the next level from that array. Leaves group 64 rows; internal
pages group 256 children; the final one-child page is retained. The root
envelope is written only after the one top page is selected. No checkpoint can
name a top root while omitting a completed leaf or internal page.

### 5.4 Verification roots

`model_catalog_retirement_v1_verification_work_root.v1` contains exactly
`schema`, `activationUUID`, `workGeneration`,
`previousVerificationWorkRootSHA256`, `treeWorkRootSHA256`,
`rowCaptureRootSHA256`, `orderedVerificationBlockSHA256s`,
`nextVerificationOrdinal`, `verifiedRowCount`, `rowCount`,
`rollingVerificationSHA256`, and `complete`. One generation appends exactly one
consecutive verification block. `complete` is true only when the next ordinal
equals row count and the ordered block chain covers every row exactly once.
The digest of that complete root becomes `verificationRootSHA256`.

Every work transcript is domain-separated, includes every scalar and ordered
digest above in schema order, and is independently recomputed during decoding.
A completed group/page/block whose digest is absent from its selected root is
unselected work; a root that skips, overlaps, repeats, reorders, or names a
missing/unfsynced object is protected.

## 6. Source-file and pathname identity

### 6.1 Exact witnesses and receipts

A `model_catalog_retirement_v1_file_witness.v1` object contains exactly:

```text
relativeName, deviceID, fileID, fileType, mode, ownerUID, groupGID,
linkCount, byteLength, modifySeconds, modifyNanoseconds,
changeSeconds, changeNanoseconds
```

`fileType` is `regular`; byte length is positive and within the inherited body
limit; link count is one; nanoseconds are `0...999,999,999`. All numeric fields
are safe integers and map directly to the no-follow `stat` values. A name-block
entry contains exactly `uuid`, `certificateWitness`, and `originWitness`.
Their names are `<uuid>.retired` and the exact origin path required by the
retained graph. A row contains exactly `uuid`, `certificateSHA256`,
`originSHA256`, `certificateWitness`, and `originWitness`.

The path receipt becomes closed
`model_catalog_retirement_v1_path_receipt.v2` containing exactly `schema`,
`activationUUID`, `configuredRootPathSHA256`, `components`,
`rootNamespaceSHA256`, and `sourceWitnessSHA256`. R9's undefined `capturedAt`
field is removed from content-addressed authority. Component fields and the
absolute configured-root digest remain as R9 specified.

`sourceWitnessSHA256` is null for metadata-only receipts and otherwise is:

```text
SHA256("macprovider-retirement-v1-source-witness-v1\0" || count-u64be ||
       for each UUID in parsed-byte order:
       uuid-16bytes || canonical-certificate-witness-length-u32be ||
       canonical-certificate-witness || canonical-origin-witness-length-u32be ||
       canonical-origin-witness)
```

The namespace digest continues to prove the complete sorted direct name/type/
device/inode set. The source-witness digest separately proves size, mode,
owner, links, mtime, and ctime for every selected certificate and origin.

### 6.2 Before/after recapture

Name capture performs two complete same-invocation no-follow passes. Pass one
opens each selected certificate and origin, records descriptor `fstat`, then
requires path `fstatat(..., AT_SYMLINK_NOFOLLOW)` equality before closing it.
Pass two reopens and recaptures every selected witness. Both namespace and
source-witness digests must be byte-equal before selecting the name root.

Row capture direct-opens the selected name and requires descriptor-before equal
to the name witness; after the complete read it requires descriptor-after and
pathname-after equal to descriptor-before, including byte length, mtime, and
ctime. Only then may it select canonical body digests and the row witness.
Verification repeats the same descriptor-before/read/descriptor-after/path-after
sequence against the selected row witness and body digest.

After terminal verification, the final invocation performs one complete
metadata-only recapture outside the journal lock. Under the journal lock, as
the last validation before writing the inactive v2 slot, it performs a second
complete metadata-only recapture by direct name. Both passes must equal the
selected row witnesses, namespace digest, and each other. It then re-resolves
the complete configured path, recaptures the exact ready selector/object/
checkpoint/format/index/source, and performs genesis without releasing the
journal lock. Compatible writers cannot mutate the root during that interval.
Any same-inode write, truncate/extend, chmod/chown, link change, rename, path
replacement, or equal-byte inode replacement before or during either recapture
fails. The maximum two-pass witness fixture must fit the unchanged eight-second
caller budget and FD 256; failure blocks implementation rather than weakening
the witness or raising a limit.

## 7. Allocation materialization and exact path digest

### 7.1 Canonical root-relative path

The materialization directory string is exactly
`.reservation-migration/lineage/<proposedTransactionUUID>` with no leading or
trailing slash, empty/`.`/`..` component, backslash, NUL, invalid UTF-8, or
normalization change. It is joined only by component-wise `openat`/`mkdirat`
from the already verified transaction-root FD. Its digest is:

```text
SHA256("macprovider-root-relative-path-v1\0" ||
       utf8ByteLength-u32be || relativeUTF8Path)
```

This domain is distinct from R9's absolute configured-root-path domain. There
is no implicit base, URL normalization, symlink resolution, or string
concatenation rule.

### 7.2 Complete A3–A6 phases

The allocation admission's `materializationPhase` is exactly one of:

```text
none, row_selected, directory_intent, directory_durable,
primary_intent, primary_durable, origin_intent, origin_durable,
class_intent, class_durable, lineage_intent, lineage_durable
```

Its path digest is null through `row_selected` and otherwise equals section
7.1. Directory identity is null through `directory_intent` and non-null from
`directory_durable`. The identity has the exact R9 directory fields. Each body
intent additionally binds its already-frozen direct relative path, digest,
canonical byte length, and exact `F(length)` charge through the admission's
existing primary/origin/class/lineage fields and materialization manifest.

The states remain A0 absent, A1 reserved, A2 row-selected, A3
directory-intent, A4 directory-durable, A5 ordered body intent/durable, A6
active, A7 aborting, and A8 aborted. The exhaustive forward path is:

```text
A2 -> A3(directory_intent) -> create/fsync directory ->
A4(directory_durable) ->
A5(primary_intent) -> write/fsync primary -> A5(primary_durable) ->
A5(origin_intent)  -> write/fsync origin  -> A5(origin_durable)  ->
A5(class_intent)   -> write/fsync class   -> A5(class_durable)   ->
A5(lineage_intent) -> write/fsync lineage -> A5(lineage_durable) -> A6
```

Every intent CAS precedes its create. An intent permits exactly absent or one
byte-identical durable candidate at the named no-follow path. After exclusive
create, file fsync, and containing-directory fsync, the durable CAS reopens and
validates the exact candidate, advances only that phase, increments
`materializedChargeBytes` by the exact charge, increments selected
`materializedBytes` by the same amount, and decrements
`reservedRemainingBytes` by the same amount. Gross, refunded, charged, and
spent-slack counters do not change at these edges.

The directory charge is exactly `D = 4,096` and transfers at the A3→A4 CAS,
after directory and parent fsync. Before A4 it remains in reserved remainder;
an equal unselected directory candidate is physical/Wpeak inventory, not
selected materialized authority. At A4 the delta is exactly
`materializedChargeBytes += 4,096`, `materializedBytes += 4,096`, and
`reservedRemainingBytes -= 4,096`. No body CAS may charge the directory again.

Death after an intent, create, file/directory fsync, or before its durable CAS
therefore leaves one selected intent plus absent/equal candidate and resumes
only that suffix. A durable phase requires the exact full prefix. An unequal,
extra, wrong-path, wrong-type, replaced, symlinked, hard-linked, wrong-owner,
wrong-mode, or noncanonical candidate is protected and never deleted. A6
transfers the unmaterialized remainder of the fixed 581,632 success admission
to spent slack exactly once. Abort/refund remains legal only at A1 or A2; A3 or
later permanently forces forward completion.

## 8. Abort envelope versus reachable actual charge

The 393,216-byte value is the conservative reservation envelope for receipt,
directory, two leaf slots, three internal-page slots, and root. It is not a
reachable actual charge and is never written into `retainedAbortChargeBytes`
unless actual canonical extents sum to it, which the frozen no-padding codecs
do not permit.

For the legal maximum-field cascade, independent canonical encoding freezes:

| New object | Canonical bytes | `F(actualLength)` |
|---|---:|---:|
| abort receipt | 966 | 8,192 |
| split leaf 32 | 8,422 | 16,384 |
| split leaf 33 | 8,682 | 16,384 |
| replacement internal page 128 | 25,450 | 32,768 |
| replacement internal page 129 | 25,648 | 32,768 |
| replacement/new top, 2 or 3 children | 506 or 708 | 8,192 |
| root envelope | 346 | 8,192 |
| receipt UUID directory | n/a | 4,096 |
| **reachable maximum retained charge** | | **126,976** |

The frozen fixture uses lowercase fixed-width UUID/digest strings, legal
32/33 and 128/129 partitions, legal row counts, timestamp
`2026-09-11T00:00:00.000Z`, gross charge 581,632, actual retained charge
126,976, and refund 454,656. Distinct legal UUID ranges replace the display
placeholders without changing byte length. R16 independently freezes the exact
canonical bytes and hashes; production output is not its oracle.

The reachable actual successor maxima are:

| Shape | Reachable actual maximum |
|---|---:|
| empty/height one, no split | 45,056 |
| height one leaf split/new top | 61,440 |
| height two, no leaf split | 102,400 |
| height two, leaf split/no internal split | 110,592 |
| height two, leaf and top split/new top | 126,976 |
| height three, no leaf split | 110,592 |
| height three, leaf split/no level-one split | 118,784 |
| height three, leaf and level-one split | 126,976 |

The old envelope figures 114,688; 184,320; 253,952; 323,584; and 393,216 remain
valid conservative admission/Wpeak classes where applicable, but they are not
actual retained charges or refund inputs. The actual all-maximum 1 GiB history
is now exactly:

```text
floor(1,073,741,824 / 126,976) = 8,456, remainder 32,768
581,632 - 126,976 = 454,656 maximum-shape refund
```

The minimum remains 28,672, so the overall row bound remains 37,449 with 4,096
bytes remainder and the abort tree remains at most height three. The success
bound remains 1,846 with 49,152 remainder. Mixed feasibility remains
`S*581,632 + sum(actual Ai) <= logical headroom`. All quota equations, fixed
bundle maxima, directory charge, Wpeak rules, and capacity preflight remain
unchanged.

## 9. Acceptance and stop conditions

Migration order remains: actual-prior-binary fence proof; v4/gen-zero selection;
durable name/row/merge/build/verification generations; two final witness
recaptures; and the sole genesis-v2 publication. Readers and writers for every
new closed schema land in one unshippable implementation slice.

Emit inherited metrics plus selected format/selector/object/checkpoint digest,
joint generation, current rooted frontier, source-witness mismatch class,
allocation intent/durable phase and exact counter delta, and abort envelope
versus actual charge. Logs contain identifiers and digests, never bodies,
private source bytes, or secrets.

Stop on an unselected activation being treated as authority; pre-genesis v2
projection mutation; missing selector/lock path; circular or contradictory
bootstrap; mutable digest treated as immutable; incomplete merge group/page
frontier; checkpoint not rooted by the selector; accepted size/mtime/ctime or
path replacement; omitted before/after recapture; body creation before intent;
unclassified A4/A5 durable suffix; directory charge at any edge other than
A3→A4; relative path encoded with the absolute domain; 393,216 used as actual
retained charge; wrong 126,976/454,656/8,456 arithmetic; raised quota, deadline,
FD, row, body, or document limit; authority deletion; stale pre-`1d2c930b`
source assumptions; or a skipped, interrupted, or timed-out command reported as
passing. Physical MLX, signed release/feed, deployment, enforcement,
settlement, and economic activation remain outside this proposal.
