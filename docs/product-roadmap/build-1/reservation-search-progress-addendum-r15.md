# Reservation search progress — corrective addendum R15

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

Frozen inputs:

| input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r14.md` | `465956bd3112649956d0de79b765c9ce5e1580c215f6d4696174bd804676d1ca` |
| `test-spec-r20-reservation-r14-corrections.md` | `401d82c4b31a573e05aa1ade6a12881616e474130929a112e3e05616179b21da` |
| `reviews/reservation-search-progress-r14-plan-sol.md` | `795b6ef4d59181fba0c7e0d4064710a0a38bb948a59b78b52cd990c2332b0c78` |

The R14 gate failed with 0 Critical / 7 High / 2 Medium / 0 Low. R15
replaces R14 sections 1 through 10. It deliberately removes multi-edge intent
files, MMR membership, ten independent budget keys per row, external run/tree
objects, and prose-only abandon states. Nonconflicting R4–R13 requirements
remain governing: the two-pass source and path witnesses, finite-directory EOF,
immutable selected evidence, A3–A8 reserve/refund arithmetic, four open FDs,
eight seconds per invocation, 65,536-byte records/pages, sixteen permanent
units per carrier, and no ordinary authority from pending work.

The inspected base is `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The current implementation is
still the frozen R4 array implementation: reservation migration
`c8505d5d...`, retention `0a6b4873...`, storage `33cf0850...`, evidence
`b49c13fa...`, bindings `60abe294...`, and transactions `65cbb0e9...`. It has
none of the R15 selector, carrier, authenticated tree, lease, continuation, or
forward-abandon formats. Coordinator/BYOM work is paused and outside this
Swift-only proposal.

The corrective mapping is explicit:

| failed R14 finding | R15 correction | R21 proof |
|---|---|---|
| H1 cross-edge digest cycle | one edge intent, separate pending CAS, no future-root fields | R21-01 |
| H2 unauthorised/incomplete budget reserve | prior selected control headroom, one row entry, selected lease state | R21-05/06 |
| H3 asserted ceilings | closed transition tables and checked formulas | R21-05/06 |
| H4 contradictory taxonomy | unique physical carrier and codec table | R21-07 |
| H5 missing literal codecs/unions | exact reference, descriptor, selector, lease, receipt and object schemas | R21-01/07/09 |
| H6 partial crash oracle | selector, object, directory, carrier and tail boundary tables | R21-03 |
| H7 unencodable abandon | eight one-edge compensation steps and exact successor receipt | R21-08 |
| M1 MMR work ambiguity | MMR removed; direct eight-carrier byte/page bound | R21-02/09/10 |
| M2 ordinal ambiguity | protocol-history, carrier, and filename domains separated | R21-02/06 |

## 1. Replacement architecture and invariants

R15 has one immutable carrier file per selected physical edge and exactly one
edge intent at a time. The intent is embedded in the fixed-size selector; it
is not an external file. An edge may publish one of three target classes:

1. `record-publish`: one through fifteen catalog records plus one receipt;
2. `tree-mutate`: one through fourteen page records plus one receipt per
   carrier, with at most two carriers for a seventeen-page mutation; or
3. `external-publish`: exactly one immutable external object plus one receipt
   record in a carrier.

Target classes never mix. A logical operation advances by a sequence of
separately selected edges. Edge `e+1` is constructed only after edge `e` and
its successor selector are durable. No intent describes a later root, later
carrier digest, or later receipt. A transaction can therefore be resumed after
every selected edge without a digest fixed point or a mutable source read.

Three selector-only transitions are closed exceptions to carrier publication:
selecting an edge intent, advancing a read-only carrier-audit cursor, and the
two bootstrap directory receipts required before the carrier directory exists.
They create no immutable catalog record, consume zero ordinary/control units,
and change no ordinary root. Their selector rewrite is fixed-extent Wpeak.

Current authority is authenticated by direct carrier digests in record
references. R14's MMR is removed. A current selector authenticates its root
records; root pages authenticate child records; work/control records
authenticate their referenced records. A superseded carrier is retained by
the immutable predecessor chain and verified by bounded incremental audit, but
it is not reread on every ordinary lookup. This is a narrower and truthful
claim than R14's incomplete MMR membership claim.

Hard limits are:

```text
canonical record/page bytes                         <= 65,536
records in one carrier                              <= 16
tree pages in one carrier                           <= 14
tree pages in one logical mutation                  <= 17
carriers in one logical mutation                    <= 2
selected B+ page reads/current lookup               <= 8
complete carrier bytes hashed/current lookup        <= 8,459,040
embedded edge intent JCS bytes                      <= 24,576
pending selector JCS bytes                          <= 49,152
selector fixed extent                               = 65,536
open FDs/invocation                                 <= 4
wall time/invocation                                <= 8 seconds
source rows R                                       <= 439,804,651,110
carrier ordinal                                     <= 433,647,385,996,387
protocol units at Rmax                              <= 4,119,650,166,965,693
wide byte amount                                    <= 2^120-1
```

`8,459,040 = 8 * 1,057,380`; it is a per-lookup byte-hash ceiling, not a
throughput assertion. The eight-second bound remains measured hardware
qualification. A host that cannot preflight exact quota, `off_t`, inode, or
time capacity is unsupported before v6 publication.

## 2. Carrier format, direct references, and the acyclic commitment graph

### 2.1 Carrier path and bytes

The only carrier directory is:

```text
.reservation-migration/retirement/v1/activation/<activationUUID>/carriers/
```

Carrier ordinal is encoded as exactly sixteen lowercase hexadecimal digits
plus `.mcc`. Ordinals are consecutive from zero. A temporary is
`.<hex>.tmp.<transactionUUID>.<edgeOrdinal>` in the same directory. Final
publication uses `renameatx_np(..., RENAME_EXCL)`; final paths are never
overwritten. Direct lookup uses `openat` and never enumerates the directory.

The framing is retained from R14:

```text
header = u32be(headerLength) || headerJCS || SHA256(headerJCS) || zero padding
slot   = u32be(bodyLength) || bodyJCS || SHA256(bodyJCS) || zero padding
header extent = 8,228 bytes
slot extent   = 65,572 bytes
file length   = 8,228 + recordCount * 65,572
```

Header JCS is 2–8,192 bytes; record JCS is 2–65,536 bytes; record count is
1–16. Thus the minimum and maximum files are 73,800 and 1,057,380 bytes.
Unknown/duplicate fields, non-JCS, unsafe numbers, nonzero padding, wrong
length, trailing bytes, wrong ordinal, and digest mismatch protect.

`model_catalog_carrier_header.v2` has exactly:

```text
schema,activationUUID,carrierOrdinal,previousCarrierReference,
pendingSelectorSHA256,transactionUUID,edgeOrdinal,edgeKind,edgeIntentSHA256,
recordCount,recordTranscriptSHA256,payloadLengthBytes
```

`previousCarrierReference` is null only at ordinal zero; otherwise it is the
exact carrier reference below and must name ordinal minus one. The record
transcript is:

```text
T0 = SHA256("macprovider-carrier-v2\0" || u64be(carrierOrdinal) ||
            u32be(recordCount))
Tn+1 = SHA256("macprovider-carrier-v2\0record\0" || Tn ||
              u32be(slotOrdinal) || recordSHA256)
```

The complete carrier digest is SHA-256 of all framed bytes. The header does
not contain that digest. `carrierReference.v2` has exactly
`carrierOrdinal,payloadLengthBytes,carrierSHA256,immutableIdentitySHA256`.

### 2.2 Record-reference union

Every record body begins with exactly
`schema,activationUUID,transactionUUID,edgeOrdinal,slotOrdinal,recordOrdinal`.
`recordOrdinal` is the consecutive selected catalog-record ordinal and is
independent of the carrier ordinal. References
are a tagged closed union:

```text
localRecordReference.v1:
  kind="local",slotOrdinal,recordOrdinal,recordCanonicalLength,recordSHA256

carrierRecordReference.v1:
  kind="carrier",carrierOrdinal,carrierLengthBytes,carrierSHA256,
  slotOrdinal,recordOrdinal,recordCanonicalLength,recordSHA256
```

A local reference may point only to a lower slot in the same carrier. A
carrier reference may point only to a selected carrier ordinal no greater than
the selected head. The reader hashes the complete bounded carrier before using
the slot. A root reference has exactly
`treeKind,entryCount,height,topPageReference`; `topPageReference` is a local or
carrier record reference. A sequence root reference uses the same shape with
`treeKind="sequence:<collectionKind>"`. No digest-only, inferred-carrier, MMR,
or future-carrier reference is legal.

### 2.3 One-edge intent

`model_catalog_edge_intent.v3` is embedded in the selected pending selector and
has exactly:

```text
schema,activationUUID,transactionUUID,logicalOperationKind,
logicalOperationOrdinal,edgeOrdinal,edgeKind,budgetScope,sourceRowOrdinal,
budgetCategory,baseSelectorSHA256,baseCarrierReference,
baseStorageRootReference,basePathRootReference,baseLifecycleRootReference,
baseBudgetRootReference,baseSequenceRootReference,baseWorkRootReference,
priorReceiptReference,continuationReference,operationInputReferences,
targetDescriptor,maximumTargetRecords,maximumExternalObjects,
maximumPermanentUnits,maximumChargeBytes,candidateSelectorRevision
```

`operationInputReferences` has 0–8 carrier record references. All nullable
fields are present. `edgeKind` is exactly
`record-publish|tree-mutate|external-publish|budget-reserve|budget-close|
abandon-step|phase-commit|audit-step`. `maximumTargetRecords` is 1–15 for
record publication, 1–14 for a tree carrier, zero for external publication,
and otherwise the exact non-receipt record count. `audit-step` requires both
maximum counts, units, and charge to be zero and uses no receipt. `maximumExternalObjects`
is one only for external publication and zero otherwise.
For every non-audit carrier edge,
`maximumTargetRecords + maximumExternalObjects + 1 <= 16`; the final one is
the receipt. `maximumPermanentUnits` equals that sum, never caller input.

`targetDescriptor.v3` has exactly:

```text
descriptorKind,targetTreeKind,targetKeyBase64URL,targetRangeFirstBase64URL,
targetRangeLastBase64URL,sequenceCollection,sequenceOrdinal,recordSchema,
externalObjectDescriptor,phaseFrom,phaseTo,compensationStep,
expectedPriorEntrySHA256,expectedPriorGeneration,targetCount,
targetCoordinateOrderSHA256
```

The closed null matrix is:

| descriptor kind | required | all other coordinates |
|---|---|---|
| `tree-update` | tree kind, key, range, prior entry/generation, target count/coordinate order | null |
| `sequence-append` | collection, ordinal, record schema, target count/coordinate order | null |
| `record-set` | record schema, target count/coordinate order | null |
| `external-object` | external descriptor, target count/coordinate order | null |
| `phase-transition` | phase from/to, target count/coordinate order | null |
| `compensation` | compensation step, prior entry/generation, target count/coordinate order | null |
| `audit` | zero target count and canonical empty coordinate digest | null |

The intent digest is:

```text
I = SHA256("macprovider-edge-intent-v3\0" || u64be(jcs.count) || jcs)
```

`targetCoordinateOrderSHA256` hashes an array of exact
`targetOrdinal,targetRole,treeLevel,keyRangeFirstBase64URL,
keyRangeLastBase64URL` coordinates. It never hashes a target record, target
record digest, carrier, or receipt. Target records bind `I`; the coordinate
list is therefore available before `I` and cannot form a digest cycle.

Records bind `I`, edge ordinal, and their deterministic input coordinates.
`selectedTargetReference.v1` is a tagged union with exactly `kind,reference`.
Kind is `tree-root|sequence-root|work-record|checkpoint|activation|none`.
Tree/sequence uses the exact root reference; work/checkpoint/activation uses a
carrier record reference; none requires null. `externalObjectReference.v2` has
exactly `descriptor,immutableIdentity,immutableIdentitySHA256,chargeBytes`.
`priorReceiptReference`, `lastReceiptReference`, and every work-record reference
are null or carrier record references; their schema discriminator must match the
phase/field that contains them.

`edge_receipt.v3` has exactly:

```text
schema,activationUUID,transactionUUID,edgeOrdinal,edgeKind,edgeIntentSHA256,
intentBaseSelectorSHA256,pendingSelectorSHA256,priorReceiptReference,
targetRecordReferences,
externalObjectReference,targetRootReference,continuationReference,
budgetLeaseDigest,selectedUnits,selectedChargeBytes,priorWorkAccumulator,
outcome,receiptTranscriptSHA256
```

Target references in a receipt are local references. `externalObjectReference`
is non-null only for external publication. `targetRootReference` is non-null
only on the final carrier of a tree/sequence mutation. `continuationReference`
is non-null only on a nonfinal tree carrier and has exactly
`mutationKind,nextTargetOrdinal,targetCount,frontierReferences,
targetCoordinateOrderSHA256,priorWorkAccumulator`; frontier references are 1–8
local or carrier references. Outcome is
`continued|committed|abandoned|protected`. `priorWorkAccumulator` is the
selector accumulator before this carrier. The successor selector folds the
complete carrier digest, unit count, and charge after the carrier exists. No
receipt contains its own carrier digest directly or indirectly.
The receipt transcript uses R14's null-field preimage and the
`macprovider-receipt-v1` domain.

The dependency graph is exactly:

```text
selected base selector/roots/inputs
  -> embedded edge intent I and pending-intent selector
  -> external bytes or target record bytes
  -> receipt bytes
  -> carrier header/transcript and complete carrier digest
  -> between-edge successor selector
  -> next pending-intent selector
```

The intent's `baseSelectorSHA256` names the selector *before* the separate
pending-intent CAS. The carrier and receipt name the selected pending selector.
The successor after a carrier contains no next intent. A separate selector-only
CAS then embeds the next intent, which can safely name the predecessor selector.
No selector contains an intent that hashes that same selector. No node
references a later node. Same-tree multi-edge work refers to the prior
selected receipt/continuation, never to a future root in an earlier intent.
Two-edge and 64-edge logical operations therefore repeat this acyclic graph;
there is no multi-edge descriptor array and no 16-versus-64 intent ambiguity.

## 3. Selected budget authority without self-recursion

### 3.1 One row entry, one fixed entry, one open lease

The budget tree has one `row-budget` entry per source row and one `fixed-budget`
entry. It never has ten independently updated keys. Operations touching more
than one row are charged to the lowest represented source-row ordinal; an
operation is never both row and fixed scoped.

`budget_entry.v2` has exactly:

```text
key,scope,sourceRowOrdinal,generation,categoryUnitLimits,categoryUnitsReserved,
categoryUnitsSpent,categoryUnitsAbandoned,categoryByteLimits,
categoryBytesReserved,categoryBytesSpent,categoryBytesAbandoned,
controlUnitLimit,controlUnitsSpent,controlByteLimit,controlBytesSpent,
openLeaseDigest,lastLeaseAuthorizationSHA256,lastCloseOutcome
```

`key` is `0x01||u64be(row)` for row and `0x02` for fixed. Row ordinal is
required only for row scope. The eight category arrays have exactly six entries
in this order: `source-capture,merge,tree,verification,materialization,abort`.
Every unit field is a safe integer. Every byte field is inherited `wide-v1`.
For every category:

```text
reserved + spent <= limit
abandoned <= spent
controlUnitsSpent <= controlUnitLimit
controlBytesSpent <= controlByteLimit
```

Budget entry JCS is at most 3,328 bytes. The budget leaf capacity is sixteen,
not R14's thirty-two; overflow splits 9/8. Storage and lifecycle retain
thirty-two-entry leaves and split 17/16. Path and every sequence retain sixteen
and split 9/8. All internal fanout is 128 and height is 0–8. The independent
maximum encoder must fit sixteen maximum budget entries plus the complete page
envelope within 65,536 bytes; byte and count limits both apply.

Only one activation transaction may be pending under the activation flock, so
one `openLeaseDigest` is sufficient. No lease index or successor search exists.

`lastLeaseAuthorizationSHA256` is null at genesis and thereafter names the most
recently closed or open authorization. `lastCloseOutcome` is
`none|committed|abandoned`. Budget entries never contain a future receipt or
carrier reference.

`budgetLease.v3` is an embedded selected object, not a catalog record:

```text
schema,authorization,authorizationSHA256,state,debits
```

`leaseAuthorization.v1` has exactly
`transactionUUID,budgetKey,budgetEntryGeneration,maximumDebits,
baseBudgetRootReference,expiresAtRevision`. Its digest is
`SHA256("macprovider-budget-lease-authorization-v1\0" || u64be(jcs.count) ||
jcs)`. `maximumDebits` has one operation-category maximum and optionally one
abort maximum; each has exactly `category,maximumUnits,maximumChargeBytes`.
The digest is stable for the life of the lease and is the budget entry's
`openLeaseDigest` and `lastLeaseAuthorizationSHA256`.

The selected `debits` mirrors the authorization order. Each has exactly
`category,maximumUnits,maximumChargeBytes,consumedUnits,
consumedChargeBytes,abandonedUnits,abandonedChargeBytes`. State is
`reserving|open|closing-commit|closing-abandon`. Expiry is exactly base selector
revision plus 64 and cannot be extended.

### 3.2 Nonrecursive control authorization

Every budget-tree reserve or close is itself a tree mutation. Its page,
receipt, and carrier work is authorized by the **previous selected** budget
entry's control headroom. Before writing the first control carrier, the
selector selects an edge intent plus:

```text
controlAuthorization.v1:
  budgetKey,budgetEntryGeneration,maximumUnits,maximumChargeBytes,
  consumedUnits,consumedChargeBytes,targetBudgetEntrySHA256
```

The old entry must prove the exact available control units and bytes. The
pending selector prevents a second writer. A continued control mutation
increments the selected consumed counters while retaining the old budget root.
The final carrier selects the new budget root whose `control*Spent` increments
exactly by those counters. Unequal simulation, overspend, undercharge, a second
open lease, or a final entry not matching `targetBudgetEntrySHA256` protects.
This is nonrecursive: control work is paid from an already selected allowance;
it does not attempt to reserve the pages that create its own allowance.

Reserve moves exact operation and abort maxima from available to reserved and
sets `openLeaseDigest`. Target carriers increment only the lease's selected
consumption fields in the selector; they cannot exceed the reserve. Close
moves consumed units/bytes from reserved to spent, moves unreachable selected
work to the abandoned subset, releases only unused reserve, charges its own
control mutation, clears `openLeaseDigest`, and selects an immutable closing
receipt. A partial reserve has no ordinary lease until its final budget root is
selected. A partial close retains the open lease and old budget root plus its
selected control continuation; it cannot double-release.

### 3.3 Genesis seed

The first selector v6 is created from the old v4 authority before any ordinary
R15 object. Its preflight freezes source row count `R`, exact source witness,
quota, and a selected bootstrap allowance:

```text
bootstrapUnitLimit = 19*(R+1) + 64
bootstrapCarrierLimit = 2*(R+1) + 6
bootstrapByteLimit = exact sum of candidate carrier F(length), two named
                     protocol directory charges, record bytes, and fixed-extent Wpeak
```

The `R+1` entries are all row entries plus the fixed entry. Each insertion is
a fully simulated budget-tree mutation of at most seventeen pages and one
receipt, hence at most nineteen permanent units and two carriers. The eight
named bootstrap publications are activation directory, carrier directory,
genesis activation record, genesis checkpoint record, empty-sequence registry
root record, source witness record, format-fence record, and bootstrap-close receipt;
budget-entry insertions are the separate `R+1` term. No other bootstrap kind is
legal. The fixed 64 is `8 publications * 8 units`; each non-directory named
publication is capped at seven targets plus its receipt and one carrier.
Bootstrap
selectors track
consumed units/bytes. Ordinary work is forbidden until every expected budget
entry is selected, the source witness is unchanged, bootstrap close is durable,
and unused bootstrap allowance is set to zero. There is no absent-row exception
after bootstrap.

Activation-directory and carrier-directory creation are the only selector-only
bootstrap targets because a receipt carrier cannot exist before its directory.
The first pending v6 selector names their exact paths, types, modes, and one-unit
charges before `mkdirat`; its successor stores both identities after parent
fsync/reopen. They consume two of the 64 units and no carrier. All later named
bootstrap publications use carriers. `bootstrapState.v1` has exactly
`phase,sourceRowCount,sourceWitnessSHA256,unitLimit,unitsConsumed,
carrierLimit,carriersConsumed,byteLimit,bytesConsumed,nextBudgetRowOrdinal,
activationDirectoryIdentity,carrierDirectoryIdentity`. Phase is
`directories|budget-rows|fixed-budget|records|closing|complete`; complete
requires both identities, all `R+1` budget entries, zero unused authority, and
ordinary work enabled.

## 4. Closed capacity derivation

One height-eight tree mutation emits at most seventeen pages plus two receipts:
fourteen pages + continuation receipt, then three pages + edge receipt. It is
therefore at most nineteen permanent units, two carriers, and
`2*F(1,057,380) = 2,129,920` carrier bytes. Every transition count below is a
count of logical mutations; multiplying by nineteen is conservative for
record/external edges and exact for the maximum tree case.

The reachable per-row transition table is closed:

| category | derivation of transition maximum N | N | unit limit `19N` | control limit `38N` |
|---|---|---:|---:|---:|
| source-capture | four provenance objects × three publish/index steps + four source/sequence closes | 16 | 304 | 608 |
| merge | at most `ceil(log_64(Rmax))=7` passes × four row participation steps + four run open/close steps | 32 | 608 | 1,216 |
| tree | eight levels × page emission and level-sequence advance | 16 | 304 | 608 |
| verification | two row passes × four steps + one storage pass × four steps | 12 | 228 | 456 |
| materialization | A3 directory three steps + four A5 bodies three steps each + prepared object three + six binding/phase steps | 24 | 456 | 912 |
| abort | eight retry generations × eight forward compensation steps | 64 | 1,216 | 2,432 |
| **row total** | | **164** | **3,116** | **6,232** |

The row operation registry is literal. Source-capture is
`primary|origin|class|lineage` crossed with
`publish|storage-index|path-index` (12), followed by
`raw-source-close|name-source-close|row-source-close|capture-run-close` (4).
Merge is pass 0–6 crossed with
`bind-input|publish-row-block|index-row-block|advance-output-sequence` (28),
followed by `run-open|run-close|merge-root-open|merge-root-close` (4). Tree is
level 0–7 crossed with `emit-page|advance-level-sequence` (16). Verification is
pass `rows-1|rows-2` crossed with
`open|publish-block|advance-sequence|close` (8), plus storage
`open|publish-block|advance-sequence|close` (4). Materialization is A3
`directory-publish|storage-index|path-index` (3), each of the four A5 bodies
crossed with those three steps (12), prepared artifact crossed with those three
(3), and `lifecycle-reserve|lifecycle-bind|binding-publish|phase-A6|
phase-A7|phase-A8` (6). Abort is generation 0–7 crossed with the eight section
7 compensation steps (64). These strings, scope, category, ordinal range, and
phase are the complete legal row cross-product.

The eight retry generations are a format limit. A ninth failed generation
selects `protected` with the last valid evidence; it does not erase evidence,
reuse a reserve, or silently continue outside the budget.

The fixed/global table is:

| category | derivation | N | unit limit | control limit |
|---|---|---:|---:|---:|
| source-capture | sixteen empty/global source states × two mutations | 32 | 608 | 1,216 |
| merge | eight pass-boundary states × eight global mutations | 64 | 1,216 | 2,432 |
| tree | eight levels × four root/sequence mutations | 32 | 608 | 1,216 |
| verification | four pass states × eight global mutations | 32 | 608 | 1,216 |
| materialization | eight A-phase boundaries × four global mutations | 32 | 608 | 1,216 |
| abort | sixteen named crash suffixes × eight compensation steps | 128 | 2,432 | 4,864 |
| **fixed total** | | **320** | **6,080** | **12,160** |

The fixed registry is likewise literal: source state 0–15 crossed with
`prepare|commit`; merge pass 0–7 crossed with boundary step 0–7; tree level
0–7 crossed with root step 0–3; verification pass 0–3 crossed with global step
0–7; materialization A-phase 0–7 crossed with global step 0–3; and protected
crash suffix 0–15 crossed with compensation step 0–7. The numeric suffixes are
canonical decimal without leading zero and are rejected outside those ranges.

The independent reachability generator must enumerate the named transitions;
production does not accept an operation enum absent from these tables. Every
operation identifies its table row and decrements the selected entry. The
first unit above any category, control, retry, or fixed bound fails before
candidate creation.

Including bootstrap, the format ceilings are:

```text
units(R) = (3,116 + 6,232 + 19)R + 6,080 + 12,160 + 19 + 64
         = 9,367R + 18,323
units(Rmax) = 4,119,650,166,965,693 < 2^52

carrierCount(R) <= (164*6 + 2)R + (320*6 + 2 + 6)
                = 986R + 1,928
carrierCount(Rmax) = 433,647,385,996,388 < 2^49
last legal carrier ordinal = 433,647,385,996,387
```

The last legal protocol-history unit is `units(Rmax)-1`; `units(Rmax)` is the
first rejected history ordinal. Filename parsing independently accepts safe
integers only through `2^53-1` and rejects `2^53`; sparse filename vectors do
not establish protocol history or physical capacity.

Byte budgets are selected, not inferred from units. Per row and fixed entries
store the exact preflight sum of external `F(length)` charges and maximum
carrier charges for their reachable table rows. Carrier-only format capacity
at Rmax is at most
`433,647,385,996,388 * 1,064,960 = 461,817,120,190,713,364,480`, below `2^69`.
External object lengths, directory charges, lifecycle reserves, finalization,
quota, Wpeak, and Uafter are added with checked `wide-v1`; overflow or host
inability rejects before v6.

## 5. Unique physical object taxonomy and literal codecs

Every physical path has exactly one carrier class. Catalog records, including
run manifests and tree pages, are never external objects.

| object kind | carrier class | content codec/limit | path class | budget category/scope | storage/path entry |
|---|---|---|---|---|---|
| four `source-*-certificate` kinds | external-regular | frozen inherited bytes, each <=65,536 | source | source-capture/row | yes |
| `prepared-model-artifact` | external-regular | opaque signed length, safe integer and host `off_t` | adoption | materialization/row | yes |
| four `receipt-*-body` kinds | external-regular | frozen inherited bytes, each <=1,048,576 | receipt | materialization/row | yes |
| `raw-name-block` | external-regular | `raw_name_block.v3` <=1,048,576 | migration-work | source-capture/row | yes |
| `name-block` | external-regular | `name_block.v3` <=1,048,576 | migration-work | source-capture/row | yes |
| `row-block-capture` | external-regular | `row_block.v4(role=capture)` <=1,048,576 | migration-work | source-capture/row | yes |
| `row-block-merge` | external-regular | `row_block.v4(role=merge)` <=1,048,576 | migration-work | merge/row | yes |
| `row-verification-block` | external-regular | `row_verification_block.v3` <=1,048,576 | verification | verification/row or fixed | yes |
| `storage-verification-block` | external-regular | `storage_verification_block.v3` <=1,048,576 | verification | verification/row or fixed | yes |
| `materialization-directory` | external-directory | no content bytes | receipt | materialization/row | yes |
| `activation-directory` | protocol-directory | no content bytes | protocol | bootstrap | no |
| `carrier-directory` | protocol-directory | no content bytes | protocol | bootstrap | no |
| `catalog-carrier` | protocol-carrier | section 2 framing | protocol | selected lease/control | no |
| `selector-fixed-extent` | fixed-extent | exactly65,536 | protocol | Wpeak only | no |
| `journal-lock-fixed-extent` | fixed-extent | exactly4,096 | protocol | bootstrap | no |

There is no external `run-manifest`, external `tree-page`, `intent-directory`,
external intent, `transaction-bytes` category, `fixed transaction` category,
or ambiguous `source-capture/merge` row-block. `run_manifest.v5`, all B+ pages,
work roots, sequence roots, receipts, checkpoints, and activations are catalog
records in carriers.

Generated external JCS schemas are exactly:

```text
raw_name_block.v3:
  schema,activationUUID,blockOrdinal,firstDirectoryOffset,
  successorDirectoryOffset,records,recordCount,recordsSHA256
name_block.v3:
  schema,activationUUID,blockOrdinal,names,nameCount,firstName,lastName,namesSHA256
row_block.v4:
  schema,activationUUID,role,blockOrdinal,rows,rowCount,firstUUID,lastUUID,rowsSHA256
row_verification_block.v3:
  schema,activationUUID,pass,blockOrdinal,firstRowOrdinal,lastRowOrdinal,
  rowCount,priorTranscriptSHA256,terminalTranscriptSHA256
storage_verification_block.v3:
  schema,activationUUID,blockOrdinal,firstStorageOrdinal,lastStorageOrdinal,
  entryCount,materializedBytes,priorTranscriptSHA256,terminalTranscriptSHA256
```

Arrays are semantic order; role is exactly `capture|merge`; empty blocks are
forbidden. Their sequence-reference schemas are R14 section 8 with
`row-block` split into `row-block-capture` and `row-block-merge`. The
`run_manifest.v5` catalog record is R14 `run_manifest.v4` plus exact
`rowBlockRole`; its row-block sequence must match that role. This is the sole
run-manifest representation.

`immutableIdentity.v3` remains R14's exact schema. The closed type/null matrix
is:

| class | byteLength | contentSHA256 | relativePathSHA256 | identity | path/storage entry |
|---|---|---|---|---|---|
| external-regular | non-null safe integer | non-null | non-null | required, fileType regular | required |
| external-directory | null | null | non-null | required, fileType directory | required |
| protocol-directory | null | null | non-null | required, fileType directory | forbidden |
| protocol-carrier | non-null safe integer | non-null complete carrier digest | non-null | required, fileType regular | forbidden |
| fixed-extent | exact literal size | null | null | forbidden | forbidden |

`externalObjectDescriptor.v4` has exactly
`objectKind,carrierClass,contentCodec,canonicalRelativePathBase64URL,pathKey,
pathClass,budgetScope,sourceRowOrdinal,budgetCategory,canonicalLength,
objectSHA256,expectedAbsent,sourceBinding`. Length/digest are null together only
for directories. `sourceBinding` is null or exactly
`sourceRowOrdinal,sourceRecordSHA256,provenance`.

Storage entries have exactly
`storageOrdinal,pathKey,pathClass,objectKind,carrierClass,state,objectSHA256,
canonicalLength,chargeBytes,immutableIdentitySHA256,lifecycleKey,
sourceRowOrdinal,transactionUUID`. Path entries have exactly
`pathKey,relativePathUTF8Base64URL,pathClass,objectKind,carrierClass,
generation,state,objectSHA256,canonicalLength,storageOrdinal,
immutableIdentitySHA256,transactionUUID,targetBinding,sourceRowOrdinal`.
Regular entries require non-null object digest/length; directory entries require
both null. `targetBinding` is null until bound and otherwise is exactly
`bindingKind,targetRecordReference`. Storage state is
`ordinary|retained-abandoned`; path state is
`reserved|materialized|bound|indexed|retained-abandoned`. All other
cross-products reject.

All remaining work/control, sequence, page, activation, and checkpoint record
field lists remain exactly R14 section 8 after these substitutions:
`batchOrdinal` becomes `carrierOrdinal`, a page/record reference uses the R15
tagged union, MMR fields are removed, `budget_lease.v1` is removed, and the
activation/checkpoint fields `baseMMRLeafCount,baseMMRRootSHA256` become
`baseCarrierReference,carrierAuditState`. `carrierAuditState.v1` has exactly
`snapshotHeadReference,nextCarrierReference,verifiedCount,verifiedBytes,
reverseTranscriptSHA256,complete`. Unknown legacy MMR, external-intent, or
mixed batch/carrier fields reject.

## 6. Selector, continuation, and whole-publication crash oracle

`model_catalog_selector.v6` has exactly:

```text
schema,selectorRevision,activationUUID,state,selectedActivationReference,
selectedCheckpointReference,priorActiveIndexSHA256,migrationSourceSHA256,
formatFenceSHA256,fixedExtentRootSHA256,activationMaterializedBytes,
activationWorkReservedBytes,activationLifecycleReservedBytes,
activationSpentSlackBytes,activationChargedBytes,activationQuotaBytes,
carrierMaterializedBytes,carrierChargedBytes,carrierCount,carrierHeadReference,
storageRootReference,pathRootReference,lifecycleRootReference,
budgetRootReference,pendingTransaction,lastReceiptReference,
carrierAuditState,bootstrapState,protocolUnitCount
```

The selector file is exactly
`u32be(jcsLength)||jcs||SHA256(jcs)||zeroPadding` to 65,536 bytes. JCS length is
2–49,152; all padding is zero. `fixedExtentRootSHA256` is
`SHA256("macprovider-selector-v6\0"||u64be(nullJCS.count)||nullJCS)`, where
`nullJCS` is the selector JCS with only that field null. The final complete
file digest is not embedded or referenced by a predecessor receipt. The
revision, predecessor roots, intent/receipt references, and internal null-field
digest determine whether the path contains the old, pending, or successor
state. This gives the fixed extent one acyclic self-check and rejects short,
trailing, or nonzero-padded selectors.

State is `migrating|ready|protected`. `pendingTransaction` is null or exactly:

```text
transactionUUID,logicalOperationKind,logicalOperationOrdinal,phase,
edgeIntent,edgeIntentSHA256,openBudgetLease,controlAuthorization,
continuationReference,workAccumulator,cancelRequested,compensationCursor
```

Phase is `between-edges|between-carriers|reserving|executing|closing-commit|
closing-abandon|abandoning`. `edgeIntent` and `edgeIntentSHA256` are non-null
only in the five active edge phases and null in the between states.
`controlAuthorization` is non-null only for `budget-reserve|budget-close` and
their control continuations; every other edge requires null. Every carrier successor first selects
a between state with no intent. The next edge starts only after a separate
pending-intent selector CAS. `openBudgetLease` may remain non-null across the
between states. A stable ready selector has null `pendingTransaction`.
`workAccumulator` has exactly
`selectedCarrierCount,selectedRecordCount,selectedExternalCount,
selectedUnits,selectedChargeBytes,abandonedUnits,abandonedChargeBytes,
terminalSHA256`; it folds each selected carrier/object in edge order.
`compensationCursor` is null outside abandoning or exactly
`generation,nextStep,completedStepCount,terminalReceiptReference`.
The embedded intent is at most 24,576 bytes; the entire pending selector JCS is
at most 49,152; framing/padding fills the 65,536 fixed extent. Independent
maximum vectors, rather than a production `MemoryLayout` assertion, prove it.

Every filesystem mutation follows one of these tables.

**Selector pending-intent publication**

| durable boundary | restart authority |
|---|---|
| before temp fsync | old selector only; remove valid temp |
| temp fsync before exclusive rename | old selector only; temp is Wpeak |
| rename before selector-directory fsync | old or pending according to exact file bytes |
| selector-directory fsync | pending only |
| reopen/closed-decode | pending only; mismatch protects |

No target path may be created before pending-only authority.

**External object or protocol-directory publication**

| durable boundary | restart action under selected intent |
|---|---|
| before final exclusive rename/create | absent target; discard temp |
| final name exists before containing-directory fsync | absent or exact candidate may be resumed; unequal/type/link mismatch protects |
| containing-directory fsync before receipt carrier | exact candidate only; recapture full identity, publish receipt or abandon forward |
| receipt carrier selected | object is selected work; index/compensate forward only |

Directory publication uses `mkdirat`, parent fsync, no-follow reopen, exact
empty-entry check, and identity recapture. The A3 materialization directory is
charged exactly 4,096 on its durable receipt edge. A4 transfers that selected
charge into materialized accounting once. Each A5 body uses its own prior
intent, file fsync, containing-directory fsync, full identity recapture, and
durable receipt before the next body intent.

**Carrier publication and selector commit**

| durable boundary | restart authority/action |
|---|---|
| temp create/write before file fsync | pending selector; remove temp |
| file fsync before exclusive final rename | pending selector; exact temp may resume |
| final rename before carrier-directory fsync | pending selector; exact candidate at `head+1` may resume |
| carrier-directory fsync before successor-selector rename | pending selector plus exact candidate; select it or abandon forward |
| successor-selector rename before selector-directory fsync | pending or successor according to exact disk outcome |
| selector-directory fsync | successor only |
| successor reopen | successor only; mismatch protects |

An exact candidate must match path, ordinal, previous head, pending selector,
intent digest, record bytes, complete digest, identity, units, charge, and
expected receipt. Same-path unequal, inode replacement, missing-after-fsync,
symlink, hardlink, stale predecessor, or descriptor mismatch protects.

There is no truncation. With no pending intent, only `head+1` may be inspected;
a well-typed unselected file there is removed and the directory fsynced because
the protocol always selects intent before create. With a pending intent,
`head+1` is adopted only if byte-identical. Paths beyond `head+1` are not
enumerated or authority; if later reached, any collision protects. Selected
carriers at or below head are never removed.

Incremental audit starts from a selected snapshot head and walks
`previousCarrierReference` backward at at most eight complete carriers or the
remaining eight-second budget per invocation. It verifies digest, identity,
ordinal decrement, and predecessor link, then selects the exact audit cursor.
Completion at carrier zero marks that snapshot head verified. It makes no claim
about a carrier not yet visited. Ordinary current lookups use at most eight
direct carrier hashes and B+ page reads; audit work is separate.

## 7. Encodable forward abandon and A3–A8 preservation

Abandonment never lists or rewrites every selected page. The selected
`workAccumulator` already commits all partial carriers and charges. The
compensation queue contains at most these eight literal steps, in order:

```text
retain-external-storage, hide-path, release-lifecycle, close-sequence,
close-work-root, close-budget-abandoned, publish-abandon-receipt,
clear-pending
```

Inapplicable steps are encoded as completed zero-delta steps; they are never
omitted or reordered. Each applicable step is its own one-edge intent. A tree
mutation may use two carrier edges through the exact continuation reference.
Thus no abandon intent exceeds one descriptor, sixteen units per carrier, or
two carriers per mutation.

The exact state effects are:

| prior selected state | forward result | roots selected | economics/budget |
|---|---|---|---|
| lease reserved, no target | no path/storage/lifecycle change | budget close only | release all ordinary+abort reserve; spend control only |
| continuation selected | pages remain carrier-selected and ordinary-unreachable | work accumulator then budget close | spent selected units; abandoned subset equals unreachable units |
| external durable, no storage entry | add `retained-abandoned` storage entry | storage then budget | retain exact charge; ordinary invisible |
| path reserved/materialized/bound | next generation `retained-abandoned` with exact identity | path, optional storage, then budget | no selected object refund |
| lifecycle reserved/bound before spend | next generation `available`, active intent/path/reserve null, lastOutcome abandoned | lifecycle then budget | release only inherited unspent reserve |
| lifecycle reserve already spent | next generation keeps consumed state and records abandoned outcome | lifecycle then budget | no economic release |
| storage ordinary, phase uncommitted | next generation `retained-abandoned`; path hidden | storage/path then budget | retain charge |
| phase committed | no compensation of committed phase | none for prior operation | cancellation applies to next operation |

Lifecycle state remains `available|reserved|bound|imported|consumed` and
`lastOutcome=none|committed|abandoned`; there is no lifecycle state named
abandoned. Path/storage use only the enums in section 5. A continuation receipt
is immutable; abandonment is represented by a later `edge_receipt.v3` whose
`priorReceiptReference` and work accumulator commit it. Nothing marks or
mutates the old receipt.

The lifecycle reserve becomes spent at exactly the selected A6 binding receipt
that transitions `bound -> imported|consumed`. Before that receipt, abandon
releases 581,632 for classified or 696,320 for unclassified provenance. After
it, abandon releases zero. The A3 4,096 directory charge, A4 transfer, A5
ordered body charges, A6 binding, A7 completion, A8 retirement, historical
holds, immutable settlement receipts, and refund formulas remain byte-for-byte
the inherited R10–R12 equations. R15 changes protocol accounting only; it does
not mint, settle, refund, or activate economic value.

`abandon_receipt.v2` has exactly:

```text
schema,activationUUID,transactionUUID,abandonGeneration,
baseSelectorSHA256,firstSelectedReceiptReference,lastSelectedReceiptReference,
preReceiptWorkAccumulator,completedCompensationSteps,baseStorageRootReference,
targetStorageRootReference,basePathRootReference,targetPathRootReference,
baseLifecycleRootReference,targetLifecycleRootReference,
baseBudgetRootReference,targetBudgetRootReference,lifecycleReserveReleasedBytes,
leaseReleasedUnits,leaseReleasedBytes,spentUnits,spentBytes,abandonedUnits,
abandonedBytes,outcome,receiptTranscriptSHA256
```

`completedCompensationSteps` contains exactly the eight literals in order.
Cancellation is acknowledged only after this receipt, budget close, and the
selector with null pending are file-fsynced, directory-fsynced, reopened, and
verified; all temporaries are gone and every FD/flock is closed. Protected
evidence cannot be converted to abandoned. A retry advances lifecycle/path/
budget and abandon generation and preserves all prior receipts.

## 8. Phases, compatibility, implementation slices, and stop gate

R14's phase matrix remains after removal of MMR fields and substitution of R15
references. Exactly one current work root is non-null in an active migration
phase; earlier result roots are monotonic, later roots null, irrelevant counters
zero, and ready has null pending. Budget reserve/close, continuation, audit, and
abandon do not advance product phase.

This remains one unshippable compatibility slice after approval:

1. independent JCS/reference/carrier/selector/budget/reachability vectors;
2. selector v6 and embedded one-edge intent CAS;
3. immutable carriers and direct carrier references;
4. five authenticated trees plus bounded continuation;
5. bootstrap, row/fixed budgets, selected leases, and exact byte accounting;
6. unique external taxonomy and all work/sequence codecs;
7. forward compensation, finite-directory EOF, and incremental audit;
8. targeted/full Swift, Xcode, CLI/app bridge, governance, maximum-shape, then
   independent GPT-5.6 Sol code/security/architecture audits.

Old binaries reject selector v6 before mutation. Before v6, rollback is the
old complete authority. After v6, rollback is forward recovery or protected
state; selected carriers/objects remain. Observability reports selector and
carrier revision, pending phase/edge, budget scope/category and remaining
units/bytes, bootstrap progress, audit snapshot/cursor, cancellation state,
and protected reason. It never logs source bodies, paths beyond existing
sanitization, artifacts, keys, or secrets.

Stop on an unlisted schema/object/enum/cross-product; target classes mixed in
one edge; more than one descriptor; future root/digest in an intent; carrier
over sixteen records; tree carrier over fourteen pages; logical mutation over
seventeen pages/two carriers; selector/intent/page/body over its exact limit;
missing selected control authorization; a second open lease; budget scope or
category substitution; first unit/byte above a selected limit; MMR or external
intent accepted; selected carrier deletion/truncation; stale selector after
directory fsync; source/path witness weakening; changed A3–A8 arithmetic;
raised FD/deadline/quota limits; coordinator overlap before BYOM resolution; or
historical, fixture-only, skipped, zero-selected, timed-out, or interrupted
evidence reported as fresh passing evidence.

No reservation migration result grants paid admission, trusted model identity,
pricing, settlement, enforcement, or economic activation. Physical signed feed
to trusted preparation to actual MLX to correctly settled request remains a
separate Build 1 qualification blocker.
