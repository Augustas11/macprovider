# Build 1 test specification R14 — reservation R8 corrections

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This specification pairs with
`reservation-search-progress-addendum-r8.md`. It corrects R7-PLAN-H1 through
H4 and R7-PLAN-M1 while retaining every applicable R4, R11, R12, and R13 case.
No test result or implementation approval is claimed.

All cases use production codecs and entrypoints against one frozen final
source/test manifest. Each result records the exact command, base/head SHA,
selected/pass/fail/skip counts, duration, soft/hard FD limits, quota and
free-space values, direct-read/body-byte/descriptor counters, and SHA-256 of the
complete log and fixture manifest. Injected errors and real child `_exit` deaths
are distinct cases. No interrupted, skipped, or timed-out command is a pass.

## R14-01 — closed schemas and mutually exclusive maximum fixtures

Exercise active-index v5, state-projection v2, capacity v2, allocation admission
v2, allocation-abort v1, all three tree kinds, retirement v2, predecessor v2,
lineage v1, completed projection, and install v2 with production codecs. For
each require canonical minimum, maximum, exact-at-limit, and one-byte-over
behavior; duplicate/unknown/missing/null/wrong-type fields; noncanonical JSON;
unsafe integers; invalid UUID/digest/generation/state/kind/count/height/level;
unsorted/duplicate/overlapping ranges; path traversal; cross-UUID locator; and
trailing bytes.

Construct these five independent maximum state projections exactly as R8
section 7 defines them:

1. 1,024 maximum classifying rows with maximum pending publications and no
   shared admission;
2. 1,024 maximum active rows plus one maximum A1 allocation admission and no
   allocating row or finalization admission;
3. 1,023 maximum active rows plus one maximum A2/A3 allocating row and admission
   and no finalization admission;
4. 1,024 maximum frozen settled rows plus one maximum finalization admission and
   no allocation admission or allocating row; and
5. 1,024 maximum complete-phase rows with neither shared admission.

Each includes maximum v1, v2, and abort root envelopes and all capacity
counters. Independently encode each twice and require byte identity; active
index and projection must each be at most 1,048,576 bytes without truncating an
inherited field. The test must print exact bytes for each named fixture. Reject
allocation plus finalization together, 1,025 rows, A2/A3 without its allocating
row, an allocating row without its admission, finalizing pending publication,
phase-illegal tranche state, and any attempt to combine maxima from mutually
exclusive phases.

Independently recompute rows, capacity, retirement/abort roots, aggregate root,
gross charge, refunds, and selected-slot digest. Flip one bit or change one
field/order/count/domain/root/admission and require rejection before write.
Crash before and after inactive-slot write, file fsync, rename, directory fsync,
final CAS, and active-index selection; restart selects exactly the old or new
complete digest-valid pair.

## R14-02 — one-time activation and full-transition boundary

Build genesis fixtures with 0, 1, 64, 65, 16,384, and multi-level v1 retirement
rows plus a maximum 1,024-member R5 graph. Require the only global root
activation to occur in `genesis-v2`, selecting the exact v1 root and canonical
empty v2 and abort roots. Change or omit each source/member/body/root, add an
unreferenced direct class/left/retired contradiction, or change the directory
witness or aggregate root during final CAS. No R8 root may become selected.

For classifying-to-finalizing and finalizing-to-complete, corrupt or omit the
first, middle, and last body and page. Require sequential complete validation,
authenticated validation progress bound to one unchanged aggregate root, and
no phase publication until all rows, pages, and bodies validate. Changing any
root or aggregate generation invalidates all prior progress. These are the only
post-genesis global walks.

Then retire target UUID first, middle, and last in trees that cause: first leaf,
nonsplitting leaf replacement, height-one leaf split, height-two nonsplitting
replacement, and height-two leaf split. Instrument the production validator.
Each retirement must call operation-local validation, open exactly the selected
old path and target bodies, derive only the canonical successor, and perform
zero global-tree, unrelated-page, or unrelated-body reads. Fail the case if
`validateReservationTransitionGraph` runs, if more than the old path is opened,
or if a newly selected successor is labeled an activation.

For every shape independently mutate the old membership/nonmembership proof,
target row, leaf order, sibling digest, child range/count, split point, replaced
ancestor, root count, or untouched subtree. Require protected failure before
the first new object. Supply a legal-looking alternate whole-tree rebuild with
the same rows and require rejection: only R8's inductive path successor is
legal.

Crash after certificate, each new leaf/node, root envelope, root/tranche CAS,
and membership-removal CAS. Require exactly: membership preserved before root
selection; unreferenced or intent-named immutable objects before selection;
consumed rooted retirement awaiting removal after selection; and idempotent
archived lookup after removal. Every old immutable page/root remains byte
identical and inventoried.

## R14-03 — allocation admission and explicit abort state machine

For one frozen allocation operation, independently derive the proposed UUID,
generation, tuple, primary, origin, class, lineage, success charge, abort
receipt, and possible abort-tree successor bytes. Traverse every legal edge:

```text
A0 -> A1 -> A2 -> A3 -> A5
A1 -> A4 -> A6
A2 -> A4 -> A6
```

At A0 capacity failure creates no row, directory, file, charge, or admission.
At A1 require exactly one 581,632-byte gross/net charge and no allocating row or
allocation body. At A2 require the exact allocating row and no body/directory.
At A3 create only primary → origin → class → genesis lineage. At A5 require the
same UUID/generation across admission, row, primary selector, origin, and
lineage, with no refund.

At both A1 and A2, an all-absent observation may only publish A4. Assert that A4
retains the admission and, for A2, changes the same row to
`allocation_aborting`; charge is unchanged; reason, receipt, and successor root
are fixed. Any production branch that directly removes an all-absent row or
admission fails the test. Materialize the exact abort receipt, changed abort-tree
pages, and root, then require one A4→A6 CAS. A6 removes only the named admission
and optional row, selects the abort root, increments refunds by exactly
`581,632 - retainedAbortChargeBytes`, and leaves all abort objects charged and
readable through the root.

Inject thrown error, deadline, EMFILE, ENOSPC, EDQUOT, and real death before and
after every A1, A2, A4, receipt, leaf, node, root, A6, primary, origin, class,
lineage, and A5 boundary. Restart must follow the exact R8 suffix. Replaying A6
returns the same terminal aborted result with byte-identical roots and counters;
it never allocates a new UUID or repeats charge/refund. Replaying A5 returns the
same active allocation.

Race two recoverers of the same operation at A1, A2, A4, and A6. Exactly one
CAS/object/root/refund wins; the other observes the identical selected result.
Use the same operation UUID with each digest changed in turn, a wrong owner,
wrong reason, stale generation, alternate abort root, or different proposed
UUID and require protected/busy without mutation. Place one byte and then one
empty per-UUID directory from the success sequence before A4; both make abort
illegal and preserve A2/A3 for exact forward completion. A1–A4 globally block
new search/allocation but do not block unrelated heartbeat/control. A6 does not
block a new operation.

## R14-04 — deterministic page, root, and proof fixtures

Independently implement the R8 canonical encoder and tree algorithms in test
code without calling production tree builders. Freeze exact byte and SHA-256
fixtures for:

- empty root, 1, 63, 64, and 65 leaf rows for each tree kind;
- 255, 256, and 257 child internal nodes;
- v1 bulk inputs at 64, 65, `64*256`, and `64*256+1` rows;
- v2 insertion before first, between two, and after last UUID;
- the exact 32/33 leaf and 128/129 internal split boundaries; and
- membership and nonmembership before first, between leaves, within a leaf, and
  after last.

Require v1 leaves to be consecutive 64-row partitions, nodes consecutive
256-child partitions, last groups retained at 1–64/1–256, and a one-child final
node not collapsed. Require v2/abort insertion to replace only the search path,
copy unchanged digests, and never merge, rotate, borrow, repack, or rebuild.
Reject alternate yet semantically equivalent JSON, alternate grouping, 33/32
split, different child choice for a gap, wrong level, null/non-null empty fields,
wrong count/range/height, page over 65,536 bytes, root over 16,384 bytes, and a
path whose filename digest differs from its canonical bytes.

For maximum canonical rows, measure and assert v1 leaf below 14 KiB, v2 leaf
below 40 KiB, and internal page below 55 KiB, as well as the hard 65,536-byte
bound. Independently prove the v1 safe-integer maximum of 439,804,651,110 rows
and six page levels. Independently prove the legal v2 population bound of 2,870
rows and fail if production admits a v2 height above two. Independently prove
the abort-tree 37,449-row bound and fail if production requires a height above
three under the frozen quota formula.

## R14-05 — v1 stable enumeration and authenticated checkpoints

Run activation through production filesystem entrypoints, not a synthetic list.
Assert the exact no-follow directory FD flags, exclusive activation lock, held
journal/fence relationship, and unchanged `fstat` witness fields named in R8.
Attempt each compatible mutation route while activation holds the lock and
require refusal before mutation. Replace the root pathname after the directory
FD is open; all reads must remain relative to the original FD and selection must
fail on witness/path CAS rather than follow the replacement.

Create directory-order fixtures deliberately different from UUID order and
enough rows for multiple 4,096-row work blocks, more than 32 logical runs, leaf
and internal boundaries, and a final short group. Independently reproduce the
4,096-row collection grouping, `(firstUUID, creationOrdinal)` logical-run order,
consecutive 32-way stable merge groups, 4,096-row merge outputs, and final
64/256 tree packing. Require byte-identical work-root chain, final sorted stream,
pages, and root. Duplicate UUIDs across the same block, different blocks, and
different merge groups fail.

Decode active checkpoint selector and both slots at every generation. Require
the closed field set, explicit nulls, direct paths, alternating slot, generation
`n+1`, exact previous digest, selected source/index/fence/directory bindings,
work root, phase/pass/cursors/frontier, session-key digest, and valid HMAC over
the canonical null-MAC body. Flip each field/MAC, replay an old generation,
select an unfsynced slot, swap activation UUIDs, or substitute a work block and
require rejection. `builderFrontier` may contain no more than one partial leaf
and 255 child entries per level and the checkpoint must remain within 1 MiB.
Reject a seventh frontier level or a row count above 439,804,651,110.

Across separate slices in the same live process, require progress from the held
`DIR *` and one unchanged witness. Inject entry insert, delete, rename, body
replacement, same-byte inode replacement, witness-field change, repeated entry,
skipped entry, and false EOF during first and second passes. Each case fails
before selection and discards only unselected work. The second pass must equal
the first transcript/count and prove every direct `.retired` entry is rooted.

Kill the activation process after every checkpoint phase and after leaf, node,
root, and verification progress. A new process must reject the old checkpoint
because it lacks the live key/FD/lock, start at entry zero, and rederive any
reused final page byte-identically. It must never resume a serialized `telldir`
cookie or trust last name/count as exhaustive. Crash before genesis selection
leaves all R8 roots nonauthoritative; crash after selection yields exactly the
verified roots.

## R14-06 — exact quota, retained pages, and lifecycle arithmetic

Independently implement `F(M)` and directory charge without calling production
accounting. Verify 4,096 boundaries and one byte on each side. Inventory every
direct in-scope object, including every old and new retirement/abort page/root,
certificate/receipt, checkpoint/work temporary during `Wpeak`, and per-UUID
directory. Unsafe, hard-linked, symlinked, wrong-owner/mode, oversized,
colliding, or unverifiable objects block rather than disappear from accounting.

Require the corrected maximum charges:

| Bundle | Exact maximum charge |
|---|---:|
| retirement-v2 certificate + UUID directory + two leaves + one node + root | 303,104 |
| allocation abort receipt + UUID directory + two leaves + two nodes + root | 323,584 |
| post-complete successful allocation lifecycle | 581,632 |
| unclassified source closure | 696,320 |
| completed projection + install | 1,073,152 |
| active index + two state slots | 3,158,016 |

Exercise retirement into empty tree, nonsplitting height one, height-one split,
nonsplitting height two, and height-two split. Before admission, independently
derive every successor object's bytes, digest, path, actual `F(length)`, and
maximum tranche. After each durable boundary, walk disk and prove all new and
old leaves/nodes/roots are present in `materializedBytes`. Require the unused
page slot and every maximum-versus-actual difference to become permanent
`spentSlackBytes`. Fail any implementation that charges only the certificate,
reuses old changed-path charge, deletes an old root/page, or charges after
admission.

Exercise A1→A4→A6 and A2→A4→A6 at minimum and maximum receipt/page encodings.
Independently compute retained abort charge and exact refund. Require monotonic
gross charge/refunds, one net-charge decrease only at A6, and retained receipt,
pages, root, and directory in materialized charge. Repeat A6 and prove no second
refund. For every selected state assert:

```text
grossCharged - refunded == charged
materialized + reservedRemaining + spentSlack == charged
charged <= quota
```

Use normal activation below 1 GiB, exactly-at-1-GiB charge, and valid v1
activation inventory above 1 GiB. Require the frozen quota formula with corrected
reserves. Admit exactly the independently computed number of later successful
allocations/aborts that fit, then reject the next before any row/object/charge.
The final admitted success or abort must close. No authority is deleted or
compacted to manufacture capacity.

## R14-07 — ordinary bounds, free-space, and storage faults

Build exactly 1,024 simultaneous maximum pending rows. Exercise heartbeat,
status, queued/live cancel, generic commit, run capture, reserve/search,
allocation recovery, cleanup, publication recovery, and retirement for target
first/middle/last. Every ordinary call opens zero unrelated body/owner/primary
files, encodes at most 1,024 rows and one aggregate root, performs at most ten
direct reads/decodes, holds at most four reservation descriptors, and finishes
below the unchanged eight seconds with no renewed helper budget.

For maximum height-two retirement require the exact read set: index, projection,
optional progress, target primary, origin, class, left, settled lineage, and two
path pages. Assert at most 3,358,720 reservation-authority body bytes and the
inherited separate primary bound. If the target has pending publication,
retirement must return/resume publication first; no call may combine
predecessor/receipt reads with retirement tree update. Corrupt unrelated A while
B retires and require B to preserve A without opening it. Corrupt B's path or
body and require protected zero mutation.

For a maximum-height v1 historical lookup require index, projection, optional
progress, six path pages, and the named v1 certificate—ten direct reads. Assert
that the origin is not reopened merely to repeat genesis validation; an operation
that needs origin bytes performs a separate bounded target dereference.

For each immutable create and mutable slot/index replacement, measure production
`Wpeak`. Put available capacity one byte below, exactly at, and one byte above
`536,870,912 + Wpeak + Uafter`. Require exact rejection/acceptance and prove the
current permanent write is removed once from Uafter while already created path
objects remain materialized. Inject ENOSPC/EDQUOT at certificate/receipt,
directory, every leaf/node/root, checkpoint slot/selector, state slot/index,
tranche consumption, refund, and membership removal. Before rooted intent the
selected pair is unchanged; after intent only the exact suffix advances.

Repeat every fault with real death. Byte-identical named immutable objects may
be reused; unequal collisions are protected. External space consumption after
admission returns typed storage unavailable with authority intact and converges
after restoration. Heartbeat/control without authority growth remains available
when discretionary admission is quota-blocked.

## R14-08 — retained correction, concurrency, rollback, and final gate

Re-run R11-01 through R11-13, R12-01 through R12-08, and R13-01 through R13-11
with these replacements:

- initial root activation and full phase walks use R14-02; ordinary retirement
  root replacement is always target-local;
- allocation recovery/refund uses only R14-03's A0–A6 machine and rooted abort
  evidence; no direct all-absent removal remains;
- all tree/checkpoint/directory-token cases use R14-04/R14-05's exact encodings,
  held-lock session, witness, two-pass transcript, and post-death restart;
- quota fixtures use R14-06's complete retained page/root charges and corrected
  581,632/696,320 reserves; and
- maximum projections use R14-01's five legal independent fixtures and reject
  simultaneous shared admissions.

Retain exact origin, primary-first departure, same-owner stabilization, frozen
finalizing membership, global allocating-intent gate, no global publication
gate, content-addressed lineage/install, target-only predecessor v2, byte-equal
pre-capture identity, strict post-capture identity, sequential prior-binary
fence, no wrapper bypass, 1,024 rows, 256 soft FD limit, four live reservation
descriptors, ten ordinary reads, body-byte ceiling, and unchanged eight-second
calls.

Use deterministic subprocess barriers for same/different allocation admission,
A2 versus abort intent, A4 object publication versus A6, candidate insertion
after search capture, UUID A pending while B starts/heartbeats/cancels/commits/
publishes/retires, finalizing versus each membership mutation, and retirement at
each certificate/page/root/removal boundary. Assert one surviving transition,
no allocation past unresolved A1–A4/candidate, no double refund/charge/root row,
no cross-owner acquisition, no lost heartbeat, and no deadlock.

Test pre-fence abort, post-fence/pre-genesis process death, genesis recovery,
post-genesis R8-aware rollback, and stopped-writer byte-exact pre-cutover backup
restoration. Before selection only unselected temporary/checkpoint/work objects
may be removed. After selection no in-place downgrade or partial deletion is
legal.

Assert R7 observability plus R8 activation session/witness/checkpoint/merge,
incremental-page, gross/refund/abort, retained-byte, FD, direct-read, body-byte,
and elapsed metrics. Logs must not contain session keys, bodies, or secrets.

Run focused codec, reservation migration, transaction, retention, catalog-read,
CLI bridge, command-composition, and app model-management suites; package-wide
`swift test`; and every applicable Build 1 compatibility, governance, and Xcode
gate. Freeze final source/test hashes. Fresh independent code, security, and
architecture reviews of the complete implementation diff must each report zero
Critical, High, and Medium findings.

Stop on any full ordinary-root walk, uncharged retained page/root, implicit
all-absent removal, unrooted/double refund, ambiguous tree bytes, post-death
cursor resume, changed directory selection, illegal simultaneous admission,
projection/page overflow, underestimated reserve, equation mismatch,
free-space double count, authority deletion, unrelated-body fanout, non-target
row mutation, global publication gate, raised deadline/FD/input limit,
unverified prior binary, missing real-death case, stale evidence, or a skipped,
interrupted, or timed-out command reported as passing. Physical MLX, signed
release/feed, deployment, enforcement, settlement, and economic activation
remain outside this specification.
