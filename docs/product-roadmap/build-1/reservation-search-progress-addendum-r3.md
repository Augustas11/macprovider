# Reservation search progress — addendum R3

Status: AUTHOR PROPOSAL; independent Astra approval of this exact revision with
zero Critical/High/Medium findings is required. No runtime implementation is
authorized. R1/R2 and their independent reviews are retained. R2 review closed
RSP-ARCH-M1/M2/M3 at plan level and rejected two additional allocation-boundary
findings. This revision replaces R2's executable protocol and addresses
RSP2-ARCH-M1/M2; the new dispositions remain author proposals, not independent
closure claims. No runtime or test implementation accompanies this revision.

## Scope economy and implementation prerequisite

First finish the separately approved operation-local index-receipt correction
and run the **unchanged** healthy full-capacity test: 1,023 unresolved small
records plus the cancelled reclaimable slot, at most eight reservation calls
within 64 seconds, original eight-second budget per call. Capture per-call
primary bytes/decodes, index bytes/decodes and maintenance progress. If that
change passes the required fixture, report that result and do not implement v4
merely because this proposal exists. This gate does not waive maximum-shape
coverage or claim the all-primary search has disappeared.

A negative-only decoder over already-read primary bytes is a valid local CPU
optimization if full validation remains mandatory for possible matches. It
introduces no persistence transition, but cannot meet the separate structural
requirement that maximum-shape repeated calls avoid rereading previously
classified large bodies. Maintenance-first alone cannot prove search absence.
A cursor alone cannot make mutable negatives permanent. A per-authority slot
adds another allocation root and still requires complete migration of competing
queued candidates. Therefore the selected structural fallback remains immutable
origin-bound classifications referenced by the existing active-index CAS.

R3 retains R2's removal of R1's **pre-primary departure WAL**. Publish the truthful
first nonreusable primary before publishing its permanent exclusion. Existing
owner-loss reconciliation can then see the real started/cancelled record;
there is no queued-looking frozen start to replay and no 6 MiB departure intent.
The publication of an exclusion is bookkeeping for an observed durable state,
not authorization to start work or apply a prospective primary transform.

## Evidence anchors and unchanged semantics

- `ModelCatalogTransactionRetention.swift:reserveOperation` currently searches
  complete primaries before maintenance. Limits remain 1,024 active entries,
  1,048,576-byte index, 4,194,304-byte primary and 2,048 events.
- `ModelTransactionOrigin.Allocation` binds UUID/generation, kind, createdAt,
  target/modelKey/revision/sha256/candidateDigest/artifactDigest/signerKeyID and
  initial-primary hash. Origin equality, not a tuple digest alone, is authority.
- `ModelCatalogTransactions.swift:reconcile` currently decides whether to obtain
  an owner from `historical.startedAt`; ownerless started work gets the existing
  interrupted-owner outcome after success-binding/result/seal checks.
- `run` acquires the UUID owner, creates its lifetime guard, writes started,
  acknowledges its own durable start and only then launches work.
  `retryBeforeMutation` already distinguishes prepublication contention from a
  begun durability bundle; generic `update` retry cannot replay such bundles.
- The lifetime guard's eight-second fence and ten-second exit remain unchanged.
  Only the live owner's own durable start/heartbeat/terminal fsync acknowledges
  progress. Migration, index, exclusion and recovery writes never acknowledge it.

Exact fresh queued reuse keeps every existing predicate and exact owner/file
CAS. No new allocation while a matching candidate is unclassified, unsafe,
pending, owner-busy or potentially reusable. Multiple matching queued originals
are preserved and searched in UUID order. Legacy/protected snapshots remain
read-only without fabricated generation. No immutable history is deleted.

## Closed formats and authority graph

Use canonical encoding, strict duplicate/unknown-key rejection, existing private
mode/owner/link/type checks and bound-directory/file-evidence validation. New
immutable files are exclusive-create; conflicting existing bytes are unsafe.
All hash fields are lowercase SHA-256; no unchecked field is a negative hint.

1. Existing mandatory `.retention-v2/format.json` becomes
   `model_catalog_retention.v3` at cutover. New code accepts v2 before cutover
   and v3 only with the exact cutover source/completion graph below. Old v2-only
   readers reject v3. Format itself remains within its current size limit.
2. Active index `model_catalog_active_index.v4` retains existing binding migration
   lineage, generation and entry fields. Add reservationMigrationID,
   reservationSourceSHA256, phase (`classifying`, `finalizing`, `complete`);
   active entries add mandatory classSHA256 and optional leftSHA256. Allocating
   entries instead carry mandatory expected originSHA256, classSHA256 and
   initialPrimarySHA256 plus allocated generation; their files may be absent
   only during the fresh-allocation protocol below. An allocating class hash is
   a frozen expectation, never evidence that its file is already durable.
   Each entry adds an optional `reservationPublication` receipt SHA256, bound
   to that entry UUID. Distinct UUIDs may have pending metadata concurrently;
   no global pending slot can block an unrelated owner heartbeat. Index CAS
   preserves all other entries and their pending refs.
3. `<uuid>.reservation-class`, at most 32,768 bytes, schema
   `model_catalog_reservation_class.v1`: UUID, originSHA256 and tagged provenance.
   Allocated contains exact origin generation/kind/createdAt and the seven-field
   reuse tuple, plus its domain-separated canonical tuple digest. Legacy and
   protected contain only their existing origin reference. They never gain
   reusable authority. `classSHA256` is mandatory for every completed entry.
4. `<uuid>.reservation-left`, at most 16,384 bytes, schema
   `model_catalog_reservation_left.v1`: UUID, generation, originSHA256,
   classSHA256, firstObservedNonreusablePrimarySHA256, reason (`started`,
   `cancelled`, `terminal`, `committed`, `cleanup`, `migrated_nonreusable`).
   Only an allocated origin admits this file. It permanently excludes reuse.
5. `.reservation-migration/sources/<migrationUUID>.json`, at most the index limit, schema
   `model_catalog_reservation_migration_source.v1`: migration UUID, exact original
   format/index hashes and index generation, existing binding-migration lineage,
   and sorted frozen membership `(id, originSHA256, provenance)` plus allocated
   generation when present. Binding refs and mutable record state are not frozen.
6. `.reservation-migration/progress.json`, at most the index limit, schema
   `model_catalog_reservation_migration_progress.v1`: migration/source hash,
   monotonic generation, phase, exact prefix length and sorted prefix class/left
   refs. A prefix ref for an initially queued entry may have no left; a later
   left is an append-only strengthening in the current index. Prefix validation
   requires the same class and, when the prefix recorded a left, the same left.
7. Immutable metadata publication receipt, schema
   `model_catalog_reservation_publication.v1`, at most 131,072 bytes, unique
   migration-or-operation UUID filename under `.reservation-migration/receipts/`:
   UUID, source lineage, old index generation/hash, original primary SHA256,
   origin/class hashes, exact encoded class bytes, optional exact left bytes,
   and exact next-entry refs. Its old index hash/generation proves preparation;
   replay requires the same entry origin, primary and pending receipt, then
   merges only its next-entry refs into the current validated index under CAS,
   preserving every other entry and current binding refs. It does not require
   unrelated index generations to stand still. It contains **no prospective primary** and cannot
   authorize any primary mutation. The active index reference is its commit
   intent. Every acknowledged file ref must remain present; recovery never
   reconstructs missing acknowledged files from new primary content.
8. Immutable `.reservation-migration/installs/<installUUID>.json`, schema
   `model_catalog_reservation_install.v1`, at most 16,384 bytes: source/progress
   hashes, prepared index hash/generation, finalizing generation and
   completed-index snapshot SHA256. The exact completed index lives separately
   at `installs/<installUUID>.active.json`, bounded by the existing index limit;
   no base64 expansion is squeezed into that same limit. Finalizing index names
   installUUID and receipt SHA256. Completed index retains installUUID and
   source/progress lineage, but not the receipt hash (avoiding a hash cycle).
   Finalizing and completed indexes have identical entries/binding refs; only
   phase, generation and the finalizing-only receipt hash differ. Validate this
   exact relationship before installation. Prepared unreferenced install files have no authority
   and remain retained; a fresh attempt uses a new UUID. This freezes exact
   installation bytes, not membership inference.

Implement format-size derivation tests using the largest accepted origin and
entry fields; class/receipt bounds must accommodate every previously accepted
origin without narrowing input acceptance. Existing index capacity/byte checks
apply before new references are committed.

The reference graph checks current origin against class on every use; tuple
hashes cannot replace exact tuple comparison. An unreferenced retained left file
is never ignored: it causes metadata-publication reconciliation or protected
failure before reuse/allocation. A referenced missing/substituted left fails
closed. Rolling a primary back to queued bytes cannot erase an anchored left.
Search never uses a maintenance/migration cursor as negative authority.

Do not add R1's unproved 65,536-byte allocation-primary limit. Existing new
allocation uses the same 4 MiB primary limit and 16 KiB origin limit. Instrument
actual encoded fresh-record sizes; no accepted input receives a tighter limit
without a separate normative change. The structural saving is elimination of
noncandidate historical-body reads, not assuming all possible queued bodies
are small.

## Retained R1-M1 resolution: primary-first departure and exact owner rules

### Live start

The starter acquires the existing UUID owner and lifetime guard. It captures
current receipt and reservation metadata before deciding from `startedAt`.
Finish any referenced metadata publication first; a changed/unsafe graph fails.
Recheck exact generation, queued state, cancellation, provenance and deadline.
Use `retryBeforeMutation` for the following bundle, never generic update retry:

1. Under journal lock and current receipt CAS, check the lifetime and original
   budget, mark mutation begun, publish/fsync the truthful started primary.
2. Capture/validate that exact written primary outside the global lock while
   retaining its UUID owner. Encode class/left metadata from it.
3. Under journal lock publish a metadata receipt, then its index intent, class
   if absent, left, and final next index clearing the intent. Check budget and
   original receipt/metadata at every final publication boundary. Any fresh
   intervening index update requires recapture before beginning this metadata
   bundle; a referenced intent freezes its exact bytes thereafter.
4. Only after the complete primary+left+index bundle may this original live
   owner acknowledge durable start, recheck its lifetime, and launch its worker.
   Failure or fencing at any boundary returns without launching work.

No other owner can publish the same first departure. No negative permits a new
reservation before the left is anchored in the index. A still-running starter
holding its owner may complete its own exact publication; status/cancel cannot
steal that owner or acknowledge its heartbeat.

### Recovery and status/cancel

Every reservation/control/run entry checks the affected entry's metadata intent
**before** deciding from primary `startedAt`. Reservation checks all potentially
matching entries and cannot infer absence from any unresolved pending entry. Metadata-intent completion does
not change a primary. If its UUID owner is busy, a control request returns the
current truthful state or bounded busy; it never claims completion or launches
work. If owner acquisition succeeds, validate exact immutable receipt and its
recorded primary/origin evidence, complete only the class/left/index bytes, then
perform ordinary reconciliation of the now-current primary.

Crash cases are fixed:

| Durable observation | Action |
|---|---|
| Old queued primary; no started write and no referenced metadata intent | Normal exact queued reuse/start/cancel; no departure is inferred. |
| Started/cancelled nonreusable primary; no metadata intent/left | Under exact owner, publish exclusion metadata from that actual primary; then ordinary reconciliation. Never replay or synthesize a start transform. |
| Referenced metadata intent; exact observed primary remains | Finish exact referenced class/left/index bytes. Acknowledged missing files are protected failures. |
| Referenced intent; primary differs | Protect/fail closed. A legitimate writer cannot pass the intent interlock before it clears; do not rebaseline. |
| Left present, final index absent; intent is referenced | Complete the same receipt; do not use the left to allocate before final anchoring. |
| Unreferenced metadata receipt only | It has no mutation/negative authority. Validate or ignore it as retained history; do not remove it or infer start. |
| Unreferenced left/class without matching recoverable intent | Protected failure; do not regenerate authority from the current primary. |
| Final index references left; primary rolled back to queued | Keep exclusion; return invalid/interrupted evidence as appropriate, never reuse. |

For an ownerless started primary, invoke existing reconciliation's success
binding/result/seal validation first. If there is no valid completed success,
publish its existing truthful interrupted-owner terminal result and ordinary
cleanup obligation. Recovery never launches the operation, installs new work,
fabricates success or grants a heartbeat acknowledgment. A queued-looking record
cannot contain a pending start in this design because there is no pre-primary
start intent.

Queued cancellation attempts the UUID owner before its first primary write.
If acquired, publish cancelled primary then exclusion metadata in the same
primary-first discipline; acknowledge cancellation only after durable completion.
If the owner is busy and the primary is still queued or has a metadata intent,
return bounded busy, allowing the caller's existing retry; do not race a queued
cancel transform into an in-progress starter. Once the started primary and
metadata are complete, cancellation uses the existing live-owner cancel-request
path under receipt CAS without acquiring custody of the worker. The live owner
consumes it. These explicit outcomes preserve cancellation safety; no response
may report a cancellation that was not durably published.

The same rule applies to queued expiry and any first committed/cleanup/terminal
transition. A transform that remains semantically eligible queued must not emit
an exclusion merely because encoding changed. Subsequent already-excluded
heartbeat/result/success/cleanup writes retain existing owner, binding, result
and CAS rules without rewriting the immutable left snapshot. All first-
departure direct writes must join this protocol; the inventory below is a
required executable audit, not permission for unlisted bypasses.

## RSP2-ARCH-M1 resolution and retained cutover/migration interlock

### Executable early fence; no healthy old-owner termination

Migration activation is a bounded attempt before classification, under the
call's original eight-second budget. Finish existing binding migration first.
Then run the existing pre-v4 `recoverAllocations` absence-specific protocol
**before any owner probe**. `initializeRetention` alone is insufficient. Capture
primary/origin evidence outside the journal lock; under exact index/file CAS:

- Empty allocating intent with absent primary, origin, all sidecars and owner:
  remove only that intent. Never acquire/create its owner or fabricate origin.
- Exact initial queued primary, absent-or-exact expected origin, all unrelated
  sidecars and owner absent: complete the expected origin if absent, then active
  membership, using existing encoded-origin hash checks. Preserve original
  primary bytes and generation. No owner acquisition is needed for this path.
- Unsafe/conflicting primary/origin/sidecar/owner evidence: leave all bytes and
  membership unchanged, return protected/unavailable before the fence.
- Changed receipt or a live allocator holding the journal lock: return bounded
  busy/retry under the original budget; never wait on that allocator or remove
  its intent. A publisher interrupted after durability begins uses explicit
  allocation recovery, never a generic fresh-allocation retry.

Require a newly validated index with **only fully active entries** before
preparing source or beginning the owner cut. Any remaining allocating entry
prevents activation. At the final journal CAS recheck every entry's phase,
exact membership/generation and origin refs, so a concurrent allocator's intent
cannot enter the frozen source unseen. No allocating UUID ever enters the
owner sweep, and a failed activation does not create an owner inode.

The quiescent-owner cut uses a new **noncreating** owner-evidence probe, not
`ownerLock`/`ModelCatalogFileLock`'s current O_CREAT path. For each fully active
UUID in sorted order, capture safe owner-path metadata. If present, open that
exact stable inode without O_CREAT using existing directory/type/link/mode
checks and try its exclusive owner flock nonblocking; retain the acquired FD.
If absent, retain absence evidence without opening/creating it. Busy, changed,
unsafe, descriptor-limit or deadline failure releases all acquired descriptors
and returns before the format fence. Never unlink an owner path. No all-owner
lock or descriptor set survives a call. All bulk evidence capture and owner
probes occur outside the journal lock; the final journal acquisition is also
nonblocking. This is a quiescence check, never owner custody for recovery/work.

Under the final journal lock, validate every retained owner inode/absence and
exact index/format receipt before any fence publication. A previously existing
live owner makes its flock busy and prevents cutover while heartbeats continue.
An owner created between absence capture and validation invalidates the cut.
An old starter creating an owner **after** the final absence check cannot publish
its first started primary while migration holds the journal lock. On release,
its mandatory final format/receipt check rejects the fence before acknowledging
start or launching a worker. A preexisting worker cannot have this absent-owner
shape: workers launch only after durable start while retaining the stable owner
FD. Qualification must prove this actual old-start ordering, including cleanup
owner startup; any bypass blocks cutover compatibility rather than permitting
an unsafe race. The cut itself creates no owner inode on success or failure.

Capture current index/format evidence and immutable source outside the global
lock. After the noncreating quiescence probes, take the journal lock
nonblocking and revalidate exact membership/index/format receipts. A changed allocation or
retirement before this cut aborts before source/fence authority is published.
Publish immutable source, then the new **existing mandatory format** v3, then
v4 classifying index with the identical frozen membership and source reference.
Every write is fsynced in the existing directory discipline. Release global and
all retained owner-probe descriptors. Classification starts only after this
fence/initial-index bundle is durable. There is no authoritative `.reservation-migration` state
while the old accepted mandatory format remains writable.

Crash after source but before format: no classification is authoritative; retry
must validate the same source or retain it as unreferenced history and create a
new uniquely named source intent (never overwrite immutable source bytes).
The unique source filename is derived from the validated migration UUID;
there is no mutable source alias. The format's v3 body includes migrationID
and sourceSHA256 and thereby names exactly that immutable source. Crash after
format but before v4: new code completes exactly the source's frozen v4 classifying index after validating
its original index/membership; old code rejects format v3. A mismatched index
is protected, not silently remigrated. No format downgrade is permitted.

Compatibility qualification uses actual binaries, not a hypothetical reader.
The minimum supported prior writer is the exact pre-v4 Build 1 snapshot that
implements the current mandatory-format and final receipt validation. Build
and retain that binary before implementation, with source/binary SHA manifests.
Every production mutation route must revalidate `format.json` under the same
journal lock immediately before mutation: captureActiveReceipt/commit, direct
result/seal/success-binding/terminal bundles, queued expiry, cleanup, allocation
and retirement. Their existing receipt path leads to loadActiveIndexLocked/
format evidence validation. A writer paused outside the lock before the fence
must reject the substituted format at its final validation; one paused inside
the lock prevents fence installation until its prior write finishes.

Test that actual binary, plus every prior binary proposed for this upgrade's
supported compatibility set. A binary lacking final mandatory-format checking
is **not a supported concurrent writer**, and activation for an installation
where it can run is prohibited; do not ship a universal compatibility claim.
This is a release qualification failure requiring a separately reviewed bridge
release, not an operational exception allowing unsafe mixed writers. No bridge
release or production deployment is authorized here. The chosen protocol has
no fallback which continues classification while such a writer is permitted.
New v4-compatible binaries understand the fence and migration interlock below.

### Frozen membership with classify-before-write

During `classifying`/`finalizing`, allocation, retirement and active-membership
changes return bounded busy. Thus frozen `(UUID, origin, provenance, generation)`
membership is unchanged through installation; no membership reconciliation is
needed. Maintenance may observe/cancel an expired queued member using normal
control semantics, but cannot remove it until complete. Immutable success
bindings and existing entry binding refs may advance; they do not change frozen
membership and are preserved from the current index at final CAS.

Healthy **new-compatible** owners may start and continue during migration.
Before any mutation of a source member, that writer ensures its class and any
required exclusion are published under its own exact receipt and the same
metadata-publication interlock. A writer of an unclassified already-running
record classifies the current nonreusable state first; a queued starter uses
primary-first departure above. Heartbeats, cancellation, success/result/seal
and cleanup use the current classified receipt and do not wait for a migration
prefix or a global sweep. No migration-wide busy flag blocks their heartbeats.

The migration worker visits source entries in sorted order. It tries a UUID
owner; if busy, skips it for this call without claiming a prefix entry. Its live
writer can classify it through the shared routine. A capture invalidated before
metadata-intent publication is discarded and recaptured within remaining
budget. Once the index references a metadata intent, its frozen bytes cannot
be reclassified: any writer first finishes that exact metadata bundle under
its existing owner; ownerless recovery obtains the owner. Missing acknowledged
class/left or changed original evidence becomes protected failure, never an
infinite retry of a guessed new negative.

Pending metadata is **per entry**, not a migration-wide or index-wide gate.
A healthy writer of UUID B preserves UUID A's pending reference during its own
index CAS and need not acquire A's owner or finish A's publication. A writer of
A finishes its exact metadata bundle under its existing owner before mutating
A's primary. Recovery of A without custody tries A's owner nonblocking. A busy
A cannot stall B's heartbeat, and no cross-UUID owner acquisition is introduced.
Before publishing an intent, recapture on any index change; after publication,
only A's exact pending/primary/origin evidence is frozen. Recovery merges A's
frozen next metadata refs into the current index, preserving concurrent other-
UUID and binding changes. Same-UUID binding/primary changes cannot bypass its
pending interlock. Tests pause A after intent across multiple heartbeat periods
and prove B continues durable heartbeats without acknowledging metadata work.

After every successful publication, recapture the index receipt under the
original budget. Advance prefix only over exact source members whose current
class/left refs validate; do not reread their prior large primary bodies. When
all members have classes and no member has a pending publication, capture current index and progress outside the lock,
verify exact frozen membership and all authority refs, encode final completed
index preserving current binding/exclusion refs, and prepare immutable completed-
index snapshot plus install receipt. Under exact journal CAS set phase finalizing
with their exact reference; then install its exact completed bytes. The completed
index is the completion receipt. In finalizing, membership remains frozen
and a writer first completes that small exact installation before proceeding;
there are no outstanding bulk reads. A changed index before install-intent
publication retries capture; afterward only those exact bytes may be installed.
All finalizing crash recovery verifies the frozen install digest, never builds
a new completed index from partial progress.

## RSP2-ARCH-M2 resolution: fresh v4 allocation and dynamic membership

This protocol runs only after reservation migration is complete. Classifying or
finalizing indexes refuse allocation and retirement as specified above. The
completed migration authorizes the format; it does not freeze every future
index generation to the original membership.

### Allocation publication

Run pending-allocation recovery first. An unresolved allocating entry prevents
new allocation; no attempt may count it as an absent reusable candidate. Search
all active candidates using the complete class/origin/left graph and exact
queued predicates. Retain the resulting validated index receipt through the
final allocation CAS. A concurrent allocation, retirement, binding or exclusion
index update invalidates that receipt: repeat the affected search against a
fresh receipt within the same original budget, never transplant an old absence
conclusion onto a changed index. Maintenance may remove entries, but its new
receipt is not an automatic absence proof: verify surviving candidate evidence
and rerun search whenever mutations could alter that conclusion.

Choose fresh operation UUID/generation only after a complete absence proof.
Outside the journal lock fully encode the initial queued primary using existing
encoding and limits, canonical allocated origin and canonical reservation class.
Derive the origin from those exact primary bytes and class from that exact
origin. Validate all three, including exact tuple/provenance, initial primary
hash, generation, closed fields and size limits. Freeze these bytes and hashes;
no reconstruction from later authority inputs or timestamps is permitted.
Prepare allocating and active index bytes, checked against the existing index
limit/capacity and preserving complete migration lineage. The allocating entry
contains UUID, allocated generation/provenance, expected origin/class/initial-
primary hashes; left and metadata-publication refs are absent. The active entry
retains the same expected hashes and adds phase active; every required file must
be durable before it becomes active.

Under the journal lock and original receipt/file/directory CAS, require complete
migration, available capacity, no unresolved allocations, and absence of this
UUID's primary/origin/class/left/metadata receipts plus all existing sidecars,
staging and owner path. Do not create/acquire its owner. Mark mutation begun,
then publish/fsync, checking original budget at each boundary:

1. Allocating index intent with the exact expected hashes.
2. Exclusively created exact primary bytes.
3. Exclusively created exact origin bytes.
4. Exclusively created exact class bytes.
5. Active index with the same hashes and class authority.

The original uninterrupted publisher holds the journal lock through this
bundle, as the existing allocator does; it performs no bulk decoding there.
A paused publisher makes another process's nonblocking recovery return busy.
After any partial publication, release on error and return interrupted; do not
restart this request as a new UUID through generic contention retry. Recovery
on a subsequent bounded call uses the state machine below. A successful reserve
returns only after active index fsync and exact current authority validation.
A return lost to process death is harmless: a later matching request must reuse
that active queued UUID through the existing exact reuse checks.

### V4 allocation recovery; owner absence is evidence

Recovery captures index, primary, origin, class and contradictory-sidecar/owner
evidence outside the journal lock, prepares the exact allowed completion, then
revalidates all of it under current index CAS. It never opens or creates an
owner. It does not replay an owner/start action or acknowledge a heartbeat.
Every present file must have its expected frozen hash and strict identity;
existing origin/class bytes must equal the canonical bytes derived from the
exact initial primary. Expected hashes alone never authorize fabricated fields.

| Allocating entry and observed files | Required outcome |
|---|---|
| Primary, origin and class all absent; all sidecars and owner absent | Remove only the allocating intent under exact absence/index CAS; no file or owner creation. This UUID was never returned active. |
| Exact initial queued primary present; origin and class absent | Recompute canonical origin from these exact primary bytes, require frozen initial-primary/origin/class hashes, then exclusively publish exact origin, class and active index. |
| Exact primary and origin present; class absent | Validate both against intent and initial queued predicates; derive only the frozen matching class, publish it exclusively, then active index. |
| Exact primary, origin and class present | Validate full graph and initial queued predicates, then publish active phase only. |
| Primary absent but origin/class present; or class present while origin absent | Protected failure. This is impossible under ordered crash publication and may be deletion of acknowledged evidence; do not recreate it. |
| Any differing bytes, unsafe placement, owner, left, metadata-publication receipt or unrelated sidecar | Preserve all evidence and intent; protected/unavailable. Never remove/rebaseline it or allocate past it. |
| Entry already active | Ordinary active authority validation. Missing acknowledged primary/origin/class is protected; allocation recovery cannot regenerate it. |
| Matching files exist without an allocating/active entry | Retained orphan evidence has no allocation authority. Never adopt it from a caller tuple or overwrite it; fresh UUID collision fails its absence CAS. |

Before intent exists there can be no files from this allocation protocol. File
absence recovery is allowed only for the ordered unacknowledged suffix above.
A present altered primary that still decodes as queued fails its initial hash;
changing its generation/date/tuple cannot be used to manufacture a new origin.
Recovery completion merges only this entry's phase into the latest validated
index after a fresh CAS capture, preserving other authorized changes and exact
lineage. It never installs stale prepared whole-index bytes across generations.

### Historical completion versus current membership

The immutable source, install receipt and completed-index snapshot prove exactly
one frozen **migration completion**. Validate that closed historical graph using
its immutable files, source membership and finalizing/completed relationship;
never compare its member set to each later current index. Keep all referenced
historical files and origin/class authority after retirement. Missing or altered
acknowledged install evidence remains protected even if current members look
valid. The existing binding-migration completion lineage remains unchanged.

The first installed complete index equals the frozen completed snapshot. Later
current generations strictly increase through existing final index CAS, retain
the identical reservation migration ID/source/install UUID and completed-snapshot
lineage, and may add a fresh allocated entry only via the protocol above or
remove one only via existing validated retirement. Existing entries retain their
origin/class identity and monotonic anchored exclusion; binding refs may advance
under their existing publication rules. New allocated entries need not appear
in the migration source. Legacy/protected entries may only originate from that
source and cannot be introduced by a new allocation. Re-adding a retired UUID
is forbidden by its retained files/absence checks. Empty-source migration is
valid and must support the first and subsequent real allocations.

A current completed-phase index never falls back into classification merely
because membership differs from the historical snapshot. Its current class
graph is checked independently under current receipt CAS. Existing retirement
cursor remains a scheduling hint; neither it nor a historical completion digest
proves current search absence. No new allocation root or fabricated legacy
identity is introduced.

### Writer inventory and rollback

Required participating surfaces: generic `update`/`commit`; `run` first start;
`reconcile` status/cancel; `retireOne` queued timeout and retirement;
`completeBoundEvaluation`/success-binding recovery/index updates; prepare result
and artifact seal publication; cleanup admission/start/heartbeat/result/original
updates; allocation recovery; direct `writePrivate`/directory writes reachable
from those production commands. Read-only archived status may remain read-only
but cannot use a format failure to enter an older mutating fallback.

Rollback retains v3-format/v4-index and every immutable source/class/left/receipt.
Use only a compatible binary. Before the fence, an unreferenced source can remain
as harmless retained history; after the fence, recovery completes forward or
reports protected failure. There is no sidecar deletion, automatic downgrade,
legacy identity fabrication or replacement-journal shortcut.

## Added R3 allocation-boundary qualification

- Crash the actual pre-v4 allocator at allocating intent, primary, origin and
  active boundaries, then invoke real migration activation. Empty intent and
  primary-only recovery must create no owner inode; unsafe sidecars/owner leave
  exact original bytes unchanged and prevent fence. Pause a live allocator at
  each boundary: failed cut creates no owner inode and never changes its intent.
  Release it, retry boundedly and prove at most one surviving allocated UUID.
- Race new allocating membership into the interval before final cut CAS: abort
  with old format intact, recover before any next owner sweep. Test noncreating
  owner probes with absent/present/substituted/unsafe paths, real running owners,
  owner creation before and after final absence validation, and old start/
  cleanup publication paused at final journal validation. No old worker launch
  or durable mutation may cross the fence; no healthy preexisting worker is
  terminated merely to force migration progress.
- Run the quiescent cut at 1,024 fully active entries with all stable owner paths
  present and separately absent. Record peak descriptor count, soft/hard limits,
  opens/flocks/closes, elapsed time and budget checks. Inject descriptor
  exhaustion: release every acquired descriptor, retain all owner paths and
  leave format/source authority unchanged. Qualification must demonstrate the
  original eight-second cut on the supported healthy resource profile; resource
  failure is bounded unavailable, not claimed capacity/migration progress. Do
  not raise process limits or alter watchdog/budget to pass.
- Actual child death and thrown errors at all five v4 allocation boundaries;
  real reserve/restart afterward for every recovery-table row. Prove no active
  returned reservation lacks class authority, absent-intent recovery creates
  no owner, only matching exact suffixes complete, altered/unsafe evidence is
  retained, and recovery never launches work. Crash before intent must leave
  no allocation files. Lost response after active must reuse the same UUID.
- Concurrent real reserve/reserve and allocation/retirement with barriers around
  search absence and final CAS, including a matching candidate inserted after
  search. No duplicate while a possible match or unresolved intent exists.
  Restart a migrated journal, repeatedly allocate/start/finish/retire, and
  validate both unchanged historical install evidence and current membership;
  include empty source and retirement of every original source member. Mutation
  of historical completion or current lineage fails closed independently.

## Qualification tests and stop conditions

1. Preserve the unchanged healthy capacity fixture and first run it after the
   separate index correction. Report measured evidence before requesting any
   v4 implementation. Re-run unchanged after any independently approved v4 work.
2. Exact fresh queued reuse, multiple queued matches, queued candidate last,
   every authority-tuple mismatch, busy owner, corrupt/unsafe/missing metadata,
   future/exact-expiry clock, and zero allocation while a possible candidate is
   unresolved. Legacy/protected snapshots never gain generation or eligibility.
3. Real child death and thrown errors after first nonreusable primary, metadata
   receipt, referenced intent, class, left and final index. Then invoke actual
   status/cancel/reserve/run. Cover old queued before any write, ownerless start,
   a live starter paused after primary, cancellation versus owner acquisition,
   interrupted success with valid/invalid binding and seal, and cleanup. Assert
   no worker launched by recovery, no success or heartbeat acknowledgment
   invented, no generic retry after publication, and correct protected outcomes.
4. Concurrent healthy owners with migration paused across several eight-second
   calls: old busy owners prevent fence while heartbeats continue; after cutover
   new-compatible owners classify/write/heartbeat without waiting for prefix.
   Force cancellation, result/terminal and cleanup writes on unclassified,
   classified and pending entries. Verify membership stays frozen, binding refs
   are preserved, and prefix progress never rebaselines acknowledged metadata.
5. Actual prior binaries at pre-source, source-only, post-format/pre-v4,
   partial classification, pending metadata, finalizing and complete states;
   pause each representative writer before final journal validation and resume
   after the fence. Compare all primary/result/seal/binding/index bytes: no
   old-writer mutation afterward. Run safe read/control failures too. Unsupported
   binary validation failure blocks release, not merely one test subcase.
6. Max-shape 1,024 records, each up to 4 MiB and 2,048 valid events. Controlled
   cooperative latency profile: complete one primary read+strict validation in
   at most two seconds, at most 256 KiB per chunk with 25 ms injected delay;
   report actual bytes, decoding time, fsync latency and budget checks. Force
   budget exhaustion after completed classifications and verify following calls
   do not reread those bodies. Put a plausible queued candidate last. The
   per-record feasibility assumption is explicit: if a single complete capture
   cannot fit any call's eight-second budget, this design returns bounded busy
   and makes no classification-progress claim for it. Noncooperative syscalls
   retain existing watchdog limitations. No arbitrary-4-GiB/64-second promise.
7. Substitute/delete/edit origin/class/left/receipt/source/progress/install/
   format/index, including duplicate/unknown fields, same-byte new inode,
   in-place mutation, unsafe links/modes and tuple/hash mismatch. Remove an
   optional index left ref while its immutable file remains: no reuse. Roll
   primary back after anchored exclusion: no reuse. Missing acknowledged
   metadata is never regenerated from current state. Immutable history remains.
8. Original budgets, short-control responsiveness, independent owner fence/
   watchdog, cancellation/cleanup and all existing migration/binding/retirement
   tests remain mandatory. Measure metadata-read and repeated-index costs; the
   new graph is not accepted merely for avoiding large-primary decoding.

The R1 finding resolutions independently accepted in R2 are retained:
primary-first departure with existing orphan reconciliation, frozen membership with classify-before-write, and early
mandatory-format cutover after a noncreating nonblocking quiescent-owner cut.
R3 additionally selects absence-specific pre-cut allocation recovery and an
explicit fresh v4 allocating/primary/origin/class/active protocol. No alternative
is delegated to implementation. Independent review and fresh measured acceptance
remain required; this author has not implemented or tested the proposal.
