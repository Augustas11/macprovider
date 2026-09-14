# Build 1 reservation search progress addendum R18

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This is the complete corrective overlay for the seven High
and two Medium findings in
`reviews/reservation-search-progress-r17-plan-sol.md`. It is reviewed together
with `test-spec-r24-reservation-r18-corrections.md`. No Swift source or test is
authorized until an independent native GPT-5.6 Sol gate reports zero Critical,
High, and Medium findings for the exact two-file revision.

The inspected repository base remains `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The working implementation remains
the R4 array/scan implementation. R18 is documentation only.

## 1. Authority, scope, and simplification

R18 replaces R17 sections 2 through 6 and the affected arithmetic and test
claims. The candidate discriminator is `model_catalog_selector.v9`; v8 was an
unimplemented rejected proposal. R17 section 1's non-authority statement,
R16's unselected pre-fence scaffold, A1/A2-only refund, A3+ forward completion,
eight-second control-call deadline, four-FD ceiling, and `R<=1,024` product
limit remain. No prior proposed codec type is inherited unless this document
names it explicitly.

R18 makes three simplifying choices:

1. directory intent/adoption and selector close consume zero permanent protocol
   units; selected counters say zero;
2. one logical mutation has exactly one terminal receipt and at most 20
   permanent carrier records; there is no continuation receipt;
3. batched adoption recapture is progress evidence only. The pending CAS
   requires a new complete metadata recapture in one bounded call. Failure to
   meet that bound is a qualification blocker.

Nothing in this addendum grants admission, model identity, pricing,
settlement, rewards, enforcement, release, deployment, or physical
qualification.

## 2. Exhaustive bootstrap ledger

The direct activation and carrier paths and `directory_intent.v2` path rules
remain byte-for-byte as R17 section 2. `bootstrap_state.v4` replaces v3 and has
exactly:

```text
schema,phase,sourceRowCount,sourceWitnessSHA256,unitLimit,unitsConsumed,
unitsReleased,carrierLimit,carriersConsumed,carriersReleased,byteLimit,
bytesConsumed,bytesReleased,nextBudgetRowOrdinal,activationDirectoryIdentity,
carrierDirectoryIdentity,bootstrapScaffoldChargeBytes,
bootstrapDirectoryChargeBytes,ledgerSHA256
```

All counts except byte counters are `u53`; byte counters are `u64wide`.
`schema="bootstrap_state.v4"`. Phase is exactly
`carrier-directory-intent|budget-rows|genesis-records|closing|complete`.
`ledgerSHA256` binds the following literal ordered ledger:

| ordinal range | item | maximum units | maximum carriers | charge source |
|---|---|---:|---:|---|
| 0 | selected activation scaffold | 0 | 0 | exact 4,096 directory charge |
| 1 | selected `carriers` intent and mkdir adoption | 0 | 0 | exact 4,096 directory charge |
| 2...R+2 | one `budget-entry-bootstrap` mutation for each row, then fixed scope | 20 each | 2 each | exact encoded extents |
| R+3 | `source_witness.v4` | 1 | shared genesis carriers | exact encoded extent |
| R+4 | `format_fence_witness.v3` | 1 | shared genesis carriers | exact encoded extent |
| R+5 | `bootstrap_close.v3` | 1 | shared genesis carriers | exact encoded extent |
| R+6 | `edge_receipt.v6` | 1 | shared genesis carriers | exact encoded extent |
| R+7 | `activation_record.v5` | 1 | shared genesis carriers | exact encoded extent |
| R+8 | `checkpoint_record.v5` | 1 | shared genesis carriers | exact encoded extent |
| R+9...R+52 | reserved genesis page slots, used only by the generated six-root/budget-tree topology | 1 each | shared genesis carriers | exact encoded extent when present |
| close selector | release every unused ledger slot and unused encoded byte | 0 | 0 | none |

The final 44 genesis slots are individually addressed and cannot be reassigned
to a row. If the generated topology needs more than 44 pages, bootstrap rejects
before the v9 fence. Unused slots are released, never consumed fictionally.
Thus, for product-admissible R:

```text
unitLimit = 20*(R+1)+50
carrierLimit = 2*(R+1)+6
```

Generation zero has `unitsConsumed=0`, `carriersConsumed=0`, byte consumption
4,096, a non-null directory intent, and null carrier-directory identity.
Revision one still has zero units/carriers consumed, has byte consumption
8,192, clears the intent, and captures the carrier-directory identity. Every
later increment is derived by counting durable records/carriers named by the
ledger. Close computes released values as limit minus observed consumption and
requires exact equality for units, carriers, and bytes. The close selector and
directory selector revisions consume no hidden unit. Ordinary work is disabled
until the complete state is durable.

`byteLimit` is the checked-wide sum of both 4,096-byte directory charges and
every maximum framed carrier extent generated from the literal ledger. No
free-space estimate or sparse-file length substitutes for it.

## 3. One executable mutation and lease contract

### 3.1 Literal carrier trace and one capacity count

Every post-bootstrap mutation is one of `reserve|progress|close-commit|
close-abort`. It has `T=0...17` target page/record values and exactly three
control records: one `edge_receipt.v6`, one `activation_record.v5`, and one
`checkpoint_record.v5`. Its permanent-unit count is therefore exactly
`U=T+3`, in `3...20`. It uses one carrier when `T+3<=16`; otherwise carrier 0
contains the first `T-1` targets and the terminal carrier contains the final
target followed by receipt, activation, and checkpoint. The generator orders
targets so every changed nonempty root's top record is in the terminal carrier;
when several roots change, all their top records occupy the last target
positions and remain in that carrier. Carrier 0 contains no receipt or
authority record. Carrier 1's header selects carrier 0 as predecessor. The
receipt is the sole receipt for both carriers and is the only receipt selected
by the successor. There is no receipt-per-carrier rule, no 21st unit, and no
20-unit/21-unit alternative.

Publication is exactly:

```text
P0 validate selected selector, six roots, activation/checkpoint and open lease
P1 select a pending edge with authorization and exact predecessor digests
P2 write/fsync carrier 0 if needed, then write/fsync the terminal carrier
P3 reopen/hash/identity-check the complete one- or two-carrier chain
P4 resolve every target root against the terminal carrier context
P5 select the successor roots, receipt, activation/checkpoint and lease state
P6 close all descriptors/flock before returning
```

Only P5 advances authority. A durable carrier without P5 is an exact candidate,
never progress. Death at any boundary resumes the byte-identical trace or
protects.

### 3.2 Stable authorization and legal progress encoding

`lease_authorization.v4` has exactly:

```text
schema,activationUUID,transactionUUID,budgetKey,baseBudgetEntryGeneration,
logicalOperationKind,logicalOperationOrdinal,maximumTargetEdges,
maximumDebits,baseBudgetRootReference,baseSelectorSHA256
```

`lease_state.v6` has exactly:

```text
schema,authorization,leaseAuthorizationSHA256,state,leaseRevision,debits,
targetEdgesConsumed,lastSelectedEdgeOrdinal
```

State is `reserving|open|closing-commit|closing-abort`; revision starts at zero
for reserve and increments by one on every selected successor. The stable
authorization digest never changes. `maximumTargetEdges` is 1...64.

`control_authorization.v4` has exactly:

```text
schema,transitionKind,budgetKey,baseBudgetEntryGeneration,
targetBudgetEntryGeneration,leaseAuthorizationSHA256,baseLeaseStateSHA256,
successorLeaseStateSHA256,maximumUnits,maximumChargeBytes,consumedUnits,
consumedChargeBytes,targetBudgetEntrySHA256
```

It is mandatory in the pending edge and in the receipt, activation, and
checkpoint selected by the successor for **every** lease-state mutation. The
successor proves it by selecting those records and the exact projected budget
root; it has no duplicate unbound authorization field. The presence matrix is
closed:

| transition | base state | successor state | target edge count | open digests in projected entry |
|---|---|---|---:|---|
| reserve | absent | `reserving`, revision 0 | 0 | stable authorization + successor state |
| reserve-open | `reserving` | `open`, revision +1 | unchanged | same stable authorization + successor state |
| progress | `open` | `open`, revision +1 | predecessor +1 | same stable authorization + successor state |
| close-commit | `open` | `closing-commit`, revision +1 | unchanged | same stable authorization + successor state |
| close-abort | `open` | `closing-abort`, revision +1 | unchanged | same stable authorization + successor state |
| terminal-commit | `closing-commit` | null | unchanged | both null; outcome committed |
| terminal-abort | `closing-abort` | null | unchanged | both null; outcome aborted |

Each transition increments the budget-entry generation by one and binds exact
predecessor and successor generations. `successorLeaseStateSHA256` is null only
for a terminal transition. `baseLeaseStateSHA256` is null only for reserve.
The projected budget entry JCS includes all counters, both open digests,
generation, and close outcome. The selected promoted budget root must return
that exact JCS at `budgetKey`; its versioned digest must equal
`targetBudgetEntrySHA256`. The receipt carries the same control authorization.
No phase permits a null control authorization or null projected-entry digest.

The payload `progress` transition with edge ordinal n requires predecessor
`targetEdgesConsumed=n`, successor `n+1`, and successor last ordinal n. Reserve,
reserve-open, closing, and terminal transitions do not consume a target edge.
Replay of an already selected successor does not debit or increment. A 65th
edge, rollback, generation gap, state mismatch, stale projected entry, category
substitution, second open lease, or closed reuse rejects before temp creation.
There is no PID, wall clock, owner, expiry, renewal, or heartbeat in authority.

## 4. Registry-legal six-root snapshots

`root_snapshot.v2` has exactly:

```text
schema,branch,selectedRootReference,emptyRootReference,localRootReference,
rootPromotion
```

Its closed branches are:

| branch | selected | empty | local | promotion |
|---|---|---|---|---|
| `unchanged` | required selected carrier-addressable root-or-empty | null | null | null |
| `changed-empty` | null | required typed `empty_root_reference.v2` | null | null |
| `changed-nonempty` | null | null | required lower-slot `local_record_reference.v4` | required `root_promotion.v3` |

An unchanged empty root is carried in `selectedRootReference`; a changed-to-
empty root uses the explicit second branch. `root_promotion.v3` has exactly
`schema,treeKind,entryCount,height,topSlotOrdinal,topRecordOrdinal,
topRecordCanonicalLength,topRecordSHA256,rootTranscriptSHA256`.

A local reference or root promotion is legal only in these exact enclosing
contexts in the terminal carrier: `edge_receipt.v6.localTargetRoots` and
`rootPromotions`, or one of the six snapshots in `activation_record.v5` or
`checkpoint_record.v5`. It must address a lower slot in that same terminal
carrier. Promotion replaces that coordinate with the reopened terminal
`carrier_reference.v4`; it cannot refer to carrier 0, a sibling, a future slot,
or itself. Selected selectors, B+ values, sequence values, work records,
external evidence, and custody records permit carrier-addressable references
only. Resolving every activation/checkpoint snapshot must byte-equal the six
roots in the successor selector.

## 5. Closed v9 codec

### 5.1 Universal grammar and scalar-width registry

All objects are RFC 8785 JCS. Strings are NFC; lowercase hex has exact declared
length; base64url is unpadded; UUID is lowercase canonical. Every object rejects
unknown, duplicate, missing, or extra keys. Every listed key is present and is
JSON null only in a listed null matrix. Floats, negative numbers, exponential
spellings, negative zero, and integer overflow reject.

The only JSON number type is `u53` (`0...2^53-1`). These fields are `u53`:
every key ending `Ordinal`, `Generation`, `Revision`, `Count`, `Limit`,
`Consumed`, `Released`, `Spent`, `Abandoned`, `Offset`, `Level`, `Height`,
`Mode`, `UID`, `GID`, `Flags`, `Seconds`, `Nanoseconds`, plus `entryCount`,
`childCount`, `itemCount`, `rowCount`, `nameCount`, `runCount`, `pageCount`,
`sourceRowCount`, `targetCount`, and all SHA continuation words `h0...h7`.
The following counter keys override that rule and are `u64wide` objects:
every key ending `Bytes`, `ByteLength`, `CanonicalLength`,
`recordCanonicalLength`, `payloadLengthBytes`, `canonicalLength`,
`chargeBytes`, `reservedBytes`, `spentBytes`, `abandonedBytes`,
`materializedBytes`, `subtreeChargeBytes`, and `totalByteCount`.
`u64wide` has exactly `schema="wide_v1",hi,lo`, both u53 constrained to
`0...2^32-1`. Booleans are JSON booleans. No field can match both registries;
a duplicate normalized key with a different width is a registry build error.

Closed enums are:

```text
treeKind = storage|path|lifecycle|budget|sequence|work
referenceKind = local|carrier|root|empty
selectorState = migrating|ready|protected
transitionKind = reserve|reserve-open|progress|close-commit|close-abort|
                 terminal-commit|terminal-abort
edgeKind = record-publish|tree-mutate|bounded-external-publish|budget-reserve|
           budget-progress|budget-close|abort-slot|phase-commit|audit-step|
           artifact-adopt
budgetScope = row|fixed|bootstrap
budgetCategory = source-capture|merge|tree|verification|materialization|abort
receiptOutcome = committed|aborted|protected
physicalClass = carrier-record|bounded-external-regular|materialization-directory|
                adopted-artifact|protocol-evidence
objectKind = catalog-record|source-certificate|publication-receipt|
             materialization-directory|prepared-artifact|protocol-evidence
contentCodec = jcs|raw|null
pathClass = protocol-carrier|ordinary-object|materialization|artifact|evidence
evidenceKind = preparation-seal|preparation-receipt|fresh-verification-head|
               fresh-verification-receipt|custody-head|drain-receipt|gc-head
```

### 5.2 Reference, selector, and record schemas

References replace the v8 proposals and have these exact keys:

| schema/type | exact keys after discriminator | rule |
|---|---|---|
| local record, `kind="local"` | `slotOrdinal,recordOrdinal,recordCanonicalLength,recordSHA256` | terminal carrier and contexts in section 4 only |
| carrier record, `kind="carrier"` | `carrierOrdinal,payloadLengthBytes,carrierSHA256,immutableIdentitySHA256,slotOrdinal,recordOrdinal,recordCanonicalLength,recordSHA256` | selected/cross-carrier record |
| `carrier_reference.v4` | `carrierOrdinal,payloadLengthBytes,carrierSHA256,immutableIdentitySHA256` | complete durable carrier |
| empty root, `kind="empty"` | `treeKind,entryCount,height,rootTranscriptSHA256` | count/height zero |
| root, `kind="root"` | `treeKind,entryCount,height,topPageReference,rootTranscriptSHA256` | count positive; selected carrier reference |
| `root_promotion.v3` | keys in section 4 | only legal contexts in section 4 |
| `root_snapshot.v2` | keys and matrix in section 4 | exactly one branch |
| `external_object_reference.v7` | `canonicalRelativePathBase64URL,pathSHA256,objectKind,physicalClass,canonicalLength,objectSHA256,immutableIdentitySHA256` | bounded regular or A3 directory |
| `protocol_evidence_reference.v3` | `evidenceKind,transactionUUID,relativePathUTF8Base64URL,pathSHA256,canonicalLength,objectSHA256,immutableIdentitySHA256` | evidenceKind closed above |

`model_catalog_selector.v9` has exactly the R17 v8 selector keys, changes only
`schema`, and uses `bootstrap_state.v4`, references above, and
`pending_transaction.v4`. All selector count/byte fields use section 5.1.
Generation zero and revision one use section 2. After bootstrap, all six roots,
activation, checkpoint, carrier head, and last receipt are non-null forever.
`pendingTransaction` is null only between transactions or after a terminal
successor. `selectedCarrierDirectoryIntent` is non-null only at generation
zero. Protected selectors preserve all last-good references.

`pending_transaction.v4` has exactly:

```text
schema,transactionUUID,logicalOperationKind,logicalOperationOrdinal,phase,
edgeIntent,edgeIntentSHA256,openLease,leaseAuthorizationSHA256,
baseLeaseStateSHA256,successorLeaseStateSHA256,controlAuthorization,
continuationReference,workAccumulator,cancelRequested,completionDisposition,
abortCursor
```

Phase is `between-edges|reserving|executing|closing-commit|closing-abort|
aborting|forward-completing`. The edge, both lease-state fields, and control
authorization follow section 3; there is no phase-specific omission.
Continuation is non-null only while carrier 0 is durable and terminal carrier
is absent. It has exact keys `schema,carrierZeroReference,
terminalCarrierExpectedOrdinal,targetRecordCount,targetCoordinateOrderSHA256,
leaseAuthorizationSHA256,baseLeaseStateSHA256` and confers no selected work.

The carrier v4 physical framing remains 8,228-byte header plus 1...16
65,572-byte record slots. Header schema `model_catalog_carrier_header.v4` has
exactly `schema,activationUUID,carrierOrdinal,previousCarrierReference,
pendingSelectorSHA256,transactionUUID,edgeOrdinal,edgeKind,edgeIntentSHA256,
recordCount,recordTranscriptSHA256,payloadLengthBytes`. Header/record framing,
length bounds, SHA field, and zero padding are exactly R17 section 5.3.

Every carrier record has common keys `schema,activationUUID,transactionUUID,
edgeOrdinal,slotOrdinal,recordOrdinal`. The allowed suffix schemas are exactly
the R17 section 5.3 table with version changes
`edge_receipt.v6`, `activation_record.v5`, `checkpoint_record.v5`,
`source_witness.v4`, `format_fence_witness.v3`, and `bootstrap_close.v3`.
Those unchanged table rows retain their exact suffix, enum, and null rules;
the six replacement rows are:

| schema | exact suffix after common keys | closed rule |
|---|---|---|
| `edge_receipt.v6` | `edgeKind,transitionKind,edgeIntentSHA256,intentBaseSelectorSHA256,pendingSelectorSHA256,priorReceiptReference,targetRecordReferences,externalObjectReference,localTargetRoots,rootPromotions,leaseAuthorizationSHA256,baseLeaseStateSHA256,successorLeaseStateSHA256,controlAuthorization,targetBudgetEntrySHA256,selectedUnits,selectedChargeBytes,priorWorkAccumulator,outcome,receiptTranscriptSHA256` | one terminal receipt; target/root arrays 0...17 and 0...6; external nullable except bounded external; all lease/control fields follow section 3 |
| `activation_record.v5` | `activationGeneration,previousActivationReference,state,phase,sourceWitnessSHA256,storageRootSnapshot,pathRootSnapshot,lifecycleRootSnapshot,budgetRootSnapshot,sequenceRegistryRootSnapshot,workRootSnapshot,checkpointPredecessorReference,lastReceiptPredecessorReference,leaseAuthorizationSHA256,baseLeaseStateSHA256,successorLeaseStateSHA256,controlAuthorization,carrierAuditState` | predecessor refs null only genesis; six v2 snapshots |
| `checkpoint_record.v5` | `checkpointGeneration,previousCheckpointReference,activationReference,phase,logicalOperationKind,logicalOperationOrdinal,edgeOrdinal,workCursor,sourceWitnessSHA256,storageRootSnapshot,pathRootSnapshot,lifecycleRootSnapshot,budgetRootSnapshot,sequenceRegistryRootSnapshot,workRootSnapshot,lastReceiptReference,leaseAuthorizationSHA256,baseLeaseStateSHA256,successorLeaseStateSHA256,controlAuthorization,carrierAuditState` | predecessor null only genesis; activation/receipt lower-slot local in terminal carrier |
| `source_witness.v4` | `sourceRowCount,priorActiveIndexSHA256,migrationSourceSHA256,namespaceSHA256,rowsSHA256,capturedAtSelectorRevision` | no null |
| `format_fence_witness.v3` | `formatFenceSHA256,selectorRelativePathBase64URL,selectorPathSHA256,lockIdentitySHA256` | no null |
| `bootstrap_close.v3` | `sourceWitnessReference,budgetRootReference,expectedEntryCount,unitsConsumed,unitsReleased,carriersConsumed,carriersReleased,chargedBytes,releasedBytes,ledgerSHA256` | exact section 2 equality |

R17's exact B+ page, work, source, phase, binding, adoption, storage, path,
lifecycle, budget-debit, external descriptor, and artifact-serving drain suffixes
remain data-model inputs, not inherited codec inference. Their complete key
lists are reproduced in the checked-in declarative `V9CodecRegistry` generated
from the literal rows in R17 5.3 and frozen before any decoder is written. The
registry build fails unless each key receives exactly one section 5.1 scalar
type, one enum/string/reference/object type, and one null rule. The independent
test registry is transcribed from these two documents and cannot import the
production registry. Any row requiring a human default is a plan failure and
reopens this gate.

Sequence leaves are no longer informal. Their exact schemas and keys are:

| schema | exact keys after `schema,collection,ordinal,contentReference,transcriptSHA256` |
|---|---|
| `raw_name_sequence_entry.v1` | `firstDirectoryOffset,successorDirectoryOffset,recordCount,firstNameSHA256,lastNameSHA256` |
| `name_block_sequence_entry.v1` | `nameCount,firstName,lastName` |
| `row_block_sequence_entry.v1` | `role,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `run_sequence_entry.v1` | `mergePass,rowCount,firstUUID,lastUUID,runManifestReference,rowsSHA256` |
| `merge_group_sequence_entry.v1` | `mergePass,groupOrdinal,creationOrdinal,inputCount,outputRunReference,rowCount,firstUUID,lastUUID,rowsSHA256` |
| `tree_page_sequence_entry.v1` | `level,itemCount,firstUUID,lastUUID,pageReference,itemsSHA256` |
| `tree_level_sequence_entry.v1` | `level,pageCount,firstUUID,lastUUID,sequenceRootReference,levelSHA256` |
| `verification_sequence_entry.v1` | `pass,firstOrdinal,lastOrdinal,itemCount` |
| `entry_digest_sequence_entry.v1` | `entryOrdinal,relativePathBase64URL,entrySHA256,entryIdentitySHA256` |

`collection` must equal the schema prefix. First/last are both null exactly when
their count is zero. `successorDirectoryOffset` is null only for the terminal
raw-name entry. Every content/manifest/page/run/root reference is selected and
carrier-addressable. `completedEntryDigestSequenceRootReference` is a
root-or-empty over only `entry_digest_sequence_entry.v1` leaves.

### 5.3 Literal digest registry

`D(domain,bytes)=SHA256(ASCII(domain)||0x00||u64be(bytes.count)||bytes)`.
The only raw SHA exceptions are carrier/record framing SHA fields, exact
historical-file SHA fields, bounded external file SHA, per-file SHA-256, and
the current SPEC-001 artifact-tree digest. Every other `*SHA256` is:

| field family | literal domain and bytes |
|---|---|
| JCS object identity | `macprovider-<schema-with-underscores-replaced-by-hyphens>` and complete JCS with that identity field null |
| transcript field | `macprovider-v9-transcript/<schema>/<field>` and object JCS with only that field null |
| content/order field | `macprovider-v9-content/<schema>/<field>` and JCS of the named value |
| relative path | `macprovider-relative-path-v1` and canonical relative UTF-8 |
| lease authorization | `macprovider-budget-lease-authorization-v4` and complete authorization JCS |
| lease state | `macprovider-budget-lease-state-v6` and complete state JCS |
| projected budget entry | `macprovider-budget-entry-state-v5` and complete projected entry JCS |
| immutable identity | `macprovider-immutable-identity-v4` and complete identity JCS |
| selector fixed root | `macprovider-selector-v9` and selector JCS with only `fixedExtentRootSHA256=null` |

The declarative registry enumerates every digest field with exactly one of the
above families or named raw exception. A field matching zero or multiple rows
is a build failure. Domain construction is literal ASCII, not localized or
case-folded. This algorithm plus schema and field spelling yields one finite
preimage without implementation inference.

## 6. Acyclic full-integrity verification and custody

### 6.1 Verification chain and custody publication

Custody paths and global lock order remain R17 6.1. Custody state adds
`verification-complete`; its record has a verification transaction and null
fresh receipt/catalog/replacement/drain/terminal fields. Publication is
acyclic:

```text
C(n) verifying
H(k) complete verification head/checkpoint selecting final chunk/root data
C(n+1) verification-complete, binding H(k), fresh receipt null
F fresh receipt, binding C(n+1) and H(k)
C(n+2) verified, binding F
```

`fresh_artifact_verification_receipt.v2` replaces v1 and has exactly R17's
receipt keys except `custodyRecordSHA256` is renamed
`verificationCompleteCustodyRecordSHA256`. It binds C(n+1), never its verified
successor. `artifact_custody_record.v2` replaces v1 and adds
`completedVerificationHeadSHA256`; the exact state matrix is:

| state | verification tx | completed head | fresh receipt | catalog pair | replacement | drain | reason |
|---|---|---|---|---|---|---|---|
| verifying | required | null | null | null | null | null | null |
| verification-complete | required | required | null | null | null | null | null |
| verified | required | required | required | null | null | null | null |
| pending-adoption | required | required | required | required pending | null | null | null |
| active | required | required | required | required terminal | null | null | null |
| replacement-pending | required | required | required | incumbent active | required | null | null |
| released | required | required | required | last incumbent | conditional | required | `replaced|removed` |
| abandoned-unverified | required | nullable | null | null | null | null | `cancelled|verification-failed` |
| abandoned-verified | required | required | required | null | null | null | `cancelled` |

The custody record/head, verification record/head, receipt, and every directory
fsync occur in the listed order. Recovery may publish only the byte-identical
missing successor. No object hashes a successor or itself.

`artifact_custody_head.v2` is a 4,096-byte fixed frame with exact keys
`schema,generation,recordSHA256,recordRelativePathBase64URL,recordPathSHA256,
recordImmutableIdentitySHA256,fixedExtentRootSHA256`. Its fixed root is
`D("macprovider-artifact-custody-head-v2", head JCS with only
fixedExtentRootSHA256 null)`. It selects the exact immutable v2 custody record;
generation and record digest must agree.

`artifact_verification_head.v2` is fully defined as the 4,096-byte frame
`u32be(JCS length)||JCS||SHA256(JCS)||zero padding`, JCS length 2...3,512, with
exact keys `schema,generation,checkpointRecordSHA256,
checkpointRelativePathBase64URL,checkpointPathSHA256,
checkpointImmutableIdentitySHA256,fixedExtentRootSHA256`. Its root is
`D("macprovider-artifact-verification-head-v2", JCS with only
fixedExtentRootSHA256 null)`.

`artifact_verification_checkpoint.v2` has R17's v1 keys plus
`lastChunkRecordReference`; that reference is null only at generation zero and
otherwise selects the immutable chunk record named by the checkpoint.
`artifact_verification_chunk.v2` replaces `priorChunkRecordSHA256` with
`priorChunkRecordReference`; generation zero is null, every successor selects
the prior immutable chunk. Chunk and checkpoint records are stored under the
verification transaction directory using protocol-evidence references and are
selected by each head generation. The head never selects an unreferenced
partial file.

### 6.2 Batched preparation and mandatory final freshness proof

After full current SPEC-001 byte hashing, complete identity recapture, flag
installation, post-flag complete recapture, H(k), C(n+1), F, and C(n+2) are
durable. A separate 4,096-byte `adoption_recapture_head.v1` has exact keys
`schema,generation,checkpointSHA256,checkpointRelativePathBase64URL,
checkpointPathSHA256,checkpointImmutableIdentitySHA256,
fixedExtentRootSHA256`; its root is
`D("macprovider-adoption-recapture-head-v1", head JCS with only
fixedExtentRootSHA256 null)`. It selects an immutable
`adoption_recapture_checkpoint.v1` under the verification directory. Its
checkpoint has exactly `schema,generation,verificationTransactionUUID,
freshVerificationReceiptSHA256,expectedIdentityTranscriptSHA256,
nextEntryOrdinal,checkedEntryCount,rollingIdentityTranscriptSHA256,
priorCheckpointSHA256,state`, with state `scanning|ready|protected`.

Repeated pre-pending calls, holding the custody flock but not activation flock,
scan at most 4,096 manifest entries and 8 MiB of manifest/path bytes, use at
most four FDs, and publish one checkpoint successor. They compare every entry
to the identities and immutable flags bound by F. They are readiness evidence
and reduce expected failure discovery time. They do not authorize pending
selection and are never incorporated into F or H(k).

The final call takes custody then activation flock, revalidates C(n+2), F, H(k),
the ready recapture head, root identity and immutable flag, then performs a new
complete manifest-order `openat/fstatat` recapture of the root and **every**
entry. It compares each identity/flag to F and recomputes the complete identity
transcript. Only after this full recapture succeeds does the same call publish
`pending-adoption` custody and the pending catalog selector, fsync both parent
directories, and release both locks. It performs no payload hash or copy.
External same-user flag clearing or replacement before its corresponding final
check changes identity/flag and rejects. Mutation after an entry was checked
but before pending remains a platform threat; qualification therefore also
requires a physical negative test showing the supported filesystem's
root-and-descendant immutable flags prevent write, rename, unlink, link, and
replacement for the whole final-call interval. If this cannot be proven, or
the full recapture exceeds eight seconds/four FDs, adoption remains
feature-gated on that artifact/filesystem profile. Batching never converts that
blocker into acceptance.

Serving continues to direct-open active custody/F and revalidate the root and
requested entry identity/flag before MLX open. This defense does not replace
fresh adoption verification.

### 6.3 Bounded indexed GC

The custody store adds:

```text
.custody/gc/gc.lock
.custody/gc/head.json
.custody/gc/records/<generation>.json
.custody/gc/candidates/<artifactSHA256>.json
```

`gc_head.v1` is a 4,096-byte fixed frame with exact keys
`schema,generation,checkpointSHA256,checkpointRelativePathBase64URL,
checkpointPathSHA256,checkpointImmutableIdentitySHA256,
fixedExtentRootSHA256`; its fixed root uses
`D("macprovider-gc-head-v1", head JCS with only fixedExtentRootSHA256 null)`.
It selects one immutable `gc_checkpoint.v1` with exact keys
`schema,generation,nextCandidateSHA256,candidateIndexTranscriptSHA256,
priorCheckpointSHA256,state`; state is
`idle|scanning|deleting|protected`. Candidate files have exact schema
`gc_candidate.v1` and keys `schema,artifactSHA256,custodyHeadSHA256,
enqueuedGeneration,state,nextArtifactSHA256,deleteManifestOrdinal,
deletePhase,priorCandidateSHA256`; state is `queued|checking|deleting|done|
protected`, phase is `flags|entries|root|fsync|complete`. The list is sorted by
artifact digest and cycle-free. `gc.lock` and custody lock are never nested.
An enqueuer first publishes custody state, releases custody, then CAS-appends a
candidate under `gc.lock`; a missing candidate can delay collection but cannot
authorize deletion. A GC call takes `gc.lock`, selects exactly one candidate
and publishes it as `checking` in the head, then releases `gc.lock` before
taking custody. After custody work and its evidence are durable, it releases
custody and CAS-publishes the cursor/result under `gc.lock`. A failed CAS
reopens the current head and converges on the already selected result; it does
not repeat a deletion. GC never enumerates the artifact store to discover
authority.

One GC call acquires each lock nonblocking, processes at most one candidate, at most
256 manifest entries, at most 8 MiB of manifest/path bytes, and at most 1,024
syscalls, then publishes the exact cursor and releases all locks/descriptors.
It stops early at six seconds so the five-second provider heartbeat can run in
a separate task and the call remains below eight seconds. A busy lock returns
typed retry without mutation. After every successful quantum the next call
starts at the lexicographically next candidate, wrapping only after the tail;
a candidate cannot receive a second quantum until every other queued candidate
present at that checkpoint received one or became ineligible. Adoption and
serving never take `gc.lock`; GC releases custody between quanta. Blocked
filesystem calls cause deadline/protection, not continued lock ownership.

Retention/deletion predicates and reverse-depth crash recovery remain R17 6.1,
but they execute only through this selected cursor. The candidate index is
advisory for discovery; direct custody/catalog/drain revalidation under locks is
still required before each deletion quantum.

## 7. Corrected capacity

Each named R16 domain transition expands into exactly three mutations: reserve,
payload progress, and terminal close. Each mutation has a maximum of 20
permanent records. The payload ledger is therefore 20 units and its two
control mutations are 40 units. This is the sole capacity interpretation.
Bootstrap contributes 20 for each row/fixed budget-entry construction plus the
50-slot fixed ledger in section 2.

```text
row payload = 174 * 20 = 3,480
row control = 174 * 40 = 6,960
fixed payload = 320 * 20 = 6,400
fixed control = 320 * 40 = 12,800
bootstrap = 20*(R+1)+50

units(R) = 10,460R + 19,270
protocol Rmax = 430,554,457,681
units(Rmax)   = 4,503,599,627,362,530 < 2^52
units(Rmax+1) = 4,503,599,627,372,990 >= 2^52
units(1,024)  = 10,730,310

carrierCount(R) <= 1,046R + 1,928
carrierCount(Rmax) <= 450,359,962,736,254
carrierCount(1,024) <= 1,073,032
```

The independent generator emits every target record and the three terminal
records, groups them 16 per carrier, and derives unit and carrier counts from
that trace. It does not accept a numeric transition count without the literal
R16 name. Protocol Rmax is sparse codec arithmetic only. Product admission,
exact encoded bytes, quota, inode, free space, `off_t`, RSS, filesystem feature,
and measured deadlines may reject a much smaller graph.

## 8. Finite SHA continuation oracle

For each length `0,1,55,56,63,64,65,64MiB-1,64MiB,64MiB+1`, define boundary
set B as all in-range values from:

```text
0, length,
{55,56,63,64,65} +/- {0,1},
every 1MiB multiple +/- {0,1},
every 64MiB checkpoint multiple +/- {0,1},
offset(i)=u64be(first 8 bytes of
SHA256("macprovider-sha-split-v1\0"||u64be(length)||u32be(i))) modulo
(length+1), for i=0...255
```

Duplicates are removed and B is sorted. The independent oracle first records
the one-shot digest and continuation at every B offset in one streaming pass.
It then clones each stored continuation, reads the suffix from an immutable
memory-mapped payload, and completes it independently. This deliberately does
not claim O(n): the finite work ceiling is
`sum(length-b for b in B)` bytes of SHA compression, with a hard aggregate cap
of 96 GiB, at most 4,096 split completions, less than 64 MiB writable oracle
state beyond the read-only mappings, and 30 minutes on the recorded physical
Mac. Registry generation fails if the exact B sets exceed either finite cap.
It compares every resumed digest to one-shot SHA-256 and mutates every word,
total-count bit, tail length/content, and final-padding choice. Production may
use CommonCrypto while the oracle uses an independent test implementation;
they share only payload bytes and expected final digests.

## 9. Implementation and gate

After approval, slices are: declarative v9 codec and independent fixtures;
bootstrap ledger; lease/mutation graph; six-root promotion; verification and
acyclic custody; final recapture and qualification gate; indexed GC; preserved
A1/A2 abort and A3+ economics; then targeted/full Swift, Xcode, bridge,
physical, code, security and architecture gates.

Any material change to record count, reference legality, lease presence,
freshness proof, custody graph, GC authority, or physical qualification reopens
this plan gate. Physical signed-feed -> trusted preparation -> valid admission
-> actual MLX -> correct settlement remains unproven until freshly executed.

## 10. R17 finding disposition

| finding | correction | R24 evidence |
|---|---|---|
| H1 bootstrap outside limit | zero-unit selector transitions and exhaustive ledger | R24-02 |
| H2 ordinary progress unauthorized | mandatory control authorization/projected entry on every state change | R24-03 |
| H3 illegal changed-root refs | closed v2 three-branch snapshot and exact enclosing contexts | R24-04 |
| H4 incomplete codec | scalar/enums/reference/schema/sequence/digest registries and fully defined heads | R24-05 |
| H5 custody/receipt cycle | verification-complete predecessor then receipt then verified successor | R24-06 |
| H6 stale batched recapture | separate progress head plus mandatory one-call full recapture and blocker | R24-07 |
| H7 20/21 conflict | literal one/two-carrier trace and sole 20-unit rule | R24-08 |
| M1 unbounded GC | selected index/cursor, one-candidate quantum, nonblocking locks and fairness | R24-09 |
| M2 infeasible SHA oracle | finite seeded boundary set and O(n) oracle budgets | R24-10 |
