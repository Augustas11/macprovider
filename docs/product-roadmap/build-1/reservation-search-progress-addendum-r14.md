# Reservation search progress — corrective addendum R14

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

Frozen inputs:

| input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r13.md` | `82f77bedc27f37dece83bdfb13181abf31217f739dde01ff758c660b771d22cd` |
| `test-spec-r19-reservation-r13-corrections.md` | `721dbe79d8d18e2c1c4999f748ee5dd8575c2da237ed8c60a2d1f324557d9a82` |
| `reviews/reservation-search-progress-r13-plan-sol.md` | `f9875f9f279f7029410eb4725ebffbf9d7baeabc857126aa0d15bfaed0f6004a` |

The R13 gate failed with 0 Critical / 8 High / 2 Medium / 0 Low. R14
replaces R13 sections 1 through 7 and 9. R13 section 8's finite-directory EOF
algorithm remains governing verbatim. Nonconflicting R4–R12 requirements
remain governing, especially A3–A8 settlement/refund arithmetic, source and
path witnesses, immutable selected evidence, four open FDs, eight seconds per
invocation, 16 permanent units per publication edge, and no ordinary authority
from a pending migration.

The inspected base is `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. Coordinator/BYOM reconciliation
is paused and is outside this Swift-only proposal. Any change to the governed
reservation, retention, storage, evidence, migration, or SPEC surfaces reopens
the gate.

## 1. Closed limits and corrected design

R14 replaces the unrepresentable single catalog log with immutable publication
batch files. One batch carries at most sixteen canonical records, including
its receipt, and is never appended after publication. The stable selector
commits an append-only Merkle-mountain-range (MMR) of batch payload hashes.
Current authority references a record by batch and slot and proves that batch's
payload hash against the selected MMR in at most 51 merge steps. No selected
prefix is truncated or rewritten during recovery.

The limits are:

```text
canonical record bytes                         <= 65,536
records plus external immutable objects/edge   <= 16
records in one immutable batch                 <= 16
B+ tree page reads/index lookup                 <= 8
MMR proof merge steps/record lookup             <= 53
open FDs/invocation                             <= 4
wall time/invocation                            <= 8 seconds
source rows                                     <= 439,804,651,110
scale protocol units                            <= 8,192 * sourceRowCount
fixed protocol units                            <= 8,388,608
safe JSON integer                               <= 9,007,199,254,740,991
wide-v1 amount                                  <= 2^120 - 1
```

The 8,192 coefficient corrects R13's undercount; it is not an economic
charge or admission claim. Preflight derives exact work below these ceilings
and rejects before v4 publication if exact quota, APFS object capacity, or
host resources cannot materialize it. The format remains arithmetically
addressable through `Rmax`; a particular host can remain unqualified for
physical capacity without making the format itself unrepresentable.

## 2. Immutable batch address space, transcript, and charging

### 2.1 Paths and framing

The activation directory contains one batch directory:

```text
.reservation-migration/retirement/v1/activation/<activationUUID>/batches/
```

Batch ordinal `b` is a safe integer in `[0, 2^53-1]`. Its filename is exactly
16 lowercase hexadecimal digits followed by `.mcb`; no alternate spelling is
accepted. Batch zero is genesis. Direct lookup uses `openat` on this exact
filename and never enumerates `batches/`. A temporary uses
`.<hex>.tmp.<transactionUUID>.<edgeOrdinal>` in the same directory and is not
authority.

Every immutable batch is one header plus 1–16 fixed slots:

```text
header = u32be(headerLength) || headerJCS || SHA256(headerJCS)
slot   = u32be(bodyLength) || bodyJCS || SHA256(bodyJCS) || zero padding
slot bytes = 65,572 = 4 + 65,536 + 32
```

Header length is 2–8,192 and the header is padded with zeroes to exactly 8,228
bytes. A batch file length is therefore `8,228 + recordCount * 65,572`, at
most 1,057,380 bytes, far below signed 64-bit `off_t`. Slot ordinal is 0–15.
Checked multiplication/addition occurs before every `pread`. Unknown or
duplicate fields, non-JCS, nonzero padding, unsafe JSON numbers, wrong lengths,
wrong ordinal, trailing bytes, and digest mismatch are protected.

Header schema `model_catalog_publication_batch_header.v1` has exactly:

```text
schema,activationUUID,batchOrdinal,transactionIntentID,edgeOrdinal,edgeKind,
baseSelectorSHA256,baseMMRLeafCount,baseMMRPeaks,recordCount,
payloadTranscriptSHA256,payloadLengthBytes
```

`baseMMRPeaks` is an array of exactly 53 entries, lowest height first; each is
hex SHA-256 or null. Entry `h` is non-null iff bit `h` of `baseMMRLeafCount` is
one. `payloadLengthBytes` is the exact file length. The header digest is not a
leaf. With `Rmax`, the maximum unit count is
`8,192*439,804,651,110+8,388,608 = 3,602,879,710,281,728`, below `2^52`; thus
batch ordinals, record counts, and MMR leaf counts remain JCS-safe.

Record transcript:

```text
P0 = SHA256("macprovider-batch-payload-v1\0" ||
            u64be(batchOrdinal) || u32be(recordCount))
Pn+1 = SHA256("macprovider-batch-payload-v1\0append\0" || Pn ||
              u32be(slotOrdinal) || recordDigest)
payloadHash = P_recordCount
```

The header field `payloadTranscriptSHA256` equals `payloadHash`. All record
bytes are created first; the header is then created; no record contains the
header or payload hash. The full immutable identity is captured after file
fsync and after containing-directory fsync.

### 2.2 MMR and bounded membership

MMR leaves are:

```text
batchContentSHA256 = SHA256(complete batch file bytes)
L = SHA256("macprovider-batch-leaf-v1\0" || u64be(batchOrdinal) ||
           batchContentSHA256 || u64be(payloadLengthBytes))
N = SHA256("macprovider-batch-node-v1\0" || u8(height) || left || right)
R = SHA256("macprovider-batch-root-v1\0" || u64be(leafCount) ||
           peak[52] || ... || peak[0])
```

Null peaks in `R` are encoded as 32 zero bytes. Appending leaf `b` performs
binary carries against the selected base peaks. The successor selector stores
the exact 53 peaks, leaf count `b+1`, and root `R`. The successor batch header
stores the base peaks, so recovery independently recomputes the carry and
rejects a forged base.

A record reference contains exactly:

```text
batchOrdinal,slotOrdinal,recordCanonicalLength,recordSHA256
```

To authorize it against a later selector, the reader opens the referenced
batch and hashes its complete bounded file, including the header. For every carry level needed
from that leaf to its current selected peak, it opens the deterministic
right-boundary batch for that merge and reads its header's selected base peak
as the sibling. The merge-event ordinal for leaf `b`, level `h`, and selected
leaf count `n` is calculated only with checked integer arithmetic as the least
`e < n` whose low `h+1` bits are all one and whose height-`h` interval contains
`b`. The header at `e` must have ordinal `e`, a base MMR root equal to the
reconstructed prior root, and the required sibling peak. For an included leaf `b`, the merge-event ordinal at height `h` is exactly
`e = (((b >> (h+1)) + 1) << (h+1)) - 1`; it is used only when `e < n`.
The verifier replays the carry in header `e` to derive whether the authenticated
sibling is the pre-append height-`h` peak or the right subtree formed by that
carry. At most 53 such
headers are needed because the maximum leaf count is below `2^52`. Files are
opened and closed sequentially, so membership uses at most two batch FDs plus
the selector/directory FDs. A proof that needs a missing future merge stops at
the selected peak and bags against the selector's other peaks.

This is lazy authenticated membership: every record used by current ordinary
authority, every current B+ root, work root, checkpoint, activation, and last
receipt is proved before use. Superseded records grant no authority and are
checked during the incremental storage-verification passes. Mutation of a live
or superseded record is detected when that record's proof is exercised; no
claim is made that every historical byte is reread on every command.

### 2.3 File identity and charge

`immutableIdentity.v3` has exactly:

```text
schema,deviceID,fileID,fileType,byteLength,mode,ownerUID,groupGID,linkCount,
mtimeSeconds,mtimeNanoseconds,ctimeSeconds,ctimeNanoseconds,contentSHA256,
relativePathSHA256
```

`fileType = regular|directory`. Regular files require non-null byte length and
content digest. Directories require null byte length/content digest. Every
other field is non-null; numeric fields are safe integers. The object digest is
`SHA256("macprovider-immutable-identity-v3\0" || u64be(jcsLength) || jcs)`.
Batch identity uses this schema with `fileType=regular`, content digest equal
SHA-256 of the entire file, and its canonical root-relative path digest.

Each batch is charged exactly once as `F(fileLength)`. Selector fields
`catalogBatchMaterializedBytes` and `catalogBatchChargedBytes` are cumulative
wide values. An MMR leaf commits the complete file hash and length. Batch carriers are
protocol representation, not storage-tree entries or additional protocol units;
this avoids a carrier describing its own content hash. The selector directly
commits their cumulative materialized/charged bytes and the MMR commits each
individual carrier. Incremental storage verification visits deterministic batch
ordinals as a separate carrier class. Page/receipt records are protocol units
but are not separately filesystem-charged. Temporary files are Wpeak only and are removed before a
stable cancellation acknowledgement.

## 3. Exact B+ tree algorithm and budgets

There are five authenticated trees: storage ordinal, canonical path,
lifecycle row, budget authority, and ordinal sequence. Storage and sequence
keys append at the right frontier; path, lifecycle, and budget keys are
arbitrary. All have height 0–8. Leaf capacities are storage/lifecycle/budget
32 and path/sequence 16; internal fanout is 128. The lower 32-entry capacity
is a representation change, not a history reduction: `32*128^7` exceeds the
R14 maximum protocol-unit count.

The arbitrary-key copy-on-write algorithm is normative:

1. Read exactly one root-to-leaf path and verify every page reference and range.
2. Use unsigned bytewise lower-bound. Equal key is an allowed forward update
   only if immutable key coordinates match; otherwise protect.
3. A leaf with room produces one successor. Overflow produces a left page with
   `ceil((capacity+1)/2)` entries and right page with the rest: 17/16 for
   capacity 32, 9/8 for capacity 16.
4. Replace the parent's one child descriptor with one or two descriptors. A
   parent with at most 128 children produces one successor. Overflow 129 splits
   65/64. The right separator is its first key; separators are derived and are
   never duplicated as independent authority.
5. Repeat upward. A non-splitting root produces one successor. A splitting root
   produces its two successors plus a new one-child-level-higher root.

For height `h` in 1–8, a no-split insert creates `h` pages; a cascade stopped
at a nonfull root creates at most `2h-1`; a root-growing cascade creates
`2h+1`. The exact maximum at height eight is seventeen pages. Deletion is not
implemented in v4. State retirement is an in-place logical forward update.
Capacity is capped by both geometry and JCS safety:

```text
path/sequence geometric capacity = 16*128^7 = 9,007,199,254,740,992
path/sequence admitted capacity  = 9,007,199,254,740,991
32-leaf geometric capacity       = 18,014,398,509,481,984
32-leaf admitted capacity        = 9,007,199,254,740,991
```

Last-safe and first-unsafe roots are frozen vectors. `2^53` is never encoded as
a JSON number.

### 3.1 Continuation edges

An index update is fully simulated before mutation. Its ordered target page
list is partitioned into chunks of at most fourteen pages. A continuation batch
contains up to fourteen page records plus one `continuation_receipt` (15
records). The final batch contains the remaining 1–14 pages and one
`edge_receipt`; if an external object is also selected, the final page chunk is
at most thirteen. No intermediate receipt changes the ordinary root. It only
advances the pending transaction's authenticated continuation cursor and MMR.

A height-eight root split therefore uses two batches: 14 pages + continuation
receipt, then 3 pages + edge receipt, nineteen total protocol units. A no-split
height-eight update uses one batch of eight pages + receipt. Every abandoned
continuation page remains selected, charged, and unreachable from ordinary
roots. No implementation may claim the old R13 8-page/9-unit maximum.

## 4. Selected budget authority

Budget keys are canonical bytes:

```text
scale key = 0x01 || u64be(sourceRowOrdinal) || u16be(categoryOrdinal)
fixed key = 0x02 || u16be(categoryOrdinal)
```

`budget_leaf.v1` entries have exactly
`key,scope,sourceRowOrdinal,categoryOrdinal,category,used,limit,generation,
lastTransactionIntentID`; row ordinal is null only for fixed. Used/limit are
safe integers. The selector holds only the budget root reference and aggregate
wide unit totals; per-key authority is in this selected tree.

Before an operation writes target bytes, a `budget-reserve` continuation:

1. deterministically simulates all target pages, carrier records, receipts,
   abort allowance, and the budget-tree update itself;
2. attributes every unit to one exact key;
3. updates all affected keys in ascending key order through separate
   single-tree edges; and
4. selects a `budget_lease.v1` record binding exact key deltas, target
   descriptor digest, expiration `selectorRevision+64`, and transaction ID.

The fixed point is unique: the budget-tree page target count is simulated from
the selected root and is included in its own requested delta before its page
bytes are emitted. A second simulation must produce the identical count. A
lease can be consumed only by the named descriptor digest. Expiry/abandon uses
a forward compensating entry that decrements unused leased units and increments
`aborted` units; used units for already selected batches are never refunded.

The closed per-row table is:

| ordinal | category | limit | includes |
|---:|---|---:|---|
| 0 | `source-capture` | 256 | six 38-unit block/index/lease transitions plus 28 close units |
| 1 | `merge` | 1,664 | forty 41-unit merge transitions plus 24 terminal units |
| 2 | `tree` | 1,024 | eight 124-unit levels plus 32 root-close units |
| 3 | `verification` | 512 | twelve 40-unit row/storage transitions plus 32 close units |
| 4 | `path-index` | 512 | twelve 38-unit arbitrary-key transitions plus 56 close units |
| 5 | `lifecycle-index` | 160 | four 38-unit transitions plus 8 close units |
| 6 | `storage-index` | 640 | sixteen 38-unit insertions plus 32 close units |
| 7 | `transaction` | 512 | sixty-four intents/receipts/selectors at eight units |
| 8 | `phase-control` | 512 | sixteen 32-unit checkpoint/activation boundaries |
| 9 | `abort` | 2,400 | at most sixty-three 38-unit abandon transitions plus 6 terminal units |
| | **total** | **8,192** | |

The fixed ledger has the same ten categories and exact limits
`262144,2097152,786432,393216,1048576,327680,1310720,1048576,524288,589824`,
whose sum is 8,388,608. Empty/global work uses only fixed keys. Shared row work
is attributed to the lowest represented source-row ordinal. Genesis imports
all scale keys in bounded row blocks and all fixed keys before any later work
lease. Creation of a previously absent row budget entry is the sole bootstrap
exception to prior-inclusion proof: its canonical initial value includes its
own simulated page/receipt debit against that row's `source-capture` limit, and
the complete insertion batch selects entry plus debit atomically. Fixed genesis
keys similarly debit the fixed `source-capture` key created in the same first
batch. Replay finds the identical entry or protects; it cannot create an
unaccounted zero-used entry. No aggregate selector counter substitutes for a
budget-tree inclusion proof.

## 5. Complete transaction commitment and publication

`transaction_intent.v2` has exactly:

```text
schema,activationUUID,transactionUUID,operationKind,operationOrdinal,
baseSelectorSHA256,baseMMRLeafCount,baseMMRRootSHA256,
baseStorageRootReference,basePathRootReference,baseLifecycleRootReference,
baseBudgetRootReference,plannedEdges,plannedBudgetDebits,
plannedChargeUpperBoundBytes,lifecycleReserveDeltaBytes,lifecycleKey
```

Each `plannedEdge.v2` has exactly:

```text
edgeOrdinal,edgeKind,targetIndex,sourceRowOrdinal,targetKeyBase64URL,
targetRangeFirstBase64URL,targetRangeLastBase64URL,sequenceCollection,
sequenceOrdinal,objectKind,canonicalRelativePathBase64URL,pathKey,
storageOrdinal,lifecycleKey,baseRootReference,operationInputReferences,
maximumPageRecords,maximumExternalObjects,maximumBatchRecords,
targetDescriptorSHA256
```

Every nullable field is present. The matrix is: index edges require target
index/key/range/base root; sequence edges require collection/ordinal/base root;
external materialization requires object kind/path/pathKey/storage ordinal;
phase edges require none of those coordinates. Source row is required for
scale work and null for fixed. `operationInputReferences` is a 0–16 array of
record references in canonical input order. `targetDescriptorSHA256` hashes
the exact edge without that field using
`SHA256("macprovider-target-descriptor-v2\0"||u64be(length)||jcs)`.

The intent ID hashes the complete intent with every descriptor digest. Target
pages bind intent ID/edge ordinal but no target digest, so the graph remains
acyclic. Recovery recomputes target bytes solely from selected base roots,
operation input records, and the descriptor. Caller arguments, mutable source,
directory enumeration, and future receipts are forbidden inputs.

The intent is not embedded in the selector: 64 complete descriptors need not
fit the 65,536-byte selector extent. Before selecting pending state, production
writes canonical intent bytes (maximum 1,048,576) to exact path
`.reservation-migration/retirement/v1/activation/<activationUUID>/intents/
<transactionUUID>.json`, fsyncs file and directory, and captures identity v3.
The pending selector commits `transactionIntentID,intentIdentity,
canonicalIntentLength,intentRelativePathSHA256`. A same-path unequal file
protects. Intent selection is one external protocol unit and the file remains
selected and charged after commit or abandon; completed selectors retain its
descriptor as `lastTransactionIntentReference`. It is entered in storage/path
trees before phase commit, or as retained-abandoned on abort.
`transactionIntentReference` and `lastTransactionIntentReference` are null or
exactly `transactionIntentID,canonicalRelativePathBase64URL,
canonicalIntentLength,intentSHA256,immutableIdentitySHA256,chargeBytes`.

`continuation_receipt.v1` exact fields are:

```text
schema,activationUUID,transactionIntentID,edgeOrdinal,chunkOrdinal,
baseSelectorRevision,targetDescriptorSHA256,firstTargetOrdinal,
targetRecordReferences,nextTargetOrdinal,targetCount,selectedBatchOrdinal,
chargedDeltaBytes,budgetLeaseReference,
receiptTranscriptSHA256
```

`edge_receipt.v2` exact fields are:

```text
schema,activationUUID,transactionIntentID,edgeOrdinal,edgeKind,
baseSelectorRevision,targetDescriptorSHA256,continuationReceiptReferences,
targetRecordReferences,externalObjects,targetStorageRootReference,
targetPathRootReference,targetLifecycleRootReference,targetBudgetRootReference,
targetSequenceRootReference,targetWorkRootReference,targetCheckpointReference,
targetActivationReference,selectedBatchOrdinal,
chargedDeltaBytes,lifecycleReserveDeltaBytes,budgetLeaseReference,
outcome,receiptTranscriptSHA256
```

Receipt transcript is never self-referential:

```text
Q = JCS(receipt object with receiptTranscriptSHA256 = null)
receiptTranscriptSHA256 = SHA256("macprovider-receipt-v1\0" ||
                                 u32be(schemaUTF8.count) || schemaUTF8 ||
                                 u64be(Q.count) || Q)
```

`outcome=continued|committed|abandoned|protected`; continuation receipts use
only `continued`. Target arrays are physical creation order. Every external
object descriptor has exactly `objectKind,pathKey,canonicalRelativePathBase64URL,
objectSHA256,canonicalLength,immutableIdentitySHA256,chargeBytes`.

The successor selector v5 has exactly:

```text
schema,selectorRevision,activationUUID,state,selectedActivationReference,
selectedCheckpointReference,priorActiveIndexSHA256,migrationSourceSHA256,
formatFenceSHA256,fixedExtentRootSHA256,activationMaterializedBytes,
activationWorkReservedBytes,activationLifecycleReservedBytes,
activationSpentSlackBytes,activationChargedBytes,activationQuotaBytes,
activationHistoryAccumulatorSHA256,activationHistoryLeafCount,
catalogBatchMaterializedBytes,catalogBatchChargedBytes,mmrLeafCount,mmrPeaks,
mmrRootSHA256,storageRootReference,pathRootReference,lifecycleRootReference,
budgetRootReference,pendingTransaction,lastTransactionIntentReference,
lastReceiptReference,protocolUnitCount
```

State is `migrating|ready|protected`. `pendingTransaction` is null or exactly
`transactionIntentReference,transactionIntentID,nextEdgeOrdinal,nextChunkOrdinal,nextTargetOrdinal,
selectedContinuationReceiptReference,budgetLeaseReference,cancelRequested,
recoveryState`; recovery state is `prepared|publishing|continuing|abandoning`.
Stable ready requires null pending. Migrating may be stable between edges while
pending remains selected recovery authority; ordinary catalog authority still
uses only committed roots named outside pending.

## 6. External object taxonomy and lifecycle

The following is exhaustive. Unlisted kinds or cross-products are rejected.
All paths are canonical root-relative UTF-8, NFC, 1–1,024 bytes.

| object kind | storage class | path class | bytes/identity | budget | lifecycle |
|---|---|---|---|---|---|
| `source-primary-certificate` | immutable-file | source | JCS, length+digest | source-capture | retain |
| `source-origin-certificate` | immutable-file | source | JCS, length+digest | source-capture | retain |
| `source-class-document` | immutable-file | source | JCS, length+digest | source-capture | retain |
| `source-lineage-document` | immutable-file | source | JCS, length+digest | source-capture | retain |
| `prepared-model-artifact` | immutable-file | adoption | opaque, length+digest | transaction | retain/index |
| `receipt-primary-body` | immutable-file | receipt | exact inherited bytes | transaction | retain |
| `receipt-origin-body` | immutable-file | receipt | exact inherited bytes | transaction | retain |
| `receipt-class-body` | immutable-file | receipt | exact inherited bytes | transaction | retain |
| `receipt-lineage-body` | immutable-file | receipt | exact inherited bytes | transaction | retain |
| `raw-name-block` | immutable-file | migration-work | JCS, length+digest | source-capture | retain |
| `name-block` | immutable-file | migration-work | JCS, length+digest | source-capture | retain |
| `row-block` | immutable-file | migration-work | JCS, length+digest | source-capture/merge | retain |
| `run-manifest` | immutable-file | migration-work | JCS, length+digest | merge | retain |
| `tree-page` | immutable-file | migration-result | JCS, length+digest | tree | retain |
| `row-verification-block` | immutable-file | verification | JCS, length+digest | verification | retain |
| `storage-verification-block` | immutable-file | verification | JCS, length+digest | verification | retain |
| `materialization-directory` | directory | receipt | null length/digest | transaction | retain |
| `activation-directory` | directory | protocol | null length/digest | fixed transaction | retain |
| `batch-directory` | directory | protocol | null length/digest | fixed transaction | retain |
| `intent-directory` | directory | protocol | null length/digest | fixed transaction | retain |
| `catalog-batch-carrier` | carrier | protocol | framed, length+digest | transaction-bytes | retain/MMR; never storage-indexed |
| `transaction-intent` | immutable-file | protocol | JCS <=1,048,576, length+digest | transaction | retain/index |
| `selector-fixed-extent` | fixed-extent | protocol | fixed 65,536, no identity | transaction | retain |
| `journal-lock-fixed-extent` | fixed-extent | protocol | fixed 4,096, no identity | fixed transaction | retain |

`fixed-extent` is legal only for selector/lock and never has a path/storage
entry. `carrier` is legal only for catalog-batch-carrier and is selected only by
the MMR plus cumulative selector charge; it cannot occur in path/storage trees. Directories have identity v3 with null byte fields and charge 4,096.
Regular files require non-null canonical length, content digest, relative path
digest, and no-follow identity. External sequence references carry both the
storage ordinal and object content digest; work/control/sequence/page records
live inside catalog batch carriers and use record references, not external
object digests.

## 7. Forward-only abandon and retry

Cancellation never truncates or deletes selected bytes. Each selected boundary
has one forward successor:

| selected boundary | abandon successor |
|---|---|
| lease only | release unused lease; abandon receipt |
| continuation pages | retain/charge pages; mark continuation abandoned |
| lifecycle reserved | clear active reservation, record last outcome abandoned, release economic reserve |
| path reserved/materialized/bound | increment entry generation, state abandoned, retain exact object identity/charge |
| external fsynced but unindexed | index as `retained-abandoned`, never ordinary-visible |
| storage indexed/path not indexed | storage state `retained-abandoned`; path state abandoned |
| path indexed before phase commit | compensating path generation hides it from ordinary phase root |
| phase committed | cancellation applies only to the next transaction; committed authority is not undone |

Lifecycle entries have exactly `lifecycleKey,rowUUID,generation,
activeTransactionIntentID,state,pathKey,reserveBytes,provenance,lastOutcome,
lastReceiptReference`. State is `available|reserved|bound|imported|consumed`;
last outcome is `none|committed|abandoned`. Abandon from reserved/bound advances
generation, clears active transaction/path/reserve, sets available/abandoned,
and emits the inherited exact release delta. A later retry may reserve only by
advancing generation from available; it cannot erase the abandoned receipt.

Path entries add `generation` and state
`reserved|materialized|bound|indexed|retained-abandoned`. Retry from a retained
tombstone must either adopt the byte-identical external object and identity or
choose a new path; unequal bytes protect. Storage entries add state
`ordinary|retained-abandoned`. Abandoned objects remain in storage totals and
quota. Only unused leased protocol units and the unspent lifecycle reserve are
released. A3–A8 refund/payment arithmetic is otherwise unchanged.

Cancellation is acknowledged only after an abandon receipt and stable selector
are directory-fsynced and verified, temporary files are removed, leases are
settled, and all FDs/flocks are closed. Permanent failure uses the same abandon
graph. Protected evidence cannot be converted to abandon without operator
repair because doing so could launder corruption.

## 8. Literal codec registry and legal-state matrix

All JSON uses RFC 8785 JCS; strings are NFC; base64url is RFC 4648 unpadded;
hex is lowercase; safe counts are JSON integers; wide amounts are exact
`{"hi":...,"lo":...}` limbs from R10. Arrays preserve the explicitly stated
semantic order. Every nullable field is present as JSON null. Unknown and
duplicate fields fail.

Final work/control record fields, after `schema,recordOrdinal,
transactionIntentID,edgeOrdinal,activationUUID`, are exactly:

| schema suffix | exact remaining fields |
|---|---|
| `name_scan_root.v3` | `directoryIdentity,attrABIProfileSHA256,nextDirectoryOffset,nextRecordSentinelSHA256,rawEntryCount,rawNameBlockSequenceRootReference,eof,scanTranscriptSHA256` |
| `name_capture_root.v3` | `previousRootReference,nameScanRootReference,rawNameBlockSequenceRootReference,nameBlockSequenceRootReference,sortWorkRootReference,nameCount,firstName,lastName,namesSHA256` |
| `row_work_root.v3` | `previousRootReference,nameBlockSequenceRootReference,rowBlockSequenceRootReference,captureRunSequenceRootReference,nextNameBlockOrdinal,nextNameOrdinal,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `run_work_root.v3` | `previousRootReference,mergePass,nextGroupOrdinal,nextCreationOrdinal,inputRunSequenceRootReference,completedMergeGroupSequenceRootReference,outputRunSequenceRootReference,activeMergeGroupWorkReference,inputRunCount,completedGroupCount,outputRunCount,mergeTranscriptSHA256` |
| `merge_group_work.v3` | `mergePass,groupOrdinal,creationOrdinal,inputRunSequenceRootReference,inputFirstOrdinal,inputCount,cursorSequenceRootReference,headSequenceRootReference,outputRowBlockSequenceRootReference,outputRowCount,firstUUID,lastUUID,predecessorUUID,exhaustedInputCount,rollingTranscriptSHA256` |
| `run_manifest.v4` | `runKind,mergePass,runOrdinal,creationOrdinal,inputRunSequenceRootReference,inputRunCount,rowBlockSequenceRootReference,rowBlockCount,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `tree_build_root.v4` | `previousRootReference,level,phase,currentLevelInputSequenceRootReference,currentLevelPageSequenceRootReference,completedLevelSequenceRootReference,nextInputBlockOrdinal,nextInputRowOrdinal,nextGlobalRowOrdinal,nextInputPageOrdinal,nextTreeObjectOrdinal,treeTranscriptSHA256` |
| `verification_work_root.v3` | `previousRootReference,pass,rowVerificationBlockSequenceRootReference,storageVerificationBlockSequenceRootReference,nextRowOrdinal,nextStorageOrdinal,targetStorageRootReference,targetEntryCount,targetMaterializedBytes,rowTranscriptSHA256,storageTranscriptSHA256` |
| `budget_lease.v1` | `leaseGeneration,descriptorSHA256,keyDeltas,expiresAtSelectorRevision,state,consumedUnits,releasedUnits` |

The sequence root has exactly
`collectionKind,entrySchema,leafCapacity,fanout,entryCount,height,firstOrdinal,
lastOrdinal,topPageReference,transcriptSHA256`. The leaf has the common record
coordinates followed exactly by `collectionKind,entrySchema,level,firstOrdinal,
lastOrdinal,entryCount,entries,transcriptSHA256`. The node replaces `entries`
with `childCount,children`; a child has exactly `firstOrdinal,lastOrdinal,
entryCount,batchOrdinal,slotOrdinal,recordCanonicalLength,recordSHA256`.

The literal sequence entry registry is:

| collection/schema | exact fields after `schema,recordOrdinal,transactionIntentID,edgeOrdinal` |
|---|---|
| `raw-name-block/activation_raw_name_block_ref.v2` | `blockOrdinal,firstDirectoryOffset,successorDirectoryOffset,recordCount,firstNameSHA256,lastNameSHA256,blockSHA256,storageOrdinal,immutableIdentitySHA256,transcriptSHA256` |
| `name-block/activation_name_block_ref.v2` | `blockOrdinal,nameCount,firstName,lastName,blockSHA256,storageOrdinal,immutableIdentitySHA256,transcriptSHA256` |
| `row-block/activation_row_block_ref.v2` | `blockOrdinal,rowCount,firstUUID,lastUUID,blockSHA256,storageOrdinal,immutableIdentitySHA256,rowsSHA256` |
| `capture-run/activation_run_ref.v2` | `runOrdinal,mergePass,rowCount,firstUUID,lastUUID,runSHA256,storageOrdinal,immutableIdentitySHA256,rowsSHA256` |
| `input-run/activation_run_ref.v2` | `runOrdinal,mergePass,rowCount,firstUUID,lastUUID,runSHA256,storageOrdinal,immutableIdentitySHA256,rowsSHA256` |
| `completed-merge-group/activation_merge_group_ref.v2` | `mergePass,groupOrdinal,creationOrdinal,inputCount,outputRunSHA256,storageOrdinal,immutableIdentitySHA256,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `output-run/activation_run_ref.v2` | `runOrdinal,mergePass,rowCount,firstUUID,lastUUID,runSHA256,storageOrdinal,immutableIdentitySHA256,rowsSHA256` |
| `current-level-input/activation_tree_page_ref.v2` | `level,pageOrdinal,itemCount,firstUUID,lastUUID,pageSHA256,storageOrdinal,immutableIdentitySHA256,itemsSHA256` |
| `current-level-page/activation_tree_page_ref.v2` | `level,pageOrdinal,itemCount,firstUUID,lastUUID,pageSHA256,storageOrdinal,immutableIdentitySHA256,itemsSHA256` |
| `completed-level/activation_tree_level_ref.v2` | `level,pageCount,firstUUID,lastUUID,sequenceRootReference,levelSHA256` |
| `row-verification-block/activation_row_verification_ref.v2` | `pass,blockOrdinal,firstRowOrdinal,lastRowOrdinal,rowCount,blockSHA256,storageOrdinal,immutableIdentitySHA256,transcriptSHA256` |
| `storage-verification-block/activation_storage_verification_ref.v2` | `blockOrdinal,firstStorageOrdinal,lastStorageOrdinal,entryCount,blockSHA256,storageOrdinal,immutableIdentitySHA256,materializedBytes,transcriptSHA256` |

The three additional pairs are:

```text
merge-cursor/activation_merge_cursor.v3:
  inputOrdinal,rowBlockOrdinal,rowOrdinal,exhausted
merge-head/activation_merge_head.v3:
  inputOrdinal,exhausted,rowCanonicalBytes,rowSHA256
planned-object/activation_planned_object.v3:
  objectOrdinal,pathKey,pathClass,objectKind,canonicalLength,objectSHA256,
  chargeBytes,targetBinding,sourceRowOrdinal
```

No digest-only reference to a catalog record is legal. A root reference is
null or exactly `entryCount,height,batchOrdinal,slotOrdinal,
recordCanonicalLength,recordSHA256`. Page schemas for storage, path, lifecycle,
and budget use the same exact envelope as sequence pages, replacing ordinal
ranges with `firstKey,lastKey` and using their named entry arrays. Storage
uses `firstStorageOrdinal,lastStorageOrdinal`. A storage child adds
`subtreeChargedBytes`; every other child has only the seven fields above.
Storage entries are exactly `storageOrdinal,pathKey,pathClass,objectKind,
storageClass,state,objectSHA256,canonicalLength,chargeBytes,
immutableIdentitySHA256,lifecycleKey,sourceRowOrdinal`; path entries are exactly
`pathKey,relativePathUTF8Base64URL,pathClass,objectKind,generation,state,
objectSHA256,canonicalLength,storageOrdinal,transactionIntentID,targetBinding,
sourceRowOrdinal`; lifecycle entries are the exact section 7 list; budget
entries are the exact section 4 list. Entry canonical limits are respectively
1,024, 2,048, 768, and 640 bytes; sequence entries are at most 3,328 bytes.
The encoder rejects an entry over its limit before mutation. Node children are
at most 448 bytes (storage) or 384 bytes (other). Independent maximum vectors
must prove the complete page, including envelope, is at most 65,536 bytes at
32/16 leaves and 128 children; count and byte limits both apply.
Activation v6 exact fields after the four common record coordinates are:

```text
activationGeneration,previousActivationReference,state,priorActiveIndexSHA256,
migrationSourceSHA256,formatFenceSHA256,configuredRootPathSHA256,
initialPathReceiptReference,nameCaptureRootReference,rowCaptureRootReference,
sortedRunReference,treeWorkRootReference,verificationRootReference,
currentCheckpointReference,baseMMRLeafCount,baseMMRRootSHA256,
storageRootReference,pathRootReference,lifecycleRootReference,
budgetRootReference,priorActivationHistoryAccumulatorSHA256,
priorActivationHistoryLeafCount,protocolUnitCount
```

Checkpoint v7 exact fields after the common coordinates are:

```text
checkpointGeneration,previousCheckpointReference,activationState,
priorActiveIndexSHA256,migrationSourceSHA256,formatFenceSHA256,
configuredRootPathSHA256,initialPathReceiptReference,latestPathReceiptReference,
nameCaptureRootReference,rowCaptureRootReference,sortedRunReference,
treeWorkRootReference,verificationRootReference,currentNameScanRootReference,
currentNameCaptureRootReference,currentRowWorkRootReference,
currentRunWorkRootReference,currentTreeBuildRootReference,
currentVerificationWorkRootReference,nextNameOrdinal,nextRowBlockOrdinal,
mergePass,nextMergeGroupOrdinal,nextCreationOrdinal,builderLevel,
nextBuilderInputOrdinal,nextTreeObjectOrdinal,nextVerificationOrdinal,
terminalRowCount,verificationPass,nextStorageVerificationOrdinal,
storageVerificationTranscriptSHA256,storageVerificationTargetRootReference,
storageVerificationTargetEntryCount,storageVerificationTargetMaterializedBytes,
baseMMRLeafCount,baseMMRRootSHA256,storageRootReference,pathRootReference,
lifecycleRootReference,budgetRootReference,
priorActivationHistoryAccumulatorSHA256,priorActivationHistoryLeafCount,
protocolUnitCount
```
Legal phase matrix:

| phase | required current root | permitted progress | forbidden non-null |
|---|---|---|---|
| `genesis` | none | all counters zero | every work/result root |
| `scanning` | name-scan | directory offset/raw count | row/run/tree/verification results |
| `capturing-names` | name-capture | next name ordinal | row/run/tree/verification results |
| `capturing-rows` | row-work | next row block/name | sorted/tree/verification results |
| `merging` | run-work | pass/group/creation | tree/verification result |
| `building-tree` | tree-build | level/input/object | verification result |
| `verifying-rows` | verification-work | pass rows-1/rows-2 | final ready |
| `verifying-storage` | verification-work | storage ordinal/transcript | final ready |
| `ready` | all terminal result roots | terminal counts only | every current work root |
| `protected` | last valid committed roots | protected reason only | pending mutation |

Earlier result roots are monotonic and required once their phase has passed.
Later result roots are null. Exactly one current work root is non-null outside
genesis/ready/protected. Progress counters not named in the phase row are zero.
Operation kinds map one-to-one to the matching phase; `adopt-row` is legal only
while ready and cannot modify migration work roots. `budget-reserve`,
`continuation`, and `abandon` are recovery/control edges and cannot advance a
phase.

The independent vector bundle must publish literal JCS bytes and digests for
every schema above, every R12 sequence pair after the explicit extension,
every enum/null phase row, minimum, maximum, one-over, last-safe, first-unsafe,
receipt transcript preimage, target descriptor preimage, MMR leaf/node/root,
and a two-batch 17-page root split. No production codec work begins until that
bundle is independently reproducible.

## 9. Crash publication and recovery

Publication is: select pending intent → create same-directory temp batch →
write all bytes → fsync file → capture identity → rename to final exclusive
path → fsync batch directory → reopen/hash/recapture → compute successor MMR →
write selector temp → fsync → rename selector → fsync selector directory →
reopen/verify. Batch final paths are never overwritten.

| last completed boundary | restart authority |
|---|---|
| before batch rename | old selector; remove temp after validation |
| rename before batch-directory fsync | old selector; exact candidate may be adopted only from pending descriptor |
| batch-directory fsync before selector rename | old selector plus exact pending candidate; publish or abandon forward |
| selector rename before selector-directory fsync | old or new complete selector according to disk outcome |
| selector-directory fsync | new only |
| selector reopen | new only |

At every recovery, selected live references prove MMR membership. A candidate
batch must reproduce the pure descriptor-derived bytes, full identity, charge,
and next MMR; a valid-looking alien batch at the ordinal protects. There is no
tail truncation. A stale selector after directory fsync, missing batch, changed
live batch, invalid merge-event header, MMR mismatch, receipt mismatch, or
budget lease mismatch protects before ordinary authority.

Death/cancel/permanent failure after every edge invokes section 7's exact
forward abandon successor. Recovery never chooses a convenient old root after
a selected continuation. Same-owner recursive entry returns typed busy before
mutable open. Queued cancel cannot report success while the activation flock
is held.

## 10. Implementation slices, rollback, and stop gate

One unshippable compatibility slice, after plan approval:

1. independent codec/vector/MMR/page/budget oracle;
2. immutable batch writer, direct address, MMR membership, selector v5;
3. five tree codecs and the exact arbitrary-key split/continuation engine;
4. selected per-row/fixed budget authority and leases;
5. exhaustive external-object import and sequence/work conversion;
6. forward abandon/retry plus A3–A8 compatibility;
7. finite-directory EOF and incremental verification;
8. targeted/full Swift, Xcode, bridge, governance, maximum-shape checks, then
   independent GPT-5.6 Sol code/security/architecture audits.

Old binaries reject selector v5 before mutation. Before v5 publication,
rollback is the old complete authority. After it, rollback is forward recovery
or explicit protected state; selected batches are retained. Stop on any
unlisted schema/object/enum, page over 65,536, batch over sixteen records,
operation edge over sixteen permanent records/objects, height over eight,
lookup over eight B+ pages or 53 MMR merges, incomplete descriptor, digest
cycle, absent selected budget proof, scale work using fixed budget, mutation of
a final batch path, old selector after directory fsync, source/path witness
weakening, changed A3–A8 economics, raised FD/deadline/quota limits, or
historical/fixture/skipped evidence reported as fresh acceptance.

No migration result grants paid admission, trusted model identity, pricing,
settlement, enforcement, or economic activation. Physical signed feed → trusted
preparation → real MLX → settled request remains a separate named Build 1
qualification blocker.
