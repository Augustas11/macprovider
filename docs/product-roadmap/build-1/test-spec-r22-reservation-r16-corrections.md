# Build 1 reservation search progress — test specification R22

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. Governing candidate:
`reservation-search-progress-addendum-r16.md`.

Every result must be fresh. Skipped, timed-out, interrupted, zero-selected,
fixture-only, synthetic-only, or historical runs are not passing evidence for
a claim they do not execute. Production and independent test encoders may
share only frozen byte fixtures, never implementation helpers.

## R22-01 — exact input and baseline gate

Verify the recorded R15/R21/review digests and `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. Prove the current R4 source has no
selector v7, carrier graph, operation lease v4, root promotion, terminal abort
successor, or adoption ticket. Fail the test if historical passing evidence is
reported as execution of R16.

## R22-02 — acyclic R4-to-v7 bootstrap

Start from the actual current R4 disk graph for R=0,1,31,32,33,1,024. Run the
actual supported prior binary and require it to reject the mandatory v4 format
before write.

Inject death after every syscall and durable boundary for lock creation/fsync,
activation parent creation/fsync/identity capture, generation-zero selector
temp/write/fsync/rename/parent-fsync, journal-lock reacquisition, every old
graph/source/identity revalidation, format temp/write/fsync/rename/
`.retention-v2` fsync, carrier-directory mkdir/parent-fsync/reopen/empty-check/
identity capture, and revision-one selector publication.

Require exactly: pre-format death selects R4 and leaves only equal reusable
unselected bytes; post-format-fsync selects generation zero; post-revision-one
fsync selects the carrier-directory identity. Freeze the exact direct paths,
lock order, 4,096-byte scaffold charge, 4,096-byte carrier-directory charge,
and no double charge. Reject a selector without a parent, any claim that the
later step creates the activation parent, unexpected parent content, changed
identity, unequal candidate, wrong mode/owner/link/type, competing format,
missing selected carrier directory, old-binary mutation, or ordinary work
before bootstrap close.

Independently encode all R+1 budget insertions and the six carrier records.
Require the exact fixed allowance of 50 units: one selected scaffold unit, one
selected carrier-directory unit, and at most eight for each carrier record.
Then require complete phase, unchanged source witness, every entry selected,
exact consumed/released accounting, and zero unused bootstrap authority.

## R22-03 — durable lease and 64-edge boundary

Freeze independent JCS/digests for `leaseAuthorization.v2`, `budgetLease.v4`,
and `budget_entry.v3`. Reject any expiry, renewal, PID, owner, heartbeat, or
wall-clock field. Reserve exactly one lease; kill and restart a different
process after every selector/carrier boundary and require it to resume from the
selected transaction without rewriting authorization identity.

Execute 63-target-edge commit, 64-target-edge commit, 63-target-edge A1/A2
abort, and 64-target-edge A1/A2 abort, including all reserve continuations,
two selector revisions per target carrier, crash replays, close continuations,
terminal receipt, and terminal selector. Each completes with the same lease
digest and balanced counters. The 65th target edge rejects before creating a
temp, carrier, external object, or selector.

Race 64 helpers at each pending-intent and successor boundary. One advances;
the others converge or return typed busy/retry. Kill the winner while holding
the per-call flock and require OS release plus recovery by another process.
Reject stale base selector bytes, closed-lease reuse, transaction/category/
ordinal substitution, second open lease, target count replay, control work
charged as a target edge, or a flock/descriptor surviving a returned call.
Measure every call against eight seconds and four FDs.

## R22-04 — root promotion and addressability

Using an independent encoder, freeze one-carrier and two-carrier tree and
sequence mutations. The final receipt contains only the local target root and
promotion descriptor; the successor contains the promoted carrier-addressable
root. Recompute the carrier digest/identity, apply the exact promotion
function, and compare every root scalar and top record coordinate/digest.

Reject a local reference in any selector, activation, checkpoint, budget/path/
storage entry, sequence entry, or work record; local-forward reference;
promotion coordinate mismatch; changed root scalar/transcript; receipt with a
carrier digest for its own carrier; selector retaining the local root; missing
identity in the promoted reference; or any future-carrier dependency. Build a
field-level graph and require a topological order from base selector through
promoted successor with no cycle.

## R22-05 — standalone codec and taxonomy cross-products

Create a test-only RFC 8785/JCS implementation sharing no production encoder,
model, digest, base64url, framing, reference, tree, or state helper. Freeze
minimum/maximum literal vectors for every R16 section 6 record, tree page,
sequence entry, selector v7, pending transaction, edge intent, receipt,
continuation, root promotion, lease, budget entry, external descriptor,
identity, storage/path/lifecycle entry, bootstrap state, adoption ticket, and
terminal selector.

Generate unknown/duplicate/missing field, null, enum, non-NFC, padded base64,
uppercase hex, negative, float, `2^53-1`, `2^53`, wide overflow, wrong schema,
and reference-kind cross-products. Reject every R14 common envelope,
`transactionIntentID`, batch/MMR field, external run/page, storage-ordinal run
reference, digest-only page reference, and mixed codec version.

Generate the complete physical-class × object-kind × codec × path class ×
length/digest/null × identity × storage/path-index matrix. Accept exactly the
R16 table. Specifically reject an adopted artifact as an external publication
target, catalog record outside a carrier, external intent/run/page/work root,
regular object without length/digest/identity, directory with content bytes,
protocol objects in ordinary indexes, and ambiguous capture/merge row block.

Prove all record/page/selector/intent bounds, 16 records per carrier, 14 tree
pages per carrier, 17 pages/two carriers per mutation, B+ split/fanout/height
limits, four FDs, complete-carrier hashing, and safe ordinal parsing.

## R22-06 — independently generated transition graph and capacity

Write an independent state-machine generator from the literal semantic A0–A8,
capture, merge, tree, verification, retry, and recovery rules rather than from
production transition tables. Compare the exact named sets and order with
production.

Require row counts 16,32,16,12,34,64 and fixed counts 32,64,32,32,32,128.
Require every A3/A4 and four A5 intent/publication/storage/path/durable edge,
prepared adoption/index edges, lifecycle/binding edges, A6/A7/A8 phase records,
reserve/close continuation, and terminal selector. Omission or fusion of a
phase publication fails.

Independently derive:

```text
row ordinary = 3,306; row control = 6,612
fixed ordinary = 6,080; fixed control = 12,160
units(R) = 9,937R + 18,309
Rmax = 453,215,218,612
units(Rmax) = 4,503,599,627,365,753
carrierCount(R) <= 1,046R + 1,928
carrierCount(Rmax) = 474,063,118,670,080
units(1024) = 10,193,797
carrierCount(1024) <= 1,073,032
```

Exercise R=0,1,31,32,33,1,024, Rmax, Rmax+1 with checked wide arithmetic.
Sparse Rmax proves codec arithmetic only. Require exact candidate byte
preflight including both directory charges, phase records, carrier rounding,
adoption transfer, lifecycle reserve, quota, Wpeak, and Uafter. Reject the
first over-limit transition/unit/byte/edge, unknown numeric state, ninth retry,
unsafe host `off_t`, quota, inode, free-space, or product row >1,024 before v7
selection.

## R22-07 — terminal abort and A3–A8 economics

For classified and unclassified provenance, inject cancellation, permanent
failure, and death at every A1/A2 eight-slot boundary, every carrier fsync,
carrier-directory fsync, terminal selector temp/fsync/rename/directory-fsync,
and immediately before/after pending becomes null.

Require the immutable abort receipt to list exactly completed slots 0–6. The
slot-7 carrier successor atomically selects the receipt, A8 outcome, promoted
closed budget root, cleared lease digest, exact released/spent/abandoned
counters, and null pending. Slot 4 must leave the prior ordinary budget root
and closing lease selected; slot 6 records proposed A8 without making it the
selected terminal state. Before the slot-7
directory fsync, recovery resumes from pending plus absent/exact carrier; after
it, cancellation is stable. Reject a receipt claiming pending-clear or slot 7
complete, a ninth slot, a later selector-only clear, success before null pending/FD/flock
closure, double release/close, or protected-to-aborted conversion.

Run exhaustive A3, A4, each ordered A5 intent/durable suffix, and A6
cancellation/failure matrices. Every case must resume the byte-exact forward
path or protect, retain the full admitted 581,632/696,320 economic charge as
governed, perform A4 4,096 transfer once, preserve A5 receipt ordering, and
perform A6 spent-slack transfer once. No post-A3 refund, available lifecycle,
retained-abandoned result, hidden path, old-root rollback, or selected-object
deletion is legal. Verify typed `cancelled_after_commit` exposes activation and
retained charge truthfully. A1/A2 alone use the inherited abort/refund vectors.

## R22-08 — actual prepared-artifact adoption

Use the production `DurableModelArtifactStore` preparation path to build the
actual supported Build 1 artifact on the physical Mac from the signed catalog
identity. Record model, release, signed digest, artifact bytes/files, hardware,
OS/runtime/filesystem, preparation duration, cancellation checks, canonical
hash, publication fsync, seal, ticket, and preparation receipt. A small fixture
cannot satisfy this case.

Freeze and independently validate the 65,536-byte-bounded adoption ticket and
its domain-separated digest. During reservation adoption, prove there is no
payload open/read/hash/copy/fsync/rename or artifact-directory enumeration.
Only ticket, seal, root identity, preparation receipt, carrier, and direct B+
paths may be read. Six cold runs must report p95 <=8 seconds, <=4 FDs, ticket/
seal bytes, pages/carriers opened and hashed, fsync duration, RSS, and exact
selected charge.

Inject cancellation and death before pending intent, after intent, after
adoption record/page/receipt/carrier boundaries, and after terminal selector.
The inactive durable artifact is preserved before selection; post-A3 work
finishes forward. Replace or mutate ticket, seal, root path/identity,
transaction/model/release/hash, preparation receipt, or catalog digest and
require rejection before pending selection. Mutate a sealed artifact entry and
require MLX pre-open seal validation to block serving and protect binding.

If the actual supported artifact or metadata path misses the eight-second
reservation bound, report physical qualification blocked. Do not substitute a
fixture, raise the limit, or count preparation time as reservation latency.

## R22-09 — crash, compatibility, audit, and observability matrices

For every legal edge, inject death after selector temp create/write/fsync/
rename/directory-fsync; carrier temp/header/slot/file-fsync/exclusive-rename/
directory-fsync/reopen/hash; external bounded object temp/write/fsync/rename/
directory-fsync/identity; directory mkdir/fsync/reopen; and successor
publication. Require old/pending/successor authority exactly. Unequal candidate,
identity drift, stale predecessor, receipt mismatch, tail `head+2`, selected
carrier loss, or charge mismatch protects. Never enumerate history, delete a
selected carrier, or truncate a tail.

Run direct current lookup at heights 1–8 and require <=8 pages, <=8 carriers,
<=8,459,040 hashed bytes, and <=4 FDs. Run historical audit separately at at
most eight carriers or eight seconds per invocation. A new head cannot widen a
frozen audit snapshot. Missing/mutated history protects only when reached; no
unvisited historical carrier is claimed verified.

Old binaries reject selector v7 without mutation. New binaries reject mixed
v1–v6/v7 graphs, R14/R15 codecs, expiry leases, local selected roots, external
artifact publication, retained-abandoned post-A3 state, incompatible receipts,
unknown fields/versions, and partial translation. Every byte-valid pending v7
state must commit, legally abort, resume forward, or protect.

Observability reports selector revision, carrier head/audit cursor, transaction
and edge ordinal, phase, lease/category remaining units/bytes, bootstrap
progress, adoption ticket/seal identity, cancellation disposition, terminal
outcome, and protection reason. It never calls preverified adoption a current
payload rehash or reservation evidence admission/settlement proof.

## R22-10 — verification and independent audit gate

Run targeted Swift tests, full `swift test`, Malibu Xcode tests, CLI/app bridge,
governance, compatibility, maximum-shape, and the physical prepared-artifact
adoption case. Report selected test counts, commands, duration, failures,
skips, timeouts, hardware, and fixture/real-service boundaries.

Review the complete implementation diff independently through native GPT-5.6
Sol code, security, and architecture lanes. Required gate is zero Critical,
High, and Medium findings in all lanes. Any architecture, contract, scope, or
test-strategy change reopens the plan gate.

Acceptance separates implementation completion, fresh local verification,
physical Mac verification, signed-feed/release verification, deployed services,
and production qualification. The real signed-feed→trusted preparation→valid
admission→actual MLX→correct settlement journey remains blocked until executed.
Reservation tests, deterministic fixtures, and preparation assertions cannot
be reported as that journey.
