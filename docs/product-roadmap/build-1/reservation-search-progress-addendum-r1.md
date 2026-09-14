# Reservation search progress — addendum r1

Status: AUTHOR PROPOSAL, NOT IMPLEMENTATION APPROVAL. Independent Astra review
of this exact document with zero Critical/High/Medium findings is required before
runtime work. This supplements the current transaction binding/migration and
retention plans; it does not modify another author's plan. The operation-local
active-index receipt proposal remains separately owned and reviewed.

## Contract and evidence

`reservation-search-progress-analysis-r1.md` records the failed full-capacity
Swift30 fixture. In `ModelCatalogTransactionRetention.swift:reserveOperation`,
the active-index loop captures and fully decodes every primary before
`maintainRetention`; every new call starts again. The active limit is 1,024,
primary limit 4,194,304 bytes, and event limit 2,048. Faster decoding alone does
not establish progress. `ModelTransactionOrigin.Allocation` already binds the
exact immutable kind, target, modelKey, revision, sha256, candidateDigest,
artifactDigest, signerKeyID, generation, creation time and initial-primary hash.
Current active-index v3 entries contain id/phase/origin/provenance/binding refs,
but do not bind a persistent classification of reservation eligibility.

Preserve these independent requirements:

1. Exact fresh queued reuse retains the current tuple and all predicates:
   allocated selector; matching kind/target/modelKey/revision/artifact and feed
   digests/signer; one queued event; no start, commit, cancellation or cleanup;
   no conflicting sidecars; age in [0, 1,800 seconds); exact owner and file CAS.
2. Never allocate while an unseen or unresolved matching reusable candidate may
   exist. Busy/corrupt authority cannot be treated as a proven negative.
3. The existing healthy local full-capacity fixture is unchanged: 1,023
   unresolved small records and a cancelled reclaimable slot; success within
   eight reservation calls and 64 seconds, each retaining its original eight-
   second operation budget. Do not shrink the fixture or increase its limits.
4. Maximum-shape and controlled-slow-primary-read fixtures prove durable progress
   across calls and no repeated prior-body scan, with the original per-call
   budget. They do not promise reading arbitrary 4 GiB within 64 seconds.
   Noncooperative filesystem syscall behavior remains the existing watchdog
   qualification, not a newly claimed hard interruptibility guarantee.

## Decision: immutable classifications referenced by the active index

Select an origin-bound, monotonic reservation-classification layer, preserving
multiple historical matching candidates. Do not introduce a per-authority slot.
The active index remains the bounded membership root; classification references
let the search skip known noncandidates without touching their large primaries.
A complete classified index proves the search set is complete. A cursor only
chooses work order and is never absence or allocation authority.

Alternatives:

| Alternative | Decision |
|---|---|
| Smaller JSON hint over each complete primary | Reject: still reads up to 4 GiB per call; no durable negative authority. |
| Maintenance first or rotating search cursor | Insufficient alone: current negatives can change, and partial scans cannot authorize allocation. |
| One mutable slot per authority | Reject for this correction: introduces another allocation CAS root and must reconcile multiple preexisting queued matches before any empty-slot claim. |
| Immutable exact-origin classification plus index references | Select: reuses allocation/index CAS and preserves all candidates; one irreversible departure record replaces repeated historical-body reads. |

This changes persistent authority and writer transitions. It is not merely an
optimization or a new advisory cache. Its normative schema and migration must
be independently approved before implementation.

## Proposed closed formats

Use the existing canonical encoder, duplicate-key rejection, closed-schema
round trip, bounded reads, private file modes, link/type/owner checks, directory
identity binding and file-evidence substitution checks. Hashes are lowercase
SHA-256. UUID/generation rules remain unchanged. Reject unknown versions/fields,
missing references, duplicate IDs, overflow and conflicting immutable bytes.

- Active index `model_catalog_active_index.v4`: retain every v3 field and entry
  field; add `reservationMigrationID` and `reservationSourceSHA256` at root;
  add required entry `reservationClassSHA256` and optional
  `reservationDepartureSHA256` for a pending first-departure intent. Maximum 1,048,576 bytes and
  1,024 unique sorted entries remain unchanged. No lossy truncation. An entry
  is never usable for reservation before its classification reference exists.
- Immutable `<uuid>.reservation-class`, maximum 16,384 bytes:
  `schema=model_catalog_reservation_class.v1`, transactionID, originSHA256,
  provenance, and tagged disposition. `allocated` disposition contains exact
  operationGeneration, kind, createdAt and the seven-field reuse authority tuple
  (target, modelKey, revision, sha256, candidateDigest, artifactDigest,
  signerKeyID; kind is separately bound). Include a domain-separated canonical
  tuple SHA-256 as an index hint, never a substitute for exact tuple comparison.
  `legacy` and `protected` dispositions carry only their existing origin ref;
  neither gains a generation, an authority tuple or reuse eligibility.
- Immutable `<uuid>.reservation-left`, maximum 16,384 bytes: schema, UUID,
  operationGeneration, originSHA256, classSHA256, reason, and exact first
  nonreusable primary SHA-256. Reasons are started, cancelled, terminal,
  committed, cleanup, or migrated_nonreusable. This record is permanent.
  Once published, ordinary primary rollback/rewrite cannot restore reuse.
  The active entry adds optional `reservationLeftSHA256`; missing/substituted
  bytes for a present reference are unsafe, not absence of exclusion.
- Migration source/progress/completion live in a distinct private
  `.reservation-migration` directory using explicit `*.v1` schemas and existing
  migration receipt conventions. Source binds exact completed binding-migration
  lineage and captured v3 active index evidence. Progress binds source digest,
  unique migration ID, monotonic generation, exact classified prefix, and at
  most one pending UUID/classification publication. Completion binds every
  source member and the installed v4 membership. It cannot summarize a partial
  scan as complete. Maximum source/progress bytes use the existing index bound.

The class tuple must exactly equal allocated origin fields. A reference whose
class conflicts with its origin is rejected even if its tuple digest matches.
`reservation-left` is valid only with its exact origin/class membership and
publication receipt; a freestanding caller-created file does not authorize an
index edit. Existing immutable origins, success bindings, retirement
certificates and legacy result bytes are neither deleted nor rewritten.

## Publication, mutation and recovery order

All bulk reads, JSON parsing, hashing and encoding stay outside the global
journal lock. Every final publication holds the existing nonblocking journal
lock and exact UUID owner where required, checks the original budget, current
index receipt/generation, pinned file identities and directory placement. The
separate operation-local index receipt optimization may avoid repeated decoding
only after its own review; this plan does not authorize that implementation.

### New allocation

Encode bounded fresh queued primary and origin plus class before the lock.
Fresh allocator-created primaries must have a proved encoded bound of 65,536
bytes, derived from the existing bounded origin and the fixed initial event;
reject the design if existing accepted authority fields can exceed this bound.
This does not reduce the 4 MiB historical/general-primary allowance.

Under existing allocation CAS, publish allocating index intent including exact
origin/class hashes, then primary, origin, immutable class, then active v4 index
entry. Add the class boundary to existing child-death tests. Never return the
reservation before active publication. Recovery must either complete that exact
intent using its existing primary/origin authority or retain it as unresolved;
it cannot invent a replacement origin/class from a partial or mismatched record.
Class publication is mandatory for active visibility. A crash after class but
before active index is completed through the allocation intent. UUID reuse and
rewriting conflicting immutable bytes remain forbidden.

### First departure from reusable queued state

A queued generation can become started/cancelled/terminal/committed/cleanup but
cannot become reusable again. Audit every primary writer: `update`/`commit`,
`run` start, cancel, queued timeout in `retireOne`, cleanup and success/recovery
paths, including direct `directory.write` sites. Generic transforms must obey
this invariant; unknown writers block acceptance.

The first departure uses an explicit pending publication intent referenced by
that same active entry, under its owner and index CAS. The intent binds old
primary evidence, exact prospective primary bytes/hash and the eventual left
record bytes/hash. Its proposed closed schema is
`model_catalog_reservation_departure.v1`; file bound is 6,291,456 bytes: an exact base64-encoded prospective primary
(at most the existing 4,194,304-byte primary limit) plus at most 16,384 bytes
of closed metadata, checked before encoding/publication. Unknown larger
representations are rejected; prospective bytes are decoded and validated before
any publication. Ordinary first-departure records start from the small fresh
queued allocation, not a newly expanded maximum-size history.
The index marks the UUID pending before primary publication; a pending member
always blocks reuse and same-authority allocation, even if its old primary still
looks fresh queued. Then publish prospective primary, immutable left record,
and final index reference clearing pending. Retain the immutable intent as
recovery evidence; do not remove history to establish absence.

Recovery under the original exact owner/CAS may finish only that exact already-
authorized transition. It verifies old/new primary match the pending intent and
all original provenance, sidecar and directory guards. It must not execute
inference, preparation side effects or fabricate success. If the runtime's
existing start recovery cannot safely represent a published but orphaned start,
stop and revise this protocol before implementation. Unknown or changed primary
states retain pending and fail closed. No generic retry after first publication.
Only after the complete left record/index publication can a subsequent call
use that UUID as a permanent negative without reading its primary.

A byte-only rewrite or transform leaving all current reuse predicates true
must preserve reusable eligibility: retain the class, do not emit `left` merely
because a digest changed. Prefer skipping semantic no-op writes. Reusable
records still undergo complete validation when selected; classification never
turns invalid primary data into reusable data.

### Reservation and capacity maintenance

Capture a fully validated v4 index receipt and its completed migration lineage.
Read bounded class/left evidence, validating exact origin binding and index
references. Nonmatching immutable tuple, legacy/protected provenance, or a
complete permanent left reference exclude that entry without primary reads.
Malformed/missing required metadata blocks a negative proof. Matching allocated
entries without a complete left reference remain candidates; choose deterministic
UUID order, fully validate primary/provenance/sidecars under exact owner/CAS and
return the first valid fresh queued reservation. Busy, pending, or unreadable
plausible candidates forbid new allocation. Time expiry is rechecked at final
CAS; neither a cursor nor a cached clock result extends freshness.

Only after all potential matches are resolved may capacity reclamation and new
allocation proceed. `maintainRetention` receives the remaining original budget;
it retains its separate retirement proofs and cursor. Classification references
are not retirement certificates and cannot themselves free a slot. In the
healthy full-capacity fixture, reservation no longer reads the 1,023 started
bodies before maintenance. Across calls maintenance retains its existing durable
cursor and reaches the one cancelled slot within the unchanged eight-call
qualification. If metadata or repeated terminal-proof work still prevents that,
measure the remaining cost and reopen the design; do not claim this proposal
already passes the fixture. The separately reviewed index-receipt correction
addresses repeated legacy/index decode cost, not reservation authority.

## Migration and compatibility

Finish the existing binding migration first. Build one immutable source snapshot
of v3 active membership under its existing file-evidence CAS. While reservation
migration is incomplete, refuse new reservations/allocation; preserve status and
existing owner safety. For each source entry, acquire its UUID owner, capture
complete primary/origin/sidecars outside the journal lock and classify under
exact final evidence/index CAS. Legacy/protected origins remain read-only and
nonreusable without manufactured generation. Allocated records receive exact
origin-derived classes; current nonreusable allocated records receive a permanent
migrated exclusion bound to the validated current primary. Eligible allocated
records remain candidates. Multiple matching queued records are all preserved;
migration does not choose one and discard unseen competitors.

Publish pending progress before immutable per-UUID classification, then completed
prefix progress after files are durable. Crash recovery verifies exact pending
bytes and their source binding. Resume only from the validated prefix; previous
large primary bodies are not reread. Previous negative authority is the immutable
classified exclusion plus its pinned references, not the cursor. All writers
allowed during migration must first consult its lineage and publish required
monotonic departure metadata for classified entries. Simpler safe implementation:
return bounded busy for mutating operations while this short-control migration
owns a classification cut; do not hold all UUID owners or the global lock across
calls. A writer racing a capture invalidates that UUID's CAS and leaves it pending
for a fresh capture, never silently negative. Final v4 installation requires the
same source membership or an explicit fully validated reconciliation; no missing
source member, origin substitution or unseen added member is ignored.

Old binaries must fail closed on v4 and incomplete reservation-migration format;
verify their actual format negotiation before rollout. Rollback means retaining
the new metadata and using a compatible binary, not deleting sidecars/downgrading
v4 to v3. A safe downgrade converter is outside this proposal. No legacy identity
fabrication, active-capacity increase, global directory history scan, removal of
immutable results, or changed expiry is authorized.

## Required tests and evidence before acceptance

1. Exact reuse tuple Cartesian tests, candidate last among 1,024 entries,
   multiple matching queued originals, busy matching owner, absent/unsafe
   sidecars, future/just-expired creation time, and same model with distinct
   digest/signer/kind/revision. No allocation while any plausible candidate is
   unclassified, pending, unreadable or busy.
2. Original healthy 1,024-capacity fixture, unchanged eight calls/64 seconds and
   original eight-second budgets. Log per-call elapsed, metadata bytes, primary
   bytes/count, full-index decodes, classifications and retired IDs. Preserve
   1,023 unresolved records byte-for-byte; prove exact cancelled-slot recovery.
3. 1,024 maximum-shape 4 MiB records with 2,048 valid events and controlled slow
   outside-lock primary reads. Kill calls at deterministic budget boundaries;
   across calls prove prefix classifications survive and prior bodies are not
   reread. Keep any fresh queued candidate at the end; until reached, new
   allocation remains forbidden. State injected read latency/throughput and
   syscall cooperation assumptions. Do not apply the healthy-fixture 64-second
   completion assertion to unbounded I/O; do retain each cooperative call's
   original deadline and watchdog tests.
4. Real child death at source, migration pending/class/left/prefix/completion;
   allocating intent/primary/origin/class/active; departure intent/primary/left/
   final index. Assert exact recovery, no duplicate UUID/authority allocation,
   no started worker or success invented by recovery, and no history deletion.
5. Concurrent reserve/reserve, reserve/start, cancel/reuse, queued expiry,
   migration/writer and maintenance/allocation. Hold outside-lock evidence
   barriers and force index generation changes. Verify owner fencing, journal
   CAS, no recursive acquisition and short-control/watchdog latency.
6. Replace/delete/in-place edit every class, left, pending, source/progress,
   completion, origin, primary and index file, including byte-identical inode
   substitution, unsafe modes/links, tuple/digest mismatch, duplicate/unknown
   fields and stale generation. Stale receipts cannot publish; fresh malformed
   graphs remain protected. Roll a primary back to its original queued bytes
   after a committed left record: no reuse and no erasure of the exclusion.
7. Preserve all current migration/retirement/binding/cancellation/cleanup tests,
   generation-less legacy behavior and original/result hashes. Test older
   binary rejection of v4 and documented compatible rollback. Measure actual
   fresh-primary encoded maximum and metadata/index limits; limit overflow is
   explicit failure, never truncation.

## Review blockers and stop conditions

Independent review must resolve departure-intent orphan-start recovery, every
writer's migration interlock, trusted-reference validation without reintroducing
unbounded historical-body scans, and old-binary format refusal. These are real
persistence changes, not implementation details to improvise. The proposal does
not assert tests have run or the finite fixture has passed. If the complete
reference validation still dominates healthy eight-call progress, or migration
requires holding owners across calls, stop and revise before implementation.
