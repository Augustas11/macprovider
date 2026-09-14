# Build 1 reservation search progress addendum R17

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This is the complete corrective overlay for the six High
findings in
`reviews/reservation-search-progress-r16-plan-sol.md`. It is reviewed together
with `test-spec-r23-reservation-r17-corrections.md`. No Swift source or test is
authorized until an independent native GPT-5.6 Sol gate reports zero Critical,
High, and Medium findings for the exact two-file revision.

The inspected repository base remains `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The working code is still the R4
array/scan reservation implementation described by R16. R17 is design only.

## 1. Authority, scope, and supersession

R17 replaces R16 sections 3.2, 4, 6, 7, 9, and the affected parts of sections
8 and 10. R16's unselected activation scaffold, carrier format, acyclic local
root promotion, ordered A3/A4/A5 publications, terminal abort successor, A3+
forward-only economics, eight-second control-call deadline, four-FD ceiling,
and product limit of 1,024 rows remain normative where this document does not
replace them. No R14 or R15 codec is inherited.

The wire discriminator becomes `model_catalog_selector.v8`; v7 is an
unimplemented rejected proposal. A selected v8 graph may contain only the
schemas and versions named here. Older binaries reject the v4 format fence and
v8 selector without mutation. R17 does not grant admission, model identity,
pricing, settlement, rewards, enforcement, or production qualification.

## 2. Generation-zero carrier-directory authority

The direct paths remain exactly:

```text
.reservation-migration/retirement/v1/activation.lock
.reservation-migration/retirement/v1/activation/<activationUUID>/active.json
.reservation-migration/retirement/v1/activation/<activationUUID>/carriers
```

The activation directory is the unselected scaffold created under the R4
journal lock before the v4 format fence. Generation zero adopts that captured
directory identity and selects the intent for its `carriers` child. The v8
selector has a mandatory `selectedCarrierDirectoryIntent` key. Its value is
`directoryIntent.v2` at generation zero and JSON null at every later revision.

`directoryIntent.v2` has exactly:

```text
schema,parentIdentitySHA256,relativePathUTF8Base64URL,pathSHA256,fileType,
mode,expectedAbsent,chargeBytes
```

The generation-zero value is fixed to
`schema="directory_intent.v2"`, the selected activation-directory identity
digest, base64url of UTF-8 `carriers`,
`SHA256("macprovider-relative-path-v1\0" || u64be(8) || "carriers")`,
`fileType="directory"`, `mode=448`, `expectedAbsent=true`, and
`chargeBytes=4096`. It cannot name `..`, `/`, an empty component, a NUL, a
non-NFC string, an absolute path, or any parent other than the selected
activation directory.

`bootstrapState.v3` has exactly:

```text
schema,phase,sourceRowCount,sourceWitnessSHA256,unitLimit,unitsConsumed,
unitsReleased,carrierLimit,carriersConsumed,carriersReleased,byteLimit,
bytesConsumed,bytesReleased,nextBudgetRowOrdinal,activationDirectoryIdentity,
carrierDirectoryIdentity,bootstrapScaffoldChargeBytes,
bootstrapDirectoryChargeBytes
```

`schema` is `bootstrap_state.v3`. Phase is exactly
`carrier-directory-intent|budget-rows|genesis-records|closing|complete`.
Generation zero requires phase `carrier-directory-intent`, non-null
`activationDirectoryIdentity`, null `carrierDirectoryIdentity`, consumed
units/carriers/bytes of `1/0/4096`, released counters zero, next row zero,
scaffold charge 4096, and directory charge zero. The selector revision-one
successor requires phase `budget-rows`, null
`selectedCarrierDirectoryIntent`, non-null captured
`carrierDirectoryIdentity`, consumed units/carriers/bytes of `2/0/8192`, and
both directory charges 4096. No other field may change.

The first post-fence call uses `mkdirat` relative to an opened, revalidated
activation-directory descriptor. It creates only the selected child, fsyncs
the parent, reopens the child without following links, requires it empty and
mode 0700, captures `immutableIdentity.v4`, then publishes revision one. Before
revision-one directory fsync, recovery accepts only absence or the exact empty
candidate matching intent and parent identity. Afterwards, absence, nonempty
content, or identity drift protects; a selected missing directory is never
recreated.

For product-admissible R, bootstrap selects
`unitLimit=21*(R+1)+50` and `carrierLimit=2*(R+1)+6`: each of the R row budget
entries and the one fixed entry receives 21 protocol units and two conservative
carrier permits; the six genesis records receive 50 units and six permits.
`byteLimit` is the exact checked-wide sum of the encoded candidate carrier
extents plus the two 4,096-byte directory charges, never merely free-space
remaining. Bootstrap close
sets
`unitsReleased=unitLimit-unitsConsumed`,
`carriersReleased=carrierLimit-carriersConsumed`, and
`bytesReleased=byteLimit-bytesConsumed`, then requires each sum to equal its
limit before phase `complete`. Released authority cannot be reused. Ordinary
work remains disabled until the close selector is durable.

## 3. Stable lease identity and selected mutable state

`leaseAuthorization.v3` has exactly:

```text
schema,activationUUID,transactionUUID,budgetKey,budgetEntryGeneration,
logicalOperationKind,logicalOperationOrdinal,maximumTargetEdges,
maximumDebits,baseBudgetRootReference,baseSelectorSHA256
```

Its stable identity is always named `leaseAuthorizationSHA256` and is:

```text
SHA256("macprovider-budget-lease-authorization-v3\0" ||
       u64be(authorizationJCS.count) || authorizationJCS)
```

It never changes across reserve, target, replay, close, abort, or terminal
selector revisions. `maximumTargetEdges` is 1...64. Each debit entry has
exactly `category,maximumUnits,maximumChargeBytes`; categories are unique and
in canonical category order.

`budgetLease.v5` has exactly:

```text
schema,authorization,leaseAuthorizationSHA256,state,debits,
targetEdgesConsumed,lastSelectedEdgeOrdinal
```

State is `reserving|open|closing-commit|closing-abort`. A selected lease-state
digest is always named `leaseStateSHA256` and is:

```text
SHA256("macprovider-budget-lease-state-v5\0" ||
       u64be(leaseJCS.count) || leaseJCS)
```

Every selected `budget_entry.v4` has both
`openLeaseAuthorizationSHA256` and `openLeaseStateSHA256`. They are both null
when no lease is open and both non-null otherwise. The first is the stable
authorization identity; the second equals the exact mutable lease embedded in
the same selector. Every pending transaction, continuation, and receipt carries
both. A retry must retain the stable authorization digest and name the exact
predecessor state digest. A counter or state change produces a new state digest
and matching budget entry; stale-state substitution rejects.

There is no lease owner, expiry, PID, task identity, timestamp, renewal, or
heartbeat. Ownership means only: the caller holds the per-call activation
flock, reopened and validated the selected selector, and publishes an intent
whose predecessor selector digest and lease-state digest both match. The flock
and all descriptors close before return. Any later compatible process may
resume the selected transaction.

`controlAuthorization.v3` has exactly:

```text
schema,budgetKey,budgetEntryGeneration,leaseAuthorizationSHA256,
baseLeaseStateSHA256,maximumUnits,maximumChargeBytes,consumedUnits,
consumedChargeBytes,targetBudgetEntrySHA256
```

`targetBudgetEntrySHA256` is the digest of the exact projected
`budget_entry.v4` leaf value after the authorized transition:

```text
SHA256("macprovider-budget-entry-state-v4\0" ||
       u64be(projectedEntryJCS.count) || projectedEntryJCS)
```

For reserve it names the entry with both open digests selected. For ordinary
progress it names the entry with unchanged stable identity and the successor
state digest. For commit/abort close it names the final entry with both open
digests null, exact spent/released/abandoned counters, incremented generation,
and `lastCloseOutcome=committed|aborted`. The carrier receipt embeds the same
projected-entry digest. Root promotion is accepted only if a direct lookup in
the promoted budget root yields byte-identical projected entry JCS. Thus the
target digest binds the closing counters and the actually selected root.

For target edge ordinal `n`, the predecessor lease has
`targetEdgesConsumed=n`, and the successor has `n+1` and
`lastSelectedEdgeOrdinal=n`. Replaying an already selected edge does not
increment it. A 65th edge, nonmonotonic ordinal, category substitution, second
open lease, closed-lease reuse, different authorization, or mutable-state
rollback rejects before filesystem mutation.

## 4. Selected progress, checkpoint, and activation graph

After bootstrap close, the v8 selector directly selects
`sequenceRegistryRootReference` and
`workRootReference` in addition to storage, path, lifecycle, and budget roots.
It also selects a checkpoint and activation record produced by every logical
mutation. Therefore no committed source capture, run/merge, tree, verification,
materialization, recovery, or audit progress exists outside selected authority.

Every post-bootstrap logical mutation expands in this exact order:

```text
P0 reopen and validate selector S(n), roots, checkpoint, activation and lease
P1 publish pending selector S(n+1) with edge intent and predecessor digests
P2 publish one or two carriers containing target records/pages,
   edge_receipt.v5, activation_record.v4 and checkpoint_record.v4
P3 reopen/hash/identity-check the complete carrier chain
P4 promote every local target root through its complete carrier reference
P5 publish successor S(n+2) selecting all six promoted roots,
   selectedActivationReference, selectedCheckpointReference, receipt,
   carrier head, counters and successor lease state
P6 release descriptors and flock before reporting success/retry/cancellation
```

The receipt, activation, and checkpoint are in the last carrier and refer only
to lower slots. A record cannot embed a complete reference to its own carrier.
Instead each activation/checkpoint root is `rootSnapshot.v1`, with exactly
`schema,selectedRootReference,localRootReference,rootPromotion`. An unchanged
root has a non-null selected carrier-addressable root and null local/promotion;
a root changed in this carrier has null selected root and a paired local root
plus promotion. Validation resolves the latter against the enclosing complete
carrier, using the same promotion function as the selector. This is the only
legal nested local reference in a selected record.

`activation_record.v4` contains the six root snapshots, previous activation
reference, current checkpoint predecessor, phase/state, source witness, last
receipt predecessor, and audit state. `checkpoint_record.v4` contains the same
snapshots, the new activation local reference, previous checkpoint reference,
phase, logical operation/edge ordinals, work cursor, source witness, last
receipt local reference, and audit state. Its same-carrier activation and
receipt references are local and lower-slot. The successor promotes and
selects the activation/checkpoint records and each changed root. Resolving
their six snapshots must equal the selector's six roots byte for byte; resolving
the checkpoint receipt must equal the selector's last receipt. No root may be
null; an empty tree uses `emptyRootReference.v1`.

A crash before P3 leaves the pending selector and absent or exact candidates.
A crash after carrier durability and before P5 resumes only the exact
promotion/successor. P5 is the sole authority advance. A carrier that contains
new work but is not selected by the successor is not committed progress and is
never an input to a later edge. A selector that advances any root without the
matching activation/checkpoint pair protects.

Each mutation can contain at most 17 B+ pages/target records, two edge receipts
(one per carrier), one activation and one checkpoint: 21 permanent records in
at most two 16-slot carriers. It reserves 21 ordinary units and 42 control
units. The existing conservative six
carrier/control permit ceiling per mutation remains. The literal logical
transition set remains R16's 174 per row and 320 fixed transitions, including
all A3/A4/A5 phase records and the terminal abort sequence. The corrected
capacity is therefore:

```text
row ordinary = 174 * 21 = 3,654
row control  = 174 * 42 = 7,308
fixed ordinary = 320 * 21 = 6,720
fixed control  = 320 * 42 = 13,440
bootstrap budget entries = 21 * (R + 1)
bootstrap fixed allowance = 50

units(R) = 10,983R + 20,231
protocol Rmax = 410,051,864,458
units(Rmax)   = 4,503,599,627,362,445 < 2^52
units(Rmax+1) = 4,503,599,627,373,428 >= 2^52

carrierCount(R) <= 1,046R + 1,928
carrierCount(Rmax) <= 428,914,250,224,996
units(1,024) = 11,266,823
carrierCount(1,024) <= 1,073,032
```

The protocol maximum is codec arithmetic only. Product admission remains
`R<=1,024`; exact byte, quota, inode, free-space, `off_t`, RSS, and eight-second
preflight can reject lower. The state-machine generator derives counts by
expanding each named mutation to P0...P6 and records/pages to the 20-unit cap;
production cannot accept unnamed numeric transitions. Checkpoint/activation
records, root promotions, reserve/close continuations, and terminal selectors
must be present in its generated trace and candidate byte budget.

## 5. Standalone v8 codec

This section plus the exact evidence/custody schemas in section 6 are the
complete v8 codec. Implementations do not consult R14/R15/R16 model types or
prose. A backticked schema name is also the exact `schema` string unless an
explicit literal is stated beside it. JSON is RFC 8785 JCS; strings are NFC;
hex is lowercase; base64url is unpadded. `u53` is 0...`2^53-1`; `u64wide` is
exactly `{schema:"wide_v1",hi:u32,lo:u32}`. UUIDs are lowercase canonical
8-4-4-4-12 strings. Every object rejects unknown, duplicate, or missing keys.
Every listed key is present. A field is non-null unless its legal-null rule is
listed below. Floats, negative integers, overflow, padded base64, uppercase
hex, invalid NFC, and ambiguous number spellings reject.

### 5.1 Reference registry

| type | discriminator and exact keys | legality |
|---|---|---|
| `localRecordReference.v3` | `kind="local",slotOrdinal,recordOrdinal,recordCanonicalLength,recordSHA256` | only within the carrier being encoded; lower slot only |
| `carrierRecordReference.v3` | `kind="carrier",carrierOrdinal,payloadLengthBytes,carrierSHA256,immutableIdentitySHA256,slotOrdinal,recordOrdinal,recordCanonicalLength,recordSHA256` | every selected or cross-carrier record reference |
| `carrierReference.v3` | `schema,carrierOrdinal,payloadLengthBytes,carrierSHA256,immutableIdentitySHA256` | complete carrier only; schema `carrier_reference.v3` |
| `emptyRootReference.v1` | `kind="empty",treeKind,entryCount,height,rootTranscriptSHA256` | `entryCount=0,height=0`; top page is absent by construction |
| `rootReference.v3` | `kind="root",treeKind,entryCount,height,topPageReference,rootTranscriptSHA256` | entryCount > 0; top page is carrier reference when selected, local only in same-carrier receipt |
| `rootPromotion.v2` | `schema,treeKind,entryCount,height,topSlotOrdinal,topRecordOrdinal,topRecordCanonicalLength,topRecordSHA256,rootTranscriptSHA256` | only in a receipt; promoted using that receipt's carrier |
| `externalObjectReference.v6` | `schema,canonicalRelativePathBase64URL,pathSHA256,objectKind,physicalClass,canonicalLength,objectSHA256,immutableIdentitySHA256` | bounded external regular or A3 directory only |
| `protocolEvidenceReference.v2` | `schema,evidenceKind,transactionUUID,relativePathUTF8Base64URL,pathSHA256,canonicalLength,objectSHA256,immutableIdentitySHA256` | preparation seal, receipt, fresh verification head/receipt, or custody head |
| `rootSnapshot.v1` | `schema,selectedRootReference,localRootReference,rootPromotion` | exactly one branch: selected non-null, or paired local/promotion non-null |

`recordCanonicalLength` always equals referenced record JCS length.
`carrierRecordReference.v3.payloadLengthBytes` equals the complete carrier's
`carrierReference.v3.payloadLengthBytes`; ordinal, carrier digest and identity
must also be byte-identical. Promotion copies the root scalars and maps the
local record coordinates into that exact carrier reference. There is no
`carrierLengthBytes` spelling. `recordReference` means the closed union local
or carrier; `selectedRecordReference` means carrier only; `rootOrEmpty` means
the closed union `rootReference.v3|emptyRootReference.v1`.

### 5.2 Selector and embedded-object registry

`model_catalog_selector.v8` has exactly:

```text
schema,selectorRevision,activationUUID,state,selectedActivationReference,
selectedCheckpointReference,priorActiveIndexSHA256,migrationSourceSHA256,
formatFenceSHA256,fixedExtentRootSHA256,activationMaterializedBytes,
activationWorkReservedBytes,activationLifecycleReservedBytes,
activationSpentSlackBytes,activationChargedBytes,activationQuotaBytes,
carrierMaterializedBytes,carrierChargedBytes,carrierCount,carrierHeadReference,
storageRootReference,pathRootReference,lifecycleRootReference,
budgetRootReference,sequenceRegistryRootReference,workRootReference,
pendingTransaction,lastReceiptReference,carrierAuditState,bootstrapState,
selectedCarrierDirectoryIntent,protocolUnitCount
```

Schema is `model_catalog_selector.v8`; selector framing remains exactly 65,536
bytes as `u32be(JCS length)||JCS||SHA256(JCS)||zero padding`, with JCS length
2...49,152. State is `migrating|ready|protected`.

| embedded schema | exact keys after `schema` | enums and null rules |
|---|---|---|
| `pending_transaction.v3` | `transactionUUID,logicalOperationKind,logicalOperationOrdinal,phase,edgeIntent,edgeIntentSHA256,openBudgetLease,leaseAuthorizationSHA256,leaseStateSHA256,controlAuthorization,continuationReference,workAccumulator,cancelRequested,completionDisposition,abortCursor` | phases are `between-edges|reserving|executing|closing-commit|closing-abort|aborting|forward-completing`; edge intent/digest are null only `between-edges`; lease fields are non-null while pending; control is non-null only reserve/close; continuation is non-null only continued edge; abort cursor only A1/A2 abort; disposition `normal|forward-only` |
| `work_accumulator.v3` | `selectedCarrierCount,selectedRecordCount,selectedExternalCount,selectedUnits,selectedChargeBytes,abandonedUnits,abandonedChargeBytes,terminalSHA256` | terminal digest null until terminal edge; counters non-null u53/u64wide as declared |
| `edge_intent.v5` | `activationUUID,transactionUUID,logicalOperationKind,logicalOperationOrdinal,edgeOrdinal,edgeKind,budgetScope,sourceRowOrdinal,budgetCategory,baseSelectorSHA256,baseCarrierReference,baseStorageRootReference,basePathRootReference,baseLifecycleRootReference,baseBudgetRootReference,baseSequenceRootReference,baseWorkRootReference,baseActivationReference,baseCheckpointReference,priorReceiptReference,continuationReference,operationInputReferences,targetDescriptor,maximumTargetRecords,maximumExternalObjects,maximumPermanentUnits,maximumChargeBytes,candidateSelectorRevision,leaseAuthorizationSHA256,baseLeaseStateSHA256` | edge kinds `record-publish|tree-mutate|bounded-external-publish|budget-reserve|budget-close|abort-slot|phase-commit|audit-step|artifact-adopt`; source row null only fixed/bootstrap; base carrier and prior receipt null only first carrier/receipt; continuation only continuation edge; inputs length 0...8 |
| `continuation_reference.v3` | `mutationKind,nextTargetOrdinal,targetCount,frontierReferences,targetCoordinateOrderSHA256,priorWorkAccumulator,leaseAuthorizationSHA256,baseLeaseStateSHA256` | frontier 0...8 selected references; next < target except terminal null continuation |
| `control_authorization.v3` | keys in section 3 | non-null only reserve/close; all counters bounded by maxima |
| `budget_lease.v5` | keys in section 3 | debit array 1...2; stable/state digests required |
| `lease_authorization.v3` | keys in section 3 | maximum edges 1...64; unique debit categories |
| `bootstrap_state.v3` | keys in section 2 | exact phase matrix in section 2 |
| `directory_intent.v2` | keys in section 2 | selected only at generation zero |
| `carrier_audit_state.v3` | `snapshotHeadReference,nextCarrierOrdinal,verifiedCarrierCount,verifiedBytes,rollingTranscriptSHA256,complete` | head null only before first carrier; complete false until cursor passes frozen head |
| `immutable_identity.v4` | `deviceID,fileID,fileType,mode,ownerUID,groupGID,linkCount,byteLength,mtimeSeconds,mtimeNanoseconds,ctimeSeconds,ctimeNanoseconds,birthtimeSeconds,birthtimeNanoseconds,userFlags,systemFlags` | type `regular|directory`; byteLength null only directory; nanoseconds 0...999999999 |

Selector null matrix: generation zero has null selected activation/checkpoint,
carrier head, last receipt, pending transaction, carrier audit head, and all six
roots are their typed empty roots. It alone has non-null
`selectedCarrierDirectoryIntent`. Revision one makes the intent null and the
carrier-directory identity non-null. After genesis close, selected activation,
checkpoint, carrier head, and last receipt are non-null forever; all six roots
remain non-null root-or-empty values. `pendingTransaction` is null only between
transactions or after a terminal successor. Protected state preserves every
last selected reference and may only replace pending with a protected terminal
receipt through the normal P0...P6 graph.

`target_descriptor.v5` has exactly:

```text
schema,descriptorKind,targetTreeKind,targetKeyBase64URL,
targetRangeFirstBase64URL,targetRangeLastBase64URL,sequenceCollection,
sequenceOrdinal,recordSchema,externalObjectDescriptor,phaseFrom,phaseTo,
abortSlot,artifactCustodyReference,expectedPriorEntrySHA256,
expectedPriorGeneration,targetCount,targetCoordinateOrderSHA256
```

| descriptor kind | required non-null coordinates; every unlisted coordinate is null |
|---|---|
| `tree-update` | targetTreeKind, targetKey, expectedPriorEntry digest/generation, targetCount, coordinate-order digest |
| `sequence-append` | targetTreeKind=`sequence`, sequenceCollection, sequenceOrdinal, targetCount, coordinate-order digest |
| `record-set` | recordSchema, targetCount, coordinate-order digest |
| `bounded-external-object` | externalObjectDescriptor, targetCount=1, coordinate-order digest |
| `phase-transition` | phaseFrom, phaseTo, targetCount=1, coordinate-order digest |
| `abort` | phaseFrom, phaseTo, abortSlot, targetCount=1, coordinate-order digest |
| `audit` | targetRangeFirst, targetRangeLast, targetCount, coordinate-order digest |
| `artifact-adoption` | recordSchema=`prepared_artifact_adoption.v2`, artifactCustodyReference, targetCount=1, coordinate-order digest |

For insertions `expectedPriorEntrySHA256` and generation are null; for update or
delete both are non-null. Range fields are paired. Target count is 1...64.

### 5.3 Carrier and catalog-record registry

Carrier v3 keeps R16's physical extents: 8,228-byte header plus 1...16
65,572-byte slots, total 73,800...1,057,380 bytes. Framing is exactly
`u32be(headerJCS.count)||headerJCS||SHA256(headerJCS)||zeroPadding` for the
8,228-byte header extent and
`u32be(recordJCS.count)||recordJCS||SHA256(recordJCS)||zeroPadding` for every
65,572-byte slot. Header JCS is 2...8,192 bytes and record JCS is
2...65,536 bytes; all padding bytes are zero. Header schema
`model_catalog_carrier_header.v3` has exactly
`schema,activationUUID,carrierOrdinal,previousCarrierReference,
pendingSelectorSHA256,transactionUUID,edgeOrdinal,edgeKind,edgeIntentSHA256,
recordCount,recordTranscriptSHA256,payloadLengthBytes`. Previous carrier is null
only ordinal zero; transaction/edge/intent are null only bootstrap carrier.

Every catalog record has exactly
`schema,activationUUID,transactionUUID,edgeOrdinal,slotOrdinal,recordOrdinal`
plus its suffix below. Transaction and edge are null only bootstrap. Fields
named `previous*`, `prior*`, `active*`, or `terminal*` are nullable only where
the table says; all others are non-null.

Embedded source values are closed. `raw_name_entry.v1` has exactly
`schema,directoryOffset,successorDirectoryOffset,nameUTF8Base64URL,nameSHA256,
fileTypeCode,fileID`; successor offset is null only for the directory EOF
sentinel. `reservation_row.v1` has exactly
`schema,transactionUUID,phase,provenance,primarySHA256,originSHA256,
classSHA256,lineageSHA256`; phase is `queued|active|terminal|protected`,
provenance is `allocated|legacy-snapshot|protected-snapshot`, and no digest is
nullable. `bplus_child.v1`, `bplus_entry.v1`, all sequence values, debit
values, and category maps are the only other embedded arrays/maps admitted by
this section; an implementation-defined dictionary is illegal.

| schema | exact suffix | legal nulls / bounds |
|---|---|---|
| `bplus_leaf.v3` | `treeKind,level,firstKeyBase64URL,lastKeyBase64URL,entryCount,entries,subtreeCount,subtreeChargeBytes,pageTranscriptSHA256` | no null; level 0; ordered `bplus_entry.v1` values |
| `bplus_node.v3` | `treeKind,level,firstKeyBase64URL,lastKeyBase64URL,childCount,children,subtreeCount,subtreeChargeBytes,pageTranscriptSHA256` | no null; level 1...8; ordered `bplus_child.v1` values |
| `name_scan_root.v5` | `directoryIdentity,attrABIProfileSHA256,nextDirectoryOffset,nextRecordSentinelSHA256,rawEntryCount,rawNameBlockSequenceRootReference,eof,scanTranscriptSHA256` | next sentinel null only eof; sequence root may be typed empty |
| `raw_name_block.v5` | `blockOrdinal,firstDirectoryOffset,successorDirectoryOffset,entries,entryCount,firstNameSHA256,lastNameSHA256,entriesSHA256` | successor null only final block; entries 1...bounded fit |
| `name_block.v5` | `blockOrdinal,names,nameCount,firstName,lastName,namesSHA256` | names nonempty |
| `row_block.v6` | `role,blockOrdinal,rows,rowCount,firstUUID,lastUUID,rowsSHA256` | role `capture|merge`; rows nonempty |
| `row_verification_block.v5` | `pass,blockOrdinal,firstRowOrdinal,lastRowOrdinal,rowCount,priorTranscriptSHA256,terminalTranscriptSHA256` | pass `rows-1|rows-2`; prior null only first; terminal null only nonfinal |
| `storage_verification_block.v5` | `blockOrdinal,firstStorageOrdinal,lastStorageOrdinal,entryCount,materializedBytes,priorTranscriptSHA256,terminalTranscriptSHA256` | prior null only first; terminal null only nonfinal |
| `name_capture_root.v5` | `previousRootReference,nameScanRootReference,rawNameBlockSequenceRootReference,nameBlockSequenceRootReference,sortWorkRootReference,nameCount,firstName,lastName,namesSHA256` | previous null only initial; first/last null iff count zero |
| `row_work_root.v5` | `previousRootReference,nameBlockSequenceRootReference,rowBlockSequenceRootReference,captureRunSequenceRootReference,nextNameBlockOrdinal,nextNameOrdinal,rowCount,firstUUID,lastUUID,rowsSHA256` | previous null only initial; first/last null iff count zero |
| `run_work_root.v5` | `previousRootReference,mergePass,nextGroupOrdinal,nextCreationOrdinal,inputRunSequenceRootReference,completedMergeGroupSequenceRootReference,outputRunSequenceRootReference,activeMergeGroupWorkReference,inputRunCount,completedGroupCount,outputRunCount,mergeTranscriptSHA256` | previous null only initial; active group null between groups |
| `merge_group_work.v5` | `mergePass,groupOrdinal,creationOrdinal,inputRunSequenceRootReference,inputFirstOrdinal,inputCount,cursorSequenceRootReference,headSequenceRootReference,outputRowBlockSequenceRootReference,outputRowCount,firstUUID,lastUUID,predecessorUUID,exhaustedInputCount,rollingTranscriptSHA256` | first/last/predecessor null iff output count zero |
| `run_manifest.v7` | `runKind,rowBlockRole,mergePass,runOrdinal,creationOrdinal,inputRunSequenceRootReference,inputRunCount,rowBlockSequenceRootReference,rowBlockCount,rowCount,firstUUID,lastUUID,rowsSHA256` | input root null only capture run; first/last null iff row count zero |
| `tree_build_root.v6` | `previousRootReference,level,phase,currentLevelInputSequenceRootReference,currentLevelPageSequenceRootReference,completedLevelSequenceRootReference,nextInputBlockOrdinal,nextInputRowOrdinal,nextGlobalRowOrdinal,nextInputPageOrdinal,nextTreeObjectOrdinal,treeTranscriptSHA256` | previous null only initial; phase `opening|emitting|closing|complete` |
| `verification_work_root.v5` | `previousRootReference,pass,rowVerificationBlockSequenceRootReference,storageVerificationBlockSequenceRootReference,nextRowOrdinal,nextStorageOrdinal,targetStorageRootReference,targetEntryCount,targetMaterializedBytes,rowTranscriptSHA256,storageTranscriptSHA256` | previous null only initial; exactly the sequence for the selected pass may be nonempty |
| `phase_record.v2` | `phaseFrom,phaseTo,materializationPathSHA256,objectKind,objectReference,priorPhaseRecordReference,phaseTranscriptSHA256` | object fields paired and non-null only publication/durable phases; prior null only A0 |
| `binding_record.v1` | `modelID,release,artifactSHA256,pathKey,storageOrdinal,lifecycleKey,adoptionReference,priorBindingReference,bindingTranscriptSHA256` | prior null only first binding; adoption reference required |
| `prepared_artifact_adoption.v2` | `modelID,release,artifactSHA256,durableRelativePathBase64URL,durablePathSHA256,preparationSealSHA256,freshVerificationReceiptSHA256,artifactCustodyHeadSHA256,artifactRootIdentitySHA256,artifactEntryCount,artifactCanonicalBytes,preparationTransactionUUID` | no null |
| `edge_receipt.v5` | `edgeKind,edgeIntentSHA256,intentBaseSelectorSHA256,pendingSelectorSHA256,priorReceiptReference,targetRecordReferences,externalObjectReference,localTargetRoots,rootPromotions,continuationReference,leaseAuthorizationSHA256,baseLeaseStateSHA256,successorLeaseStateSHA256,targetBudgetEntrySHA256,selectedUnits,selectedChargeBytes,priorWorkAccumulator,outcome,receiptTranscriptSHA256` | prior null only first; external only bounded external; roots/promotions paired; continuation only continued; successor state null only terminal close; target budget digest only reserve/close; outcome `continued|committed|aborted|protected` |
| `abort_receipt.v4` | `abortGeneration,basePhase,completedCompensationSteps,priorReceiptReference,baseBudgetRootReference,localTargetBudgetRootReference,budgetRootPromotion,lifecycleReserveReleasedBytes,leaseAuthorizationSHA256,baseLeaseStateSHA256,targetBudgetEntrySHA256,leaseReleasedUnits,leaseReleasedBytes,spentUnits,spentBytes,abandonedUnits,abandonedBytes,outcome,receiptTranscriptSHA256` | exactly slots 0...6; prior null only first; local root/promotion required |
| `activation_record.v4` | `activationGeneration,previousActivationReference,state,phase,sourceWitnessSHA256,storageRootSnapshot,pathRootSnapshot,lifecycleRootSnapshot,budgetRootSnapshot,sequenceRegistryRootSnapshot,workRootSnapshot,checkpointPredecessorReference,lastReceiptPredecessorReference,carrierAuditState` | previous/checkpoint/receipt predecessor null only genesis; snapshots obey the exact two-branch union |
| `checkpoint_record.v4` | `checkpointGeneration,previousCheckpointReference,activationReference,phase,logicalOperationKind,logicalOperationOrdinal,edgeOrdinal,workCursor,sourceWitnessSHA256,storageRootSnapshot,pathRootSnapshot,lifecycleRootSnapshot,budgetRootSnapshot,sequenceRegistryRootSnapshot,workRootSnapshot,lastReceiptReference,carrierAuditState` | previous null only genesis; operation/edge/work cursor null only bootstrap; activation/receipt may be lower-slot local only in their containing carrier |
| `source_witness.v3` | `sourceRowCount,priorActiveIndexSHA256,migrationSourceSHA256,namespaceSHA256,rowsSHA256,capturedAtSelectorRevision` | no null |
| `format_fence_witness.v2` | `formatFenceSHA256,selectorRelativePathBase64URL,selectorPathSHA256,lockIdentitySHA256` | no null |
| `bootstrap_close.v2` | `sourceWitnessReference,budgetRootReference,expectedEntryCount,unitsConsumed,unitsReleased,carriersConsumed,carriersReleased,chargedBytes,releasedBytes` | no null; consumed+released equals limit |

`bplus_child.v1` has exactly
`schema,firstKeyBase64URL,lastKeyBase64URL,subtreeCount,
subtreeChargeBytes,pageReference`. `bplus_entry.v1` has exactly
`schema,keyBase64URL,valueSchema,value,valueSHA256`. Its value is one complete
object from the following tree-kind union: storage -> `storage_entry.v4`, path
-> `path_entry.v4`, lifecycle -> `lifecycle_entry.v4`, budget ->
`budget_entry.v4`, sequence -> one sequence leaf value below, work ->
`work_entry.v1`. The key equals the tree-specific key inside the value;
`valueSHA256` is the mapped v8-content digest of `value`. Tree kinds are exactly
`storage|path|lifecycle|budget|sequence|work`. Storage/lifecycle leaves hold at
most 32 entries and split 17/16; path/budget/sequence/work leaves hold at most
16 and split 9/8. Node fanout is at most 128 and height at most eight.

`work_entry.v1` has exactly
`schema,workKind,workKeyBase64URL,generation,state,workRecordReference,
priorWorkRecordReference,workTranscriptSHA256`. Work kind is
`name-scan|name-capture|row-capture|run-merge|tree-build|row-verification|
storage-verification|materialization|recovery|audit`; state is
`open|continued|complete|protected`; prior is null only generation zero.

`source_binding.v1` has exactly
`schema,sourceKind,sourceSHA256,sourceRecordReference`; source kind is
`primary|origin|class|lineage`, and the reference must select the corresponding
source record. `work_cursor.v1` has exactly
`schema,workKind,phase,nextOrdinal,terminalOrdinal,workEntryReference`; next is
0...terminal, and the reference is null only before the first unit. These are
the only legal values of `sourceBindingReference` and `workCursor`.

Sequence leaf values have exact common keys
`schema,collection,ordinal,contentReference,transcriptSHA256` plus:
raw-name `firstDirectoryOffset,successorDirectoryOffset,recordCount,
firstNameSHA256,lastNameSHA256`; name-block `nameCount,firstName,lastName`;
row-block `role,rowCount,firstUUID,lastUUID,rowsSHA256`; run
`mergePass,rowCount,firstUUID,lastUUID,runManifestReference,rowsSHA256`;
merge-group `mergePass,groupOrdinal,creationOrdinal,inputCount,
outputRunReference,rowCount,firstUUID,lastUUID,rowsSHA256`; tree-page
`level,itemCount,firstUUID,lastUUID,pageReference,itemsSHA256`; tree-level
`level,pageCount,firstUUID,lastUUID,sequenceRootReference,levelSHA256`;
verification `pass,firstOrdinal,lastOrdinal,itemCount`. Successor directory
offset is null only final; first/last are null iff count zero; all content,
manifest, page and root references are selected carrier references or
root-or-empty values as their names require.

`budget_entry.v4` has exact keys
`key,scope,sourceRowOrdinal,generation,categoryUnitLimits,
categoryUnitsReserved,categoryUnitsSpent,categoryUnitsAbandoned,
categoryByteLimits,categoryBytesReserved,categoryBytesSpent,
categoryBytesAbandoned,controlUnitLimit,controlUnitsSpent,controlByteLimit,
controlBytesSpent,openLeaseAuthorizationSHA256,openLeaseStateSHA256,
lastLeaseAuthorizationSHA256,lastCloseOutcome`. Source row is null only fixed
scope. Category maps have exactly
`source-capture,merge,tree,verification,materialization,abort`. Last
authorization is null only unused entry. Outcome is `none|committed|aborted`.
Each category map is an object with exactly the six category keys and u64wide
values. `maximumDebits` entries have exactly
`schema,category,maximumUnits,maximumChargeBytes`; selected lease debit entries
have exactly `schema,category,maximumUnits,maximumChargeBytes,consumedUnits,
consumedChargeBytes,abandonedUnits,abandonedChargeBytes`. The authorization
uses only the first form and lease state only the second.

`storage_entry.v4` has exactly
`schema,storageOrdinal,pathKey,pathClass,objectKind,physicalClass,state,
objectSHA256,canonicalLength,chargeBytes,immutableIdentitySHA256,lifecycleKey,
sourceRowOrdinal,transactionUUID,freshVerificationReceiptSHA256,
artifactCustodyHeadSHA256`. `path_entry.v4` has exactly
`schema,pathKey,relativePathUTF8Base64URL,pathClass,objectKind,physicalClass,
generation,state,objectSHA256,canonicalLength,storageOrdinal,
immutableIdentitySHA256,transactionUUID,bindingReference,sourceRowOrdinal,
freshVerificationReceiptSHA256,artifactCustodyHeadSHA256`. `lifecycle_entry.v4`
has exactly `schema,lifecycleKey,generation,state,transactionUUID,
sourceRowOrdinal,reservedBytes,spentBytes,activeIntentReference,pathKey,
bindingReference,lastOutcome`. Artifact-only receipt/custody/binding fields are
null for ordinary objects and all non-null for adopted artifacts. Source row is
null only for fixed-scope objects. Storage state is `ordinary|adopted`; path
state is `reserved|materialized|bound|indexed`; lifecycle state is
`available|reserved|bound|imported|consumed`; outcome is
`none|committed|aborted`. Active intent is non-null only reserved/bound;
path/binding are non-null only bound/imported/consumed as applicable.
`retained-abandoned` is illegal.

`external_object_descriptor.v6` has exactly
`schema,objectKind,physicalClass,contentCodec,canonicalRelativePathBase64URL,
pathKey,pathClass,budgetScope,sourceRowOrdinal,budgetCategory,canonicalLength,
objectSHA256,expectedAbsent,sourceBindingReference`. Regular objects require
length, digest, identity after publication, storage/path indexing, and a source
binding; A3 directory requires null length/digest/content codec and non-null
directory identity. Catalog records, protocol files, runs/pages/work roots and
artifacts cannot be external targets.

### 5.4 Digest registry

Every digest has exactly one rule:

| field/family | digest preimage |
|---|---|
| record reference | `SHA256(recordJCS)` |
| carrier | `SHA256(all framed carrier bytes)` |
| immutable identity | domain `macprovider-immutable-identity-v4` + length + JCS |
| selector fixed extent | domain `macprovider-selector-v8` over selector JCS with only `fixedExtentRootSHA256=null` |
| edge intent | domain `macprovider-edge-intent-v5` + length + JCS |
| stable lease / lease state / projected budget entry | exact domains in section 3 |
| root/page/record transcript field | domain `macprovider-v8-transcript` + schema length/schema + field-name length/name + JCS with only that field null |
| content/order/rows/names/entries digest | domain `macprovider-v8-content` + schema length/schema + field-name length/name + canonical JCS value |
| relative path digest | domain `macprovider-relative-path-v1` + UTF-8 length + canonical relative UTF-8 |
| prior active index / migration source / format fence | SHA-256 of the exact selected historical file bytes |
| preparation seal/receipt/ticket/fresh receipt/custody head | their named versioned evidence domain + length + JCS |
| artifact digest | current SPEC-001 canonical artifact-tree digest, equal to the signed catalog digest |
| bounded external object | SHA-256 of exact file bytes |

There is no blanket name inference beyond these rows. Fields ending SHA256
must be enumerated by the schema generator into one row above; an unmapped
digest field is a compile/test failure. No undomained concatenation or
implementation encoder is permitted.

## 6. Fresh full-integrity verification and durable custody

R17 preserves current SPEC-001: preparation seals are historical evidence;
adoption performs a fresh full current-integrity verification before selecting
the artifact. That long-running work occurs outside the eight-second
reservation control invocation.

### 6.1 Custody authority and lock order

The artifact store adds one direct lock and one fixed head per canonical
artifact digest:

```text
<artifact-store>/.custody/custody.lock
<artifact-store>/.custody/<artifactSHA256>/head.json
<artifact-store>/.custody/<artifactSHA256>/records/<generation>.json
```

`artifact_custody_record.v1` has exactly
`schema,generation,artifactSHA256,durableRelativePathBase64URL,
durablePathSHA256,artifactRootIdentitySHA256,state,verificationTransactionUUID,
freshVerificationReceiptSHA256,catalogActivationUUID,catalogSelectorSHA256,
replacementCustodySHA256,servingDrainReceiptSHA256,terminalReason,
priorCustodyRecordSHA256`. State is
`verifying|verified|pending-adoption|active|replacement-pending|released|
abandoned-unverified|abandoned-verified`. Fields unavailable in the state are
present as null. The exact state matrix is:

| state | verification transaction | fresh receipt | catalog activation/selector | replacement | drain receipt | terminal reason |
|---|---|---|---|---|---|---|
| verifying | required | null | null | null | null | null |
| verified | required | required | null | null | null | null |
| pending-adoption | required | required | both required, selector is pending | null | null | null |
| active | required | required | both required, selector is terminal active | null | null | null |
| replacement-pending | required | required | incumbent active pair required | required | null | null |
| released | required | required | last incumbent pair required | required only when reason `replaced` | required | `replaced|removed` |
| abandoned-unverified | required | null | null | null | null | `cancelled|verification-failed` |
| abandoned-verified | required | required | null | null | null | `cancelled` |

Generation zero has null prior custody record; every successor has a non-null
prior digest and generation exactly one greater. The fixed
head has exactly `schema,generation,recordSHA256,fixedExtentRootSHA256`, uses a
4,096-byte framed extent, and selects the immutable record. Both digests use
their schema-named `macprovider-artifact-custody-*-v1` domains.

For any path touching custody, the global lock order is custody flock,
activation flock, then transaction journal lock. No custody path takes these
in another order. The pre-fence bootstrap never touches custody and retains
R16's one-time journal-lock then activation-flock order. GC takes the custody flock
and direct-opens each candidate artifact's known head before removal; it never
uses a keep set captured before the lock. Adoption takes the custody flock
before its pending selector and holds it through validation, activation-flock
CAS, and pending-selector directory fsync. It releases both within eight
seconds. Full hashing never holds the activation flock.

Before fresh verification starts, custody publishes `verifying`; therefore GC
must retain the artifact. Cancellation or verification failure before a fresh
receipt selects `abandoned-unverified`; cancellation after a fresh receipt and
before pending selects `abandoned-verified`. Either transition is legal only
after root/path recapture and proof that no selector references it. A verified
or pending-adoption pin cannot be abandoned by GC. Once pending is selected,
the selector plus custody head are
dual retention evidence. Terminal adoption advances custody to `active` with
the selected catalog selector digest; recovery accepts either ordering and
must finish the missing equal transition. An active record remains pinned
until an authorized replacement selector durably selects another artifact,
the old catalog lifecycle is `consumed`, the provider has stopped accepting
new requests for the old activation, and all old activation requests have
drained. The drain controller then publishes
`artifact_serving_drain_receipt.v1`, with exactly
`schema,artifactSHA256,catalogActivationUUID,acceptingStoppedSelectorSHA256,
lastAcceptedRequestOrdinal,completedRequestOrdinal,openRequestCount,
replacementCustodySHA256,outcome,receiptTranscriptSHA256`; outcome is
`replaced|removed`, open count is zero, and completed ordinal is at least the
last accepted ordinal. Only then may a successor custody record select
`released` and bind that receipt. A
replacement cancelled before its pending selector selects
`abandoned-unverified` or `abandoned-verified` according to whether a fresh
receipt exists and does not change the incumbent active pin. A
post-pending cancellation follows
the A3+ forward path. Corrupt or ambiguous custody selects protection and is
never treated as permission to delete.

After `released` is selected, GC still holds the custody flock, revalidates the
released record, drain receipt and absence from every current/pending catalog
reference, then clears user-immutable flags and removes only entries named by
the fresh receipt's sealed manifest in reverse path-depth and manifest order.
An unexpected entry, identity mismatch, symlink or path escape protects. Death
after any flag-clear or unlink leaves `released` selected; a later GC validates
the exact already-absent prefix and resumes. The custody head/records live
outside the artifact directory and remain terminal evidence. GC never
recursively deletes an unvalidated name.

### 6.2 Resumable fresh hashing

Fresh verification publishes immutable
`artifact_verification_chunk.v1` records with exact
`schema,verificationTransactionUUID,entryOrdinal,relativePathBase64URL,
entryIdentityBefore,byteOffset,byteCount,chunkSHA256,sha256StateBefore,
sha256StateAfter,entryIdentityAfter,priorChunkRecordSHA256`.
`sha256_continuation.v1` has exactly
`schema,h0,h1,h2,h3,h4,h5,h6,h7,totalByteCount,tailBase64URL`; each `h` is
u32, total is u64wide, and the decoded tail is 0...63 bytes. The initial state
is the standard SHA-256 IV, zero bytes, empty tail. `sha256StateBefore` must
equal the selected checkpoint continuation; after processing the exact chunk,
`sha256StateAfter` must equal an independent SHA-256 compression calculation.
The final padding operation produces the same per-file digest as one-shot
SHA-256 and is never applied to an intermediate state. Each call hashes at
most 64 MiB and stops early enough
to close all descriptors before eight seconds; a single payload descriptor,
transaction directory descriptor, custody descriptor and scratch descriptor
are the maximum four. The selected
`artifact_verification_checkpoint.v1` has exactly
`schema,generation,verificationTransactionUUID,artifactSHA256,
sealedManifestSHA256,nextEntryOrdinal,nextByteOffset,chunkCount,
currentEntrySHA256Continuation,completedEntryDigestSequenceRootReference,
chunkSequenceTranscriptSHA256,priorCheckpointSHA256,state`, with state
`hashing|recapturing|complete|protected`. It is selected by a 4,096-byte
`artifact_verification_head.v1` fixed extent under the transaction directory.
Every chunk successor names and validates the predecessor head digest.

The verifier walks only the exact sealed manifest order. It opens every regular
file without following links, hashes every byte through the exact continuation
states, commits each completed file digest to the selected sequence root,
rejects holes/extra bytes/type/path/identity drift, and recomputes the current
SPEC-001 canonical tree digest from those exact one-shot-equivalent file
digests and manifest coordinates.
After the final byte it performs a second complete metadata recapture of every
manifest entry and the root, rejects any difference from the before/after
identities, removes write permissions, sets the supported macOS user-immutable
flag on root and descendants, fsyncs changed files/directories, then recaptures
again. Failure to set or observe the immutable flag rejects qualification on
that filesystem. Normal writes, rename, unlink, and replacement must fail while
custody is verified/pending/active. Clearing a flag changes identity and
invalidates the receipt before selection.

`fresh_artifact_verification_receipt.v1` has exactly
`schema,verificationTransactionUUID,preparationTransactionUUID,modelID,release,
artifactSHA256,durableRelativePathBase64URL,durablePathSHA256,
sealedManifestSHA256,artifactRootIdentitySHA256,artifactEntryCount,
artifactCanonicalBytes,chunkCount,chunkSequenceTranscriptSHA256,
finalIdentityTranscriptSHA256,custodyRecordSHA256,completedCheckpointSHA256`.
It is selected only after full hash equality, complete recapture, immutability,
and custody transition to `verified`; all are fsynced. Its digest is the
versioned domain plus length/JCS.

The short adoption call reads the custody head, completed verification head,
fresh receipt, seal manifest and root through direct paths. It does no payload
hashing. While holding custody then activation locks it verifies all digests,
opens and `fstatat`s each manifest entry in bounded batches across repeated
pre-pending calls, and records progress in the selected verification
checkpoint. The final call recaptures the root and every entry since the last
batch, requires immutable flags and exact identities, rechecks the full
identity transcript, advances custody to `pending-adoption`, and fsyncs the
pending catalog selector before releasing the locks. If the manifest cannot be
fully recaptured under the measured bounded-call protocol, qualification is
blocked; the contract is not weakened.

Serving direct-opens the active custody head and receipt, revalidates root and
requested entry identity/immutable flag before MLX open, and refuses/protects
on mismatch. This is defense after valid adoption, not a substitute for fresh
verification. Custody and reservation evidence remain outside admission and
settlement authority.

## 7. Implementation and acceptance gate

After plan approval, implementation slices are:

1. v8 codec generator and independent byte fixtures, including exact null,
   reference, digest and promotion registries;
2. generation-zero directory intent/bootstrap accounting and prior-binary
   rejection;
3. stable lease identity plus mutable state digest, exact projected budget
   entry and 63/64/65 recovery;
4. six-root selector, per-mutation activation/checkpoint publications,
   generated graph and corrected capacity arithmetic;
5. SPEC-001 fresh verification checkpoints, immutable custody, GC composition,
   adoption and serving handoff;
6. preserved A1/A2 terminal abort and A3+ forward-only economics;
7. targeted/full Swift, Xcode, bridge, physical artifact and independent code,
   security and architecture audit gates.

Rollback is legal only before the v4 format fence selects v8. Later recovery
must complete, legally abort at A1/A2, or protect. Selected carriers,
checkpoints, receipts, custody records, and active artifacts are not deleted as
rollback.

Acceptance requires the fresh commands and evidence in R23. The physical
signed-feed -> trusted preparation -> valid admission -> real MLX -> correct
settlement journey remains blocked until executed. This reservation work does
not authorize coordinator reconciliation while BYOM v0.2 remains active, new
dependencies, release/deploy, economic activation, payments, enforcement,
remote hardware purchase, or confidential-compute claims.

## 8. R16 finding disposition

| R16 finding | R17 correction | R23 proof |
|---|---|---|
| H1 generation-zero intent absent | selected v8 intent field, exact directory schema/path/null matrix, revision-one removal, carrier release counter | R23-02 independent bytes and syscall death matrix |
| H2 lease identity undefined | stable authorization digest, mutable state digest, exact projected-entry digest and ownership semantics | R23-03 63/64/65 vectors and stale substitution |
| H3 incomplete codec | closed reference, embedded, record, null, physical and digest registries; binding record included | R23-04 independent encoder and exhaustive cross-products |
| H4 work not selected/counted | six roots plus activation/checkpoint on every mutation; corrected 20-unit graph and arithmetic | R23-05 semantic generator and max-shape arithmetic |
| H5 historical adoption violates SPEC-001 | resumable full content hash, final recapture, immutable custody, fresh receipt before pending | R23-06 corruption at every boundary |
| H6 GC/custody race | selected no-expiry custody from pre-verification through active/replacement/release; shared lock order and exact GC rules | R23-07 GC/adoption/serving race matrix |
