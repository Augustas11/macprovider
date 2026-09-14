# Build 1 reservation search progress R17/R23 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: exact R17 plan and R23 test specification, inspected independently
against the failed R16 review, current SPEC-001, the retained R16 transition
graph, current Swift reservation/artifact code, and `origin/main`. No source or
test implementation was authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 7 High, 2 Medium, 0 Low.**

R17 closes several R16 defects in direction: it gives generation zero a
selected directory intent, separates stable lease authorization from mutable
lease state, directly selects all six roots, puts activation/checkpoint records
on every logical mutation, preserves fresh full hashing before adoption, and
introduces durable artifact custody. The gate remains closed because multiple
required byte graphs are internally contradictory or cyclic. In particular,
bootstrap spends units outside its own limit, ordinary lease progress is both
required and forbidden to carry its budget authorization, changed-root
snapshots use references that the registry prohibits, and the verified custody
record and fresh receipt digest each other. The proposed batched pre-adoption
recapture also leaves earlier entries outside the final freshness check.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r17.md` | `f098f00ff754829ce136d986c187e39433a635ac6dee03ffb038867e8f1ddd01` |
| `test-spec-r23-reservation-r17-corrections.md` | `531287e4c753e4faf454507ed1d4c4e515a2e49e5fcbf5da1070c21647b83b6c` |
| Failed R16 review | `df68a2e1bf89df673bead77f54d7698768a614945276698777378a0220891a32` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`, matching the plan. The current
reservation implementation remains the R4 array/scan implementation. Searches
of `phase3-binary/Sources` and `phase3-binary/Tests` found no
`model_catalog_selector.v8`, `artifact_custody_record.v1`,
`artifact_verification_head.v1`, `leaseAuthorizationSHA256`,
`sequenceRegistryRootReference`, or `rootSnapshot.v1`. The six relevant current
source digests still match the R16 review except for the already-recorded
storage file digest:

| Current source | SHA-256 |
|---|---|
| `ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `ModelCatalogTransactionStorage.swift` | `33cf08501a9d0e8509e8433d1cde7537bf9f660b814da0bf26fa1287a104916e` |
| `ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |

The advertised R17 arithmetic was reproduced exactly, including the stated
`Rmax` boundary. Arithmetic agreement does not cure the incomplete accounting
and graph contradictions below.

## Critical (0)

None.

## High (7)

### R17-PLAN-H1 — bootstrap spends two protocol units outside the stated limit

**Severity:** High. **Confidence:** High.

**Evidence.** Generation zero and revision one select `unitsConsumed=1` and
`2` for the carrier-directory intent and adoption (`R17:72-81`). The complete
bootstrap unit limit is then defined as exactly `21*(R+1)+50`, with all 21
units for each of the R row budget entries plus the fixed entry and all 50
units for the six genesis records (`R17:92-95`). No units remain for the two
already-consumed directory transitions. R23 freezes the same limit and also
requires every allowance to remain in its category (`R23:30-39`). Treating the
directory selector revisions as zero-unit control would instead contradict the
selected consumed counters.

**Consequence.** A complete bootstrap must exceed `unitLimit`, underfund a
budget entry/genesis record, or falsify its consumed/released equality. The
generation-zero closure and the global capacity formula cannot both hold.

**Required correction.** Define one exhaustive bootstrap unit ledger that
names the intent, directory adoption, every budget entry, every genesis record,
and close. Either include the first two units in a recomputed limit and all
downstream formulas or make selector-only work consume zero with generation
zero/revision-one vectors that say so. Derive the close counters from the
literal ledger in R23.

### R17-PLAN-H2 — ordinary lease-state advancement has no legal authorization encoding

**Severity:** High. **Confidence:** High.

**Evidence.** Every counter/state change must create a new lease-state digest
and matching budget entry (`R17:143-150`), and section 3 explicitly says
`controlAuthorization.v3.targetBudgetEntrySHA256` binds the projected entry for
ordinary progress (`R17:159-182`). The closed pending schema permits
`controlAuthorization` only during reserve/close (`R17:337-345`), while the
closed edge-receipt schema permits `targetBudgetEntrySHA256` only during
reserve/close (`R17:438`). Thus an ordinary target edge is required to mutate
the lease/budget root but forbidden from carrying either authorization/binding
that section 3 requires.

**Consequence.** No byte-valid ordinary edge can prove its successor lease
state and selected budget entry. Permissive implementations can advance
counters without the projected-root check; strict implementations cannot make
progress. The stale-state and debit protections that were intended to close
R16 H2 are not implementable.

**Required correction.** Freeze a single per-phase presence matrix for control
authorization and projected-entry binding. If every lease-state mutation uses
control authorization, permit and count it on every such edge. If ordinary
edges use a distinct authorization, define its exact schema, digest, root
equality, and receipt fields. Regenerate 63/64/65 vectors and capacity from that
choice.

### R17-PLAN-H3 — changed-root activation/checkpoint snapshots use references the registry forbids

**Severity:** High. **Confidence:** High.

**Evidence.** Every changed root in an activation/checkpoint record must use a
paired local root and `rootPromotion` inside `rootSnapshot.v1`
(`R17:215-235`). The supposedly closed reference registry says a local
`rootReference.v3.topPageReference` is legal only in a same-carrier receipt and
that `rootPromotion.v2` is legal only in a receipt (`R17:295-305`). Activation
and checkpoint records are distinct record schemas, not receipts. R23 then
requires independent encoders to place those forbidden values in every
changed-root snapshot (`R23:116-123`). The registry also has no promotion form
for a mutation whose resulting tree is `emptyRootReference.v1`, despite testing
all changed-root subsets from empty.

**Consequence.** Any mutation that changes a root has no object satisfying both
the snapshot rule and reference registry. Implementations would need to weaken
the local-reference prohibition or invent an unreviewed promotion union,
reopening the acyclic-root defect.

**Required correction.** Define the exact enclosing-record contexts in which a
local root and promotion are legal, including slot-order checks and promotion
against the enclosing complete carrier. Add an explicit acyclic representation
for changed-to-empty roots. Freeze positive and negative activation/checkpoint
bytes rather than describing the impossible current cross-product.

### R17-PLAN-H4 — the v8 codec is still not standalone or closed

**Severity:** High. **Confidence:** High.

**Evidence.** R17 claims sections 5-6 are a complete codec that needs no older
model prose (`R17:280-291`), but required bytes remain undefined:

* the sequence leaf paragraph lists informal variants (`raw-name`, `run`,
  `verification`, and others) without exact schema discriminators, collection
  enums, scalar types, or a leaf for
  `completedEntryDigestSequenceRootReference` (`R17:474-487,672-686`);
* most selector, record, counter, ordinal, length, mode, and offset fields are
  not mapped to `u53`, `u64wide`, or another width even though the rejection
  boundary depends on that mapping (`R17:282-291,318-349,418-444`);
* `protocolEvidenceReference.v2.evidenceKind` has no closed enum
  (`R17:303-305`);
* `artifact_verification_head.v1` is named as a selected 4,096-byte fixed extent
  but has no exact keys, framing, root-digest rule, null matrix, or publication
  order (`R17:672-679`);
* chunk records are chained by `priorChunkRecordSHA256`, but the selected
  checkpoint contains neither a last-chunk reference nor another root selecting
  that chain (`R17:655-679`);
* the digest table uses the generic phrase “their named versioned evidence
  domain” for several different structures and does not enumerate the exact
  domain bytes that R23 requires to match exactly one rule (`R17:535-557`).

The independent encoder required by R23 sections 04 and 06 would have to invent
these types and preimages.

**Consequence.** Independent implementations can accept different graphs and
produce different digests while each claims v8 conformance. Required negative
tests cannot determine the sole legal encoding, so R16 H3 remains open.

**Required correction.** Publish a machine-transcribable closed registry for
every selector, reference, embedded value, sequence leaf, verification record,
head, receipt, and custody object. Include exact discriminator strings, scalar
widths, enum values, null/union matrices, selected-chain roots, fixed-extent
framing, and literal digest domains/preimages. Make R23 generate every vector
from that registry without inference.

### R17-PLAN-H5 — the verified custody record and fresh receipt form an unsatisfiable digest cycle

**Severity:** High. **Confidence:** High.

**Evidence.** `artifact_custody_record.v1` requires
`freshVerificationReceiptSHA256` in state `verified` (`R17:578-597`). The fresh
receipt in turn requires `custodyRecordSHA256` and is selected only after the
custody transition to `verified` (`R17:696-704`). Both are closed immutable JCS
objects whose digest includes the other object's digest. No predecessor form,
null-at-publication form, or fixed-point construction is defined.

**Consequence.** Neither the verified custody record nor the fresh receipt can
be encoded and hashed first. Fresh verification can never reach the state that
the adoption path requires, so the core R16 H5/H6 closure is non-executable.

**Required correction.** Make the graph acyclic. For example, let the fresh
receipt bind a selected pre-receipt custody record/checkpoint, then publish a
successor verified custody record that binds the receipt, or introduce an
explicit intermediate state with exact predecessor/successor digests. Freeze
the publication/fsync/crash order and independent bytes for every boundary.

### R17-PLAN-H6 — batched pre-pending recapture neither preserves the completed receipt nor closes the freshness gap

**Severity:** High. **Confidence:** High.

**Evidence.** The fresh receipt permanently binds
`completedCheckpointSHA256` (`R17:696-704`). The later short adoption path says
repeated pre-pending calls record batched recapture progress in “the selected
verification checkpoint” (`R17:706-710`). Mutating that checkpoint invalidates
the receipt's completed-checkpoint binding; leaving it unchanged provides no
selected place for the recapture cursor or expected per-entry identities. The
final call checks only the root and “every entry since the last batch,” then
reuses the accumulated full transcript (`R17:711-716`). Earlier entries can
have their user-immutable flag cleared and be replaced after their batch but
before the pending CAS; custody flock does not exclude an external same-user
filesystem writer. Current SPEC-001 expressly warns that root metadata does not
prove unchanged descendants and requires fresh adoption verification
(`SPEC-001:4324`). R23 requires corruption before the pending CAS to reject
(`R23:165-172`) but does not supply an authority mechanism that makes that
claim true.

**Consequence.** The plan either breaks its receipt chain or selects adoption
from stale batched observations. A modified earlier manifest entry can escape
the final check, recreating the exact validation-to-selection race identified
in R16 H5/H6.

**Required correction.** Define a separate acyclic adoption-recapture
checkpoint/head and receipt, or an equivalent selected structure, with exact
expected identities and predecessor digests. Before pending selection, prove
all entries remain at the freshly verified identities after the last possible
external mutation, using retained kernel custody or one final complete
recapture under a qualification-proven bound. Batching alone is not that
proof; if full atomic recapture cannot meet eight seconds, retain the stated
qualification blocker.

### R17-PLAN-H7 — the central capacity proof has conflicting 20-unit and 21-unit graphs

**Severity:** High. **Confidence:** High.

**Evidence.** R17 first defines each mutation as 17 target records/pages, two
edge receipts, one activation, and one checkpoint: 21 permanent records, with
21 ordinary and 42 control units (`R17:244-259`). It later requires the state
generator to expand records/pages to a “20-unit cap” (`R17:272-278`). The
two-receipt rule is itself not expanded into a closed first-carrier continuation
and last-carrier terminal receipt graph; P2 names `edge_receipt.v5` in the
singular (`R17:200-212`), while the capacity paragraph counts one per carrier.
R23 demands that the independent generator derive 21 units and two receipts
(`R23:133-147`).

**Consequence.** The generator and implementation can disagree by one permanent
unit per logical mutation and on whether a two-carrier edge has one or two
receipts. That changes every row/fixed limit and invalidates the claimed first-
over-limit proofs even though the printed multiplication is arithmetically
correct.

**Required correction.** Expand literal one-carrier and two-carrier mutation
traces, including each receipt's outcome, continuation, accumulator, lease
state, target-root coverage, slot order, and which receipt becomes selected.
Choose one exact record/unit count, then recompute all bootstrap, row, fixed,
carrier, byte, and protocol-maximum formulas from the generated traces.

## Medium (2)

### R17-PLAN-M1 — global-custody GC has no bounded progress or fairness contract

**Severity:** Medium. **Confidence:** High.

**Evidence.** GC takes the single store-wide custody flock and direct-opens
each candidate head before removal (`R17:569-575,605-613`). Release validation
also requires proving absence from every current/pending catalog reference and
then walking the sealed manifest (`R17:643-651`). The plan defines no maximum
candidates, selected GC cursor, per-call work budget, lock retry semantics, or
five-second heartbeat while this global lock is held. R23 races GC broadly but
does not assert a bounded GC quantum or adoption fairness (`R23:193-219`).

**Consequence.** A large or adversarial artifact set can monopolize the global
custody lock, causing adoption and serving/replacement control paths to miss
their eight-second bound even if each individual head is valid.

**Required correction.** Define selected, resumable GC progress with strict
per-call candidate/manifest/byte/syscall budgets, nonblocking lock acquisition,
deadline and heartbeat behavior, and fairness. Test maximum product shape and
blocked filesystem calls while proving adoption and active-serving checks can
still progress.

### R17-PLAN-M2 — the SHA split test is not stated as a finite reproducible workload

**Severity:** Medium. **Confidence:** Medium.

**Evidence.** R23 requires 64 MiB-1, 64 MiB, and 64 MiB+1 payloads to be split
at “every legal boundary” and independently completed to the one-shot digest
(`R23:174-180`). Neither R17 nor R23 defines legal boundary as SHA block,
checkpoint chunk, read buffer, or every byte offset, nor defines a finite
sampling/streaming oracle. The last interpretation entails tens of millions of
large suffix completions and is not a practical acceptance run.

**Consequence.** The test can be silently weakened to a few friendly splits or
become infeasible, so a green run would not have a stable meaning.

**Required correction.** Freeze a finite boundary set that covers SHA padding
edges, 64-byte compression boundaries, read-buffer boundaries, checkpoint
boundaries, and deterministic randomized offsets. Define an O(n) independent
state oracle or an explicit maximum runtime/data budget, and retain targeted
mutation of every continuation component.

## Low (0)

None.

## Required disposition

The implementation gate remains closed. Revise both the plan and test
specification to resolve every High and Medium finding, then submit the exact
new file digests to a fresh independent GPT-5.6 Sol review. Do not implement
the v8 reservation/custody design from R17/R23.
