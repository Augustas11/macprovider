# Reservation search progress — corrective addendum R7

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no source or test change.

This proposal corrects the failed R6 plan gate. Its frozen inputs are:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r6.md` | `b26a480d801c3c9ebe8c2b282a05702315470ad7ef5d8af1482e6a094856869e` |
| `test-spec-r12-reservation-r6-corrections.md` | `61f2dc00b3b5d362783228c77cf1fe58c6928f33e67952b12d2e2cb0d4e1f2b2` |
| `reviews/reservation-search-progress-r6-plan-sol.md` | `e985c269b23f373221ec9ba18d509dff17d9ee46f37cc711c470ebfe82d07ce6` |

The independent R6 verdict was FAIL, 0 Critical / 4 High / 0 Medium. This
addendum closes R6-PLAN-H1 through H4. It is paired with
`test-spec-r13-reservation-r7-corrections.md`. Both exact documents require a
fresh independent zero-Critical/High/Medium plan gate before implementation.

## 1. Governing relationship and retained invariants

R4, R5, and R6 remain governing except for the following explicit replacements.

1. This document replaces R5 section 4, R5 acceptance clauses 6 and 7, R6
   sections 2, 5, and the v1 paragraph of section 6, and the corresponding R11
   and R12 cases. The replacement authority model is sections 2–4 below.
2. R6's unrepresentable target-row charge-only state is replaced by the closed
   capacity state in section 5. R6's charge table and absolute 1 GiB ceiling are
   replaced by section 6.
3. R6's single 1 MiB v1-retirement manifest is replaced by the paged tree and
   activation protocol in section 7.
4. A statement that every ordinary writer validates every detached body is
   superseded. A statement that a committed row may be ignored because its body
   is missing is also superseded. The exact distinction is in section 3.

Every other R4/R5/R6 correction remains mandatory: the global allocating-intent
gate and three-way allocation-generation equality; exact origin comparison;
primary-first departure; same-owner pending-publication stabilization; permanent
left/rollback rejection; queued-cancel busy; frozen finalizing membership;
content-addressed install lineage; closed decoding and direct paths; sequential
prior-binary owner fence; byte-equivalent pre-capture identity and strict
post-capture identity; no global publication-pending gate; no wrapper bypass;
and real-death recovery.

Limits remain unchanged: 1,024 active rows; 1,048,576-byte active index,
migration source, progress, state projection, completed projection, and tree
page; 4,194,304-byte/2,048-event primary; 16,384-byte origin; 32,768-byte class;
16,384-byte left; 131,072-byte publication receipt; 8,192-byte predecessor; and
16,384-byte lineage/install. R7 sets the new retirement-v2 maximum to 65,536
bytes and the new retirement-root envelope maximum to 16,384 bytes. No existing
input or object limit is reduced and no dependency is added.

The original single-call eight-second deadline applies to cutover slices and
every ordinary call. No nested helper renews it. Ordinary reservation work keeps
R6's constant live-descriptor maximum of four and its ten-direct-open maximum.
The additional capacity fields are inside the already selected projection and
do not add an open. Bulk phase-transition and retirement-tree work is paged over
multiple calls; each call remains below eight seconds and the soft FD limit is
never raised.

## 2. One authenticated current root

Use closed `model_catalog_active_index.v5` and
`model_catalog_reservation_state_projection.v2`. The active index selects one
of R6's two direct state slots and binds its SHA-256. The projection contains
the R6 header and sorted rows, the capacity state from section 5, the selected
v1 and v2 retirement-root digests/counts, and these domain-separated roots:

- `rowsRootSHA256` over the exact canonical active rows;
- `capacityRootSHA256` over the exact canonical capacity state;
- `retirementRootsSHA256` over both retirement-root envelopes; and
- `aggregateRootSHA256 = H("reservation-state-v2" || header || rowsRoot ||
  capacityRoot || retirementRoots)`.

The active index repeats the projection generation, aggregate root, quota,
charged bytes, and retirement roots. Canonical leaf encodings include their
type tag, length, and ordinal or UUID; the tree includes row count and fixed
empty/padding tags. Duplicate, unknown, reordered, omitted, or extra fields are
invalid. A maximum-field projection with 1,024 rows, all row capacity fields,
and the two optional shared admissions must fit 1,048,576 bytes. Failure of that
measurement blocks implementation rather than narrowing any inherited field.

### 2.1 Closed genesis

The only transition from the pre-R7 graph is `genesis-v2`. After the actual
supported-prior-binary fence is durable, it fully validates the R5 historical
source/progress/install graph, every current member and named origin/class/left
body, every pending target receipt/predecessor allowed to survive cutover, all
binding lineage, and the complete v1 retirement tree in section 7. It also
rejects any contradictory direct class/left/retired file for which the graph has
no legal intent. It derives every projection row and capacity tranche from those
validated bytes, then publishes the inactive state slot and the active index by
the dual-slot protocol. No inferred absence, progress cursor, directory
existence, or detached digest can create a row.

The genesis receipt is the content-addressed completed projection/install pair
already required by R5/R6, extended with the exact v1-root digest, activation
inventory charge, capacity state digest, and aggregate root. The transition is
accepted only if independently re-deriving the full graph yields byte-identical
genesis bytes. That establishes the base case for all later transitions.

### 2.2 Inductive CAS rule

Every successor is derived from one captured digest-valid index/projection pair.
It increments generation exactly once, applies exactly one transition from the
table below, recomputes all roots, and copies every non-target row byte-for-byte.
The final locked CAS revalidates the captured index, selected slot identity and
digest, aggregate root, target evidence, and any shared admission it changes.
It writes/fsyncs/renames/fsyncs the inactive slot before selecting it with the
active index. A selected slot is never overwritten.

| Transition | Permitted delta |
|---|---|
| target publication reserve/materialize/settle | One target pending commitment, its capacity tranche state/materialized count, class/left/lineage refs, and classifying progress digest |
| allocation admission | The sole top-level absent-target allocation admission; no row |
| allocation intent/materialize/settle | Add its one allocating row, move the same admission through states, then make that row active and bind its lifecycle reservation |
| target control/binding/primary update | Existing permitted target fields only; reservation row identity and all capacity/retirement roots preserved |
| retirement materialize/consume/remove | One target retirement tranche, v2 root, then removal of that row and its completed lifecycle admission |
| migration phase transition | Full-validated classifying to finalizing or finalizing to complete fields and install lineage only |
| shared finalization admission | The sole finalization admission and its exact completed-projection/install digests/state |

Any other delta, a changed non-target row, two target deltas, unexplained root,
removed charge, changed retirement root, generation skip, or a successor not
derivable from the captured pair is protected before mutation. This inductive
rule is the sole evolution authority; detached objects cannot update a root.

## 3. Full validation versus bounded operational validation

There are two noninterchangeable validators.

`validateReservationTransitionGraph` performs full body validation at
genesis-v2, before classifying-to-finalizing, before finalizing-to-complete, and
when a retirement root is first activated. It walks all applicable pages and
all named bodies sequentially, may checkpoint authenticated validation progress,
and cannot publish the phase/root transition until the complete walk is tied to
one unchanged captured aggregate root.

`validateReservationOperation` is used by heartbeat, status, cancel, commit,
run, reserve/search, allocation recovery, cleanup, ordinary publication, and
retirement. It reads and validates the active index, selected projection, and
current progress while classifying. It recomputes the aggregate roots and
validates the target row plus only the target bodies/lineage/proof required by
the requested transition. It copies every other row exactly and never opens,
finishes, flocks, or repairs another UUID's detached objects. Finalization is
not an ordinary operation.

A selected row is authoritative about the expected value and monotonic state;
its detached files are availability witnesses for that value. If a committed
non-target origin/class/left/receipt/predecessor/lineage body is missing or
corrupt, an unrelated operation may preserve its exact row and proceed. It may
not remove, change, reclassify, retire, reuse, or treat that member as absent.
When that UUID is dereferenced, its direct paths are checked and the operation
returns protected/unavailable before mutation. An extra direct class/left body
not named by the row is likewise quarantined: it is never negative or positive
authority, blocks use of that UUID, and may not be adopted. Genesis and full
phase transitions reject either contradiction globally. Thus no contradictory
detached body is accepted as authority while ordinary work remains bounded.

This section deliberately replaces R5's rule that any detached-body mismatch
blocks every unrelated writer. The security invariant retained from R5 is exact
cross-member state preservation at the authenticated CAS, not unrelated-body
availability.

## 4. Target proof and publication recovery

R6 predecessor v2 and settled lineage v1 remain. A pending row copies the exact
publication kind, predecessor digest, prior lineage, prior/next class/left,
source, old target generation, receipt digest, and capacity reservation ID.
Recovery directly opens only those target objects. It proves a Merkle membership
proof against the captured `rowsRootSHA256`, exact predecessor target row, legal
immediate successor or defined suffix, monotonic target acknowledgment, and
byte-identical non-target projection rows. It can add only the receipt's target
acknowledgment and settle only its charge tranche. Cross-UUID evidence, replay,
removed acknowledgment, altered commitment, unexplained target delta, or
changed aggregate root is protected.

## 5. Closed capacity state and allocation-before-row semantics

The projection contains a closed `capacity` object with:

- `quotaBytes`, `chargedBytes`, `materializedBytes`, `reservedRemainingBytes`,
  and `spentSlackBytes` as UInt64 safe integers;
- one optional `allocationAdmission` and one optional `finalizationAdmission`;
- for each active row, `lifecycleReservationID` and fixed `classPublication`,
  `leftPublication`, and `retirement` tranches; and
- for each admission/tranche: kind, owner operation UUID, target UUID if known,
  tuple/source/install identity, deterministic object digests, fixed charge,
  `materializedCharge`, and state `reserved`, `materializing`, or `consumed`.

There can be only one absent-target allocation admission because it is an
unresolved allocation and therefore activates the retained global allocation
gate. This does not block unrelated heartbeat/control operations and is not a
global publication-pending gate. The optional finalization admission is legal
only with frozen membership and no allocation admission. Per-row publication
and retirement tranches remain independent across all 1,024 rows.

An allocation computes the proposed UUID, generation, initial primary, origin,
class, genesis lineage, tuple digest, and all deterministic digests before its
first write. Under the final journal CAS it publishes `allocationAdmission` in
`reserved` state and increments `chargedBytes`; there is still no active row or
detached allocation object. A retry with the same operation UUID and identical
digests returns/resumes that admission without recharging. Same operation UUID
with different bytes, or different owner for the reserved admission, is
protected/busy.

The next CAS changes the admission to `materializing` and creates the exact
allocating row linked to its reservation ID. Only then may primary, origin,
class, and genesis lineage be exclusive-created in the inherited order. The
settling CAS verifies all exact bytes, makes the row active, marks the genesis
tranche `consumed`, and leaves left and retirement tranches `reserved`. A crash
before reservation CAS leaves no row/object/charge. A crash after it resumes the
same proposed UUID. A crash after materializing may only complete the exact
allocation suffix or perform R5's all-absent removal while returning the entire
still-unmaterialized charge to the same rooted admission; it cannot choose a
new UUID, double-charge, or establish search absence. Once any allocation body
exists, the admission cannot be refunded or removed.

Publication and retirement use the same three states. `reserved` means charge
is rooted but no intent/object exists; `materializing` means the exact pending
row exists and only its ordered objects may appear; `consumed` means the exact
objects and successor row/root are durable. A consumed publication tranche
remains on its active row. Retirement writes v2, publishes a consumed retirement
tranche and new v2 tree root, then a separate CAS removes the row/admission.
The v2 certificate binds the complete capacity record, so retry after removal
is idempotent. `chargedBytes` never decreases. The only refund is the exact
all-absent allocation case before any body or row successor exists; it removes
the still-reserved admission and its charge in one CAS, and is covered as a
pre-authority abort rather than authority deletion.

Accounting must satisfy, at every selected projection:

```text
materializedBytes + reservedRemainingBytes + spentSlackBytes == chargedBytes
chargedBytes <= quotaBytes
reservedRemainingBytes = sum(max(0, tranche.charge - tranche.materializedCharge)
                             for reserved or materializing tranches)
```

Consumed tranches contribute zero reserved remainder. `materializedBytes` is
the charge of every retained in-scope file/directory plus the fixed mutable
footprint. Slack is the conservative difference between a fixed admitted charge
and smaller actual materialization; it remains charged and is never reusable.

## 6. Exact quota inventory, charges, and storage failure

For a file with maximum canonical length `M`, define
`F(M) = ceil(M / 4096) * 4096 + 4096`. The final 4,096 bytes cover the file's
inode and directory entry. Each newly created directory is separately charged
`D = 4096` once. Existing activation objects are charged by actual canonical
length using the same formula; unsafe/unverifiable objects block activation.

| Authority object | Direct path/version | M | F(M) |
|---|---|---:|---:|
| active index | journal active-index v5 | 1,048,576 | 1,052,672 |
| state slot, each of two | `.reservation-migration/state/slot-{0,1}.json` v2 | 1,048,576 | 1,052,672 |
| migration source/progress | direct R4 paths | 1,048,576 each | 1,052,672 each |
| origin | `<uuid>.origin` | 16,384 | 20,480 |
| class | `<uuid>.reservation-class` v1 | 32,768 | 36,864 |
| left | `<uuid>.reservation-left` v1 | 16,384 | 20,480 |
| predecessor | `predecessors/entry/<uuid>/<sha>.json` v2 | 8,192 | 12,288 |
| publication receipt | `receipts/<uuid>/<sha>.json` v1 | 131,072 | 135,168 |
| lineage | `lineage/<uuid>/<sha>.json` v1 | 16,384 | 20,480 |
| completed projection | `installs/<uuid>/<sha>.active.json` | 1,048,576 | 1,052,672 |
| install | `installs/<uuid>/<sha>.json` v2 | 16,384 | 20,480 |
| retirement v1 certificate | `<uuid>.retired` v1 | 16,384 | 20,480 |
| retirement v2 certificate | `retirement/v2/<uuid>/<sha>.json` | 65,536 | 69,632 |
| v1/v2 leaf or internal page | content-addressed tree path | 1,048,576 | 1,052,672 |
| retirement root envelope | `retirement/*/roots/<sha>.json` | 16,384 | 20,480 |

Computed minimum file charges are therefore: class publication
`12,288 + 135,168 + 20,480 + 36,864 = 204,800`; left publication
`12,288 + 135,168 + 20,480 + 20,480 = 188,416`; allocation genesis
`20,480 + 36,864 + 20,480 = 77,824`; retirement v2 `69,632`; and final
projection/install `1,052,672 + 20,480 = 1,073,152`. R7 activation creates and
charges the predecessor/receipt/lineage per-source directories. A new allocation
adds one lineage directory, two later-publication directories, and one v2
retirement directory. Its exact worst-case lifecycle reserve is therefore:

```text
(77,824 + 4,096) + (188,416 + 8,192) + (69,632 + 4,096)
= 352,256 bytes
```

An unclassified source row reserves class + later left + retirement:
`204,800 + 188,416 + 73,728 = 466,944` bytes. A combined first-class-and-left
publication consumes both tranches; its smaller actual charge becomes permanent
slack. Existing class/left files are charged once in activation inventory and
their corresponding tranche begins consumed. The active index and two state
slots have a fixed 3,158,016-byte charge and are not recharged on replacement.
Atomic replacement peak is handled by free-space preflight.

The declared quota is
`roundUp4096(max(1,073,741,824, activationMaterializedBytes +
activationReservedRemainingBytes + finalizationReserve))`. This preserves the
1 GiB bound for normal journals while allowing every previously valid, possibly
larger, v1 history to be rooted without a schema-induced incompatibility. If the
grandfathered baseline forces a larger quota, no discretionary post-activation
admission is allowed until its full lifecycle fits the frozen quota; charged
bytes never fall after retirement.

Before a write, let `Uafter` be reserved remainder after crediting the permanent
charge that this exact write will materialize, and let `Wpeak` be peak additional
volume allocation for this step: rounded encoded bytes plus 4,096 for an
exclusive-create metadata object or atomic replacement temporary, plus 4,096
for each newly created directory. Require:

```text
availableCapacity >= 536,870,912 + Wpeak + Uafter
```

The current write is removed from `Uafter`, so it is not counted twice.
Measure `availableCapacity` on the containing volume immediately before and
after each create/write/fsync/rename/directory-fsync/CAS boundary. ENOSPC or
EDQUOT before rooted intent leaves the selected pair unchanged. After rooted
intent it preserves that exact intent and retries only its suffix. Referenced
or charged authority is never deleted for space; only an unselected, unnamed,
unfsynced temporary may be removed. External space loss returns typed storage
unavailable and converges after unrelated space is restored.

## 7. Paged retirement roots and v1 activation

Replace the R6 flat manifest with closed content-addressed B+ trees:

```text
.reservation-migration/retirement/v1/leaves/<sha256>.json
.reservation-migration/retirement/v1/nodes/<sha256>.json
.reservation-migration/retirement/v1/roots/<sha256>.json
.reservation-migration/retirement/v2/leaves/<sha256>.json
.reservation-migration/retirement/v2/nodes/<sha256>.json
.reservation-migration/retirement/v2/roots/<sha256>.json
```

A v1 leaf contains sorted nonoverlapping rows `(uuid, certificateSHA256,
originSHA256)`. A v2 leaf additionally binds certificate, origin, class, left,
lineage, and lifecycle-reservation digests. An internal node contains sorted
`(firstUUID,lastUUID,rowCount,childSHA256)` entries. Leaves and nodes are at most
1 MiB; a root envelope is at most 16 KiB and contains schema, tree kind, height,
fanout/encoding version, total row count, first/last UUID, and top-node digest.
Internal nodes may point to internal nodes, so height grows as needed and no
valid history is constrained by one manifest's 1 MiB size. Empty history has a
canonical empty root.

Activation occurs only after the R5 prior-binary fence makes every old mutation
route reject the new mandatory format under the journal lock. New R7 mutation
routes remain disabled until genesis. The migrator then validates every safe
direct `<uuid>.retired` v1 certificate and its origin, rejects duplicate UUIDs,
unsafe names/metadata, collisions, or non-v1 content, and emits immutable pages,
nodes, and the root. Enumeration is an authenticated paged transcript: each
slice binds the directory identity/change token, prior continuation token,
sorted rows consumed, rolling transcript hash, and next token or EOF. A slice
stops before the shared eight-second deadline. Compatible writers cannot change
the directory; any invalid token or directory change discards only unselected
scan state and restarts from a fresh enumeration. After process death, reuse is
allowed only for content-addressed pages re-derived byte-identically; the
enumeration transcript restarts unless the platform proves its continuation
token valid. A terminal EOF transcript plus disjoint ordered leaf ranges proves
exhaustiveness; no caller-supplied locator or directory count does.

Before genesis CAS, validate the complete tree and every v1 body incrementally
against one unchanged terminal transcript and directory change token. Publish
and fsync leaves, nodes, then root; all are nonauthoritative until the selected
projection/index names the root digest and count. Crash before root, after root,
or before selection leaves the old graph; restart may reuse only matching
content-addressed objects. Crash after selection yields the exact new root.
After activation, a direct v1 certificate not in the frozen v1 tree is unsafe,
and no v1 writer is permitted. Missing/changed rooted v1 bytes fail target use
and the next full transition, but do not erase the root during unrelated work.

Every new retirement writes v2 before inserting exactly one new leaf path and
publishing a new v2 root in the target retirement CAS. Unchanged subtrees are
reused by digest. The old root remains immutable. Crash before v2/root selection
preserves membership; after v2 but before root selection the object is
unreferenced; after root selection and before row removal the consumed tranche
and rooted certificate drive exact removal; after removal lookup through the
root proves idempotent retirement. No valid history is flattened into an active
index, projection, install, or 1 MiB manifest.

## 8. Migration, rollback, implementation order, and observability

Migration order is: freeze prior source/executable hashes and mutation-route
fence; add strict codecs and maximum encodings; install the mandatory format
fence; build/validate paged v1 history; inventory and precharge all authority;
publish genesis-v2; add operation-local validation; add capacity state and
allocation recovery; add publication/lineage; add v2 retirement; then enable
phase transitions. Readers that accept a new writer must land in the same
unshippable development slice.

Before mandatory-format/genesis selection, rollback removes only unselected
temporaries and leaves the old graph. After selection, in-place downgrade is
forbidden: rollback software must retain the R7 reader/recovery path, or an
operator must stop all writers and restore a byte-exact pre-cutover journal
backup. It may not delete roots, charges, rows, receipts, lineage, or certificates.

Emit structured counters/gauges for aggregate-root validations and failures;
full versus operation-local validation; rows hashed; target and unrelated body
opens; capacity reserved/materializing/consumed/refunded; charged/materialized/
reserved/slack/quota bytes; free-space floor and Wpeak/Uafter; ENOSPC/EDQUOT;
retirement tree height/pages/rows/root; transcript restart; CAS conflict; exact
durable boundary; descriptor high-water; elapsed budget; and typed protected,
busy, capacity, or interrupted result. Logs contain UUIDs/digests but no body or
secret bytes.

## 9. Acceptance and stop conditions

Implementation is eligible for audit only after every R13 case and every
retained R11/R12/R4 case passes against one frozen source/test manifest. The
maximum projection/index/tree pages fit; the 1,024-pending matrix stays within
ten opens, four live reservation descriptors, the measured byte bound, and
eight seconds; every quota equation is independently reconstructed from disk;
all crash/ENOSPC/EDQUOT/real-death suffixes converge; v1 histories above one
leaf remain fully rooted; and fresh code/security/architecture reviews each
report zero Critical, High, and Medium findings.

Stop on any narrower input, unrooted or omitted retirement, full predecessor
snapshot, unrelated detached-body fanout, non-target row mutation, global
publication gate, allocation object before rooted admission, double charge,
unrefunded all-absent reservation, underestimated bundle, quota deletion,
free-space double count, raised deadline/FD limit, unverified prior binary,
missing real-death case, stale result, or skipped/interrupted/timed-out command
reported as passing. Physical MLX, signed release/feed, deployment, enforcement,
settlement, and economic activation remain outside this proposal.
