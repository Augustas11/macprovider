# Reservation search progress — corrective addendum R12

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R11 plan gate. Its frozen inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r11.md` | `2c0a8ac095f277331f9cd65c41217bc2fe5fba742c5c143b7576ac01ef253e8b` |
| `test-spec-r17-reservation-r11-corrections.md` | `5179135faac5a0a78124c61364b3ba17bdc4bf2ed2e74c842ca622876cf1064e` |
| `reviews/reservation-search-progress-r11-plan-sol.md` | `e408b41b5062099ec4cb17901dfcc6e462ad203bf675e87c381caaf3e5232b63` |

The independent R11 verdict was FAIL, 0 Critical / 5 High / 2 Medium / 0
Low. Sections 2 through 8 close R11-PLAN-H1 through H5 and R11-PLAN-M1/M2.
They replace R11 sections 4, 5.1–5.2, 7, and the name-scan algorithm in 5.2;
all nonconflicting R4–R11 requirements remain governing. In particular, this
revision does not raise the inherited row, file, document, page, FD, read,
eight-second, quota, or free-space bounds; weaken the two-pass source witness;
delete selected authority; change A3–A8 or abort/refund arithmetic; hold the
activation lock across work; or allow ordinary authority before genesis.

The repository/base revision for this proposal is `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. Fetch origin and reopen the plan
gate before implementation if any governed reservation, retention, evidence,
storage, migration, SPEC, or active decision-path surface changes.

## 1. Normative codec rules

All objects below are UTF-8 RFC 8785 JCS objects with no BOM or trailing byte.
Every listed field is required; unknown or duplicate fields fail before use.
`null` is legal only where the field table says so. Digests are exactly 64
lowercase hexadecimal characters and UUIDs are lowercase RFC 9562 strings.
Every JSON number is an integer in `[0, 9,007,199,254,740,991]`. Counts and
ordinals use that safe-number domain and reject overflow before write.

`wide-v1` is the only amount wider than that domain. It is a JSON object with
exact fields `schema`, `limb3`, `limb2`, `limb1`, `limb0`; `schema` is
`model_catalog_wide_uint.v1`, every limb is `[0, 4,294,967,295]`, limbs are
big-endian base `2^32`, and `limb3 <= 16,777,215`. It therefore represents
exactly `[0, 2^120-1]` without an unsafe JSON number. Leading zero limbs are
required. Addition, subtraction, comparison, multiplication by a safe count,
round-up, and conversion to filesystem `off_t` are checked operations. An
overflow, underflow, noncanonical limb, or attempt to convert a value above the
target platform limit is protected before write. `W(x)` below means this exact
object. No decimal string, float, omitted leading limb, or alternate limb base
is accepted.

Every new or version-bumped R12 object digest uses exactly
`SHA256("macprovider-json-v1\0" || u32be(schemaByteCount) || schemaASCII ||
u64be(canonicalByteCount) || canonicalBytes)`. Every R12 transcript uses the
separate domain `D = "macprovider-transcript-v1\0" ||
u32be(schemaByteCount) || schemaASCII`; `T0 = SHA256(D || "empty\0")` and
`Tn+1 = SHA256(D || "append\0" || Tn || u64be(ordinal) || entryDigest)`.
Schema strings are the literal values in this document. Existing R4–R11
objects retain their frozen domains. No schema reuses another schema's object
or transcript domain.

## 2. One selected storage authority at grandfathered scale

### 2.1 Exact bounds and wide accounting

The grandfathered source bound remains exactly `Rmax = 439,804,651,110`
rows. `Rmax + 1` is rejected by the source-charge ceiling before v4 selection.
The activation state machine additionally enforces:

```text
logical chargeable objects <= 512 * sourceRowCount + 1,048,576
canonical bytes for any one chargeable file <= 4,194,304
charge for any one file <= 4,210,688
directories per row-equivalent <= 64
total activation charged bytes <= 2^120 - 1
```

The coefficient is the sum of these conservative transition-table ceilings per
source row: adopted v1 authority 8; data/work/run/tree objects 48; sequence
pages/roots 112; path-registry pages/roots 144; phase transactions/bindings 80;
storage-catalog pages/roots 64; verification objects 32; reserve 24. The total
is exactly 512. The implementation must derive the prospective count from the
closed transition table and emit the category counters; it may not merely
compare a caller assertion. The 1,048,576 constant covers empty/bootstrap/final
objects and right-frontier rounding at every maximum height. These are
compatibility limits, not capacity claims: physical free-space and R10
`Wpeak/Uafter` admission still apply to every selected step.

At `Rmax`, the object-count upper bound is
`225,179,982,416,896`, below `2^53-1`. Multiplying it by the maximum object
charge, adding `Rmax * 696,320` lifecycle reserve, the conservative
`64 * Rmax * 4,096` directory charge, 1,073,152 finalization reserve, and the
536,870,912 free-space floor is exactly bounded above by
`948,584,186,728,694,423,552`, below `2^70` and therefore below `2^120-1`.
Thus the complete legal maximum is representable even though the
adopted certificate charge alone leaves only 8,191 bytes in the old safe-number
domain. Every selector amount, storage subtotal, quota, reserve, slack,
materialized amount, planned charge, `Wpeak`, `Uafter`, and finalization value
is `wide-v1`; no cumulative byte amount remains a JSON safe integer.

The quota equation remains semantically exact, now in wide arithmetic:

```text
quota = roundUp4096(max(W(1,073,741,824), charged + finalizationReserve))
availableCapacity >= W(536,870,912) + Wpeak + Uafter
materialized + workReserved + lifecycleReserved + spentSlack == charged
```

The selector rejects a value above the host's addressable filesystem/quota
range as a typed local qualification blocker. It does not lower `Rmax` or call
that history accepted.

### 2.2 Partitioned storage catalog with one root

R11's linear storage-root chain becomes one persistent storage catalog rooted
by the stable selector. The selector has exactly one
`activationStorageCatalogRootSHA256`; it never selects multiple independent
accounting roots. Direct paths are generation-qualified and content-bound:

```text
.../activation/<uuid>/storage/<generation>/<ordinal>-<sha256>.json
.../activation/<uuid>/storage/catalog/<sha256>.json
```

Schema `model_catalog_activation_storage_catalog_root.v1` has exactly:

```text
schema, activationUUID, catalogRevision, topPageSHA256, height,
partitionCount, entryCount, directoryCount, materializedBytes,
workReservedBytes, lifecycleReservedBytes, spentSlackBytes, chargedBytes,
quotaBytes, pathRegistryRootSHA256, fixedExtentRootSHA256,
historyAccumulatorSHA256, historyLeafCount, selfCanonicalLength,
selfChargeBytes, transcriptSHA256
```

The six byte fields are `wide-v1`; counts are safe integers. Empty has height
and counts zero and null top page. Nonempty pages form a persistent B+ tree with
leaf capacity 32 and fanout 256. A leaf schema
`model_catalog_activation_storage_partition.v1` contains exactly `schema`,
activation UUID, first/last storage ordinal, entry count, entries, the six wide
subtotals, `selfCanonicalLength`, `selfChargeBytes`, and transcript. It has
1–32 consecutive entries and no leaf subtotal may exceed `2^120-1`. An internal schema
`model_catalog_activation_storage_catalog_node.v1` contains exactly `schema`,
activation UUID, level, first/last storage ordinal, child count, children, the
same six wide subtotals, `selfCanonicalLength`, `selfChargeBytes`, and
transcript. Each child has exactly first ordinal, last ordinal, entry count, the
six wide subtotals, `selfChargeBytes`, and page digest. Partition/node
materialized and charged subtotals include their own bounded fixed-point self
charge. Nodes have
1–256 consecutive children. Interior nodes are full except the right frontier.
Height is at most eight and total entries at most the object-count bound above.
One lookup/append reads or creates at most one page per level plus the root.

`selfCanonicalLength` is the canonical root byte length and `selfChargeBytes`
is its exact `F(length)`, found by R11's bounded fixed-point encoding. The
root's materialized and charged subtotals include that self charge, so the
currently selected root is never deferred to a later generation or left
outside accounting.

Each storage entry has exactly:

```text
storageOrdinal, relativePath, pathClass, objectKind, storageClass,
objectSHA256, canonicalLength, chargeBytes, immutableIdentity, lifecycleKey
```

`canonicalLength` is a safe integer or null only for a directory/fixed extent;
`chargeBytes` is wide. `immutableIdentity` is the exact R10 full no-follow
identity for immutable files/directories and null only for a `fixed-extent`.
`lifecycleKey` is non-null only on the one lifecycle-reserve entry described in
section 6. Entries are ordered by consecutive storage ordinal, not path.
Catalog pages are chargeable protocol objects written at injective generation/
ordinal/digest paths and self-account through their fixed-point fields; they
are not recursively listed as storage entries. The successor root also
accounts itself and does not list itself as an entry. Exact new-page/root self
charges are reserved in the pending intent and become materialized in the same
selector CAS. Parent subtotals include child self charges exactly once. This
avoids a digest cycle and leaves no catalog byte for a later generation.

## 3. Mutable controls and stable selector identity

R11 selector v2 becomes
`model_catalog_retirement_v1_activation_selector.v3` with exactly:

```text
schema, selectorRevision, activationUUID,
selectedActivationGeneration, selectedActivationSHA256,
selectedCheckpointSHA256, state, priorActiveIndexSHA256,
migrationSourceSHA256, formatFenceSHA256,
activationStorageCatalogRootSHA256, fixedExtentRootSHA256,
pathRegistryRootSHA256, activationMaterializedBytes,
activationWorkReservedBytes, activationLifecycleReservedBytes,
activationSpentSlackBytes, activationChargedBytes, activationQuotaBytes,
activationHistoryAccumulatorSHA256, activationHistoryLeafCount,
activePhaseTransactionSHA256, pendingWriteIntent
```

All amount fields are `wide-v1`. Stable has explicit null intent. The active
phase transaction is null between operations and otherwise names the one split
transaction allowed by section 6. R11 revision and selected-pair monotonicity
remain exact.

R11 activation v3 becomes
`model_catalog_retirement_v1_activation.v4` with exactly:

```text
schema, activationUUID, activationGeneration, previousActivationSHA256,
state, priorActiveIndexSHA256, migrationSourceSHA256, formatFenceSHA256,
configuredRootPathSHA256, initialPathReceiptSHA256, nameCaptureRootSHA256,
rowCaptureRootSHA256, sortedRunSHA256, treeWorkRootSHA256,
verificationRootSHA256, currentCheckpointSHA256,
priorStorageCatalogRootSHA256, priorPathRegistryRootSHA256,
priorActivationHistoryAccumulatorSHA256, priorActivationHistoryLeafCount
```

R11 checkpoint v4 becomes
`model_catalog_retirement_v1_checkpoint.v5` with exactly:

```text
schema, activationUUID, checkpointGeneration, previousCheckpointSHA256,
activationState, priorActiveIndexSHA256, migrationSourceSHA256,
formatFenceSHA256, configuredRootPathSHA256,
initialPathReceiptSHA256, latestPathReceiptSHA256,
nameCaptureRootSHA256, rowCaptureRootSHA256, sortedRunSHA256,
treeWorkRootSHA256, verificationRootSHA256,
currentNameScanRootSHA256, currentNameCaptureRootSHA256,
currentRowWorkRootSHA256, currentRunWorkRootSHA256,
currentTreeBuildRootSHA256, currentVerificationWorkRootSHA256,
activePhaseTransactionSHA256, nextNameOrdinal, nextRowBlockOrdinal,
mergePass, nextMergeGroupOrdinal, nextCreationOrdinal, builderLevel,
nextBuilderInputOrdinal, nextTreeObjectOrdinal, nextVerificationOrdinal,
terminalRowCount, verificationPass, nextStorageVerificationOrdinal,
storageVerificationTranscriptSHA256,
storageVerificationTargetCatalogRootSHA256,
storageVerificationTargetEntryCount,
storageVerificationTargetMaterializedBytes,
priorStorageCatalogRootSHA256, priorPathRegistryRootSHA256,
priorActivationHistoryAccumulatorSHA256, priorActivationHistoryLeafCount
```

Every field is present. R10/R11 state-dependent explicit-null and monotonic
terminal-result rules apply; the only replacements are the exact R12 root and
phase-transaction fields. `storageVerificationTargetMaterializedBytes` is wide;
all other counters are safe integers. Candidate activation/checkpoint bind the
prior stable catalog/path/history values. Only the stable selector successor
binds the candidate catalog/path roots and appends history, preserving the
one-way, cycle-free relation.

The fixed-control inventory is replaced by
`model_catalog_activation_fixed_extent_root.v1`, with exact fields `schema`,
activation UUID, entry count, entries, and transcript. An entry has exactly
`relativePath`, `extentKind`, `maximumCanonicalLength`, `chargeBytes`,
`requiredMode`, `requiredOwnerUID`, `requiredGroupGID`, and `requiredFileType`.
It contains the direct selector, v4 format, activation lock, and their parent
directories exactly once. It represents logical reserved extents. It never
stores `deviceID`, `fileID`, ctime, mtime, or link count for a file replaced by
atomic rename. Its charge is `F(maximumCanonicalLength)` or 4,096 for a
directory and never changes across selector replacements.

Every selector CAS uses a fresh no-follow parent-directory FD and performs:

1. `fstatat(..., AT_SYMLINK_NOFOLLOW)` on the current path and safe-open/fstat;
2. require regular file, link count one, governed owner/group/mode, exact prior
   selector bytes and digest, and directory identity equal the lock-frozen root;
3. exclusive-create the prepared file in that same directory, fsync it, and
   recapture its full identity and bytes;
4. `renameat` over `active.json`, fsync the directory, reopen `active.json`
   no-follow, and require prepared identity, bytes, and digest;
5. close all descriptors before releasing journal then activation flock.

Death before rename selects the old path; death after rename may select old or
new durable bytes and recovery validates the complete selected graph. A
same-path replacement before either recapture, a different inode after rename,
hard/symbolic link, changed directory, unequal bytes, or rollback selector is
protected. The selector entry's logical fixed-extent charge remains valid
through every legal inode replacement. Bootstrap writes the fixed-extent root
before v4, but captures and validates the final selector identity only through
the live CAS procedure; it never claims that the bootstrap inode is immutable.

## 4. Bounded global path membership

Every non-protocol path is governed by one authenticated registry named by the
storage catalog root. `pathKey = SHA256("macprovider-activation-path-v1\0" ||
u32be(pathByteCount) || canonicalRootRelativeUTF8)`. Canonical paths are NFC,
use `/`, contain no empty, `.` or `..` component, are not absolute, and
re-encode byte-identically.

`model_catalog_activation_path_registry_root.v1` has exactly `schema`,
activation UUID, revision, height, entry count, top page digest, first/last key,
and transcript. Its B+ leaf has schema
`model_catalog_activation_path_registry_leaf.v1` and exact fields `schema`,
activation UUID, level zero, first/last key, entry count, and entries. Each
entry has exactly `pathKey`, `relativePath`, `pathClass`, `objectKind`,
`reservationState`, `objectSHA256`, `canonicalLength`, and `storageOrdinal`.
`reservationState` is `reserved`, `materialized`, or `bound`; digest/length/
ordinal are null only when reserved. The internal page schema
`model_catalog_activation_path_registry_node.v1` has exactly `schema`,
activation UUID, level, first/last key, child count, and children; each child is
exactly first key, last key, entry count, and page digest. Leaves hold 16;
nodes fan out 256; height is at most eight; pages are at most 65,536 bytes and
the root at most 16,384.

Lookup returns an inclusion/non-inclusion proof of root plus at most eight
pages. A batch contains one path mutation, so an update creates at most eight
pages and one root. A hash collision with unequal path bytes is protected.
`reserved -> materialized -> bound` is the only update sequence; a state cannot
be skipped or changed to a different digest/ordinal. Already bound byte-equal
authority is reused without recharge; already bound unequal authority fails.
An unselected physical equal file is not adopted until its no-follow witness is
selected through this transition.

Protocol-generated paths—the storage catalog/path-registry pages and roots,
phase-transaction objects, activation/checkpoint objects, and sequence pages—
use the injective tuple
`<activationUUID>/<selectorRevision>/<intentUUID>/<objectOrdinal>/<digest>`.
Uniqueness is proved from the stable selector revision, deterministic intent,
ordinal, and byte digest; these paths are not recursively inserted into the
registry. Reuse is legal only at the identical tuple with byte-equal content and
does not add a second storage entry. Thus every chargeable path has either a
bounded registry proof or an injective protocol-path proof. The storage catalog
records both classes, and no complete-history path walk is permitted.

## 5. Closed page, work, and phase schemas

### 5.1 Sequence envelope and entries

R11 sequence root fields remain exact. Its digest domain is
`macprovider-activation-sequence-root-v1`. The leaf schema is
`model_catalog_activation_sequence_leaf.v1` with exactly:

```text
schema, activationUUID, collectionKind, entrySchema, level,
firstOrdinal, lastOrdinal, entryCount, entries, transcriptSHA256
```

`level` is zero. The node schema is
`model_catalog_activation_sequence_node.v1` with exactly:

```text
schema, activationUUID, collectionKind, entrySchema, level,
firstOrdinal, lastOrdinal, entryCount, childCount, children,
transcriptSHA256
```

A child has exactly `firstOrdinal`, `lastOrdinal`, `entryCount`,
`pageSHA256`. Nonempty ordinal and packing rules remain R11. Null is forbidden
in pages. All three use section 1's schema-separated domains.

The allowed collection/entry pairs and exact entry fields are:

| collection | entry schema | exact fields after `schema` |
|---|---|---|
| `raw-name-block` | `activation_raw_name_block_ref.v1` | `blockOrdinal, firstDirectoryOffset, successorDirectoryOffset, recordCount, firstNameSHA256, lastNameSHA256, blockSHA256, transcriptSHA256` |
| `name-block` | `activation_name_block_ref.v1` | `blockOrdinal, nameCount, firstName, lastName, blockSHA256, transcriptSHA256` |
| `row-block` | `activation_row_block_ref.v1` | `blockOrdinal, rowCount, firstUUID, lastUUID, blockSHA256, rowsSHA256` |
| `capture-run` | `activation_run_ref.v1` | `runOrdinal, mergePass, rowCount, firstUUID, lastUUID, runSHA256, rowsSHA256` |
| `input-run` | `activation_run_ref.v1` | same as `capture-run` |
| `completed-merge-group` | `activation_merge_group_ref.v1` | `mergePass, groupOrdinal, creationOrdinal, inputCount, outputRunSHA256, rowCount, firstUUID, lastUUID, rowsSHA256` |
| `output-run` | `activation_run_ref.v1` | same as `capture-run` |
| `current-level-input` | `activation_tree_page_ref.v1` | `level, pageOrdinal, itemCount, firstUUID, lastUUID, pageSHA256, itemsSHA256` |
| `current-level-page` | `activation_tree_page_ref.v1` | same as `current-level-input` |
| `completed-level` | `activation_tree_level_ref.v1` | `level, pageCount, firstUUID, lastUUID, sequenceRootSHA256, levelSHA256` |
| `row-verification-block` | `activation_row_verification_ref.v1` | `pass, blockOrdinal, firstRowOrdinal, lastRowOrdinal, rowCount, blockSHA256, transcriptSHA256` |
| `storage-verification-block` | `activation_storage_verification_ref.v1` | `blockOrdinal, firstStorageOrdinal, lastStorageOrdinal, entryCount, blockSHA256, materializedBytes, transcriptSHA256` |

All ordinals/counts are safe integers; boundaries/digests are non-null except
first/last values are explicit null only when the referenced count is zero,
which is legal only in an empty root and never in a leaf entry. Amounts are
wide. Names are NFC strings of 1–255 UTF-8 bytes; rows remain under the inherited
1,024-byte canonical limit. Entry canonical bytes are at most 3,072. Any
unlisted pair is invalid.

### 5.2 Exact work/control schemas

Each listed object has only the exact fields below after `schema`; every digest
is non-null unless explicitly marked `?`, and every `?` field is present as
JSON null when absent.

```text
model_catalog_retirement_v1_name_scan_root.v2:
  activationUUID, directoryIdentity, attrABIProfileSHA256,
  nextDirectoryOffset, nextRecordSentinelSHA256?, rawEntryCount,
  rawNameBlockSequenceRootSHA256, eof, scanTranscriptSHA256

model_catalog_retirement_v1_name_capture_root.v2:
  activationUUID, previousRootSHA256?, nameScanRootSHA256,
  rawNameBlockSequenceRootSHA256, nameBlockSequenceRootSHA256,
  sortWorkRootSHA256?, nameCount, firstName?, lastName?, namesSHA256

model_catalog_retirement_v1_row_work_root.v2:
  activationUUID, previousRootSHA256?, nameBlockSequenceRootSHA256,
  rowBlockSequenceRootSHA256, captureRunSequenceRootSHA256,
  nextNameBlockOrdinal, nextNameOrdinal, rowCount,
  firstUUID?, lastUUID?, rowsSHA256

model_catalog_retirement_v1_run_work_root.v2:
  activationUUID, previousRootSHA256?, mergePass, nextGroupOrdinal,
  nextCreationOrdinal, inputRunSequenceRootSHA256,
  completedMergeGroupSequenceRootSHA256, outputRunSequenceRootSHA256,
  activeMergeGroupWorkSHA256?, phaseTransactionRootSHA256?,
  inputRunCount, completedGroupCount, outputRunCount, mergeTranscriptSHA256

model_catalog_retirement_v1_merge_group_work.v2:
  activationUUID, mergePass, groupOrdinal, creationOrdinal,
  inputRunSequenceRootSHA256, inputFirstOrdinal, inputCount,
  cursorSequenceRootSHA256, headSequenceRootSHA256,
  outputRowBlockSequenceRootSHA256, outputRowCount,
  firstUUID?, lastUUID?, predecessorUUID?, exhaustedInputCount,
  rollingTranscriptSHA256

model_catalog_retirement_v1_run_manifest.v3:
  activationUUID, runKind, mergePass, runOrdinal, creationOrdinal,
  inputRunSequenceRootSHA256, inputRunCount,
  rowBlockSequenceRootSHA256, rowBlockCount, rowCount,
  firstUUID?, lastUUID?, rowsSHA256

model_catalog_retirement_v1_tree_build_root.v3:
  activationUUID, previousRootSHA256?, level, phase,
  currentLevelInputSequenceRootSHA256, currentLevelPageSequenceRootSHA256,
  completedLevelSequenceRootSHA256, nextInputBlockOrdinal?,
  nextInputRowOrdinal?, nextGlobalRowOrdinal?, nextInputPageOrdinal?,
  nextTreeObjectOrdinal, phaseTransactionRootSHA256?, treeTranscriptSHA256

model_catalog_retirement_v1_verification_work_root.v2:
  activationUUID, previousRootSHA256?, pass,
  rowVerificationBlockSequenceRootSHA256,
  storageVerificationBlockSequenceRootSHA256,
  nextRowOrdinal, nextStorageOrdinal, targetStorageCatalogRootSHA256,
  targetEntryCount, targetMaterializedBytes,
  rowTranscriptSHA256, storageTranscriptSHA256,
  phaseTransactionRootSHA256?

model_catalog_retirement_v1_phase_transaction.v1:
  activationUUID, transactionUUID, operationKind, operationOrdinal,
  baseActivationSHA256, baseCheckpointSHA256, baseSelectorSHA256,
  baseStorageCatalogRootSHA256, basePathRegistryRootSHA256,
  targetBindingsSHA256, plannedObjectSequenceRootSHA256,
  nextRegistrationOrdinal, nextMaterializationOrdinal, nextBindingOrdinal,
  state, preparedBindingSequenceRootSHA256, transactionTranscriptSHA256
```

Enums are closed: `runKind = empty|capture|merge`; tree `phase = level-zero|
higher-level|level-close|root-close`; verification `pass = rows-1|rows-2|
storage|storage-close`; phase transaction `state = registering|materializing|
binding|committing|complete`; and `operationKind = scan-block|sort-step|
capture-block|merge-step|merge-close|tree-page|tree-level-close|tree-root-close|
verification-block|verification-close|genesis-control|adopt-row`.

Cursor and head collections use the same sequence envelope. Cursor entry
`activation_merge_cursor.v1` has exactly `schema, inputOrdinal,
rowBlockOrdinal, rowOrdinal, exhausted`; head entry
`activation_merge_head.v1` has exactly `schema, inputOrdinal, exhausted,
rowCanonicalBytes, rowSHA256`, where bytes/digest are both null iff exhausted.
Planned-object entry `activation_planned_object.v1` has exactly `schema,
objectOrdinal, relativePath, pathClass, objectKind, canonicalLength,
objectSHA256, chargeBytes`; prepared-binding entry
`activation_prepared_binding.v1` has exactly `schema, bindingOrdinal,
bindingKind, targetField, objectSHA256, storageOrdinal`. These four collection
kinds and entry schemas are added to the allowed table. Their domains use the
exact section 1 construction.

Empty sequence/run/tree/verification objects use these same schemas and exact
zero/null rules. There is no alternate “empty object,” implicit collection,
flat array, or prose-only manifest.

## 6. Split intents and normative lifecycle reserve

### 6.1 Phase transaction protocol and capacity

R11's 16-entry intent ceiling remains. A logical phase operation first selects
one `phase_transaction.v1` from the current selector. Its target binding digest
commits every intended sequence successor, work root, checkpoint, activation,
and phase change. It then advances through these separately recoverable edges:

1. **Register:** one planned non-protocol path changes the path registry to
   `reserved`. The intent contains at most eight registry pages, one registry
   root, one phase-transaction successor, one storage partition/catalog page per
   affected level spread over continuation edges, and never more than 16 total.
2. **Materialize:** one planned object is exclusive-created or exact-adopted,
   fsynced, and changes its registry entry to `materialized`. The selected intent
   contains that object, one phase-transaction successor, and only the bounded
   storage-catalog continuation for that edge.
3. **Bind:** one prepared binding changes the registry entry to `bound` and
   appends its binding record. A bound object is independently useful because
   the selected phase transaction fixes its only possible target; ordinary
   phase authority still references the old roots.
4. **Commit:** after every planned object is bound, separate successors select
   at most one sequence-root change, then at most one work-root change, then the
   checkpoint and activation pair. Only the final pair advances product phase
   authority and marks the transaction complete.

Where a B+ update needs more catalog pages than remain in an intent, an
`activation_catalog_continuation.v1` object with exact fields `schema`,
activation UUID, transaction UUID, mutation kind, base root digest, target key/
ordinal, next level, child digest, accumulated page-sequence-root digest, and
transcript is selected. Each continuation edge creates at most eight pages;
the old catalog/root remains authoritative until the final bounded root edge.
The continuation is rooted by the phase transaction and charged. It cannot be
used by ordinary reads or phase completion.

No edge appends two sequences. Maximum sequence append is eight right-edge
pages plus one sequence root. Adding one phase-transaction successor, one
prepared binding, one storage continuation, and selector temporary requires at
most 12 permanent entries (the mutable selector temporary is `Wpeak`, not an
entry). Maximum checkpoint/activation commit requires four. Maximum registry or
storage-catalog continuation requires 12. These are the exact worst legal
transition classes; 13–16 remain reserved for fixed final-control cases. A
phase transition that cannot be expressed through these edges is invalid,
rather than widening an intent or publishing half of a phase.

`pendingWriteIntent.v2` has exactly:

```text
intentUUID, intentKind, phaseTransactionSHA256, intentStep,
candidateSelectorRevision, candidateStorageCatalogRootSHA256,
candidatePathRegistryRootSHA256, entries, plannedChargeBytes,
lifecycleReserveDeltaBytes, lifecycleKey?, expectedPriorSelectorSHA256,
expectedPriorStorageCatalogRootSHA256, expectedPriorPathRegistryRootSHA256,
wpeakBytes, uafterBytes
```

All amounts are wide. `intentStep` is `register|materialize|bind|commit|
catalog-continuation|genesis-control`. Entries are 1–16 and byte-equal to the
new storage catalog entries. Stable-to-intent and intent-to-stable equations
remain R11 in wide arithmetic. A helper resumes exact intent bytes; replay
cannot double-charge or double-advance a registry/transaction state.

### 6.2 Lifecycle reserve derivation

`lifecycleReserveDeltaBytes` is never caller input. It is derived by the codec
from `operationKind`, selected source-row provenance, lifecycle key, and prior
path-registry inclusion proof:

| selected operation/source provenance | required delta | lifecycle key |
|---|---:|---|
| activation-created work/control, historical completed/retired/non-primary row | 0 | null |
| adopted active primary with selected complete class | 581,632 | `SHA256("macprovider-lifecycle-v2\0" || rowUUID || "classified")` |
| adopted active primary without selected complete class | 696,320 | `SHA256("macprovider-lifecycle-v2\0" || rowUUID || "unclassified")` |
| later allocation admission | 581,632 | existing allocation reservation ID under R8–R10 |

The older R7 values 352,256 and 466,944 are superseded by R8/R9 and are never
legal deltas. A nonzero activation delta occurs only on the one `adopt-row`
materialization edge that changes its lifecycle-key registry entry from
reserved to bound. Existing inclusion in any state, an alternate provenance,
or a second delta for the row fails. At genesis, the exact bound lifecycle key
and amount are imported into the v2 row/lifecycle reservation and the aggregate
`lifecycleReservedBytes`; no new reserve is added. Later completion/retirement
consumes that already charged reserve under R8–R10 and never decrements charged
bytes. Zero-delta operations cannot carry a key.

## 7. Exact `getattrlistbulk` cursor algorithm

The supported ABI profile is frozen in
`model_catalog_getattrlistbulk_profile.v1` with exactly:

```text
schema, osBuild, filesystemType, filesystemSubtype, volumeUUID,
attrBitmapCount, commonAttributes, volumeAttributes, directoryAttributes,
fileAttributes, forkAttributes, options, recordAlignment,
minimumRecordBytes, maximumRecordBytes, batchBufferBytes,
lookaheadBufferBytes, lookaheadRecordBound
```

Strings are nonempty NFC UTF-8 except filesystem subtype may be empty;
`volumeUUID` is lowercase canonical, and every bitmap/size/bound is a safe
integer. Production uses:

```text
bitmapcount = ATTR_BIT_MAP_COUNT
commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJID |
             ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME |
             ATTR_CMN_CHGTIME
volattr = dirattr = fileattr = forkattr = 0
options = FSOPT_NOFOLLOW
recordAlignment = 4
```

Startup qualification derives `minimumRecordBytes` and
`maximumRecordBytes` from the compiled ABI layout and the governed 255-byte
name maximum, then verifies them against actual returned records. Both are
positive multiples of four and every returned `length` lies in that interval.
`batchBufferBytes = 32 * minimumRecordBytes`; therefore a batch syscall can
return at most 32 records. `lookaheadBufferBytes = maximumRecordBytes`; it can
return at most `floor(maximumRecordBytes/minimumRecordBytes)` records, an exact
profile field `lookaheadRecordBound`; only its first record is parsed and the
descriptor is rewound, so none is selected. A record larger than the frozen
maximum, malformed `attrreference`, missing requested returned-attribute bit,
or `ERANGE` blocks the profile before v4.

An invocation opens the frozen directory with no follow and verifies its full
identity/time witness. `nextDirectoryOffset` is an opaque nonnegative `off_t`
encoded as a safe integer and must round-trip exactly through `off_t`; EOF uses
the last valid offset, not `-1`.

1. `lseek(fd, selectedOffset, SEEK_SET)` must return `selectedOffset`.
2. Record `batchBefore = lseek(fd, 0, SEEK_CUR)` and require equality.
3. Call `getattrlistbulk` once with the batch buffer. Parse all `n` records,
   `0 <= n <= 32`, in returned order. If a selected sentinel is non-null, the
   first record digest must equal it; a null sentinel is legal only at offset
   zero or selected EOF.
4. Record `batchAfter = lseek(fd, 0, SEEK_CUR)`. `n > 0` requires
   `batchAfter != batchBefore`; every record is included in the candidate raw
   block. No returned record is discarded.
5. If `n == 0`, call once again with the same batch buffer. A second zero with
   unchanged offset is EOF; any record/error/offset change is unsupported.
6. For non-EOF, call `getattrlistbulk` with the lookahead buffer from
   `batchAfter`. It must return at least one and at most the frozen lookahead
   bound. Hash only the first canonical record as the successor sentinel.
   Immediately `lseek(fd, batchAfter, SEEK_SET)`, require exact return, and
   require `lseek(fd,0,SEEK_CUR) == batchAfter`. The remaining lookahead records
   are intentionally unselected and remain reachable because of this rewind.
7. Reverify directory witness, close the FD, and select one successor containing
   `nextDirectoryOffset = batchAfter`, sentinel or null at EOF, raw block for
   all batch records, and the folded transcript.

Death after the batch syscall, offset capture, lookahead syscall, rewind, close,
or before selector CAS leaves the old selected offset. A fresh FD repeats the
same bytes or rejects the directory witness/sentinel. Death after CAS resumes
at `batchAfter`. `EINVAL`, `EIO`, `ESTALE`, `ENOTSUP`, offset overflow, nonmoving
non-EOF offset, or inability to rewind is typed unsupported/protected; no
lexical rescan or held FD fallback exists. The startup qualification runs exact
32/33 mixed minimum/maximum records and child death at every step on the actual
volume. The batch, lookahead, two witness checks, and close must fit the same
eight-second invocation and four-FD ceiling.

## 8. Compatibility, implementation order, and stop gate

Implementation remains one unshippable compatibility slice. The order is:

1. independent wide, page, registry, work, transaction, and cursor codecs plus
   frozen vectors;
2. bootstrap/fixed-extent and selector live-identity CAS;
3. single-root storage catalog, path proofs, and split phase transaction engine;
4. exact name scan and all bounded phase operations;
5. incremental source/storage verification and sole genesis import;
6. exhaustive crash, mutation, maximum-shape, compatibility, CLI/app, Swift,
   Xcode, governance, then independent code/security/architecture audits.

The prior binary must reject v4 before mutation. The new binary supports only
forward completion after v4 and retains all selected objects. Observability adds
wide amounts as four limbs plus decimal presentation derived for humans,
storage/path root revisions, phase transaction step/ordinal, intent entry count,
directory batch offsets/record counts/lookahead bound, and protected reason.
Logs never contain source bodies, names beyond existing sanitized policy, or
secrets.

Stop on any unsafe numeric field; multiple selected accounting roots; a row-max
cost outside wide capacity; mutable-selector inode in immutable inventory;
unbounded path walk; unproved duplicate path; incomplete schema or codec;
intent above 16; two sequence mutations in one edge; unrooted intermediate;
caller-chosen lifecycle delta; accepted 352,256/466,944 reserve; discarded
directory record; unrewound lookahead; raised deadline/FD/body/page/quota limit;
weak source witness; selected-authority deletion; changed A3–A8/abort arithmetic;
stale base; or historical, skipped, timed-out, zero-selected, or fixture-only
evidence called passing. Physical MLX, signed release/feed, deployed services,
production enforcement, settlement activation, and economic activation remain
outside this corrective plan.
