# Build 1 test specification R16 — reservation R10 corrections

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This specification pairs with
`reservation-search-progress-addendum-r10.md`, SHA-256
`4b82dd1e0fd849f1472fff86e1f5cd8c5f9bd966946c91b21d8951ca5d17c407`.
It closes R9-PLAN-H1 through H5 and R9-PLAN-M1 while retaining every
applicable R4 and R11–R15 case. No source/test implementation or test result is
claimed.

All cases use production codecs and real CLI/app entrypoints against one frozen
final source/test manifest. Independent encoders in test code derive expected
bytes without calling production encoders. Every run records exact command,
base/head SHA, selected/pass/fail/skip counts, duration, FD and quota limits,
read/body/descriptor counters, and SHA-256 of complete logs and fixtures.
Injected errors and real child `_exit` deaths are separate. An interrupted,
skipped, timed-out, or partially selected run is not a pass.

## R16-00 — merged-baseline reconciliation

Pin the source baseline to `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. Recompute the
`914f7caf..1d2c930b` changed-path list and require zero changes to:

```text
ModelCatalogTransactionRetention.swift
ModelCatalogTransactionEvidence.swift
ModelCatalogTransactionReservationMigration.swift
ModelCatalogTransactionStorage.swift
```

Inspect and freeze the merged BYOM artifact-identity path. Prove its digest
cache is outside the transaction root and is never read by activation,
checkpoint, migration, allocation, or genesis code. Reuse its
descriptor-before/after plus path-re-resolution behavior only as a source
pattern. The reservation witness must additionally bind ctime, mode, owner,
group, and link count. Fail the gate if later baseline reconciliation changes a
reservation/activation path or makes a BYOM cache entry authoritative without a
new reviewed addendum.

## R16-01 — format-delegated activation and sole genesis

### Closed bytes and direct paths

Independently encode minimum, maximum, exact-limit, and one-byte-over fixtures
for:

- `model_catalog_retention.v4`;
- `model_catalog_retirement_v1_activation_selector.v1`;
- `model_catalog_retirement_v1_activation.v2`;
- `model_catalog_retirement_v1_checkpoint.v3`;
- path receipt v2, file witness v1, name block v2, name root v1, row block v2,
  row root v1, run manifest, run root v1, tree-build root v1, verification
  block, and verification-work root v1; and
- the amended active-index v5, projection v2, and allocation admission.

Freeze canonical bytes and SHA-256 for every direct path in R10 section 2.1.
Reject duplicate/unknown/omitted fields, implicit null, wrong type, unsafe
integer, malformed or uppercase UUID/digest, noncanonical JSON, BOM,
whitespace, trailing bytes, wrong activation directory, filename/digest
mismatch, traversal, symlink, and normalized-name collision. Source-map
insertion-order permutations must encode identically.

Create the lock through production descriptor-relative I/O. Assert exact
`O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC`, mode 0600, one regular link, owner, no
ACL, file and parent fsync on first create, and exact v4-frozen identity.
Replace the path after open and require every later invocation to reject the
detached old inode. Race two callers against one valid path: exactly one
nonblocking flock enters, both close all FDs, and only the winner may attempt a
selector generation.

### Bootstrap truth table

Run the actual supported prior binary against candidate v4 format bytes and
require rejection before mutation. Freeze exact old-format/old-index/source,
generation-zero checkpoint, activation object, selector, and candidate-v4
bytes. Inject thrown error, cancellation, deadline, ENOSPC, EDQUOT, and real
death at each of:

```text
lock create -> lock fsync -> activation-directory fsync -> checkpoint create ->
checkpoint fsync -> activation create -> activation fsync -> selector temp ->
selector fsync -> selector rename -> selector-directory fsync ->
v4 format temp -> format fsync -> format rename -> retention-directory fsync
```

Before format rename, the old graph remains selected and all R10 objects are
unselected equal-reusable candidates. After format rename, the direct selector
must resolve one complete generation-zero pair. A missing/unequal object,
selector at another path, changed lock identity, competing activation UUID,
changed prior index/source, or format pointing to a nonzero/invalid pair is
protected. Prove the one-time bootstrap lock order cannot recur after v4 is
selected.

### Selector CAS and genesis order

For every activation generation, freeze exact old, prepared candidate, and new
selector bytes. Kill before/after checkpoint create/fsync/directory-fsync,
activation-object create/fsync/directory-fsync, selector temporary/fsync/
rename/directory-fsync, and journal-lock recapture. On restart, require exactly
the old or new direct selector and its complete graph. Never select the highest
generation, an orphan checkpoint, or a content-addressed object absent from the
selector chain.

At `ready`, independently derive v2 projection and v5 active-index bytes with
the five R10 activation bindings. Crash before/after inactive-slot temporary,
file fsync, rename, slot-directory fsync, and active-index selection. Before
index selection, format v4 still fences every mutation and no v2 projection is
authority. After index selection, require the sole `genesis-v2` transition:
the selected projection, v5 index, still-direct ready selector, activation,
checkpoint, and format all match. Prove no earlier checkpoint changes an
active index/projection and no later transition rewrites the ready selector.

Run every actual compatible mutation route at generation zero, middle states,
ready-before-genesis, and after genesis. It rejects before write in all
pre-genesis states and proceeds only from the exact v5/v2 genesis binding.
Heartbeat, status, queued/live cancel read paths, and read-only catalog control
remain bounded and available. This section is the acceptance oracle for
R9-PLAN-H1.

## R16-02 — legal joint generations and mutable progress

Freeze the exact generation-zero pair: generation 0, both previous digests
null, state `capturing_names`, configured-root digest and checkpoint digest
non-null, path receipts/results/progress roots/cursors null. Require selector,
activation, and checkpoint equality for UUID, generation, state, prior index,
source, fence, and checkpoint digest.

For every legal same-phase and phase-advance successor, independently derive:

- activation/checkpoint generation `n+1`;
- exact prior activation and checkpoint digests;
- unchanged frozen fields;
- current checkpoint replacement;
- the one legal current-progress-root successor;
- terminal-result fill only at the named phase boundary; and
- the R10 cursor/nullability row.

Reject an initial non-null path receipt, self-referential checkpoint, changed
current pointer without a previous-root edge, immutable result replacement,
cleared result, future result, phase skip/backtrack, alternate predecessor,
generation skip, mismatched activation/checkpoint generations, stale selector,
cursor outside its frozen input, or explicit-null violation. Prove a legal
checkpoint digest changes on every selected progress generation without
violating any immutable-field rule.

At every crash boundary decode the selector, activation, checkpoint, every
referenced immutable root, and all previous links back to zero. A byte change,
missing predecessor, cross-activation object, changed filename digest, or cycle
is protected. This section is the bootstrap/digest-chain oracle for
R9-PLAN-H2.

## R16-03 — complete rooted row, merge, tree, and verification work

Create name sets at 0, 1, 4,095, 4,096, 4,097, more than 32 capture runs,
multiple merge passes, 64/65-row leaf boundaries, 256/257-child boundaries,
and a final short group. Physical directory order must differ from parsed UUID
order.

For row work, independently freeze every consecutive name range, row block,
capture run, next ordinal, creation ordinal, ordered row/capture arrays, and
transcript. Kill after each row/run create and fsync but before/after the root
and selector CAS. Recovery selects all and only blocks named by the current row
root, resumes its next ordinal, and never rescans a selected earlier range.

For each merge pass, independently sort frozen inputs by
`(firstUUID, creationOrdinal, manifestSHA256)` and partition consecutive groups
of at most 32. At each group freeze `firstInputOrdinal`, `lastInputOrdinal`,
exact input array, reserved creation ordinal, output manifest, completed-group
entry, output array, and root digest. Kill after group output, group root, final
group, pass-advance root, and one-run terminal selection. Recovery must consume
the exact prior completed groups and perform only the missing suffix. Reject
33 inputs, skip/overlap/repeat/reorder, alternate grouping, output not named by
the root, pass advance with an incomplete group, or sorted terminal digest
before one run remains.

For tree build, independently reproduce fixed 64-row leaves and 256-child
internal pages. At every bounded batch freeze current-level input array,
input ordinal range, page ordinal/level/range/count/digest, current page list,
completed-level entry, next input/object ordinals, and root. Kill after every
leaf, internal page at every level, completed-level root, top page, root
envelope, and terminal tree selection. Recovery reuses byte-equal named pages
and creates only the missing suffix. Reject a top/root that omits any leaf or
internal page, an extra/reordered page, alternate packing, collapsed one-child
page, wrong input level, or page not named by the selected build root.

For verification, independently chain consecutive blocks over every row.
Freeze first/middle/last block, rolling digest, next ordinal, ordered block
array, verified count, and complete flag. Kill after block/object/root/selector
boundaries. Omission, substitution, overlap, order change, premature complete,
or complete count mismatch prevents ready/genesis. This section is the partial
run/page authority oracle for R9-PLAN-H2.

## R16-04 — selected source identity and final recapture

Independently encode full certificate/origin witnesses with device, inode,
regular type, mode, owner, group, link count, byte length, mtime seconds/
nanoseconds, and ctime seconds/nanoseconds. Independently derive the ordered
source-witness digest and path receipt v2. Require explicit null only where R10
permits it and reject any missing time half, nanoseconds outside
`0...999,999,999`, negative/unsafe number, zero/oversized body, or mismatched
relative name.

During both name passes mutate each identity field independently. Exercise:

- same-inode same-length byte rewrite;
- same-inode truncate/extend and restore;
- mtime restoration while ctime changes;
- chmod/chown where permitted and link-count change;
- same-byte inode replacement before open;
- rename/path replacement after open;
- symlink/type substitution; and
- certificate/origin swap across UUIDs.

Both namespace and source-witness digests must match before name-root
selection. For row capture and verification, insert barriers immediately before
descriptor-before, during every read chunk, immediately before descriptor-after,
and immediately before pathname-after. Each mutation must fail before row/work
selection. Same bytes on a new inode still fail.

After terminal verification, inject the same mutations before, during, and
after the first outside-lock metadata recapture and immediately before/during
the second under-lock recapture. Also replace every configured-root parent and
the transaction root with an equal-byte tree. Require exact witness, namespace,
component, and ready-selector equality before the inactive v2 slot is written.
Instrument the journal lock: it may cover this metadata-only second recapture
and genesis CAS, but no body read, sort, merge, tree build, or body hash.

Build the maximum legal 1,024-row/two-file witness fixture. Both final passes
and the complete invocation must finish below eight seconds with soft FD 256,
bounded memory, and no surviving descriptor or directory stream. A timeout
blocks implementation; it cannot justify dropping ctime, skipping a pass, or
raising a limit. This section is the oracle for R9-PLAN-H3.

## R16-05 — complete A4/A5 crash suffix and exact directory charge

Independently encode every legal allocation phase and transition:

```text
A0 -> A1 -> A2 -> A3(directory_intent) -> A4(directory_durable) ->
A5(primary_intent) -> A5(primary_durable) ->
A5(origin_intent) -> A5(origin_durable) ->
A5(class_intent) -> A5(class_durable) ->
A5(lineage_intent) -> A5(lineage_durable) -> A6
A1 -> A7 -> A8
A2 -> A7 -> A8
```

Freeze the root-relative string
`.reservation-migration/lineage/<proposedTransactionUUID>` and independent
binary digest vector for domain `macprovider-root-relative-path-v1\0`, u32be
UTF-8 length, and exact bytes. Flip domain, leading slash, base path, length,
component, normalization, UUID case, or join order and require rejection.
Separately freeze the absolute configured-root digest and prove the two domains
cannot substitute for one another. This is the oracle for R9-PLAN-M1's path
finding.

For directory, primary, origin, class, and lineage, inject error/cancellation/
deadline/ENOSPC/EDQUOT/real death at:

```text
before intent CAS -> after intent CAS -> before create -> after create ->
after file or directory fsync -> after containing-directory or parent fsync ->
before durable CAS -> after durable CAS
```

At every boundary inventory selected phase, exact disk paths and bytes,
admission materialized charge, global materialized bytes, reserved remainder,
spent slack, gross, refunded, charged, available capacity, `Wpeak`, and
`Uafter`. Before durable CAS, the selected intent permits only absent or one
equal candidate and all selected counters remain at the prior values. After
durable CAS, only the named phase and exact charge transfer change.

For A3→A4 assert the sole exact delta:

```text
materializedChargeBytes += 4,096
materializedBytes       += 4,096
reservedRemainingBytes  -= 4,096
gross/refunded/charged/spentSlack unchanged
```

Assert the directory charge occurs once, only there. For each body use its
independently computed `F(canonicalLength)` in the same three-counter transfer.
At A6 transfer only the final fixed-admission remainder to spent slack. Repeat
every durable CAS and A6 to prove no double charge or slack.

At every intent place a wrong path, extra entry, unequal bytes, symlink, hard
link, wrong type/mode/owner, changed inode, or second body from a later phase.
Require protected result with no deletion/refund. Race same-owner recoverers;
exactly one phase CAS wins and both converge to identical bytes/counters. Race
A2→A3 against A2→A7; exactly one wins. A3 or any later phase makes abort/refund
illegal even when its next candidate is absent. This section is the oracle for
R9-PLAN-H4.

## R16-06 — abort envelope, reachable encodings, refund, and history

Use an independent abort-tree encoder. Freeze legal predecessor trees and
insertion UUIDs for every R10 successor row, including both three-internal-page
cascades. The maximum-field fixture uses exact timestamp
`2026-09-11T00:00:00.000Z`, gross 581,632, retained 126,976, refund 454,656,
legal distinct fixed-width UUIDs, and maximum-width lowercase digests.

Require these independently encoded lengths and charges:

| Object | Bytes | Charge |
|---|---:|---:|
| receipt | 966 | 8,192 |
| leaf 32 | 8,422 | 16,384 |
| leaf 33 | 8,682 | 16,384 |
| internal 128 | 25,450 | 32,768 |
| internal 129 | 25,648 | 32,768 |
| top 2 / top 3 | 506 / 708 | 8,192 |
| root | 346 | 8,192 |
| directory | n/a | 4,096 |

Freeze the exact bytes and SHA-256 for both cascade variants. Their actual
retained sum must be 126,976 even though admission reserves the 393,216
envelope. Require exact reachable maxima 45,056; 61,440; 102,400; 110,592;
126,976; 110,592; 118,784; and 126,976 for the ordered R10 shape table.
Independently retain the conservative envelope classes 114,688; 184,320;
253,952; 323,584; and 393,216 only for preflight/Wpeak tests.

At A7 gross/net charge remains 581,632. At A8 require one exact refund
`581,632 - actualRetainedAbortChargeBytes`. Check minimum 28,672/552,960 and
maximum 126,976/454,656. Repeat A8 and prove no second refund. Inventory every
receipt, directory, new/old leaf, internal page, and root in materialized disk
and selected accounting; no padding or envelope slack is called materialized.

Freeze exact 1 GiB arithmetic:

```text
1,846 * 581,632 = 1,073,692,672; remainder 49,152
37,449 * 28,672 = 1,073,737,728; remainder 4,096
8,456 * 126,976 = 1,073,709,056; remainder 32,768
```

Exercise all-success, all-minimum-abort, all-maximum-actual-abort, and mixed
`S/Ai` histories exactly at headroom and one byte over. The final closure that
fits succeeds; the next rejects before row/object/charge. Assert v2 at most
2,870 rows/height two and abort at most 37,449 rows/height three. A test that
expects 393,216 actual retention, a 188,416 refund, or 2,730 all-maximum actual
aborts must fail. This section is the oracle for R9-PLAN-H5.

## R16-07 — preserved quota, capacity, and operational limits

Independently implement `F(M)`, directory charge, quota rounding, selected
accounting, and physical inventory. Verify every 4,096 boundary and one byte
each side. Preserve exact bundle ceilings 303,104 retirement, 393,216 abort
envelope, 581,632 success lifecycle, 696,320 source closure, 1,073,152
finalization, and 3,158,016 fixed mutable footprint.

For every selected state assert:

```text
grossChargedBytes - refundedBytes == chargedBytes
materializedBytes + reservedRemainingBytes + spentSlackBytes == chargedBytes
chargedBytes <= quotaBytes
```

For every permanent write verify `Wpeak` from its actual rounded extent plus
the inherited create/metadata allowance and any new directory; remove only that
write from `Uafter`. Test free space one byte below, exactly at, and one byte
above `536,870,912 + Wpeak + Uafter`. Include selector temporaries, activation
objects, checkpoints, path receipts, name/row/run/work/verification roots,
pages, manifests, and directory candidates in peak physical inventory. After
genesis remove only unselected work; selected authority and old immutable
pages/roots remain.

Measure every activation invocation below eight seconds with no nested budget
renewal. Assert zero surviving lock, file FD, directory FD, `DIR *`, cursor,
or key across invocation exit. Ordinary post-genesis operations retain at most
ten direct reads/decodes, four live reservation descriptors, 3,383,296
reservation-authority bytes, 1,024 rows, FD 256, and the inherited primary/body
limits. A failed capacity search or write leaves selected authority intact and
does not suppress heartbeat/control.

## R16-08 — retained regressions, hostile concurrency, and gate

Re-run R11-01 through R11-13, R12-01 through R12-08, R13-01 through R13-11,
R14-01 through R14-08, and R15-01 through R15-09 with these replacements:

- R16-01 replaces all held-session, detached-activation, checkpoint-slot, and
  pre-genesis projection assumptions;
- R16-02/R16-03 replace contradictory checkpoint rules and incomplete run/tree
  work authority;
- R16-04 replaces name/row witnesses and final pathname/body recapture;
- R16-05 replaces A3–A6 materialization and every ambiguous A4/A5 crash suffix;
- R16-06 replaces every fixture that treats 393,216 as reachable actual charge;
  and
- R16-00 pins the merged `1d2c930b` source reconciliation.

Retain exact origin binding, primary-first departure, same-owner stabilization,
frozen finalizing membership, global allocating-intent gate, no global
publication gate, content-addressed lineage/install, target-only predecessor
v2, sequential actual-prior-binary fence, no wrapper bypass, no authority
deletion, and real-death recovery.

Use deterministic subprocess barriers at every format/selector/checkpoint/
genesis, source-witness, allocation intent/durable, abort page/root/refund,
retirement, publication, finalization, and membership CAS. Assert one surviving
transition, no double generation/charge/refund/root row, no mutation past the
activation/allocation gates, no unrelated-body fanout, no lost heartbeat, and
no deadlock.

Run focused codec, reservation migration, transaction, retention, catalog-read,
CLI bridge, command-composition, and app model-management suites; package-wide
`swift test`; and every applicable Build 1 compatibility, governance, and Xcode
gate. Freeze final source/test hashes. Fresh independent code, security, and
architecture reviews of the complete implementation diff must each report zero
Critical, High, and Medium findings.

Stop on a stale baseline; unselected pre-genesis authority; early v2
projection; incomplete/circular selector chain; unrooted partial group/page;
accepted size/mtime/ctime or path change; omitted final second recapture; body
write before intent; ambiguous A4/A5 suffix; incorrect directory counter edge;
absolute/relative path-domain substitution; envelope charged as actual;
incorrect 126,976/454,656/8,456 arithmetic; capacity admitted after search;
authority deletion; raised deadline/FD/input limit; missing real-death case;
stale evidence; or a skipped, interrupted, or timed-out command reported as
passing. Physical MLX, signed release/feed, deployment, enforcement,
settlement, and economic activation remain outside this specification.
