# Reservation search progress — corrective addendum R13

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R12 plan gate. Its frozen inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r12.md` | `8ad7d3780b58177afb62383a46cc4be97d6c400cb6d57a91bd2241d6f1648375` |
| `test-spec-r18-reservation-r12-corrections.md` | `5924589af7ed8d41fe94bbd0189ed030524594a9a7dd8d79a7c57dd43bc6a459` |
| `reviews/reservation-search-progress-r12-plan-sol.md` | `58110df61aadb1cd5511cc10ab5a4c3d698c9bf731a5f63b5323f79c07872b37` |

The independent R12 verdict was FAIL, 0 Critical / 8 High / 1 Medium / 0
Low. Sections 2 through 9 close R12-PLAN-H1 through H8 and R12-PLAN-M1.
They replace R12 sections 2.2, 3, 4, 5, 6.1, 7, and all R12 statements
that make catalog pages separate files, put a phase-transaction digest in its
targets, use a class-qualified lifecycle key, or permit an old selector after a
successful selector-directory fsync. R12 section 1 and 2.1 remain governing
except where this addendum gives a narrower or differently named exact schema.
All nonconflicting R4–R12 requirements remain governing, including the source
and path witness, A3–A8 and abort/refund arithmetic, four-FD and eight-second
limits, 16-entry intent cap, no selected-authority deletion, no caller-selected
lifecycle charge, and no ordinary authority before genesis.

The repository/base revision for this proposal is `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. Fetch origin and reopen the plan
gate before implementation if a governed reservation, retention, evidence,
storage, migration, SPEC, or active decision-path surface changes.

## 1. Design decision and invariants

R13 uses one append-only catalog-log file per activation. The stable selector
selects an exact durable prefix and three authenticated B+ tree roots inside
that prefix: storage ordinal, canonical path, and lifecycle identity. Every
prior catalog generation remains in the same selected prefix. Its bytes are
therefore retained, named by the prefix transcript, and charged once as part of
that one file. Catalog pages are framed records, not recursively cataloged
files. This removes R12's unbounded metadata-generation inventory and
self-charge recursion.

The only mutable paths are the selector and the append-only catalog log. The
selector remains a fixed logical extent. The log has one inode for an
activation, may grow only by append while the activation flock is held, and
may be truncated only to the stable selector's length while recovering a
selected pending transaction. No selected byte can be overwritten, punched
out, or truncated. Every other protocol object is a catalog-log record or an
immutable, no-follow external object selected through the path and storage
indexes.

The following remain hard limits:

```text
catalog page canonical bytes                 <= 65,536
catalog record payload canonical bytes       <= 65,536
records or external objects per write intent <= 16
selected B+ tree page reads per lookup       <= 8
open FDs per invocation                      <= 4
one invocation                               <= 8 seconds
source rows                                  <= 439,804,651,110
scale-dependent protocol units               <= 768 * sourceRowCount
fixed/bootstrap/final protocol units         <= 1,048,576
all cumulative byte amounts                  <= 2^120 - 1
```

An implementation rejects before mutation if its preflight cannot prove all
limits for the selected source. It does not lower the advertised history bound
silently, discard old log generations, or call a host incapable of materializing
the required quota compatible.

## 2. Exact catalog log and retained-generation accounting

### 2.1 File and frame format

The log path is exactly
`.reservation-migration/retirement/v1/activation/<activationUUID>/catalog.log`.
It is created under the journal lock before v4 publication, mode `0600`, owner
and group equal the provider process, regular, link count one, no ACL, and
opened no-follow. The first record is the header. Every record occupies one
exact 65,572-byte slot at `recordOrdinal * 65,572` and is:

```text
u32be(canonicalByteCount) || canonicalJCSBytes || SHA256(canonicalJCSBytes) ||
zero padding through the end of the 65,572-byte slot
```

`canonicalByteCount` is in `[2, 65,536]`; 65,572 is exactly
`4 + 65,536 + 32`. Header ordinal is zero and later ordinals are consecutive.
The selected file length is exactly `selectedRecordCount * 65,572` in checked
wide arithmetic. A parser
rejects a nonzero padding byte, truncated frame, length outside the bound,
digest mismatch, duplicate/unknown JSON field, non-JCS bytes, wrong record
ordinal, or record whose end exceeds the selected prefix.

Header schema `model_catalog_activation_catalog_log_header.v1` has exactly:

```text
schema, activationUUID, formatVersion, recordCodec, pageLimitBytes,
recordLimitBytes, recordSlotBytes, storageLeafCapacity, storageNodeFanout,
pathLeafCapacity, pathNodeFanout, lifecycleLeafCapacity,
lifecycleNodeFanout, sequenceLeafCapacity, sequenceNodeFanout
```

The literal values are `formatVersion = 1`, `recordCodec = jcs-slot-v1`, both
limits `65536`, slot bytes `65572`, storage `64/128`, path `16/128`, lifecycle `64/128`, and sequence
`16/128`. No other profile is accepted by v4.

Every record after the header has `recordOrdinal` as its first logical field
and a schema-specific body. Record ordinals are consecutive safe integers.
The selected transcript is:

```text
C0 = SHA256("macprovider-catalog-log-v1\0" || headerRecordDigest)
Cn+1 = SHA256("macprovider-catalog-log-v1\0append\0" ||
              Cn || u64be(recordOrdinal) || recordDigest)
```

The selector contains `catalogLogSelectedLengthBytes` as `wide-v1`,
`catalogLogSelectedRecordCount` as a safe integer, and
`catalogLogTranscriptSHA256`. A stable selector requires file size exactly the
selected length. A pending selector permits only the exact tail bounds and
base transcript in its pending transaction. Selected length is converted to
`off_t` with checked conversion before I/O; an unrepresentable value is a
local qualification blocker.

The selected log identity has exactly:

```text
deviceID, fileID, fileType, byteLength, mode, ownerUID, groupGID, linkCount,
mtimeSeconds, mtimeNanoseconds, ctimeSeconds, ctimeNanoseconds
```

`catalogLogIdentity` is schema `model_catalog_catalog_log_identity.v1` with
`schema` plus exactly those fields. For storage/path entries,
`immutableIdentitySHA256` is the R12 domain-separated object digest of schema
`model_catalog_immutable_identity.v2`, which has `schema` plus those same
fields and exact additional fields `contentSHA256,relativePathSHA256`.
Directories set content digest null; regular immutable files require both
digests. No identity digest is a hash of a prose concatenation.

All values are nonnegative safe integers except `fileType` is the literal
`regular`. Immediately before append, after append+file-fsync, and after the
selector-directory fsync, production reopens the path no-follow and recaptures
all fields. Device/inode/mode/owner/group/link must not change. Size must equal
the selected or proposed length. Both times must equal the transaction's
captured post-fsync identity. A same-size rewrite, restored mtime, changed
ctime, inode replacement, link, short tail, or excess tail is protected.

### 2.2 One charge for every retained generation

The catalog log is one chargeable file. Its exact charge is `F(selectedLength)`
under the inherited R10 function. The selector has
`catalogLogChargeBytes = W(F(selectedLength))`. This value participates once in
`activationMaterializedBytes` and `activationChargedBytes`; no page or root
record adds a separate filesystem-file charge. Record-byte budgets remain part
of preflight and `Wpeak`, but never double-charge the same log allocation.

Every successful edge appends its page and receipt records, fsyncs the log,
then selects the longer prefix. Superseded pages and roots remain inside that
prefix. Their record ordinal/digest contributes to the selected transcript,
and their physical bytes contribute to the selected length and file charge.
They are neither live tree nodes nor collectible. A current tree subtotal
contains only live inventory entries; the selector's separate log charge
accounts all current and superseded catalog metadata. Thus child subtotal
equality and retained-generation accounting are simultaneously true.

At recovery, current root pages are verified on bounded reads. Historical
pages need not be walked because they grant no current authority; the selected
prefix identity and transcript continuation were verified when each edge was
selected. The two storage-verification passes additionally fold the exact log
identity, selected length, record count, transcript, and charge. Any change to
a selected historical byte changes the log identity witness and blocks before
ordinary authority.

## 3. Feasible authenticated indexes and exact page geometry

All page references have exactly:

```text
pageRecordOrdinal, pageCanonicalLength, pageSHA256
```

Ordinal and length are safe integers; length is in `[2,65536]`; digest is 64
lowercase hex. A read calculates `recordOrdinal * 65,572` in wide arithmetic,
performs checked `off_t` conversion, uses one `pread` for the slot, and verifies
padding, length, digest, schema, activation UUID, range, level, and transcript.
Root references add exactly `height` and `entryCount`. Empty roots
have height/count zero and null page reference; nonempty height is `[1,8]`.

Every non-page catalog-log link uses an exact `recordReference` object with
fields `recordOrdinal,recordCanonicalLength,recordSHA256`. It is read directly
from the ordinal's fixed slot and verified like a page. A field ending
`Reference` below contains this object unless explicitly called a root/page/
sequence reference. No digest-only catalog-log link is legal; SHA-only fields
refer external bytes or transcript values.

Every page uses R12 section 1's object digest domain. Page transcripts append
entry digests or child canonical-object digests in array order. For any nested
item, `itemDigest = SHA256("macprovider-page-item-v1\0" ||
u32be(parentSchemaByteCount) || parentSchemaASCII ||
u64be(itemCanonicalByteCount) || itemCanonicalBytes)`. The literal
transcript step is `Tn+1 = SHA256(D || "append\0" || Tn || u64be(n) ||
itemDigest)`, where `n` is the zero-based array index. No first/last field or
page digest substitutes for the item digest.

### 3.1 Storage-ordinal index

Storage leaves use schema `model_catalog_activation_storage_leaf.v2` and exact
fields:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
level, firstStorageOrdinal,
lastStorageOrdinal, entryCount, entries, transcriptSHA256
```

`level = 0`; leaves contain 1–64 consecutive entries. Each entry has exactly:

```text
storageOrdinal, pathKey, pathClass, objectKind, storageClass, objectSHA256,
canonicalLength, chargeBytes, immutableIdentitySHA256, lifecycleKey
```

`pathClass = non-protocol|protocol-log`; `storageClass = immutable-file|
directory|fixed-extent`. Digests are non-null except `objectSHA256` and
`canonicalLength` are null only for directory/fixed-extent, identity is null
only for protocol-log/fixed-extent, and lifecycle key is null except on the
one imported lifecycle-reserve entry. `objectKind` is exactly one of
`activation-source-primary-certificate`, `activation-source-origin-certificate`,
`activation-source-class-document`, `activation-source-lineage-document`,
`prepared-model-artifact`, `receipt-primary-body`, `receipt-origin-body`,
`receipt-class-body`, `receipt-lineage-body`, `catalog-log-fixed-extent`,
`selector-fixed-extent`, or `migration-directory`. Amount is wide.

Storage nodes use schema `model_catalog_activation_storage_node.v2` and exact
fields:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
level, firstStorageOrdinal,
lastStorageOrdinal, entryCount, childCount, children, transcriptSHA256
```

Each child has exactly `firstStorageOrdinal, lastStorageOrdinal, entryCount,
pageRecordOrdinal, pageCanonicalLength, pageSHA256, subtreeChargedBytes`.
Nodes have 1–128 consecutive children. All non-right-frontier nodes are full.
The root stores aggregate live-entry category totals separately in the
selector; a child carries only the charged subtotal needed by a lookup/update.

Using a 16-digit safe integer, maximum `wide-v1`, the longest 37-byte legal
object-kind value,
64 lowercase-hex digests, and every nullable field populated with its longest
legal value, the exact independent JCS maxima are: storage entry 644 bytes,
64-entry leaf 41,743 bytes, child 389 bytes, and 128-child node 50,415 bytes.
They are below 65,536.
Capacity is `64 * 128^7 = 36,028,797,018,963,968`, greater than the maximum
`337,769,973,101,056` scale-dependent units, with at most eight page reads.

### 3.2 Canonical-path index

The path key remains the R12 digest of canonical root-relative UTF-8. The leaf
stores the path bytes as unpadded RFC 4648 base64url in field
`relativePathUTF8Base64URL`; decoded bytes are 1–1,024 bytes, NFC UTF-8, and
must reproduce the key and canonical relative path exactly.

Schema `model_catalog_activation_path_leaf.v2` has exactly:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
level, firstKey, lastKey, entryCount, entries, transcriptSHA256
```

It holds 1–16 entries and level is zero. Each entry has exactly:

```text
pathKey, relativePathUTF8Base64URL, pathClass, objectKind,
reservationState, objectSHA256, canonicalLength, storageOrdinal,
transactionIntentID, targetBinding
```

`reservationState = reserved|materialized|bound|indexed`. Digest/length/
ordinal are null only while reserved; `targetBinding` is one of the literal
strings `source-row|work-object|activation-object|checkpoint-object|
receipt-body|none`, at most 21 bytes. `objectKind` uses the exact closed enum in
section 3.1. State transitions only forward.
`indexed` means the corresponding storage-ordinal entry is selected; ordinary
phase authority may reference the object only after indexed and final commit.

Schema `model_catalog_activation_path_node.v2` has exactly:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
level, firstKey, lastKey, entryCount, childCount, children, transcriptSHA256
```

Each child has exactly `firstKey,lastKey,entryCount,pageRecordOrdinal,
pageCanonicalLength,pageSHA256`. Nodes contain 1–128 children. Exact maximum
JCS sizes are: path entry 1,865 bytes (1,366-byte maximum base64url path and
longest legal enums), 16-entry leaf 30,394 bytes, child 331 bytes, and
128-child node 43,066 bytes. Capacity is
`16 * 128^7 = 72,057,594,037,927,936`, above the maximum units, in eight reads.

### 3.3 Lifecycle-key index

Uniqueness is keyed by row, not class:

```text
lifecycleKey = SHA256("macprovider-lifecycle-row-v3\0" || rowUUIDBytes)
```

This prevents classified and unclassified keys for the same row from
coexisting. Schema `model_catalog_activation_lifecycle_leaf.v1` has exactly:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
level, firstKey, lastKey, entryCount, entries, transcriptSHA256
```

It holds 1–64 entries and level is zero. Each entry has exactly:

```text
lifecycleKey, rowUUID, pathKey, state, reserveBytes, provenance,
transactionIntentID
```

`state = reserved|bound|imported|consumed`; `provenance = active-primary-
classified|active-primary-unclassified`; reserve is exactly `W(581632)` or
`W(696320)` matching provenance. The only activation transitions are absent →
reserved → bound → imported. Genesis changes bound to imported without adding
reserve. Later allocation may change imported to consumed only under the
inherited R8–R10 allocation reservation ID; it cannot insert another row key.

Schema `model_catalog_activation_lifecycle_node.v1` has exactly:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
level, firstKey, lastKey, entryCount, childCount, children, transcriptSHA256
```

Its child schema is exactly the path-index child schema and it has 1–128
children. Exact maximum sizes are:
lifecycle entry 489 bytes, 64-entry leaf 31,903 bytes, child 331 bytes, and
128-child node 43,071 bytes. Capacity exceeds the row bound in eight reads.
Insertion requires one non-inclusion proof; every later transition requires
one inclusion proof. A collision with unequal row UUID is protected.

### 3.4 Sequence pages

There is no separate sequence-root record. A work root embeds a
`sequenceRootReference` with exactly:

```text
collectionKind, entrySchema, leafCapacity, fanout, entryCount, height,
firstOrdinal, lastOrdinal, topPageReference, transcriptSHA256
```

Empty has count/height zero, null ordinals/page, and the domain empty
transcript. Nonempty uses leaf capacity 16, fanout 128, height at most eight,
and a section 3 page reference. Sequence leaf schema
`model_catalog_activation_sequence_leaf.v2` has exactly:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
collectionKind, entrySchema, level, firstOrdinal, lastOrdinal, entryCount,
entries, transcriptSHA256
```

Sequence node schema `model_catalog_activation_sequence_node.v2` replaces
`entries` with exact fields `childCount,children`; each child has exactly
`firstOrdinal,lastOrdinal,entryCount,pageRecordOrdinal,pageCanonicalLength,
pageSHA256`. R12's allowed collection/entry pairs remain and every entry
canonical encoding is at most 3,072 bytes. A maximum leaf is
therefore exactly 49,719 bytes with the longest legal collection and entry-
schema literals; a maximum child is 239 bytes and a maximum 128-child internal
page is 31,303 bytes, all below 65,536. Independent
vectors freeze the exact byte count for every collection's legal maximum.

## 4. Acyclic transaction and publication graph

There is no `phaseTransactionRootSHA256` field in any target object and no R12
`targetBindingsSHA256`. A logical operation starts by constructing canonical
`model_catalog_activation_transaction_intent.v1` bytes with exactly:

```text
schema, activationUUID, transactionUUID, operationKind, operationOrdinal,
baseSelectorSHA256, baseCatalogLogSelectedLengthBytes,
baseCatalogLogSelectedRecordCount, baseCatalogLogTranscriptSHA256,
baseStorageRootReference, basePathRootReference,
baseLifecycleRootReference, plannedEdges, sourceBudgetDebits,
plannedChargeUpperBoundBytes, lifecycleReserveDeltaBytes, lifecycleKey
```

Root references use section 3's exact nullable object. Each planned edge has
exactly `edgeOrdinal, edgeKind, targetIndex, maximumEntryCount,
maximumAppendBytes, targetBinding`; edge kind is `path-reserve|lifecycle-
reserve|external-materialize|path-bind|lifecycle-bind|storage-index|
sequence-append|work-root|phase-commit|genesis`; target index is `none|storage|
path|lifecycle|sequence`. `maximumEntryCount` counts target log records,
external immutable files, and
the receipt and is in `[1,16]`. `maximumAppendBytes` is exactly the number of
planned log records, including receipt, times 65,572; it does not estimate
variable payload bytes. Amounts are wide. `plannedEdges` contains 1–64 entries.
Budget debits use section 7's exact
category names and safe counts. Lifecycle delta/key obey section 3.3 or are
both null/zero.

`transactionIntentID` is the R12 domain-separated digest of those canonical
bytes. The selector's `pendingTransaction` embeds the complete intent object
and exact fields in section 5. The intent does not contain any target digest.

Every page, protocol record, and external immutable object created for an edge
binds `transactionIntentID` and `edgeOrdinal`. The last log record for an edge
is `model_catalog_activation_edge_receipt.v1` with exactly:

```text
schema, recordOrdinal, activationUUID, transactionIntentID, edgeOrdinal,
edgeKind, baseSelectorRevision, baseCatalogLogSelectedLengthBytes,
baseCatalogLogTranscriptSHA256, targetRecordCount, targetRecordDigests,
externalObjects, targetStorageRootReference, targetPathRootReference,
targetLifecycleRootReference, targetSequenceRootReference,
targetWorkRootReference, targetCheckpointReference, targetActivationReference,
targetRecordsEndLengthBytes, targetRecordsTranscriptSHA256,
chargedDeltaBytes, lifecycleReserveDeltaBytes, receiptTranscriptSHA256
```

The target-record digest array is ordered, contains 0–15 digests, and excludes
the receipt itself. `targetRecordsEndLengthBytes` and target transcript describe
the prefix after those records and before the receipt. The final selector
length is exactly one slot longer and its transcript is the target transcript
with the receipt ordinal/digest appended. Every receipt enforces
`targetRecordCount + externalObjects.count + 1 <= 16`. An external object has
exactly `pathKey,objectSHA256,canonicalLength,immutableIdentitySHA256`.
Unused target fields are explicit null. The receipt digest depends on completed
target digests; target records depend only on the preimage-independent intent
ID. The successor selector depends on the receipt digest. Construction order
is therefore strictly intent → target bytes → receipt → selector, with no edge
back to a later digest.

The final `phase-commit` receipt binds the successor work root, checkpoint, and
activation digests. Those objects bind the intent ID and exact prior selected
digests but never the receipt digest. The final selector selects their digests,
the receipt, and the longer log prefix, then clears `pendingTransaction`.
Readers use only a stable selector. A pending transaction is recovery authority
only and cannot grant product readiness, admission, identity, or pricing.

## 5. Split edges and the 16-entry proof

One edge mutates at most one authenticated index or one sequence. Path,
lifecycle, and storage changes never share an edge. The path entry itself
carries target binding; R12's prepared-binding sequence and catalog
continuation object are removed. No edge appends two sequences.

| edge | permanent units selected by the edge | maximum |
|---|---|---:|
| path reserve/bind/indexed | up to 8 path pages + edge receipt | 9 |
| lifecycle reserve/bind/imported/consumed | up to 8 lifecycle pages + receipt | 9 |
| storage index | up to 8 storage pages + receipt | 9 |
| external materialize | 1 immutable external file + up to 8 path pages + receipt | 10 |
| sequence append | up to 8 sequence pages + receipt | 9 |
| work-root progress | 1 work-root record + receipt | 2 |
| checkpoint/activation phase commit | checkpoint + activation + receipt | 3 |
| genesis | header + checkpoint + activation + receipt; all three roots null | 4 |

The page count includes the successor root page. A maximum-depth split creates
one replacement page at each of eight levels, never eight plus a separate
root. The selector temporary and alignment padding are `Wpeak`, not permanent
units. No row or operation can request a combined path+lifecycle edge. For
adoption the mandatory order is lifecycle-reserve → path-reserve → external-
materialize/adopt → path-bind → lifecycle-bind → storage-index → path-indexed
→ phase-commit. Death between edges leaves a selected pending transaction;
ordinary authority still names the old roots. Recovery either resumes the
exact next edge or performs the section 9 protected rollback before any
external object was indexed. It never exposes a bound-but-unindexed object.

Selector v4 has exactly:

```text
schema, selectorRevision, activationUUID, selectedActivationGeneration,
selectedActivationReference, selectedCheckpointReference, state,
priorActiveIndexSHA256, migrationSourceSHA256, formatFenceSHA256,
fixedExtentRootSHA256,
activationMaterializedBytes, activationWorkReservedBytes,
activationLifecycleReservedBytes, activationSpentSlackBytes,
activationChargedBytes, activationQuotaBytes,
activationHistoryAccumulatorSHA256, activationHistoryLeafCount,
catalogLogSelectedLengthBytes, catalogLogSelectedRecordCount,
catalogLogTranscriptSHA256, catalogLogChargeBytes, catalogLogIdentity,
storageRootReference, pathRootReference, lifecycleRootReference,
pendingTransaction, selectedEdgeReceiptReference,
protocolUnitCount, protocolUnitBudget
```

`schema` is `model_catalog_retirement_v1_activation_selector.v4`.
R12 `activationStorageCatalogRootSHA256`, `pathRegistryRootSHA256`,
`activePhaseTransactionSHA256`, and `pendingWriteIntent` are absent. Amounts are
wide; counts are safe. `protocolUnitBudget` is an array in section 7 category
ordinal order whose entries have exactly `category,used,limit`. Stable has null
pending transaction and a non-null last receipt after genesis. Selector
canonical bytes are at most 65,536.

`catalogLogIdentity` is the exact object in section 2.1. `pendingTransaction`
is null or an exact object with fields:

```text
intent, transactionIntentID, nextEdgeOrdinal, selectedReceiptReference,
tailState, baseCatalogLogIdentity, expectedTailEndBytes
```

`intent` is the exact transaction-intent JSON object, not encoded bytes or a
string. `tailState = no-tail|tail-fsynced`; receipt is null only before the
first completed edge. Expected tail end is wide and equals the maximum legal
end for the current edge. Base identity is exact section 2.1 identity.

Activation v5 has exactly:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
activationGeneration, previousActivationReference, state,
priorActiveIndexSHA256, migrationSourceSHA256, formatFenceSHA256,
configuredRootPathSHA256, initialPathReceiptReference, nameCaptureRootReference,
rowCaptureRootReference, sortedRunReference, treeWorkRootReference,
verificationRootReference, currentCheckpointReference,
baseCatalogLogSelectedLengthBytes, baseCatalogLogTranscriptSHA256,
storageRootReference, pathRootReference, lifecycleRootReference,
priorActivationHistoryAccumulatorSHA256, priorActivationHistoryLeafCount,
protocolUnitCount, protocolUnitBudget
```

Its schema literal is `model_catalog_retirement_v1_activation.v5`.
Checkpoint v6 has exactly:

```text
schema, recordOrdinal, transactionIntentID, edgeOrdinal, activationUUID,
checkpointGeneration, previousCheckpointReference, activationState,
priorActiveIndexSHA256, migrationSourceSHA256, formatFenceSHA256,
configuredRootPathSHA256, initialPathReceiptReference, latestPathReceiptReference,
nameCaptureRootReference, rowCaptureRootReference, sortedRunReference,
treeWorkRootReference, verificationRootReference,
currentNameScanRootReference, currentNameCaptureRootReference,
currentRowWorkRootReference, currentRunWorkRootReference,
currentTreeBuildRootReference, currentVerificationWorkRootReference,
nextNameOrdinal, nextRowBlockOrdinal, mergePass, nextMergeGroupOrdinal,
nextCreationOrdinal, builderLevel, nextBuilderInputOrdinal,
nextTreeObjectOrdinal, nextVerificationOrdinal, terminalRowCount,
verificationPass, nextStorageVerificationOrdinal,
storageVerificationTranscriptSHA256,
storageVerificationTargetRootReference, storageVerificationTargetEntryCount,
storageVerificationTargetMaterializedBytes,
baseCatalogLogSelectedLengthBytes, baseCatalogLogTranscriptSHA256,
storageRootReference, pathRootReference, lifecycleRootReference,
priorActivationHistoryAccumulatorSHA256, priorActivationHistoryLeafCount,
protocolUnitCount, protocolUnitBudget
```

Its schema literal is `model_catalog_retirement_v1_checkpoint.v6`. Every
digest/root/result not applicable to the selected phase is present as JSON
null; each progress counter is present and zero until applicable. Wide fields
are catalog lengths, materialized bytes, and budget byte amounts; other counts
are safe integers. R10–R12 monotonic state/result rules remain. Both records
bind the base log prefix and target roots, never the final receipt or final log
transcript. The receipt binds them; the selector binds the receipt and both
digests. Independent cycle detection rejects any field added contrary to this
order.

## 6. Closed remaining codecs

R12 section 5.2 work schemas remain exact after these universal changes:
`schema` is followed by `recordOrdinal,transactionIntentID,edgeOrdinal`; every
`phaseTransactionRootSHA256` field is absent; and each root's transcript appends
the exact ordered child/entry digest described in section 3. Every field ending
`SequenceRootSHA256` is renamed by replacing that suffix with
`SequenceRootReference` and contains the exact embedded object in section 3.4;
every other field whose value names a catalog-log record is renamed from
`*SHA256` to `*Reference` and contains section 3's exact record reference. The
old digest-only fields are forbidden. External source/body/content and
transcript SHA fields retain their literal names. The following previously prose-only
encodings are closed:

* `rowCanonicalBytes` is unpadded RFC 4648 base64url of 1–1,024 canonical row
  bytes. Its decoded bytes must hash to `rowSHA256` and re-encode byte-identically.
* `activation_merge_cursor.v2` exact fields are `schema,recordOrdinal,
  transactionIntentID,edgeOrdinal,inputOrdinal,rowBlockOrdinal,rowOrdinal,
  exhausted`. Ordinals are null iff exhausted.
* `activation_merge_head.v2` exact fields are `schema,recordOrdinal,
  transactionIntentID,edgeOrdinal,inputOrdinal,exhausted,rowCanonicalBytes,
  rowSHA256`. Bytes/digest are null iff exhausted.
* `activation_planned_object.v2` exact fields are `schema,recordOrdinal,
  transactionIntentID,edgeOrdinal,objectOrdinal,pathKey,pathClass,objectKind,
  canonicalLength,objectSHA256,chargeBytes,targetBinding`. Length/digest are
  null only for a directory/fixed extent.
* R12 `activation_prepared_binding.v1` and
  `activation_catalog_continuation.v1` are forbidden and have no R13 encoder.
* Sequence collection literals are exactly `merge-cursor`, `merge-head`,
  `planned-object`, and the twelve literals in R12 section 5.1. Their paired
  entry schema strings are the exact schema names in that table or this list.
* Root references are either JSON null or the exact object
  `{entryCount,height,pageCanonicalLength,pageRecordOrdinal,pageSHA256}` in JCS
  key order. No string shorthand is legal.
* `sourceBudgetDebits` is an array ordered by section 7 category ordinal; each
  entry has exactly `category,units`. `targetRecordDigests` is an array of
  lowercase-hex strings in physical append order and never includes its
  containing receipt. Both arrays are part of the containing object's ordinary
  JCS digest, with no second prose transcript.

Minimum, maximum, and one-over-limit vectors are mandatory for header, frame,
root reference, all three index leaves/nodes/entries, every retained R12
sequence entry, R13 sequence page/root reference and work root, intent,
receipt, selector v4,
activation v5, checkpoint v6, merge cursor/head, and planned object. A codec is
not implemented if an independent encoder must invent a field, enum, null,
array order, byte representation, maximum length, or digest preimage.

## 7. Corrected 768-unit coefficient and maximum-history arithmetic

A **protocol unit** is one catalog-log record, one immutable external file, or
one selected fixed-extent selector revision created by migration. Directories
and the initial fixed extents are units in the fixed allowance. A physical
catalog-log or selector file is charged once by length/fixed extent, while its
selected revisions are units for bounded work/count arithmetic; this
distinction is explicit and never used to charge both.

Each source row receives exactly the following scale-dependent budget. The
writer stores and decrements category counters in the selector; an operation
names its deterministic source-row ordinal(s), charges each unit to exactly one
row/category, and rejects before append if a category would exceed its limit.
Shared block/page work is charged to the lowest row ordinal represented by that
object. Empty inputs and objects representing no row use the fixed allowance.

| ordinal | category | exact maximum per source row | derivation |
|---:|---|---:|---|
| 0 | `source-capture` | 32 | eight row-attributed capture steps × at most four data/sequence/work units |
| 1 | `merge` | 256 | at most 40 passes × at most six row-attributed output/sequence/group/work/receipt units, plus 16 terminal units |
| 2 | `tree` | 64 | eight levels × at most six row-attributed page/sequence/work units, plus 16 close units |
| 3 | `verification` | 32 | four passes × at most six row-attributed block/sequence/work units, plus eight close units |
| 4 | `path-index` | 96 | at most three non-protocol paths per row × four forward index transitions × eight pages |
| 5 | `lifecycle-index` | 24 | one row key × three activation transitions × eight pages |
| 6 | `storage-index` | 128 | at most sixteen row-attributed immutable units × eight pages per insertion |
| 7 | `transaction` | 128 | at most 64 row-attributed edges × one receipt record and one selected selector revision |
| 8 | `phase-control` | 8 | at most four row-attributed phase boundaries × checkpoint and activation records |
| | **total** | **768** | exact sum |

The operation table is closed: source capture may debit category 0; merge only
1; tree only 2; verification only 3; path transitions only 4; lifecycle
transitions only 5; storage insertions only 6; intent/receipt publication only
7; checkpoint/activation publication only 8. A unit cannot use a fallback
category. The algorithm must prove during preflight that every row has at most
three non-protocol paths, sixteen row-attributed immutable units, 40 merge
passes, one lifecycle key, and the listed transition counts. A source violating
one of these structural predicates is unsupported before v4; production may
not merely rely on a runtime budget failure after mutation.

The fixed allowance 1,048,576 has its own closed ledger: 64 header/empty-root/
fixed-extent units; at most 256 empty/terminal units for each of 64 phases
(16,384); at most 4,096 global merge/tree close units for each phase (262,144);
at most 2,048 global verification close units for each phase (131,072); at most
4,096 idempotent global recovery/control units for each phase (262,144); at
most 2,048 genesis/final compatibility units for each phase (131,072); and at
most 245,696 fixed directory, bootstrap, and terminal units. The
sum is exactly 1,048,576. Each sub-ledger counter is selected and preflighted;
no scale-dependent unit may debit it.

Therefore, for `R` rows:

```text
U(R) = 768 * R + 1,048,576
U(0) = 1,048,576
U(1) = 1,049,344
U(Rmax-1) = 337,769,973,100,288
U(Rmax)   = 337,769,973,101,056
U(Rmax+1) is rejected by sourceRowCount before multiplication
```

The byte preflight sums exact planned external charges plus exact catalog slot
bytes, applies `F` once to the resulting log length, then applies
the inherited directory, lifecycle reserve, finalization, quota, `Wpeak`, and
`Uafter` equations in `wide-v1`. Using the inherited maximum unit charge, the
independently reproducible conservative expression is exactly
`1,422,665,509,422,598,725,632`, below `2^71` and therefore below `2^120`.
The independent oracle must compute that value from terms, not copy it.

## 8. Correct finite-directory EOF

R12's ABI profile, bounded buffers, record validation, offset witness, sentinel,
and fresh-FD rules remain. Step 5–7 are replaced:

1. A main call returning zero is candidate EOF. From the unchanged selected
   offset, a second main-buffer call must also return zero with unchanged
   offset. Select EOF with no raw block.
2. A main call returning 1–32 records persists all returned records in the
   candidate raw block and records `batchAfter`.
3. Lookahead starts at `batchAfter`. If it returns records, hash its first
   record as successor sentinel, rewind exactly to `batchAfter`, recapture the
   offset, and select the non-EOF block.
4. If lookahead returns zero with unchanged offset, rewind to `batchAfter` and
   call a second lookahead with the same buffer. A second zero with unchanged
   offset is confirmed EOF. Rewind once more to `batchAfter`, reverify the
   directory witness, close, and atomically select the nonempty final raw block
   with `eof=true`, null sentinel, and `nextDirectoryOffset=batchAfter`.
5. Any error, offset movement on zero, record after a zero candidate, failed
   rewind, witness change, or inconsistent repeated bytes is unsupported.

Thus one final nonempty block followed by zero is ordinary success. Exactly
1, 31, 32, 33, 64, and 65 records have unambiguous final blocks; no record is
discarded or selected twice. Death before selector CAS leaves the old offset;
death after the durable CAS resumes at selected EOF or selected successor.

## 9. Strong crash, rollback, recovery, and observability contract

For every selector CAS the only permitted restart outcome is boundary-specific:

| last completed boundary | permitted selected selector after restart |
|---|---|
| prepared temp created or temp fsynced, before rename | old only |
| rename returned, before selector-directory fsync returned | old or new complete graph |
| selector-directory fsync returned | new only |
| no-follow reopen and byte/identity verification returned | new only |

An old selector after the directory-fsync boundary is rollback and protected,
even if internally complete. A new selector before rename is impossible and
protected. A selector digest, selected log prefix, receipt, root, activation,
or checkpoint mismatch is protected; recovery never chooses the most convenient
complete graph.

For catalog append, death before the pending-selector CAS leaves the stable log
size unchanged because append has not started. After pending-selector CAS and
before log fsync, restart may see any tail length; recovery validates the base
identity and truncates only bytes beyond the stable selected length, fsyncs the
log, recaptures identity, and resumes the exact edge. After log fsync and before
final selector rename, the complete tail may remain but is not ordinary
authority; recovery replays the pure page/update codec from the selected base
roots and embedded intent, recomputes every target byte/digest/root and the
receipt, and either publishes that byte-exact receipt or truncates to the stable
base. Tail bytes are never accepted merely because their internal hashes
match. After final selector-
directory fsync, truncation or selection of the base prefix is forbidden.

Cancellation is acknowledged only after reaching a stable selector with no
unaccounted tail and releasing all locks/FDs. Queued cancellation cannot report
success while an owner holds the activation flock. Same-owner recursive entry
returns typed busy before opening mutable files. Every operation closes the log,
directory, selector, and source descriptors before releasing the journal and
activation flocks.

Observability emits activation UUID, selector revision/digest, selected log
length/record count/transcript/charge, three root heights/counts/digests,
transaction intent ID and edge ordinal, intent unit count, budget category
debits/remaining, EOF probe state, and typed protected reason. Wide amounts are
logged as limbs plus derived human decimal. Names, source bodies, keys, and
secrets remain excluded.

## 10. Implementation order, compatibility, rollback, and stop gate

The R12 findings map to corrections as follows:

| finding | R13 correction | proof required by R19 |
|---|---|---|
| H1 page geometry | exact 64/128 and 16/128 pages with byte maxima | R19-01 |
| H2 retained catalog versions | one retained selected log prefix, one file charge | R19-02 |
| H3 digest cycle | intent → target → receipt → selector | R19-03 |
| H4 bind over 16 | separate single-index edges, maximum 10 | R19-04 |
| H5 incomplete codecs | literal schemas, enums, nulls, bytes, arrays, vectors | R19-01/R19-03 |
| H6 final batch EOF | double-zero lookahead after nonempty batch | R19-07 |
| H7 unsupported 512 coefficient | corrected closed 768-unit transition ledger | R19-06 |
| H8 lifecycle lookup | row-keyed authenticated index, eight reads | R19-05 |
| M1 post-fsync rollback | boundary-specific old/new/new-only oracle | R19-09 |

Implementation remains one unshippable compatibility slice:

1. independent exact codecs, page-size generator, budget oracle, and frozen
   vectors;
2. catalog-log bootstrap, framing, transcript, file identity, and selector v4
   CAS/recovery;
3. three authenticated indexes and bounded proof/update engine;
4. acyclic intents, receipts, split edges, and lifecycle uniqueness;
5. sequence/work conversion and corrected name scan;
6. incremental source/storage verification and sole genesis import;
7. compatibility, crash, mutation, maximum-shape, CLI/app, Swift, Xcode,
   governance, then independent code/security/architecture audits.

The prior binary rejects selector v4/catalog-log format before mutation. The
new binary may resume only a byte-valid selected pending transaction. Before
v4 publication, rollback is the old complete authority. After v4 publication,
rollback means forward recovery to a stable v4 selector; selected catalog-log
bytes are never deleted. No migration output is paid admission, identity,
pricing, settlement, enforcement, or production qualification.

Stop on a page over 65,536 bytes; height over eight; intent over 16; incomplete
codec; digest cycle; two indexes or sequences changed in one edge; unselected
or uncharged catalog tail; mutation of a selected log byte; missing size/mtime/
ctime recapture; class-qualified lifecycle uniqueness; budget debit without a
closed source-row attribution; scale-dependent use of fixed allowance;
nonempty-final-batch rejection; old selector after directory fsync; raised FD,
deadline, row, file, body, quota, or source bounds; source/path witness
weakening; changed A3–A8 or refund arithmetic; or skipped, timed-out,
zero-selected, fixture-only, or historical evidence called passing. Physical
MLX, signed release/feed, deployed services, production enforcement,
settlement activation, and economic activation remain outside this corrective
plan.
