# Reservation search progress — corrective addendum R5

Date: 2026-09-10. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This document authorizes no runtime or test change.

This proposal corrects the frozen R4 implementation reviewed against
`reservation-search-progress-addendum-r4.md`, SHA-256
`3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21`.
It is paired with `test-spec-r11-reservation-r5-corrections.md`. Independent
review of both exact documents is required before implementation. After
implementation, the complete replacement diff still requires independent code,
security, and architecture audits with zero Critical, High, or Medium findings.

The frozen audits are:

| Audit | SHA-256 | Result |
|---|---|---|
| `reviews/reservation-r4-code-audit-sol.md` | `db50512be6b61a9dc509a5add0d7987bb0d8b69eeb8130cd0f2381cfab77f112` | FAIL: 0C/2H/4M |
| `reviews/reservation-r4-security-audit-sol.md` | `c07a7034ed92b9734bc07b8bd4a106cd8aa47e3c05d0ad1d6185b85bad673ec7` | FAIL: 0C/2H/2M |
| `reviews/reservation-r4-architecture-audit-sol.md` | `1250819d1d24351abe55fca163bcfdf962ccd4d403b7810b78de8a9920d25c4e` | BLOCKED: 0C/3H/2M |

The current six source files still match the frozen implementation manifest in
`implementation-reservation-r4.md`. The defects below are therefore current
source defects, not dispositions inferred from a later implementation.

## 1. Scope and retained R4 contract

R5 replaces only the defective executable details identified by the three R4
audits. Every other R4 invariant remains mandatory. In particular:

- The existing mandatory-format v3 fence and active-index v4 remain the only
  cutover and allocation roots. No second index, allocation authority, mutable
  absence cache, per-authority slot, or migration cursor becomes reusable
  authority.
- Origin equality remains exact. An allocated origin retains its UUID,
  operation generation, kind, created time, target, model key, revision,
  artifact and candidate digests, signer key, and initial-primary digest. A
  tuple digest never substitutes for exact field comparison.
- Primary-first departure remains mandatory. The real first started,
  cancelled, terminal, committed, cleanup, or migrated-nonreusable primary is
  durable before its immutable left exclusion. Recovery never synthesizes or
  replays a start, worker launch, heartbeat, success, or terminal transition.
- Classifying and finalizing retain frozen membership. Complete phase permits
  only the already specified fresh allocation and validated retirement
  transitions. Legacy and protected origins never gain allocated identity or
  reuse eligibility.
- Every format remains closed and canonical, with duplicate and unknown keys
  rejected. Existing owner, mode, regular-file, link-count, `O_NOFOLLOW`,
  directory binding, size, SHA-256, exclusive-create, fsync, and direct-path
  rules remain mandatory. Immutable reservation evidence is retained forever.
- The active limit remains 1,024, the active-index and migration-document limit
  remains 1,048,576 bytes, a primary remains accepted up to 4,194,304 bytes,
  and a record remains accepted up to 2,048 events. R5 introduces no smaller
  record, origin, class, left, or input limit and no new dependency.
- One incoming `ModelTransactionWorkBudget` governs the whole call. The
  existing eight-second transaction deadline, heartbeat/watchdog rules, and
  outer owned-catalog deadlines are not raised or renewed.

The implementation owner must change only the existing reservation authority,
retention, transaction-evidence, and transaction-control seams needed for this
correction. The test owner may extend only the existing Swift transaction,
retention, reservation-migration, catalog-read, bridge, and purpose-built
fixture suites. Release, coordinator, gateway, economics, admission, and SPEC
behavior are out of scope. Shared files are integrated by one owner at a time;
no lane may overwrite unrelated Build 1 work already present in the worktree.

## 2. Finding-to-correction closure

| Corrective contract | Frozen findings closed |
|---|---|
| Bounded sequential owner fence and bounded detached graph witnesses | R4-CODE-H1; architecture H2 |
| Globally blocking unresolved allocation result and exact allocation-generation equality | R4-CODE-H2; R4-SEC-H2 |
| One all-member phase validator used before every mutation | R4-CODE-M1; R4-CODE-M2; architecture H1 |
| Same-owner pending-publication stabilization plus departed-primary rollback rejection | R4-CODE-M3; R4-SEC-H1; architecture M2 |
| Content-addressed completed-install anchor and exact historical graph | R4-SEC-M1; architecture H1 |
| Authenticated publication predecessor index/progress and legal monotonic merge | R4-SEC-M2 |
| Typed busy for queued cancellation without owner custody | architecture M1 |
| Full R11 qualification matrix and fresh combined evidence | R4-CODE-M4; architecture H3 |

No finding is closed by a test alone. No implementation claim is accepted from
aggregate test counts without the exact adversarial and capacity evidence in
the paired test specification.

## 3. Bounded descriptor ownership and the prior-binary fence

Remove both descriptor-proportional shapes from the frozen implementation:

1. Cutover must not retain an array of 1,024
   `ModelTransactionNoncreatingOwnerProbe` objects.
2. Classification finalization and completed-graph capture must not retain an
   array of per-member `ModelTransactionFileEvidence` objects. Origin, class,
   and left descriptors must close before the next member is opened.

### 3.1 Sequential cutover owner fence

Run pre-v4 allocation recovery first under R4's absence-specific table. Any
unresolved entry stops activation as section 5 specifies. Capture the candidate
source and exact index/format receipt outside the journal lock. Then acquire the
journal lock nonblocking and retain it through the complete owner sweep and the
source/format/progress/v4-index publication bundle.

While that journal lock is held, recapture the exact old format and active index
and require only fully active entries with unchanged membership, generation,
origin refs, and binding lineage. Visit sorted UUIDs one at a time. For each:

- inspect the owner path without `O_CREAT` and without directory enumeration;
- if absent, validate exact absence and continue;
- if present, open that exact safe inode, take its exclusive flock nonblocking,
  validate placement/type/link/mode/owner and stable inode evidence, then unlock
  and close it before visiting the next UUID;
- on busy, unsafe, changed, deadline, or descriptor exhaustion, close the local
  descriptor exactly once, release the journal lock, and return the existing
  typed bounded unavailable/busy result without publishing source, format,
  progress, or index authority.

This reverse lock observation is nonblocking, so it cannot deadlock with the
normal owner-before-journal mutation order. A writer that already owns a UUID
makes that probe busy. A compatible old writer that acquires or creates an owner
after its UUID was checked cannot acquire the journal lock before the fence is
durable. When it later reaches its mandatory final locked format validation, it
must reject v3 before changing primary, sidecar, binding, result, seal, index, or
heartbeat bytes. A writer already inside the journal lock prevents cutover from
starting. No cutover path creates or removes an owner inode, terminates a
healthy owner, or treats an absent owner as permanent negative authority.

This proof is valid only for an actual prior binary whose every production
mutation route performs the final mandatory-format validation under the journal
lock. Freeze the exact minimum supported prior binary before changing source,
record source and executable SHA-256 values, and exercise every named writer.
A binary lacking the fence is unsupported for concurrent upgrade and blocks
release; R5 does not authorize a bridge release or operational exception.

### 3.2 Detached all-member witnesses

Introduce one internal detached reservation witness representation containing
only closed decoded identities, byte digests, file placement/metadata identity,
and the exact entry/source/progress relationship. It owns no file descriptor
and no primary body. Build the witness graph sequentially outside the journal
lock: open, strictly read, hash, and close each required origin/class/left and
root document before advancing. At the final locked CAS, re-open and revalidate
each named item sequentially against its detached identity and close it before
the next open. Only small reservation metadata is revalidated; acknowledged
4 MiB primaries are never reread to re-prove a classification.

All reservation correction routines must use a constant descriptor bound
independent of entry count. The implementation report must state the calculated
maximum number of reservation-owned live descriptors for each phase. Under a
real soft `RLIMIT_NOFILE` of 256, the 1,024-owner cut and the largest completed
origin/class/left graph must finish without `EMFILE`; observed total process
descriptors must remain below 256. Injected `EMFILE` must release every local
descriptor/flock and leave all durable bytes unchanged. Retry after releasing
the injected pressure must succeed without raising the soft or hard limit.

## 4. One closed reservation authority graph before mutation

Replace the phase-local and requested-UUID-only checks with one
`capture/validateReservationGraph` contract. Every production writer listed in
R4, allocation recovery, reservation search, cancellation/status, retirement,
catalog quick/verify journal work, migration progress, finalizing recovery, and
complete-phase mutation must obtain the appropriate graph receipt before its
first mutation and revalidate it under its final journal CAS.

### 4.1 Classifying

The validator requires the current index membership to equal the exact frozen
source membership and validates every source member, not merely the caller's
UUID. It validates exact reservation migration/source IDs and hashes, source
index generation/hash, binding-migration completion lineage, progress source
and generation, derived prefix, and every origin provenance/generation.

For every source member, enforce the R4 phase matrix against the complete
acknowledgment map:

- an unclassified member has null class/left refs, no acknowledgment, no
  referenced publication, and no retained unreferenced class/left file that can
  be mistaken for absence;
- a pending first-class or first-left publication validates the exact direct
  receipt and the predecessor rules in section 6; any already durable next file
  must equal the receipt;
- an acknowledged member's index class and optional left equal the progress map
  exactly, including members beyond the prefix, and every named origin, class,
  and left file is present and validates;
- a pending receipt may only add its frozen first class or first left. It cannot
  remove or replace an acknowledgment, change origin, mutate primary, or relax
  another member;
- legacy/protected members cannot carry allocated generation or left evidence;
  allocating entries remain forbidden.

Any mismatch in any UUID makes the graph protected before a healthy different
UUID can write. Validation must not acquire unrelated owners or finish their
pending work.

### 4.2 Finalizing

Before publishing finalizing, require: full derived prefix; one exact
acknowledgment for every source member; no pending receipt; exact equality of
source, progress, prepared index, completed projection, origin/class/left refs,
and binding refs; and the content-addressed install relationship in section 4.3.

`recoverReservationFinalizing` must perform that same complete read-only graph
capture before writing complete bytes. Deletion, substitution, same-byte new
inode, in-place mutation, phase/generation mismatch, prepared-index mismatch,
or source/progress/binding mismatch stops recovery with the finalizing index
byte-identical. Validation after the write is additional confirmation and can
never be the first lineage check.

### 4.3 Complete and the install digest anchor

Remove the unauthenticated UUID-only install lookup and the cyclic notion that
an install receipt must hash exact index bytes that themselves contain the
receipt hash. Use these closed artifacts:

- `model_catalog_reservation_completed_projection.v1`, bounded by the existing
  index limit, contains the planned completed generation, exact frozen entries,
  binding refs, migration/source/progress lineage, install UUID, and phase
  fields. It intentionally has no install-receipt digest field. Store it at a
  direct content-addressed path beneath the install UUID.
- `model_catalog_reservation_install.v2`, bounded by 16,384 bytes, contains the
  install UUID; exact source and completed-progress hashes; binding completion
  identity; prepared-index hash and generation; finalizing and completed
  generations; and the completed-projection SHA-256. Encode and hash it, publish
  it exclusive-create at
  `installs/<installUUID>/<installSHA256>.json`, and retain that exact
  `installSHA256` in both finalizing and every later complete active index.
- The complete index is derived from the validated completed projection plus
  that install digest. The projection hash is computed over its own closed
  schema, so there is no hash cycle. Finalizing and first-complete entries and
  binding refs are identical; only the permitted phase and generation fields
  differ.

Complete validation opens the index-named install file directly, checks its byte
digest and repeated UUID, then opens the projection by its digest. It proves the
projection equals the exact source membership and complete progress map, and it
validates every historical source origin/class/left file. It checks the
prepared-index hash and exact generation sequence, source and progress hashes,
binding lineage, finalizing/complete relationship, and the current index's
retained install digest. Replacing both UUID-named files cannot establish new
authority because the active index retains the content digest.

After completion, historical source/progress/projection/install bytes remain
immutable. Current dynamic membership is validated separately: original source
members may be retired but their historical evidence remains; new members must
have allocated v4 provenance and exact class authority; no legacy/protected
member can be introduced; departed left evidence is monotonic; binding refs may
advance only through their existing validated lineage. Every complete-phase
mutation validates both the closed historical graph and the current dynamic
graph before writing.

## 5. Allocation recovery is a global gate

`recoverAllocations` must return or throw a typed result for every allocating
entry: exactly completed, exactly removed by the all-absent row, busy,
protected/unsafe, changed, capacity, or budget exhausted. It may not swallow an
error and continue as though search absence were established.

After recovery, recapture the index and require every entry to be active before
candidate search. Repeat the all-active invariant under the final fresh-
allocation journal CAS. If any allocating entry remains, no request may search
past it or create a UUID, primary, origin, class, owner, sidecar, receipt
directory, predecessor file, or index member. This is global even when the
unresolved entry's bytes cannot be decoded into a caller tuple.

For an exact suffix completion, require `allocatedGeneration` to equal both the
decoded primary selector generation and the allocation generation in the exact
origin. Primary, origin, and class must also equal all frozen hashes and fields.
Mismatch is protected and preserves the allocating intent. R4's all-absent
removal and ordered exact-suffix table otherwise remain unchanged.

## 6. Authenticated publication predecessors and monotonic recovery

The existing `oldIndexSHA256` and `previousProgressSHA256` receipt members must
become enforced authority. Before publishing a reservation-publication receipt,
persist the exact captured predecessor index and progress bytes, exclusive-create
and fsync, at direct content-addressed paths:

```text
.reservation-migration/predecessors/index/<oldIndexSHA256>.json
.reservation-migration/predecessors/progress/<previousProgressSHA256>.json
```

Each file uses the existing corresponding closed schema and size limit. The
receipt binds both hashes, the target UUID and origin, the exact old generation,
source/migration lineage, original primary, frozen next class/left bytes, and
next refs. A path is derived only from the validated lowercase digest. No
directory enumeration or caller-provided locator is permitted. Predecessors and
unreferenced prepared receipts remain immutable retained history.

Recovery must:

1. open and hash the exact predecessor files named by the receipt;
2. prove the receipt's old index is a valid graph and contains the same target
   entry/origin/class/left state from which this publication is allowed;
3. derive the exact immediate intent successor: generation increments once,
   only the target entry gains this receipt digest, and every other index field,
   entry, pending receipt, and binding ref is preserved;
4. require the current index either to equal that immediate successor or to be
   a legal validated monotonic descendant that still carries the same target
   receipt and identity; and
5. require current progress either to equal the exact predecessor or to be a
   proven monotonic merge: identical lineage, greater generation, every old
   acknowledgment preserved byte-for-byte, derived prefix correct, and every
   added class/left acknowledgment authorized by that member's valid current or
   completed pending publication and exact durable files.

One pending UUID never relaxes progress validation for another. Recovery may
add only the target receipt's missing acknowledgment or finish only its exact
entry refs, preserving simultaneous unrelated pending receipts, acknowledgments,
binding changes, and legal current generations. An altered predecessor hash,
cross-UUID receipt, replayed old generation, removed acknowledgment, changed
class/left, or unexplained current delta is protected before mutation.

## 7. Departure, control, reservation, and retirement interlocks

Create one affected-UUID stabilization rule used by `captureActiveReceipt`,
`run`, status/check, cancel, reservation search, cleanup reservation, and
retirement:

1. inspect the current entry for `reservationPublication`;
2. if present, obtain or reuse that exact UUID owner nonblocking;
3. call publication recovery with the same `heldOwner`, never reacquire the
   owner's flock from inside the helper;
4. recapture the index and primary after recovery, then restart the decision
   from the refreshed graph; and
5. if custody is busy or frozen evidence cannot validate, return typed
   busy/protected and perform no ordinary decision or mutation.

After stabilization, an allocated entry with an anchored left is permanently
nonreusable. If its current primary again satisfies the immutable initial-queued
record or equals the origin's initial-primary digest, treat the journal as
rolled back and fail protected. Do not return the UUID as reusable, run it,
report it as an ordinary queued record, cancel it as fresh work, or allocate a
replacement. For a pending first-left receipt, current primary must still equal
the receipt's first observed nonreusable primary while recovery completes. A
rollback to queued bytes is protected; the pending receipt is never ignored or
rebased from current primary content.

Reservation search must stabilize a potentially matching entry before using it.
A pending or busy possible candidate prevents a negative result and new
allocation. It must not take the owner and then call a helper that tries a
second flock.

`retireOne` obtains the UUID owner, stabilizes any pending publication with that
same owner, recaptures and validates the full graph, and only then evaluates
expiry/terminal truth and constructs retirement evidence. Failure preserves
membership and the pending reference. Retirement cannot strand or discard a
receipt, class, left, progress acknowledgment, or predecessor link.

For queued cancellation, after a failed owner acquisition recapture the current
record and graph. If cancellation was requested and the record is still queued
or has reservation metadata intent, throw the existing typed
`ModelCatalogTransactionError.busy`. Returning the unchanged record as a
successful cancellation response is forbidden. The existing started-primary
live-owner cancel-request route remains valid only after required departure
metadata is complete.

## 8. Order of implementation

Implementation must proceed in this dependency order:

1. Freeze the actual supported prior binary and its source/executable manifest.
   Add test-only FD, open/flock/close, body-read/decode, durable-boundary, child,
   worker-launch, and index/progress publication counters and barriers.
2. Add closed predecessor, completed-projection, and install-v2 codecs/path
   validation. Add strict round-trip, size-envelope, unknown/duplicate-field,
   direct-open, and collision tests before using the formats.
3. Replace retained descriptor arrays with the sequential owner fence and
   detached all-member witness validator. Route classifying, finalizing, and
   complete captures through it before mutation.
4. Enforce predecessor lineage in publication recovery and the
   content-addressed install anchor in finalization/completion.
5. Make allocation recovery globally typed and blocking, including exact
   allocation-generation equality.
6. Add affected-UUID stabilization, rolled-back-departure rejection, queued
   cancel busy, and retirement pending-intent recovery across every production
   caller.
7. Execute the complete paired R11 matrix, then the broader unchanged Swift and
   Build 1 gates against one frozen final source manifest.

Do not combine a schema writer with readers that still accept the old weak
relationship. Until steps 2–6 land together, the candidate remains an
unshippable development state. Crash recovery always completes forward from
the exact content-addressed evidence or fails protected; it never deletes,
rebases, fabricates, or downgrades R4 authority.

## 9. Budget, availability, and crash rules

- All capture, stabilization, allocation recovery, graph validation, catalog
  composition, and publication helpers receive the caller's existing budget.
  No nested `.init()`, default deadline, or retry loop renews it.
- Bulk class/left/origin/predecessor reads and decoding occur outside the
  journal lock. The final locked phase performs bounded direct metadata/identity
  revalidation and sequential nonblocking owner probes only. No primary body is
  read under the journal lock.
- Check the same budget before and after each bounded read, each owner probe,
  every exclusive-create/fsync, progress/index write, and final recapture. Once
  a durable intent exists, expiration returns interrupted/busy with that intent
  retained for exact recovery; it never starts a generic fresh allocation.
- Cutover and each ordinary transaction attempt retain the existing eight-second
  maximum. A max-shape migration may advance over several calls. Previously
  acknowledged classification bodies are not reread on later calls.
- Descriptor exhaustion, busy owner, changed CAS, or budget exhaustion before a
  write leaves exact bytes unchanged. After a write, only the specified ordered
  suffix recovery may advance. Every thrown and real-death boundary must converge
  to the same outcome.
- Recovery never launches a child, acknowledges a heartbeat/success, creates an
  owner for allocation, removes immutable evidence, or uses a migration cursor,
  progress prefix, install digest, or predecessor snapshot as search absence.

## 10. Acceptance and stop conditions

R5 implementation is eligible for a new frozen audit only when all of the
following are true:

1. Every row in `test-spec-r11-reservation-r5-corrections.md` passes against one
   unchanged source manifest, with commands, selected/pass/fail/skip counts,
   duration, relevant measurements, and SHA-256 of durable logs/artifacts.
2. A soft limit of 256 supports the exact 1,024-owner cut and 1,024-member
   maximum graph below that limit. Injected `EMFILE` proves cleanup and an
   unchanged retry. No test raises the limit.
3. Actual prior binaries prove every final mutation fence at all required
   phases. Any unsupported writer blocks release.
4. The exact 1,024 × 4 MiB × 2,048-event fixture proves incremental progress,
   plausible candidate last, original budgets, and zero rereads of acknowledged
   primary bodies.
5. Every unresolved allocation state globally blocks search/allocation; every
   rolled-back departed or pending-departure state fails closed; queued cancel
   returns typed busy while its owner is busy; and retirement never drops
   unresolved reservation metadata.
6. Classifying, finalizing, and complete mutation attempts fail before changing
   bytes when any source member, progress acknowledgment, origin/class/left,
   predecessor, install/projection, binding lineage, or current dynamic entry is
   deleted, substituted, or inconsistent.
7. Publication recovery proves the old-index and prior-progress hashes, including
   simultaneous cross-UUID pending work and monotonic progress merges.
8. Fresh owned catalog quick, verify, and concurrency cases prove no wrapper
   bypass, false empty recovery, budget renewal, lost durable progress, or
   mutation after a protected graph result.
9. Targeted suites, package-wide `swift test`, applicable Build 1 catalog bridge
   and compatibility suites, and the repository's required broader gates pass.
10. Fresh independent code, security, and architecture reviews of the complete
    final diff each report zero Critical, High, and Medium findings.

Any missing required fixture, process death replaced only by a thrown error,
raised FD/deadline limit, stale result reused from R4, unverified prior binary,
aggregate-only test report, interrupted/skipped command represented as passing,
or known mutation route outside the graph/stabilization inventory is a stop.
Physical MLX, signed release/feed, deployment, enforcement, settlement, and
economic activation remain outside this proposal and are not qualified by it.
