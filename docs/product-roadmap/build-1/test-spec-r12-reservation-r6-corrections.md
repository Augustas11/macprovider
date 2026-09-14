# Build 1 test specification R12 — reservation R6 corrections

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This specification pairs with
`reservation-search-progress-addendum-r6.md`. It adds the corrections required
by the failed R5 plan gate and retains every applicable R11 and R4 case. No test
result or implementation approval is claimed.

All cases run against one frozen final source/test manifest. Every result records
the exact command, base/head SHA, selected/pass/fail/skip counts, duration,
soft/hard FD limits, free-space/quota settings, relevant counters, and SHA-256
of the complete log and durable fixture manifest. Real child death remains
separate from injected thrown errors.

## R12-01 — closed schemas, maximum encodings, and dual-slot roots

Exercise production codecs for state-projection v1, predecessor v2, lineage v1,
retirement v2, v1-retirement manifest, and revised publication receipt/index
fields. Require canonical minimum, exact maximum, exact-at-limit, and one-byte
over; duplicate/unknown/missing/null/wrong-type fields; unsorted/duplicate rows;
bad UUID/digest/generation/phase/slot/root; cross-UUID locator; path traversal;
and trailing data.

Encode 1,024 maximum-field active rows with every row pending and separately
with every row settled after first-left. Both the active index and projection
must remain at or below 1,048,576 bytes without truncating any R4-valid field.
Predecessor is at most 8,192, lineage at most 16,384, and all inherited limits
remain exact. Recompute every leaf/root independently and reject one-bit row,
padding, count, domain, index/projection, progress, or selected-slot changes.

Crash or inject failure before/after inactive-slot create, file fsync, rename,
directory fsync, and active-index selection. Restart must select exactly the old
or new digest-valid pair. An unselected slot, even if well formed, has no
authority. Reusing a slot while an index still selects it must be impossible.

## R12-02 — exact 1,024-pending ordinary-operation bound

Build exactly 1,024 legal simultaneous pending members, alternating first-class
and first-left, with maximum 131,072-byte receipts. Give each a distinct compact
predecessor and valid prior lineage. Put the exercised UUID first, middle, and
last. Run real production heartbeat, queued and live cancel, generic commit,
reservation search, allocation recovery, and retirement entrypoints.
For every call assert: one active-index open/decode, one selected-projection
open/decode, at most one progress open/decode; at most 1,024 row encodings and
one root computation; zero unrelated receipt/predecessor/lineage/class/left/
origin/owner/primary opens; at most ten reservation-specific direct opens and
3,383,296 reservation body bytes; reservation-owned live descriptors at most
four; and elapsed time below the unchanged eight-second budget on the reviewed
healthy profile. No helper creates a new budget.

UUID B must start, heartbeat repeatedly, cancel, commit, and publish its own
valid suffix while UUID A remains pending. B never flocks A, finishes A, changes
A's row, or loses a heartbeat. Recover A afterward and prove its target-only
transition while every current B and unrelated row is copied byte-for-byte.

Corrupt or substitute A's copied commitment, predecessor, receipt, target row,
origin/class/left, prior/next refs, target acknowledgment, generation, lineage,
or current progress delta. A recovery must fail before its first write. Substitute
B's valid objects into A and replay A's old generation; both fail. Corruption of
detached A bytes cannot remove/change A's committed row while B mutates; direct
use or retirement of A fails protected until the exact bytes are restored.

## R12-03 — quota, free-space, long-run churn, and storage faults

Initialize with safe existing objects at exact 4,096-byte charge boundaries and
verify length rounding plus per-object charge. Unsafe, unknown, oversized, hard
linked, symlinked, wrong-owner/mode, or colliding objects block activation. The
index and selected projection must agree on quota and charged bytes.

At cutover prove room is prepaid for the worst-case remaining class, left, and
retirement closure of all 1,024 members. At post-complete allocation prove the
65,536 + 196,608 + 65,536 byte lifecycle reserve is charged before intent.
Drive repeated allocate/depart/retire churn until the next lifecycle would
exceed 1,073,741,824 bytes. The last admitted lifecycle completes; the next
admission returns typed capacity with zero new UUID, file, charge, or index row.
Retained authority never exceeds quota and is never deleted or compacted.

Set volume capacity just below, exactly at, and just above the 536,870,912-byte
floor plus write and unmaterialized prepaid-closure requirement. Assert exact
boundary behavior.
Inject `ENOSPC` and `EDQUOT` before/after every create, temporary write, file
fsync, rename, directory fsync, state selection, pending CAS, class, left,
progress, lineage, retirement-v2, and membership-removal boundary. Before
authority CAS, selected bytes remain identical. After CAS, charge and intent
remain and retry resumes only the exact suffix. Equal direct prepared objects
are reused; unequal collisions are protected.

Repeat every post-intent fault with a real child `_exit`, then restart in a new
process. Free unrelated external space and require forward convergence without
deleting any predecessor, receipt, lineage, class, left, source, progress,
install, projection, retirement, or manifested v1 certificate. Verify ordinary
heartbeats that require no reservation-authority growth still succeed when new
admission is quota-blocked. Simulate external consumption defeating headroom;
closure returns typed storage unavailable, retains all bytes, and succeeds only
after external space returns.

## R12-04 — settled lineage and retirement v2

For a migrated allocated member and a post-complete allocation, cover class
genesis/first-class, first departure while running, first-left publication,
later terminal primary, retirement, restart, and historical validation. Require
the left to bind the exact first nonreusable primary and v2 outcome to bind the
possibly different terminal primary. Require v2 to bind exact origin, class,
left, settled-lineage digest, publication receipt, predecessor evidence, and
migration/source/install identity.

Crash after pending predecessor, receipt, intent, class, left, progress,
lineage, v2 certificate, and membership removal. Retirement before settled
lineage or with any pending ref must not remove the row. After restart, deletion,
same-path different-byte substitution, cross-UUID substitution, replay, or
one-bit change of class, left, receipt, predecessor, lineage, v2, or its roots
must fail archived validation. No path may re-add, run, reserve, or reuse the
retired UUID.

Create safe historical v1 certificates before R6 activation. Freeze their UUID,
certificate digest, and origin digest in the content-addressed v1 manifest.
After activation they validate only v1 outcome fields. Changed or missing v1 or
manifest bytes fail; no test claims v1 proves absent class/left lineage. Every
retirement after activation must produce v2, including an entry that existed at
activation but retired later.

## R12-05 — honest file-identity matrix

For predecessor, receipt, projection slot, install, lineage, class, left, and
retirement files, replace a safe file with a new inode containing identical
canonical bytes before a fresh recovery process performs its first capture.
Require acceptance as byte-equivalent only when path, owner, mode, type, link
count, size, digest, schema, and all lineage fields match.

Repeat replacement after capture and before final CAS using deterministic
barriers; require stable-device/inode validation failure and zero mutation.
Also test in-place mutation, metadata change, symlink/hard link, wrong owner/mode,
same-size different bytes, restored timestamp with different bytes, and coherent
different-byte multi-file substitution. All fail. Restore exact bytes before a
new capture and prove rollback state remains rejected by origin/class/left/
lineage rules. Test names and reports must distinguish `pre_capture_equivalent`
from `post_capture_identity_change`; no result may claim restart detection of an
unpersisted prior inode.

## R12-06 — retained R11/R4 correction matrix

Re-run R11-01 through R11-13 with these precise adaptations:

- R11-01 uses the R12-05 identity boundary and the R6 schemas/limits.
- R11-02 all-member validation uses index + selected projection + progress as
  current cross-member authority. Detached corruption may not alter/remove a
  committed non-target row; dereferencing or retiring that row fails protected.
- R11-03 validates completed historical roots and every target lineage; it does
  not require unrelated pending predecessor fanout for ordinary mutation.
- R11-08 uses predecessor v2 target evidence and current projection preservation,
  not full predecessor index/progress snapshots.
- R11-09 adds both state slots, quota charge, lineage, retirement v2, and all
  `ENOSPC`/`EDQUOT` boundaries.
- R11-10 retains exactly 1,024 × 4,194,304-byte × 2,048-event primaries and the
  unchanged eight-second calls; acknowledged primaries remain zero-reread.
- R11-11 must use all 1,024 simultaneous pending rows, not only two, for the
  unrelated heartbeat/cancel/commit/reserve/allocation/retirement matrix.

All R5 allocation-global-gate, exact three-way generation, sequential owner
fence, same-owner stabilization, departed-primary rollback, queued-cancel busy,
content-addressed install/projection, closed historical graph, owned catalog
composition, prior-binary fence, and no-wrapper-bypass cases remain mandatory.

## R12-07 — ordering and budget acceptance table

Instrument every production boundary and prove this order:

| Operation | Required durable order |
|---|---|
| state mutation | capture selected pair → encode inactive projection → write/fsync/rename/dir-fsync inactive slot → final CAS → active index |
| publication | preflight → charge-only state/index → predecessor → receipt → pending state/index → class → left if any → progress if classifying → lineage → settled state/index |
| allocation | lifecycle preflight → charge-only state/index → allocating state/index → primary → origin → class → genesis lineage → active state/index |
| retirement | recover pending with held owner → validate target lineage/files → consume prepaid charge reservation → v2 → remove row in state/index |
| finalization | incremental validation → preflight → charge-only state/index → completed projection → install → finalizing state/index → complete state/index |

At each arrow inject changed CAS, budget expiry, `EMFILE`, `ENOSPC`, and real
death where applicable. No path writes a later artifact first, renews the
budget, creates an unrelated owner, launches work during recovery, treats an
unreferenced object as authority, or deletes authority. Record exact opens,
bytes, decodes, descriptors, fsyncs, quota values, free-space observations, and
elapsed time. Any counter above section R12-02's bound or healthy call at or
above eight seconds is a failure.

## R12-08 — evidence and stop gate

Run focused codec, reservation migration, transaction, retention, catalog read,
CLI bridge, command composition, and app model-management suites, then package
wide `swift test` and every applicable Build 1 compatibility/governance/Xcode
gate. Freeze final source/test hashes before review. Three independent complete
diff reviews—code, security, and architecture—must each report zero Critical,
High, and Medium findings.

Stop on any narrowed maximum input, projection/index above 1 MiB, full historical
predecessor snapshot, unrelated pending-object fanout, global pending gate,
unreserved authority write, quota above 1 GiB, authority deletion, stranded
retirement lineage, dishonest inode claim, raised deadline/FD limit, missing
real-death case, skipped/interrupted/timed-out command represented as passing,
or stale aggregate evidence. Physical MLX, signed release/feed, deployment,
enforcement, settlement, and economic activation remain outside this plan.
