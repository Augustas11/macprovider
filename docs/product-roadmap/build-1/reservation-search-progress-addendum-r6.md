# Reservation search progress — corrective addendum R6

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R5 plan gate while retaining the R4 contract
and every R5 correction not replaced below. Its frozen inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r5.md` | `051eb952608bf05810211d4c4a9f68133b185ff8fe3a41d34756944621859e78` |
| `test-spec-r11-reservation-r5-corrections.md` | `96a51cb48d27fcd2f960158a9b1adde93bb72782802b477dc4cf30559c7a5ae0` |
| `reviews/reservation-search-progress-r5-plan-sol.md` | `7b1e71fd996e12383b7de82f0b5ef3dcdaf4e7b5d629674ff5975c844595d80c` |

The independent R5 gate verdict was FAIL, 0 Critical / 3 High / 1 Medium.
This addendum closes only R5-PLAN-H1, H2, H3, and M1. It is paired with
`test-spec-r12-reservation-r6-corrections.md`; both exact documents require a
fresh independent zero-Critical/High/Medium plan gate before implementation.

## 1. Retained contract and explicit replacements

R4 and R5 remain governing except for these replacements:

1. R5 section 6 full predecessor index/progress snapshots are replaced by the
   bounded state projection, compact per-entry predecessor, and settled lineage
   protocol in sections 2–4 below. No publication retains a full historical
   active index or progress body.
2. R5's unbounded "retained forever" storage consequence is replaced by the
   hard quota, prepaid closure reserve, and storage-failure contract in section
   5. Authority is never deleted to recover capacity.
3. R5 retirement is strengthened by the v2 archive root in section 6.
4. R5's restart-time same-byte-new-inode rejection is narrowed exactly as
   section 7 states. Different bytes, unsafe metadata, rollback, replay, and
   replacement after capture remain protected.

The active limit remains 1,024; active index, migration source, progress, and
state projection remain at most 1,048,576 bytes; primary remains at most
4,194,304 bytes and 2,048 events; class remains 32,768 bytes; left remains
16,384 bytes; publication receipt remains 131,072 bytes. The original one-call
eight-second budget, owner concurrency, no global pending gate, exact origin,
primary-first departure, frozen finalizing membership, closed decoding, direct
paths, and prior-binary fence remain mandatory. No input field or per-object
capacity is reduced and no dependency is added.

## 2. Bounded current reservation root

Add `model_catalog_reservation_state_projection.v1`, stored in exactly two
fixed direct slots:

```text
.reservation-migration/state/slot-0.json
.reservation-migration/state/slot-1.json
```

The active index names `reservationStateSlot` (`0` or `1`) and
`reservationStateSHA256`. The projection is a closed canonical document with:

- schema, migration/source/install identity, active-index generation, phase,
  progress SHA-256 and progress generation;
- one sorted row for every active entry, containing exact UUID, phase, origin,
  provenance, allocated generation, initial-primary, binding, class, left,
  settled-lineage digest, and pending-publication digest;
- for a pending row only, compact copied commitment fields: publication kind,
  predecessor-evidence digest, prior lineage digest, prior class/left, next
  class/left, source digest, and old target generation; and
- `rowsRootSHA256`, the domain-separated binary Merkle root of the canonical
  row encodings. Empty leaves and tree padding have fixed domain tags. The row
  count is included in the root domain.

The projection contains no file bodies and no caller locator. Its maximum is
the unchanged 1 MiB index envelope. A maximum-field 1,024-row projection and
active index must fit before R6 may be implemented; otherwise the plan fails
rather than narrowing R4 inputs.

Every writer decodes the active index, the selected projection, and, while
classifying, the one current progress document. It recomputes the projection
root and requires exact index/projection/progress equality. For a non-target
row, its complete canonical row is copied byte-for-byte into the successor.
Only the target row and explicitly permitted shared generation/root fields may
change. Final locked CAS revalidates the captured index and selected projection
identities/digests, then publishes the inactive projection slot before the
active index that selects it. A later call may overwrite the now inactive slot
only after recapturing an index that selects the other slot. Thus a crash leaves
either the old selected pair or the new selected pair; a slot is never trusted
without the digest selected by the active index.

The selected projection is the current all-member authority boundary. Ordinary
mutation does not recursively replay historical transitions and does not open
unrelated pending receipts, predecessor objects, or lineage objects. Exact
cross-member preservation is instead enforced at every index CAS by the
captured current projection and byte-for-byte non-target rows. Missing detached
historical bodies never permits their digest or row to be removed, replaced,
reclassified, retired, or used as absence; any operation that dereferences that
member fails protected. This retains rollback protection without making UUID B
prove UUID A's complete history.

## 3. Compact per-entry predecessor evidence

Replace the R5 full predecessor files with
`model_catalog_reservation_predecessor.v2`, at most 8,192 bytes, stored only at:

```text
.reservation-migration/predecessors/entry/<uuid>/<sha256>.json
```

The closed schema contains the target UUID; migration/source/install identity;
publication kind (`first_class` or `first_left`); captured index generation;
captured state-projection SHA-256 and rows root; captured progress SHA-256,
generation, and target acknowledgment; exact prior target row; prior settled
lineage digest; exact origin/class/left refs; and the permitted next class/left
refs. It contains no complete index, progress map, other member row, or primary
body. The receipt v2 binds this predecessor digest, all existing R5 frozen
target fields, and the exact class/left bytes.

Before the pending-index write, publish and fsync the predecessor and receipt
by validated content-addressed paths. The pending successor may change only the
target row, its pending commitment, generation, inactive state slot, and selected
state digest. The captured active-index and projection CAS proves every other
row was preserved at that transition.

Recovery opens only the selected index/projection/current progress plus the
target receipt, target predecessor, target origin/class/left, and target settled
lineage. It proves the receipt and copied pending commitment agree exactly; the
predecessor target row permits the requested transition; current target state
is either that exact pending successor or the defined later suffix; current
progress preserves the target's prior acknowledgment and may add only the
receipt's next acknowledgment; and every non-target row is preserved from the
current captured projection during this recovery CAS. It never opens or
finishes another UUID's pending objects.

This deliberately treats the durable current projection, rather than a chain of
full historical indexes, as current cross-member authority. A cross-UUID
receipt, changed target predecessor, removed current acknowledgment, changed
pending commitment, replayed old target generation, or unexplained target delta
is protected before mutation.

## 4. Settled per-entry lineage

Add `model_catalog_reservation_lineage.v1`, at most 16,384 bytes, stored at:

```text
.reservation-migration/lineage/<uuid>/<sha256>.json
```

It contains UUID, migration/source/install identity, origin digest, exact class
and optional left digest, previous lineage digest, and one or two settled
transition records. Each record binds publication kind, receipt digest,
predecessor-evidence digest, old target generation, and exact prior/next refs.
An allocation created after complete has an `allocated_class` genesis record
binding its allocation index generation, origin, class, and initial primary;
it does not fabricate a migration publication receipt.

After class or first-left bytes and any required progress acknowledgment are
durable, publish the next lineage object before the final entry CAS. The final
row installs its digest and clears pending. A later first-left object names the
class lineage as its predecessor. Lineage is immutable, direct, and
content-addressed; chains are capped at two publication records for a source
member and at genesis plus one first-left record for a post-complete allocation.
No active member has an unbounded lineage chain.

The selected projection commits each member's settled-lineage digest. Target
use and retirement validate the complete bounded target chain and exact
origin/class/left bodies. Finalization validates all source lineages
sequentially and incrementally within the existing eight-second calls; it may
advance durable validation progress but may not publish finalizing until all
1,024 rows have been validated against one unchanged source and projection.

## 5. Storage quota, preflight, and failure recovery

R6 establishes a hard logical authority quota of 1,073,741,824 bytes (1 GiB)
for `.reservation-migration` immutable predecessor, receipt, lineage, install,
projection-history, and retirement-v2 authority attributable to this protocol.
Existing safe objects are charged at activation by canonical file length rounded
up to 4,096 bytes plus 4,096 bytes per object. Unknown, unsafe, or unverifiable
objects block activation; they are never ignored to create apparent capacity.

The two mutable state slots are charged once at 2,105,344 bytes total. Each new
authority bundle is charged before its first durable byte at these fixed
worst-case amounts; charges are monotonic and never refunded:

| Bundle | Charge |
|---|---:|
| first-class or first-left predecessor + receipt + lineage | 196,608 bytes |
| post-complete allocation class genesis lineage | 65,536 bytes |
| v2 retirement archive | 65,536 bytes |
| final projection/install bundle | 4,259,840 bytes |

The active index and selected state projection carry identical
`reservationAuthorityChargedBytes` and `reservationAuthorityQuotaBytes` values.
Before writing any immutable bundle object, publish a charge-only state/index
CAS whose target row records the bundle kind and deterministic target digests.
A crash before that CAS leaves no new object or charge. A crash after it retains
the charge and reservation; retry resumes that exact bundle without charging
again or choosing new bytes. The later pending/allocation/retirement CAS consumes
the recorded reservation. No code subtracts a charge, including retirement or
operator maintenance.

At cutover, preflight must prove quota room for all existing objects plus the
worst-case remaining first-class, first-left, and retirement closure of every
active source member. Each later allocation requires room for its genesis,
first-left, and retirement bundles before its allocating intent. A publication
or retirement may consume its prepaid closure amount even when new admissions
are blocked. This bounds retained growth while ensuring quota exhaustion cannot
strand authority already admitted.

Before every durable bundle, query the containing volume and require:

```text
availableCapacity >= 536,870,912
                     + bytesAboutToWrite
                     + unmaterializedPrechargedClosureBytes
```

The 512 MiB floor is not spendable by new admissions. Failure returns a typed
storage-capacity/unavailable result before mutation. Heartbeat and other writes
that add no reservation authority may continue after root validation.

Every create, temporary replacement, fsync, rename, and directory fsync has an
injected `ENOSPC`/`EDQUOT` boundary. Before the pending/index authority CAS,
failure leaves the selected pair byte-identical; an equal unreferenced prepared
object may be reused by direct digest on retry. After a pending or charged CAS,
failure preserves it and exact recovery resumes the ordered suffix when space
returns. Referenced predecessor, receipt, lineage, class, left, projection,
install, retirement, source, and progress authority is never deleted,
compacted, or rewritten to regain space. Only a failed atomic-write temporary
that was never fsynced, named by an authority digest, or selected by an index
may be removed. If external disk consumption defeats prepaid headroom, affected
closure returns typed storage unavailable with all authority retained; freeing
unrelated external space and retrying must converge.

## 6. Retirement v2 closes dynamic departure lineage

Every retirement after R6 activation writes
`model_catalog_transaction_retirement.v2`. It retains all v1 outcome fields and
adds a closed `reservation` object containing migration/source/install identity,
origin digest, exact class digest, optional anchored-left digest, settled-lineage
digest, and the exact class/left publication or allocation-genesis records from
that lineage. A generated allocated entry that ever departed must have an
anchored left and settled first-left record. The left continues to bind the
first observed nonreusable primary; the v1 outcome separately binds the terminal
primary. Equality between those two primaries is neither assumed nor required.

`retireOne` holds the target owner, completes its exact pending publication,
recaptures the current selected index/projection, validates the target
origin/class/left/lineage and terminal proof, precharges the retirement bundle,
then exclusive-creates and fsyncs v2 before removing membership. The retirement
CAS removes the active row only if the v2 bytes and all captured evidence remain
stable. Crash before v2 preserves membership; crash after v2 but before index
removal recovers by exact v2 bytes; crash after removal validates through v2.
No path removes a row carrying pending publication or unsettled lineage.

At R6 activation, direct safe v1 certificates already present are grandfathered
in a closed `model_catalog_retirement_v1_manifest.v1`, bounded by 1 MiB and
content-addressed from the completed install root. Each row binds UUID,
certificate digest, and origin digest. V1 validates only the historical outcome
it actually represents; it is never claimed to prove class/left lineage and is
never used for a new retirement. Missing or changed manifested v1 bytes are
protected. All active and future entries require v2 on retirement.

## 7. File identity boundary

R6 does not claim an unrepresentable restart guarantee. A safe regular file
with identical canonical bytes at the same direct path, replaced before a fresh
process performs its first capture, is byte-equivalent authority. No persisted
inode number, device number, birth time, or filesystem generation is added.

From the first capture through the final CAS, the existing descriptor and
metadata identity rules remain mandatory: direct `O_NOFOLLOW` open, regular
file, exact owner/mode/link count and directory placement, stable device/inode,
size and metadata, and SHA-256/canonical bytes. Same-byte inode replacement,
in-place mutation, or metadata change after capture fails. Different-byte
replacement before or after capture fails by digest/schema/lineage. A
byte-equivalent pre-capture replacement cannot alter origin, class, left,
pending, lineage, progress, install, retirement, generation, or rollback truth,
so this narrowing does not authorize rollback or replay.

## 8. Per-call work bounds

At 1,024 simultaneous pending members, an ordinary non-target mutation may:

- open/decode one active index (1 MiB), one selected state projection (1 MiB),
  and at most one progress document (1 MiB);
- compute at most 1,024 row encodings and one 1,024-leaf Merkle root in memory;
- open zero unrelated receipts, predecessor objects, lineage objects, class
  files, left files, origins, owners, or primaries; and
- for its target, open at most one predecessor (8 KiB), one receipt (128 KiB),
  two lineage objects (32 KiB total), one origin (16 KiB), one class (32 KiB),
  one left (16 KiB), and the already-required target primary.

Thus reservation-specific work is at most 3,383,296 body bytes, ten direct
opens, ten closed decodes including the active-index/progress/projection
decodes, and a constant live-descriptor bound of four for ordinary mutation.
The final CAS rereads no bodies: it revalidates the captured selected files and
target descriptors/metadata, encodes at most one projection and one index, and
performs the bounded writes for the target suffix. UUID B never acquires A's
owner or opens A's detached objects. Cutover/finalization bulk qualification
remains incremental and uses R5's sequential descriptor discipline.

The implementation must measure these exact counters at maximum state and
finish each healthy ordinary heartbeat, cancel, commit, reserve, allocation
recovery, and retirement call within its unchanged eight-second budget. A
budget check occurs before and after every body read, decode, root computation,
filesystem-capacity query, create/fsync/rename, owner probe, and final CAS. No
helper renews the budget.

## 9. Implementation order and acceptance

Implementation, if separately approved, proceeds in this order:

1. Add closed state-projection, predecessor-v2, lineage-v1, retirement-v2,
   v1-manifest, and storage-accounting codecs plus maximum encodings.
2. Add dual-slot publication and exact root/CAS validation; prove crash states.
3. Replace R5 full predecessor snapshots with target-only publication recovery.
4. Add quota precharge, free-space preflight, and every storage fault boundary.
5. Add settled lineage to allocation/publication and v2 retirement/archive
   validation, including v1 grandfathering.
6. Apply the section 7 identity wording to implementation assertions and tests.
7. Run the paired R12 matrix and all retained R11/R4 gates on one frozen diff.

Acceptance requires: exact maximum encodings under unchanged caps; 1,024 pending
members with the section 8 measured bounds and healthy eight-second operations;
quota and free-space behavior at every boundary; long-run growth never above
1 GiB; no deletion of authority; crash/retry convergence; post-completion first
left retained through v2 retirement and restart; honest pre-capture byte-equivalent
identity behavior; all retained R4/R5 audit corrections; and fresh independent
code, security, and architecture reviews reporting zero Critical, High, and
Medium findings. Any missing maximum fixture, exceeded bound, global pending
gate, stranded lineage, unreserved authority write, authority deletion,
deadline increase, input narrowing, stale result, or approval inferred from
this proposal is a stop.
