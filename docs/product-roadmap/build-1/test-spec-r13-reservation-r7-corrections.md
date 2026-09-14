# Build 1 test specification R13 — reservation R7 corrections

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This specification pairs with
`reservation-search-progress-addendum-r7.md`. It corrects the four High
findings from the R6 plan gate and retains every applicable R4, R11, and R12
case. No test result or implementation approval is claimed.

All cases use production codecs and entrypoints against one frozen final
source/test manifest. Every result records command, base/head SHA, selected/
pass/fail/skip counts, duration, soft/hard FD limits, quota/free-space values,
relevant counters, and SHA-256 of the complete log and fixture manifest. A real
child `_exit` case is separate from every injected thrown-error case.

## R13-01 — closed projection-v2 and aggregate-root schemas

Exercise active-index v5, state-projection v2, capacity objects, retirement
leaves/nodes/roots, retirement v2, predecessor v2, lineage v1, completed
projection, and install v2. For each require canonical minimum, maximum,
exact-at-limit, and one-byte-over behavior; duplicate/unknown/missing/null/
wrong-type fields; unsafe UInt64; unsorted/duplicate/overlapping rows or ranges;
bad UUID/digest/generation/state/kind/count/height/slot; path traversal;
cross-UUID locator; and trailing data.

Encode 1,024 maximum-field rows with all publications pending, all three
capacity tranches present, both shared admissions at their legal maximum, and
maximum retirement-root envelopes. Active index and projection must each stay
at or below 1,048,576 bytes without truncating an inherited valid field.
Independently recompute row, capacity, retirement, and aggregate roots. Reject
one-bit leaf, order, ordinal, padding, count, domain, shared-admission, quota,
retirement-root, projection, or selected-slot changes.

Crash/fail before and after inactive-slot write, file fsync, rename, directory
fsync, final CAS, and active-index selection. Restart selects exactly the old or
new digest-valid pair. An unselected slot is never authority and a selected slot
cannot be overwritten.

## R13-02 — full genesis and phase-transition validation

Construct the complete maximum R5 historical graph: 1,024 source members,
acknowledgments beyond prefix, simultaneous pending publications, binding
lineage, completed projection/install, origins/classes/lefts, and paged v1
retirement history. Derive genesis-v2 independently and require byte equality
for every row/root/capacity field. Change or omit each member/body/root in turn,
add an unreferenced direct class/left/retired contradiction, or change the graph
during final CAS. Genesis must fail before selecting v2.

For classifying-to-finalizing and finalizing-to-complete, put the corrupt or
missing body at UUID first, middle, and last. Require sequential full validation,
authenticated checkpoint binding to one unchanged aggregate root, no phase
publication before all 1,024 rows validate, and restart from only a valid
checkpoint. A changed aggregate root invalidates prior validation progress.
Deletion, substitution, extra direct body, pending row, incomplete
acknowledgment, or changed source/progress/install/binding/retirement root leaves
the selected pair byte-identical.

## R13-03 — inductive transition theorem and bounded operation-local reads

For every transition-table row in R7 section 2.2, generate the legal immediate
successor and require acceptance. Mutate each target field, each shared field,
one unrelated row, two rows, generation, root, capacity tranche, progress,
retirement root, or install identity and require rejection before the first
write. Replay every predecessor and legal-looking old successor. Require one
exact generation increment and byte-for-byte non-target rows.

Build exactly 1,024 legal simultaneous pending rows with maximum receipts,
predecessors, and lineage. Exercise heartbeat, status, queued/live cancel,
generic commit, run capture, reserve/search, allocation recovery, cleanup,
publication recovery, and retirement for UUID first/middle/last. Each ordinary
call opens/decodes one active index, one projection, and at most one progress;
opens zero unrelated body/owner/primary files; performs at most ten reservation
direct opens, four live reservation descriptors, 1,024 row encodings and one
aggregate-root computation; and finishes below the unchanged eight seconds.
Record the exact reservation body-byte count and fail if it exceeds R6's
3,383,296-byte ceiling. No helper creates a new budget.

Delete/corrupt A's named detached body while B heartbeats, cancels, commits,
publishes, and reserves. B must preserve A's exact row and succeed without
opening/flocking A. B may not treat A as absent or change its roots. Direct use,
recovery, or retirement of A returns protected with zero mutation. Repeat with
an extra unreferenced A class/left body: it supplies neither reusable nor
negative authority and blocks A. Restore the exact bytes before a new capture
and require A to recover. Repeat all corruptions during each full phase
transition and require the global transition to fail. This proves the explicit
replacement of R5's unrelated-body failure rule without weakening target truth.

## R13-04 — absent-target allocation capacity state

At an empty eligible slot, deterministically compute the allocation operation
UUID, proposed transaction UUID, generation, tuple, initial primary, origin,
class, and genesis-lineage digests. Fail quota/free-space admission and assert
zero new row, UUID, file, directory, or charge. Admit capacity and assert one
top-level `reserved` admission, increased charge, no active row, and no detached
allocation object.

Retry the same operation UUID/digests concurrently and sequentially: it returns
or resumes exactly one admission and charges once. Same operation UUID with one
changed digest is protected; a different operation is typed busy by the global
allocation gate. Ordinary unrelated heartbeat/control remains available.
Transition to `materializing`, add the exact allocating row, and then publish
primary → origin → class → genesis lineage → active/consumed state. At every
arrow inject changed CAS, deadline, EMFILE, ENOSPC, EDQUOT, thrown error, and
real death. Recovery chooses no new UUID/bytes and never launches work.

Cover the all-absent suffix before and after the materializing CAS. Only the
pre-body exact all-absent state may remove the reserved admission and subtract
its one charge atomically. Any body/directory/row successor makes refund
illegal. Repeat crashes before/after refund and prove exactly one outcome,
without a negative candidate result until allocation recovery finishes. Verify
allocated generation equals allocating row, primary selector, and origin.

## R13-05 — tranche consumption, refund, and idempotency

For migrated and post-complete members, exercise each tranche through
`reserved → materializing → consumed`. Publication must bind the capacity ID in
predecessor, receipt, pending row, lineage, and settled row. Retirement must
bind it in v2, publish the new v2 root, mark consumed, then remove membership in
a distinct CAS. Inject every durable-boundary failure and real death.

On restart, an exact consumed tranche is not charged again; a materializing
tranche resumes only its suffix; a reserved tranche has no object unless the
specified intent exists. Changed owner, kind, amount, object digest,
materialized charge, or state regression is protected. After row removal, the
v2 certificate/tree proves idempotent retirement. Assert no refund for
publication, retirement, consumed allocation, or any reservation with one
materialized byte. Concurrent UUID A and B publications consume only their own
tranches and preserve both rows.

## R13-06 — exact quota arithmetic and maximum bundles

Independently implement the specification formula in test code, without calling
the production accounting helper. At 4,096 boundaries and one byte on either
side verify `F(M)` and `D`. Inventory every direct in-scope file and directory,
including active index, two state slots, source, progress, origin, class, left,
predecessor, receipt, lineage, completed projection, install, v1/v2 retirement
certificate, every retirement leaf/node/root, and every per-UUID directory.
Unknown, unsafe, hard-linked, symlinked, wrong-owner/mode, oversized, colliding,
or unverifiable objects block activation rather than disappearing from the sum.

Require these exact minimum file charges:

| Bundle | Exact charge |
|---|---:|
| class predecessor + receipt + lineage + class | 204,800 |
| left predecessor + receipt + lineage + left | 188,416 |
| allocation origin + class + genesis lineage | 77,824 |
| retirement-v2 certificate | 69,632 |
| completed projection + install | 1,073,152 |
| active index + two state slots | 3,158,016 |

Require directory-inclusive post-complete lifecycle reserve exactly 352,256
bytes and unclassified source closure exactly 466,944 bytes. Exercise combined
first-class-and-left materialization and prove its unused conservative reserve
becomes `spentSlackBytes`, not reusable capacity. For every state independently
sum disk materialization and tranches and require:

```text
materialized + reservedRemaining + spentSlack == charged
charged <= quota
```

Use a normal history below 1 GiB, exactly-at-1-GiB charge, and a valid paged v1
history whose activation inventory exceeds 1 GiB. Require quota
`roundUp4096(max(1 GiB, activation materialized + reserve + finalization))`.
The large legacy history activates without a 1 MiB manifest overflow, but no new
lifecycle is admitted unless its full reserve fits the frozen quota. Repeated
allocate/depart/retire churn stops before the next 352,256-byte lifecycle; the
last admitted lifecycle closes and charged bytes never decrease.

After every durable boundary, walk the fixture and independently assert that no
retained authority or outstanding reserve lies outside the equation. No source,
progress, predecessor, receipt, lineage, origin, class, left, install,
projection, retirement certificate/page/root, or charge record is deleted or
compacted to manufacture capacity.

## R13-07 — free-space formula and storage faults

For immutable exclusive create and mutable state/index replacement, measure
production `Wpeak`. Set available capacity one byte below, exactly at, and one
byte above `536,870,912 + Wpeak + Uafter`. Require exact reject/accept behavior.
Demonstrate that the current write's permanent charge is removed from Uafter and
is counted once, while every other outstanding closure remains reserved.

Inject ENOSPC/EDQUOT before and after create, write, fsync, rename, directory
fsync, slot publication, index selection, admission, pending row, class, left,
progress, lineage, completed projection, install, retirement certificate, tree
page/root, tranche consumption, and membership removal. Before rooted intent,
the selected pair is byte-identical. After intent, charge/state persist and
only the exact suffix advances. Repeat with real process death. Equal direct
prepared objects may be reused by digest; unequal collisions fail protected.

Simulate unrelated external consumption after admission. Closure returns typed
storage unavailable with all authority intact, then converges after external
space is restored. Heartbeats/control that add no reservation authority remain
available after root validation while discretionary admission is quota-blocked.

## R13-08 — paged v1 retirement compatibility

Create valid pre-activation histories with 0 rows, 1 row, the exact maximum
rows that fit one leaf, one row over, multiple full leaves, enough leaves for a
second internal level, and sparse first/last UUIDs. Independently build expected
leaf/node/root bytes and require exact root, count, ranges, height, and direct
paths. No active index, projection, install, or root envelope may exceed its
limit regardless of history size.

Cover duplicate UUID, duplicate certificate under another UUID, unsafe filename,
non-v1 `.retired`, wrong origin, symlink/hard link, changed bytes, directory
entry inserted/deleted/renamed during scan, repeated entry, skipped range,
overlap/gap, bad continuation, false EOF, changed directory token, and root/
page substitution. Every case restarts/discards only unselected scan state and
cannot select an incomplete root. Compatible prior writers are held before and
after owner acquisition and journal lock; after the mandatory format fence they
must reject before every named mutation route.

At every boundary—enumeration checkpoint, leaf, node, root fsync, full-tree
validation checkpoint, genesis slot, and index selection—inject error and real
death. Before selection, objects remain nonauthoritative and may only be reused
if byte-identical. After selection, lookup of every historical UUID succeeds
through the root. Missing/changed manifested v1 fails target use and the next
full transition. An unmanifested direct v1 fails protected. No test claims v1
proves class/left lineage.

## R13-09 — v2 retirement tree crash protocol

Retire first, middle, and last keys causing leaf split, internal split, and root
height increase. Require structural sharing of unchanged child digests and one
new exact v2 row. Crash after certificate, each new page/node, root envelope,
consumed-tranche/root selection, and membership removal. Validate the four
specified outcomes: membership preserved before root selection; unreferenced v2
before selection; consumed rooted row awaiting removal after selection; and
idempotent archived lookup after removal. Replay/cross-UUID/substitution and a
root that omits any prior row fail before mutation.

## R13-10 — retained correction and concurrency matrix

Re-run R11-01 through R11-13 and R12-01 through R12-08 with these replacements:

- all-member detached-body cases use R13-02/R13-03's explicit full-transition
  versus operation-local contract;
- R12 quota and allocation rows use rooted admissions and the R13-06 charges;
- the flat v1 manifest cases use the paged tree and transcript cases;
- identity cases retain byte-equivalent pre-capture acceptance and
  post-capture device/inode/metadata rejection without claiming persisted inode
  knowledge; and
- maximum pending cases retain 1,024 rows, exact origin, primary-first
  departure, same-owner stabilization, frozen finalizing membership, global
  allocating-intent gate, no global publication gate, 256 soft FD limit, four
  reservation descriptors, and unchanged eight-second calls.

Use deterministic subprocess barriers for reserve/reserve same and different
tuple, candidate insertion after search capture, allocation admission versus
allocation recovery/retirement, UUID A pending while B starts/heartbeats/
cancels/commits/publishes, finalizing versus every membership mutation, and
retirement at every capacity/certificate/tree/removal boundary. Assert one
surviving match, no allocation past an unresolved admission/candidate, no
cross-owner acquisition, no lost heartbeat, and no deadlock.

## R13-11 — migration, rollback, observability, and final gate

Test pre-fence abort, post-fence/pre-genesis restart, genesis recovery, and
post-genesis software rollback. Before selection only unselected temporaries may
be removed. After selection an old reader must reject; an R7-aware recovery
binary must preserve and advance exact authority. In a separate stopped-writer
fixture, byte-exact restoration of the complete pre-cutover backup restores the
old graph; partial/in-place downgrade is rejected.

Assert structured metrics for full/operation validation, aggregate-root failure,
rows hashed, target/unrelated opens, every capacity state/refund, quota equation,
Wpeak/Uafter/floor, ENOSPC/EDQUOT, retirement pages/height/rows/root/transcript
restart, CAS conflict, durable boundary, FD high-water, elapsed budget, and typed
result. Logs must not contain body or secret bytes.

Run focused codec, reservation migration, transaction, retention, catalog-read,
CLI bridge, command-composition, and app model-management suites; package-wide
`swift test`; and every applicable Build 1 compatibility, governance, and Xcode
gate. Freeze final source/test hashes. Fresh independent code, security, and
architecture reviews of the complete diff must each report zero Critical, High,
and Medium findings.

Stop on any narrowed input; aggregate/page/index overflow; omitted retirement;
unrelated body fanout; non-target row mutation; global publication gate;
allocation object before rooted admission; replay/double charge/illegal refund;
underestimated file or directory; charge-equation mismatch; free-space double
count; authority deletion; raised deadline/FD limit; unverified prior binary;
missing real-death case; stale evidence; or skipped/interrupted/timed-out command
reported as passing. Physical MLX, signed release/feed, deployment, enforcement,
settlement, and economic activation remain outside this plan.
