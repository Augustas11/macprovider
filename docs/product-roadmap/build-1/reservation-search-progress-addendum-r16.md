# Build 1 reservation search progress addendum R16

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This revision is a docs-only response to the eight High
findings in
`reviews/reservation-search-progress-r15-plan-sol.md`. No Swift source or test
is authorized by this document until an independent native GPT-5.6 Sol gate
reports zero Critical, High, and Medium findings for this exact file and
`test-spec-r22-reservation-r16-corrections.md`.

Repository evidence was inspected at `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The working implementation is
still the R4 reservation implementation, including array-valued progress,
bounded legacy-directory scans, sorted-key `JSONEncoder`, and the 1,024-row
limit. It has no selector v6, carrier graph, authenticated budget tree,
durable operation lease, root promotion, or terminal abort selector. Existing
tests are baseline evidence only.

Code-grounded status used by this revision:

| Surface | Current symbol | Status against R16 |
|---|---|---|
| selected retention/index | `ModelTransactionActiveIndex`, `decodeActiveIndex`, `initializeLegacyRetention` in `ModelCatalogTransactionRetention.swift` | partial baseline; array and scan design is replaced |
| reservation migration | `initializeReservationMigration`, `recoverReservationPublicationIfNeeded`, `publishReservationDeparture` in `ModelCatalogTransactionReservationMigration.swift` | partial baseline; no carrier/selector authority |
| filesystem publication | `ModelTransactionDirectory.writeWithPublicationOutcome` in `ModelCatalogTransactionStorage.swift` | reusable primitive only; lacks R16 graph |
| preparation transaction | `ModelCatalogTransactionRunner.prepare`, `validatedPreparationSeal`, and `reconcile` in `ModelCatalogTransactions.swift` | landed preparation/seal path; adoption ticket missing |
| durable artifact custody | `stageVerifiedCopy`, `publishSealedCopy`, and `artifactURL` in `DurableModelArtifactStore.swift` | landed input to R16 adoption; ticket binding missing |
| artifact evidence | `ModelCatalogArtifactSeal.validate`, `ModelCatalogArtifactSnapshot.verified`, and `observe` | landed historical preparation evidence; selected adoption contract missing |
| maximum-shape evidence | `ModelCatalogReservationCapacityMeasurementTests` | historical R4 measurement only; does not prove R16 |

## 1. Authority and explicit supersession

R16 supersedes R15 sections 2.2–2.3, 3.1, 3.3–8 and every R14 codec or
taxonomy clause retained by textual substitution. It also supersedes R15's
post-A3 retained-abandoned result and its prepared-artifact external
publication edge. The following clauses remain governing only where R16 does
not replace them: R10's direct format-fence path and A0–A8 economic boundary;
R15's fixed carrier framing, four-FD ceiling, complete-carrier verification,
one-intent-at-a-time acyclic order, B+ page split rules, eight-second control
invocation deadline, and direct incremental historical audit limitation.

When a prior document conflicts with R16, R16 wins. No implementation may
combine the R14 envelope, R15 external run/page references, R15 revision-expiry
lease, R15 bootstrap-directory creation, R15 eight-step abandon queue, or R15
large external publication with this state machine.

The product boundary remains unchanged. Reservation evidence does not grant
network admission, trusted model identity, price authority, settlement,
rewards, enforcement, or production activation.

## 2. Fixed execution and ownership model

Each mutating control invocation has one monotonic eight-second deadline. It
may acquire `.reservation-migration/retirement/v1/activation.lock` with
`LOCK_EX|LOCK_NB`, but releases the flock and every descriptor before returning.
No flock, task, process identity, PID, wall-clock timestamp, or heartbeat is
durable authority. A call that cannot begin a syscall and finish its specified
postcondition before the remaining budget returns typed `retry` without
selecting new authority. Hosts on which a required bounded control syscall
cannot be qualified are rejected before selector v6 selection.

The selected selector and carrier graph are the only cross-call authority.
Every caller reopens and validates the current selector after acquiring the
per-call flock. Every pending-intent CAS names the exact predecessor selector
digest and revision. A caller holding bytes derived from an older selector
cannot publish after another caller advances the selector. Crash recovery is
performed by any compatible caller from the same selected pending transaction;
there is no durable owner to become stale.

## 3. Acyclic bootstrap from the current R4 graph

The direct selected path remains exactly:

```text
.reservation-migration/retirement/v1/activation/<activationUUID>/active.json
```

The lock remains exactly:

```text
.reservation-migration/retirement/v1/activation.lock
```

The carrier directory is exactly:

```text
.reservation-migration/retirement/v1/activation/<activationUUID>/carriers
```

Bootstrap has two authorities, in this order.

### 3.1 Unselected scaffold

Under the current R4 journal lock, before the v4 format fence exists:

1. create and fsync `activation.lock` and its existing parents as R10 requires;
2. create and fsync the exact `<activationUUID>` directory, capture
   `immutableIdentity.v4`, and fsync its parent;
3. write, fsync, rename, and directory-fsync generation-zero
   `model_catalog_selector.v7` at `active.json`;
4. revalidate the old format/index/source, lock identity, activation-directory
   identity, selector bytes, and absence of a competing activation;
5. write, rename, and directory-fsync the R10 v4 format fence that names this
   exact selector path and lock identity.

The activation directory is an **unselected bootstrap scaffold**, not a later
creation target. Generation zero adopts its exact captured identity and
records `bootstrapScaffoldChargeBytes=4096` in fixed bootstrap accounting. It
is not in storage/path trees and is never refunded. Death before the format
fence selects the old graph; equal unselected scaffold/selector bytes may be
reused after complete validation. Unequal bytes, an unexpected format fence,
or a changed scaffold/lock identity protect before mutation. Death after the
format-fence directory fsync selects generation zero. An old binary must reject
the unknown mandatory v4 format before any write; that exact prior-binary
fixture is a gate.

The one-time lock order is journal lock, then activation flock. Every selected
invocation thereafter takes the activation flock before any journal lock.

### 3.2 Selected carrier-directory adoption

Generation zero has `bootstrapState.phase="carrier-directory-intent"` and an
exact `directoryIntent.v1` containing
`relativePathUTF8Base64URL,pathSHA256,fileType="directory",mode=448,
expectedAbsent=true,chargeBytes=4096`. This intent is selected by the format
fence itself; it does not authorize creation of its own parent.

The first selected invocation may `mkdirat` only that child, fsync the
activation directory, reopen without following links, require it empty, and
capture its full identity. It then publishes selector revision one with phase
`budget-rows`, the exact identity, and `bootstrapDirectoryChargeBytes=4096`.
This is the sole receipt-free post-fence filesystem mutation. Before revision
one is directory-fsynced, recovery accepts only absence or the exact empty
candidate. After revision one is directory-fsynced, absence or identity drift
protects. It never re-creates a selected missing directory.

All later bootstrap work is written as catalog carriers. The bootstrap graph
contains exactly all `R+1` budget-entry insertions, genesis activation,
checkpoint, empty sequence registry, source witness, format-fence witness, and
bootstrap-close receipt. The selected generation-zero scaffold and selected
carrier-directory adoption consume one protocol unit each; each of the six
carrier publications reserves at most eight, for a fixed allowance of 50.
Bootstrap close releases any unused portion and records consumed and released
amounts; it cannot silently burn it. There is no activation-directory or
carrier-directory carrier receipt and no second charge for either directory.
Ordinary work is disabled until the close selector sets
`bootstrapState.phase="complete"`, all entries are selected, source witnesses
still match, and unused bootstrap authority is zero.

## 4. Durable operation lease without expiry or stale ownership

`leaseAuthorization.v2` has exactly:

```text
schema,activationUUID,transactionUUID,budgetKey,budgetEntryGeneration,
logicalOperationKind,logicalOperationOrdinal,maximumTargetEdges,
maximumDebits,baseBudgetRootReference,baseSelectorSHA256
```

`maximumTargetEdges` is 1–64. `maximumDebits` has exactly one ordinary category
and, only for A1/A2 cancellation, one `abort` category. Each debit has exactly
`category,maximumUnits,maximumChargeBytes`. Its digest is:

```text
SHA256("macprovider-budget-lease-authorization-v2\0" ||
       u64be(JCS.count) || JCS)
```

`budgetLease.v4` is embedded in the selected pending transaction and has
exactly `schema,authorization,authorizationSHA256,state,debits,
targetEdgesConsumed,lastSelectedEdgeOrdinal`. State is
`reserving|open|closing-commit|closing-abort`. There is no expiry revision,
renewal, owner identifier, or liveness timestamp. Each debit contains exactly
`category,maximumUnits,maximumChargeBytes,consumedUnits,consumedChargeBytes,
abandonedUnits,abandonedChargeBytes`.

The corresponding selected `budget_entry.v3` stores the same
`openLeaseDigest`. At most one pending transaction and one open lease exist for
the activation. The lease remains valid across selector revisions, process
death, and retries until its selected close. It authorizes only the exact
transaction, operation ordinal, category, and limits. A closed lease, stale
base selector, mismatched transaction, edge ordinal replay, 65th target edge,
or second lease rejects before target creation.

Every carrier edge still has two selector revisions: one pending-intent CAS and
one carrier successor. Reserve and close continuations use the same durable
lease identity but consume selected control authorization, not target-edge
count. Therefore a 64-target-edge operation, its reserve, crash replay,
commit/abort close, and terminal selector are reachable without renewing or
extending authority. Replaying a completed edge converges on the selected
successor; it does not consume another edge. Concurrent callers serialize only
for one invocation through the activation flock.

## 5. Addressable selected roots and acyclic root promotion

`localRecordReference.v2` has exactly
`kind="local",slotOrdinal,recordOrdinal,recordCanonicalLength,recordSHA256`.
It is legal only inside the carrier being encoded and may point only to a lower
slot. `carrierRecordReference.v2` has exactly
`kind="carrier",carrierOrdinal,carrierLengthBytes,carrierSHA256,
immutableIdentitySHA256,slotOrdinal,recordOrdinal,recordCanonicalLength,
recordSHA256`.

`rootReference.v2` has exactly
`treeKind,entryCount,height,topPageReference,rootTranscriptSHA256`.
Receipts inside a final tree carrier contain `localTargetRootReference`, whose
top page is local, plus `rootPromotion.v1` with exactly
`treeKind,entryCount,height,topSlotOrdinal,topRecordOrdinal,
topRecordCanonicalLength,topRecordSHA256,rootTranscriptSHA256`. Neither
contains a carrier digest.

After the carrier bytes, digest, and immutable identity exist, the successor
selector computes `promote(receipt.rootPromotion,currentCarrierReference)` by
copying the root scalar fields unchanged and replacing only the local top page
with the corresponding complete carrier record reference. The selector stores
that external root and the receipt reference. Independent validation requires
all scalar fields and record coordinates/digests to match. A selector,
activation, checkpoint, budget entry, path entry, storage entry, work record,
or sequence entry containing any local reference rejects. A receipt containing
a promoted carrier digest would create a cycle and rejects.

The frozen dependency order is:

```text
base selector and carrier-addressable roots
 -> one edge intent
 -> pending selector
 -> target records and local target root/promotion descriptor
 -> receipt
 -> complete carrier digest and identity
 -> promoted external root in successor selector
```

## 6. Standalone R16 codec and physical taxonomy

Nothing in this section inherits bytes from R14. JSON uses RFC 8785 JCS;
strings are NFC; hex is lowercase; base64url is unpadded; ordinary integers are
nonnegative and at most `2^53-1`; wide bytes use exact `wide-v1` hi/lo limbs.
Every nullable key is present with JSON null. Unknown/duplicate fields,
noncanonical encodings, floats, and overflows reject.

Every catalog record has the exact common key set
`schema,activationUUID,transactionUUID,edgeOrdinal,slotOrdinal,recordOrdinal`
plus the suffix in this registry. `transactionUUID` is null only for bootstrap
records. No `transactionIntentID`, batch ordinal, MMR field, digest-only page
reference, or external run/page reference is legal.

`immutableIdentity.v4` has exactly
`deviceID,fileID,fileType,mode,ownerUID,groupGID,linkCount,byteLength,
mtimeSeconds,mtimeNanoseconds,ctimeSeconds,ctimeNanoseconds,birthtimeSeconds,
birthtimeNanoseconds,userFlags,systemFlags`. `fileType` is
`regular|directory`; `byteLength` is null only for a directory. Mode is a safe
integer (`0700` is encoded as decimal 448). Every placement check compares a
descriptor `fstat` with no-follow pathname `fstatat` before and after the
operation, including every field above.

The carrier v2 path is sixteen lowercase hexadecimal digits plus `.mcc`.
Framing is exactly
`u32be(headerLength)||headerJCS||SHA256(headerJCS)||zeroPadding` in an
8,228-byte header extent followed by 1–16 slots, each exactly
`u32be(bodyLength)||bodyJCS||SHA256(bodyJCS)||zeroPadding` in a 65,572-byte
extent. Header JCS is 2–8,192 bytes and record JCS is 2–65,536 bytes, yielding
minimum/maximum files 73,800/1,057,380 bytes. Header schema
`model_catalog_carrier_header.v2` has exactly
`schema,activationUUID,carrierOrdinal,previousCarrierReference,
pendingSelectorSHA256,transactionUUID,edgeOrdinal,edgeKind,edgeIntentSHA256,
recordCount,recordTranscriptSHA256,payloadLengthBytes`. The record transcript
uses the R15 `macprovider-carrier-v2` ordinal/slot chain. The complete file
digest is outside the header. `carrierReference.v2` has exactly
`carrierOrdinal,payloadLengthBytes,carrierSHA256,immutableIdentitySHA256`.

`model_catalog_selector.v7` has exactly:

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

It retains the exact 65,536-byte
`u32be(length)||JCS||SHA256(JCS)||zeroPadding` framing and 49,152-byte JCS
ceiling. `fixedExtentRootSHA256` uses the length-prefixed null-field
`macprovider-selector-v7` domain. State is `migrating|ready|protected`.
`pendingTransaction.v2` has exactly
`transactionUUID,logicalOperationKind,logicalOperationOrdinal,phase,
edgeIntent,edgeIntentSHA256,openBudgetLease,controlAuthorization,
continuationReference,workAccumulator,cancelRequested,completionDisposition,
abortCursor`. Phase is `between-edges|between-carriers|reserving|executing|
closing-commit|closing-abort|aborting|forward-completing`.
`completionDisposition` is `normal|forward-only`; `abortCursor` is null outside
legal A1/A2 abort and otherwise exactly
`generation,nextSlot,completedSlotCount,terminalReceiptReference`.
`workAccumulator.v2` has exactly
`selectedCarrierCount,selectedRecordCount,selectedExternalCount,selectedUnits,
selectedChargeBytes,abandonedUnits,abandonedChargeBytes,terminalSHA256`.

`edgeIntent.v4` has exactly
`schema,activationUUID,transactionUUID,logicalOperationKind,
logicalOperationOrdinal,edgeOrdinal,edgeKind,budgetScope,sourceRowOrdinal,
budgetCategory,baseSelectorSHA256,baseCarrierReference,
baseStorageRootReference,basePathRootReference,baseLifecycleRootReference,
baseBudgetRootReference,baseSequenceRootReference,baseWorkRootReference,
priorReceiptReference,continuationReference,operationInputReferences,
targetDescriptor,maximumTargetRecords,maximumExternalObjects,
maximumPermanentUnits,maximumChargeBytes,candidateSelectorRevision`.
Its digest uses the `macprovider-edge-intent-v4` length-prefixed JCS domain.
`operationInputReferences` has 0–8 carrier references. Edge kind is
`record-publish|tree-mutate|bounded-external-publish|budget-reserve|
budget-close|abort-slot|phase-commit|audit-step|artifact-adopt`.
`targetDescriptor.v4` has exactly
`descriptorKind,targetTreeKind,targetKeyBase64URL,targetRangeFirstBase64URL,
targetRangeLastBase64URL,sequenceCollection,sequenceOrdinal,recordSchema,
externalObjectDescriptor,phaseFrom,phaseTo,abortSlot,
expectedPriorEntrySHA256,expectedPriorGeneration,targetCount,
targetCoordinateOrderSHA256`. Descriptor kind is
`tree-update|sequence-append|record-set|bounded-external-object|
phase-transition|abort|audit|artifact-adoption`; exactly the named coordinates
for that kind are non-null. `targetCoordinateOrderSHA256` hashes coordinates
only, never future records or digests.

`continuationReference.v2` has exactly
`mutationKind,nextTargetOrdinal,targetCount,frontierReferences,
targetCoordinateOrderSHA256,priorWorkAccumulator`; frontier has 1–8 local or
carrier references. `controlAuthorization.v2` has exactly
`budgetKey,budgetEntryGeneration,maximumUnits,maximumChargeBytes,
consumedUnits,consumedChargeBytes,targetBudgetEntrySHA256`.
`directoryIntent.v1` has exactly
`relativePathUTF8Base64URL,pathSHA256,fileType,mode,expectedAbsent,chargeBytes`.
`bootstrapState.v2` has exactly
`phase,sourceRowCount,sourceWitnessSHA256,unitLimit,unitsConsumed,unitsReleased,
carrierLimit,carriersConsumed,byteLimit,bytesConsumed,bytesReleased,
nextBudgetRowOrdinal,activationDirectoryIdentity,carrierDirectoryIdentity,
bootstrapScaffoldChargeBytes,bootstrapDirectoryChargeBytes`.

`budget_entry.v3` has exactly
`key,scope,sourceRowOrdinal,generation,categoryUnitLimits,
categoryUnitsReserved,categoryUnitsSpent,categoryUnitsAbandoned,
categoryByteLimits,categoryBytesReserved,categoryBytesSpent,
categoryBytesAbandoned,controlUnitLimit,controlUnitsSpent,controlByteLimit,
controlBytesSpent,openLeaseDigest,lastLeaseAuthorizationSHA256,
lastCloseOutcome`. Category arrays are exactly
`source-capture,merge,tree,verification,materialization,abort` in that order.
`lastCloseOutcome` is `none|committed|aborted`; reserved+spent <= limit,
abandoned <= spent, and all control values remain within their limits.

`storage_entry.v3` has exactly
`storageOrdinal,pathKey,pathClass,objectKind,physicalClass,state,objectSHA256,
canonicalLength,chargeBytes,immutableIdentitySHA256,lifecycleKey,
sourceRowOrdinal,transactionUUID,adoptionTicketSHA256`.
`path_entry.v3` has exactly
`pathKey,relativePathUTF8Base64URL,pathClass,objectKind,physicalClass,
generation,state,objectSHA256,canonicalLength,storageOrdinal,
immutableIdentitySHA256,transactionUUID,targetBinding,sourceRowOrdinal,
adoptionTicketSHA256`. Storage state is `ordinary`; path state is
`reserved|materialized|bound|indexed`. The R15 `retained-abandoned` value is
forbidden. `lifecycle_entry.v3` has exactly
`lifecycleKey,generation,state,transactionUUID,sourceRowOrdinal,reservedBytes,
spentBytes,activeIntentReference,pathKey,lastOutcome` with state
`available|reserved|bound|imported|consumed` and outcome
`none|committed|aborted`.

The digest registry is uniform and closed. A catalog record reference uses
`SHA256(recordJCS)`. A complete carrier reference uses SHA-256 of every framed
file byte. An identity reference uses
`SHA256("macprovider-immutable-identity-v4\0"||u64be(JCS.count)||JCS)`.
Every terminal field named `*TranscriptSHA256` uses
`SHA256("macprovider-r16-transcript\0"||u16be(schemaUTF8.count)||schemaUTF8||
u16be(fieldNameUTF8.count)||fieldNameUTF8||u64be(nullJCS.count)||nullJCS)`,
where exactly that terminal field is null. Array/content fields named
`*SHA256` use the same construction with domain `macprovider-r16-content` and
the canonical JCS array/value instead of nullJCS. `objectSHA256` for a bounded
external regular is SHA-256 of its exact file bytes; `artifactSHA256` is the
signed canonical artifact-tree digest already selected by preparation. Path,
selector, lease, edge-intent, ticket, carrier, and fixed-extent digests use
their separately stated domains. No digest field permits an implementation-
defined encoder or undomained concatenation.

| record schema | exact suffix fields |
|---|---|
| `name_scan_root.v4` | `directoryIdentity,attrABIProfileSHA256,nextDirectoryOffset,nextRecordSentinelSHA256,rawEntryCount,rawNameBlockSequenceRootReference,eof,scanTranscriptSHA256` |
| `raw_name_block.v4` | `blockOrdinal,firstDirectoryOffset,successorDirectoryOffset,entries,entryCount,firstNameSHA256,lastNameSHA256,entriesSHA256` |
| `name_block.v4` | `blockOrdinal,names,nameCount,firstName,lastName,namesSHA256` |
| `row_block.v5` | `role,blockOrdinal,rows,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `row_verification_block.v4` | `pass,blockOrdinal,firstRowOrdinal,lastRowOrdinal,rowCount,priorTranscriptSHA256,terminalTranscriptSHA256` |
| `storage_verification_block.v4` | `blockOrdinal,firstStorageOrdinal,lastStorageOrdinal,entryCount,materializedBytes,priorTranscriptSHA256,terminalTranscriptSHA256` |
| `name_capture_root.v4` | `previousRootReference,nameScanRootReference,rawNameBlockSequenceRootReference,nameBlockSequenceRootReference,sortWorkRootReference,nameCount,firstName,lastName,namesSHA256` |
| `row_work_root.v4` | `previousRootReference,nameBlockSequenceRootReference,rowBlockSequenceRootReference,captureRunSequenceRootReference,nextNameBlockOrdinal,nextNameOrdinal,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `run_work_root.v4` | `previousRootReference,mergePass,nextGroupOrdinal,nextCreationOrdinal,inputRunSequenceRootReference,completedMergeGroupSequenceRootReference,outputRunSequenceRootReference,activeMergeGroupWorkReference,inputRunCount,completedGroupCount,outputRunCount,mergeTranscriptSHA256` |
| `merge_group_work.v4` | `mergePass,groupOrdinal,creationOrdinal,inputRunSequenceRootReference,inputFirstOrdinal,inputCount,cursorSequenceRootReference,headSequenceRootReference,outputRowBlockSequenceRootReference,outputRowCount,firstUUID,lastUUID,predecessorUUID,exhaustedInputCount,rollingTranscriptSHA256` |
| `run_manifest.v6` | `runKind,rowBlockRole,mergePass,runOrdinal,creationOrdinal,inputRunSequenceRootReference,inputRunCount,rowBlockSequenceRootReference,rowBlockCount,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `tree_build_root.v5` | `previousRootReference,level,phase,currentLevelInputSequenceRootReference,currentLevelPageSequenceRootReference,completedLevelSequenceRootReference,nextInputBlockOrdinal,nextInputRowOrdinal,nextGlobalRowOrdinal,nextInputPageOrdinal,nextTreeObjectOrdinal,treeTranscriptSHA256` |
| `verification_work_root.v4` | `previousRootReference,pass,rowVerificationBlockSequenceRootReference,storageVerificationBlockSequenceRootReference,nextRowOrdinal,nextStorageOrdinal,targetStorageRootReference,targetEntryCount,targetMaterializedBytes,rowTranscriptSHA256,storageTranscriptSHA256` |
| `phase_record.v1` | `phaseFrom,phaseTo,materializationPathSHA256,objectKind,objectReference,priorPhaseRecordReference,phaseTranscriptSHA256` |
| `prepared_artifact_adoption.v1` | `modelID,release,artifactSHA256,durableRelativePathBase64URL,durablePathSHA256,preparationSealSHA256,adoptionTicketSHA256,artifactRootIdentitySHA256,artifactEntryCount,artifactCanonicalBytes,preparationTransactionUUID` |
| `edge_receipt.v4` | `edgeKind,edgeIntentSHA256,intentBaseSelectorSHA256,pendingSelectorSHA256,priorReceiptReference,targetRecordReferences,externalObjectReference,localTargetRootReference,rootPromotion,continuationReference,budgetLeaseDigest,selectedUnits,selectedChargeBytes,priorWorkAccumulator,outcome,receiptTranscriptSHA256` |
| `abort_receipt.v3` | `abortGeneration,basePhase,completedCompensationSteps,priorReceiptReference,baseBudgetRootReference,localTargetBudgetRootReference,budgetRootPromotion,lifecycleReserveReleasedBytes,leaseReleasedUnits,leaseReleasedBytes,spentUnits,spentBytes,abandonedUnits,abandonedBytes,outcome,receiptTranscriptSHA256` |
| `activation_record.v3` | `activationGeneration,previousActivationReference,state,sourceWitnessSHA256,storageRootReference,pathRootReference,lifecycleRootReference,budgetRootReference,sequenceRegistryRootReference,workRootReference,currentCheckpointReference,carrierAuditState` |
| `checkpoint_record.v3` | `checkpointGeneration,previousCheckpointReference,activationReference,phase,sourceWitnessSHA256,storageRootReference,pathRootReference,lifecycleRootReference,budgetRootReference,sequenceRegistryRootReference,workRootReference,lastReceiptReference,carrierAuditState` |
| `source_witness.v2` | `sourceRowCount,priorActiveIndexSHA256,migrationSourceSHA256,namespaceSHA256,rowsSHA256,capturedAtSelectorRevision` |
| `format_fence_witness.v1` | `formatFenceSHA256,selectorRelativePathBase64URL,selectorPathSHA256,lockIdentitySHA256` |
| `bootstrap_close.v1` | `sourceWitnessReference,budgetRootReference,expectedEntryCount,unitsConsumed,carrierCount,chargedBytes,unusedUnits,unusedBytes` |

Receipt target references are local and point backward. `externalObjectReference`
is non-null only for `bounded-external-publish`; local target root and promotion
are paired and non-null only on the final tree/sequence carrier; continuation
is non-null only on a nonfinal carrier. Outcome is
`continued|committed|aborted|protected`. The receipt contains no complete
digest/reference for its own carrier. All other illegal-null combinations
reject.

Tree/sequence pages are only `bplus_leaf.v2` and `bplus_node.v2`. A leaf suffix
is `treeKind,level,firstKeyBase64URL,lastKeyBase64URL,entryCount,entries,
subtreeCount,subtreeChargeBytes,pageTranscriptSHA256`; a node suffix replaces
`entries` with `childCount,children`. Each child has exactly
`firstKeyBase64URL,lastKeyBase64URL,subtreeCount,subtreeChargeBytes,
pageReference`. Storage/lifecycle leaves hold at most 32 entries and split
17/16; path/budget/sequence leaves hold at most 16 and split 9/8; node fanout is
128; height is 0–8; page JCS is at most 65,536 bytes.

Sequence-entry records use the common keys and the following suffixes. Every
`contentReference`, `runManifestReference`, `pageReference`, and
`sequenceRootReference` is a carrier record/root reference; none uses storage
ordinal or immutable external identity.

| collection/schema | exact suffix fields |
|---|---|
| `raw-name-block/raw_name_block_ref.v3` | `blockOrdinal,firstDirectoryOffset,successorDirectoryOffset,recordCount,firstNameSHA256,lastNameSHA256,contentReference,transcriptSHA256` |
| `name-block/name_block_ref.v3` | `blockOrdinal,nameCount,firstName,lastName,contentReference,transcriptSHA256` |
| `row-block-capture/row_block_ref.v3` | `role,blockOrdinal,rowCount,firstUUID,lastUUID,contentReference,rowsSHA256` |
| `row-block-merge/row_block_ref.v3` | `role,blockOrdinal,rowCount,firstUUID,lastUUID,contentReference,rowsSHA256` |
| `capture-run/run_ref.v3` | `runOrdinal,mergePass,rowCount,firstUUID,lastUUID,runManifestReference,rowsSHA256` |
| `input-run/run_ref.v3` | `runOrdinal,mergePass,rowCount,firstUUID,lastUUID,runManifestReference,rowsSHA256` |
| `completed-merge-group/merge_group_ref.v3` | `mergePass,groupOrdinal,creationOrdinal,inputCount,outputRunReference,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `output-run/run_ref.v3` | `runOrdinal,mergePass,rowCount,firstUUID,lastUUID,runManifestReference,rowsSHA256` |
| `current-level-input/tree_page_ref.v3` | `level,pageOrdinal,itemCount,firstUUID,lastUUID,pageReference,itemsSHA256` |
| `current-level-page/tree_page_ref.v3` | `level,pageOrdinal,itemCount,firstUUID,lastUUID,pageReference,itemsSHA256` |
| `completed-level/tree_level_ref.v3` | `level,pageCount,firstUUID,lastUUID,sequenceRootReference,levelSHA256` |
| `row-verification-block/row_verification_ref.v3` | `pass,blockOrdinal,firstRowOrdinal,lastRowOrdinal,rowCount,contentReference,transcriptSHA256` |
| `storage-verification-block/storage_verification_ref.v3` | `blockOrdinal,firstStorageOrdinal,lastStorageOrdinal,entryCount,materializedBytes,contentReference,transcriptSHA256` |

The physical taxonomy is closed:

| physical class | legal objects | representation | indexed |
|---|---|---|---|
| catalog record | every schema in this section, run manifests, pages, work roots, receipts | record in immutable carrier | by carrier reference only |
| bounded external regular | four source certificates and four receipt bodies, each <=1,048,576 | `externalObjectDescriptor.v5` plus full identity | storage and path |
| materialization directory | exact A3 directory | descriptor plus full directory identity | storage and path |
| adopted durable artifact | already-published `DurableModelArtifactStore` directory and preselected seal/ticket | `prepared_artifact_adoption.v1`; never a target of reservation publication | path/storage adoption entry |
| protocol evidence | preparation seal <=4,194,304 and adoption ticket <=65,536 | direct transaction-store digest/identity reference | neither |
| protocol directory | activation and carrier directories | selector bootstrap identity | neither |
| protocol carrier | fixed R15 carrier v2 | complete digest and identity | neither |
| fixed extent | selector 65,536 and lock 4,096 | direct path | neither |

`externalObjectDescriptor.v5` has exactly
`objectKind,physicalClass,contentCodec,canonicalRelativePathBase64URL,
pathKey,pathClass,budgetScope,sourceRowOrdinal,budgetCategory,canonicalLength,
objectSHA256,expectedAbsent,sourceBinding`. External regular requires length,
digest, identity, storage, and path; directory requires null length/digest and
directory identity. Adopted durable artifact cannot appear in an external
descriptor. Run/page/work/intent/selector objects cannot be external.
Content blocks are split before intent selection at the greatest deterministic
semantic prefix whose independently encoded record JCS is <=65,536; an empty
block or an item that cannot fit alone rejects. This replaces R15's 1 MiB
external work blocks.

## 7. Complete ordered transition graph and capacity

Every transition below is a logical mutation. A tree mutation emits at most 17
pages and two receipts in at most two carriers; any logical transition is
conservatively allocated 19 permanent units and six carrier/control slots.
Selector-only pending/successor revisions consume no protocol unit but are
counted separately in the operation's revision trace. The independent
generator expands these literal names; production accepts no numeric unnamed
state.

Per-row transitions are:

| category | literal expansion | count |
|---|---|---:|
| source-capture | `primary|origin|class|lineage` × `publish|storage-index|path-index`, then `raw-source-close|name-source-close|row-source-close|capture-run-close` | 16 |
| merge | pass `0...6` × `bind-input|publish-row-block|index-row-block|advance-output-sequence`, then `run-open|run-close|merge-root-open|merge-root-close` | 32 |
| tree | level `0...7` × `emit-page|advance-level-sequence` | 16 |
| verification | `rows-1|rows-2` × `open|publish-block|advance-sequence|close`, then `storage` × those four | 12 |
| materialization | A3/A4 five-edge sequence below; four A5 bodies × five-edge sequence; `prepared-adoption-record|prepared-storage-index|prepared-path-index`; `lifecycle-reserve|lifecycle-bind|binding-publish|phase-A6|activation-record|checkpoint-record` | 34 |
| abort/retry | generation `0...7` × the eight terminal/retry slots in section 8 | 64 |
| **row total** | | **174** |

The materialization graph is literal and ordered:

```text
A2 -> phase-A3-directory-intent
   -> A3-directory-publication-receipt
   -> A3-storage-index
   -> A3-path-index
   -> phase-A4-directory-durable

for body in primary, origin, class, lineage:
   phase-A5-<body>-intent
   -> A5-<body>-publication-receipt
   -> A5-<body>-storage-index
   -> A5-<body>-path-index
   -> phase-A5-<body>-durable

prepared-adoption-record
 -> prepared-storage-index
 -> prepared-path-index
 -> lifecycle-reserve -> lifecycle-bind -> binding-publish -> phase-A6
 -> activation-record -> checkpoint-record
```

No external/tree edge also advances phase. Each named phase is a
`phase_record.v1` carrier record. A5 bodies retain the exact R10 path, content,
identity, receipt suffix, and charging order.

The fixed registry names states rather than numbers:

* source: `empty-primary,empty-origin,empty-class,empty-lineage,
  primary-open,origin-open,class-open,lineage-open,raw-close,name-close,
  row-close,capture-close,source-verified,source-failed,source-retry,
  source-protected` × `prepare|commit` = 32;
* merge: `pass-0...pass-7` × `open-input,open-output,bind-input,
  publish-row-block,index-row-block,advance-output,close-run,close-pass` = 64;
* tree: `level-0...level-7` × `open-level,select-root,advance-sequence,
  close-level` = 32;
* verification: `rows-1,rows-2,storage,terminal` × `open,publish-block,
  index-block,advance-sequence,close-pass,record-result,retry,protect` = 32;
* materialization: `A0,A1,A2,A3,A4,A5,A6,A7` ×
  `record-phase,bind-root,record-result,close` = 32;
* recovery: `selector-temp,selector-renamed,carrier-temp,carrier-renamed,
  carrier-durable,external-temp,external-renamed,external-durable,
  directory-created,directory-durable,phase-recorded,budget-reserving,
  budget-closing,abort-receipt,terminal-selector,protected` ×
  `inspect,adopt,resume,compensate,retry,close,record,protect` = 128.

This preserves 320 fixed transitions. The new per-row limits are
`174*19=3,306` ordinary units and `6,612` control units. Fixed limits remain
6,080 ordinary and 12,160 control units. Bootstrap contributes 19 units for
each row and the fixed entry plus 50 fixed units. Therefore:

```text
units(R) = (3,306 + 6,612 + 19)R + 6,080 + 12,160 + 19 + 50
         = 9,937R + 18,309
protocol Rmax = 453,215,218,612
units(Rmax) = 4,503,599,627,365,753 < 2^52
units(Rmax+1) = 4,503,599,627,375,690 >= 2^52

carrierCount(R) <= (174*6 + 2)R + (320*6 + 2 + 6)
                = 1,046R + 1,928
carrierCount(Rmax) = 474,063,118,670,080 < 2^49
```

The protocol arithmetic ceiling is not a physical-capacity claim. The current
product continues to admit at most 1,024 selected rows; at that product limit,
`units=10,193,797` and `carrierCount<=1,073,032`. Bootstrap selects exact byte
limits from encoded candidate sizes, directory charges, adopted-artifact
transfer, lifecycle reserve, quota, Wpeak, and Uafter in checked wide
arithmetic. It does not preallocate maximum carriers. Any omitted phase edge,
unknown transition name, first over-limit unit/byte/edge, unsafe `off_t`, quota,
inode, or free-space result rejects before selector v7 publication.

## 8. Legal abort, terminal selection, and inherited economics

There are two terminal routes.

### 8.1 A1/A2 abort

Only A1 `reserved` and A2 `row-selected` may abort/refund. Each generation has
exactly eight ordered slots:

```text
0 begin-abort-generation
1 close-sequence
2 close-work-root
3 release-lifecycle-if-selected
4 prepare-budget-abort-close
5 record-A7-aborting
6 record-A8-aborted
7 publish-abort-receipt
```

Each applicable step is one intent at a time. Inapplicable steps select an
explicit zero-delta `phase_record.v1` or close record, preserving order and
work accumulator. `abort_receipt.v3.completedCompensationSteps` lists exactly
slots 0–6; it never lists itself or claims that pending was cleared. Slot 4
may select control continuations but leaves the ordinary budget root and lease
in `closing-abort`. Slot 6 publishes proposed A8 phase evidence while selected
product state remains A7. Slot 7's final carrier contains the remaining budget
pages and abort receipt with a local target budget root and promotion
descriptor. Its sole `terminal-abort-successor` atomically promotes/selects the
closed budget root, clears its `openLeaseDigest`, selects the receipt and A8
outcome, and sets `pendingTransaction=null`. It is explicitly exempt from the
ordinary between-edge successor rule and requires no later selector-only CAS.

Death before the receipt carrier directory fsync leaves the selected pending
intent and absent/exact candidate. Death after carrier durability but before
selector durability resumes only the exact terminal successor. Death after
the selector directory fsync is stable A8/null-pending. No state can contain a
receipt claiming a future clear.

A1 releases the exact unused classified/unclassified lifecycle reservation
selected at A1. A2 releases that same unused reserve and any unconsumed
operation/abort lease. Selected carrier/control work remains spent. The abort
receipt gives exact released/spent/abandoned counters. Retry generations 0–7
retain prior receipts; a ninth failure protects.

### 8.2 A3 and later forward completion

From selected A3 `directory-intent` onward, cancellation or ordinary permanent
failure sets `cancelRequested=true` and `completionDisposition="forward-only"`.
Recovery must execute the exact A3→A6 path, preserving the full admitted
economic charge, or select `protected`. It cannot choose abort, retained-
abandoned, available lifecycle, hidden ordinary path, or any refund. A6
transfers the unmaterialized remainder to spent slack exactly once. A7/A8 are
reachable only from the A1/A2 abort route.

Cancellation after A3 is acknowledged to the caller only after the forward
path and stable null-pending selector are durable; the result is typed
`cancelled_after_commit` and reports that the model became active and the full
charge was retained. It must never be presented as rollback. Protected
evidence cannot be laundered into abort.

## 9. Prepared artifact adoption with bounded reservation publication

Reservation no longer copies, hashes, fsyncs, renames, or publishes model
artifact bytes. The existing `DurableModelArtifactStore` preparation workflow
owns download, canonical content hashing, verified copy, durable publication,
and `ModelCatalogArtifactSeal`. Those operations remain cancellable and their
actual duration is reported separately from reservation control latency.

After durable publication, preparation creates and fsyncs a small
`adoption_ticket.v1` at a digest-addressed transaction path. It has exactly:

```text
schema,preparationTransactionUUID,modelID,release,artifactSHA256,
durableRelativePathBase64URL,durablePathSHA256,artifactRootIdentity,
artifactEntryCount,artifactCanonicalBytes,preparationSealSHA256,
preparationTerminalReceiptSHA256
```

The ticket is selected only after the artifact content hash equals the signed
catalog digest, every seal entry and root identity is captured, the artifact
and seal are durable, publication uses exclusive rename/adoption, and the
preparation transaction has a stable success receipt. It is at most 65,536
bytes. Its digest uses
`SHA256("macprovider-artifact-adoption-ticket-v1\0"||u64be(JCS.count)||JCS)`.

The reservation adoption invocation direct-opens the selected ticket, seal,
and durable root without enumeration; validates transaction/model/release/hash,
path containment, ticket/seal digests, full root identity including
device/inode/type/mode/owner/group/link/size/mtime/ctime/birthtime/flags, and
the successful preparation receipt; then publishes only
`prepared_artifact_adoption.v1` plus its storage/path tree entries in carriers.
It rereads no artifact payload. The selected integrity claim is exactly
“content was fully verified by the named successful preparation transaction
and the durable root still has its sealed identity,” not “payload was rehashed
during adoption.” MLX opening must revalidate the selected seal and file
identities; mismatch blocks serving and protects the catalog binding.

The ticket, seal, and artifact root are immutable inputs. Replacement,
same-inode metadata drift, path drift, changed ticket/seal, missing preparation
receipt, untrusted catalog digest, or an artifact not at its final durable path
rejects before the pending adoption selector. Cancellation before that selector
leaves the inactive durable artifact untouched; cancellation after A3 follows
forward completion. GC may remove an inactive artifact only under the existing
store policy and never while a ticket is selected by pending work.

The mandatory performance proof uses the actual Build 1 supported artifact on
the physical Mac. Six cold reservation-adoption invocations must each publish
the small record/tree work at p95 <=8 seconds and <=4 FDs while recording
artifact bytes (as preverified input), ticket/seal bytes read, page/carrier
bytes hashed, fsync duration, RSS, cancellation, crash recovery, and MLX seal
revalidation. Preparation duration is reported separately and cannot be
substituted by a 1 MiB fixture. If the actual artifact/ticket/metadata path does
not meet the bound, Build 1 remains unqualified; the limit is not raised and
evidence is not relabeled.

## 10. Implementation slices and acceptance gate

Implementation may begin only after the R16/R22 plan gate passes. Slices are:

1. independent v7 selector, standalone codecs, carrier references, and root
   promotion vectors;
2. acyclic R4-to-v7 bootstrap and prior-binary rejection;
3. durable no-expiry lease, control authorization, 64-edge recovery, and
   concurrency;
4. named state-machine generator, complete capacity arithmetic, and all A3–A5
   phase publications;
5. A1/A2 terminal abort plus A3+ forward-only recovery and truthful results;
6. adoption ticket integration with `DurableModelArtifactStore` and physical
   supported-artifact proof;
7. compatibility, full Swift/Xcode/bridge checks, and independent GPT-5.6 Sol
   code, security, and architecture audits.

Rollback is permitted only before selector v7 selection. After the format fence
selects v7, old binaries reject and recovery must complete, abort where legal,
or protect. Selected carriers, artifact tickets, seals, and evidence are never
truncated or deleted as rollback.

Acceptance requires fresh targeted tests, full `swift test`, Malibu Xcode
tests, CLI/app bridge tests, max-shape measurement, and the actual physical
prepared-artifact adoption path. It separately reports implementation, local
verification, physical hardware verification, signed-feed/release evidence,
deployed services, and production qualification. The signed-feed→trusted
preparation→valid admission→real MLX→correct settlement journey remains a named
blocker until executed; this reservation plan cannot satisfy it alone.

Explicit non-goals are coordinator admission reconciliation while BYOM v0.2 is
active, new dependencies, payout/payment work, economic activation,
enforcement, deployment, release publication, remote hardware procurement, or
any claim of confidential compute.

## 11. R15 finding disposition

| Failed R15 finding | Required R16 correction | Mandatory R22 proof |
|---|---|---|
| H1 bootstrap parent cycle | unselected activation scaffold selected only by the format fence; selected carrier child follows | R22-02 byte/syscall crash oracle |
| H2 lease expires before close | durable transaction-bound no-expiry lease; stale callers rejected by selector CAS | R22-03 63/64/65 and process-death matrix |
| H3 local selected root | receipt-local root plus deterministic carrier promotion; selected graphs reject local refs | R22-04 one/two-carrier independent vectors |
| H4 contradictory codecs/taxonomy | standalone v7/R16 registry; carrier-only run/page/block graph; R14 fields reject | R22-05 independent literal/cross-product suite |
| H5 phase work absent from limits | literal A3/A4/A5 and named fixed graph; revised 34/174 counts and arithmetic | R22-06 semantic generator and first-over cases |
| H6 receipt claims future clear | eight slots; receipt lists 0–6; slot-7 successor atomically selects receipt and null pending | R22-07 death immediately around terminal carrier/CAS |
| H7 post-A3 refund | A1/A2 abort only; A3+ resumes full-charge forward completion or protects | R22-07 classified/unclassified A1–A6 economics |
| H8 unbounded artifact publication | preverified durable artifact/ticket is input; reservation publishes only small adoption evidence | R22-08 actual supported artifact, <=8-second adoption, cancellation/recovery |
