# Build 1 reservation search progress — test specification R19

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. Governing plan candidate:
`reservation-search-progress-addendum-r13.md`.

This specification must close every R12 independent finding without weakening
R4–R12 security, capacity, compatibility, recovery, or product-truthfulness
requirements. Every test is fresh. A skipped, timed-out, zero-selected,
fixture-only, or historical run is not passing acceptance evidence.

## R19-01 — independent codecs and page geometry

Build a test-only encoder/decoder that shares no production model, encoder,
digest, transcript, base64url, wide-integer, frame, or page helper. Freeze
minimum, maximum, and one-over vectors for every schema named by R13 section 6,
including every retained R12 sequence entry/work object and each R13 sequence
page/root reference.

Assert exact maximum JCS byte counts from independently constructed values:

| object | maximum bytes |
|---|---:|
| storage entry | 644 |
| storage leaf | 41,743 |
| storage child | 389 |
| storage node | 50,415 |
| path entry | 1,865 |
| path leaf | 30,394 |
| path child | 331 |
| path node | 43,066 |
| lifecycle entry | 489 |
| lifecycle leaf | 31,903 |
| lifecycle child | 331 |
| lifecycle node | 43,071 |
| sequence leaf | 49,719 |
| sequence child | 239 |
| sequence node | 31,303 |

The fixture generator must derive these counts from literal schemas and legal
maximum fields, not copy a production constant. Exercise 63/64/65 storage and
lifecycle entries, 127/128/129 node children, 15/16/17 path/sequence entries,
levels 0/7/8, maximum base64url path, maximum row bytes, every nullable field,
every enum, and each safe/wide boundary. Reject unknown/duplicate fields,
alternate base64/padding, invalid UTF-8/NFC/path, float, unsafe number,
noncanonical wide limb, wrong array order, digest domain, transcript item
order, slot ordinal/offset, nonzero slot padding, truncated slot, and
65,537-byte record. Require exact 65,572-byte slots and selected length equal
record count times slot bytes in checked wide arithmetic.

Compute capacities independently and require storage `64 * 128^7` and path/lifecycle
`leafCapacity * fanout^7` exceed the exact maximum unit/row counts while every
inclusion and non-inclusion proof reads at most eight pages. This test fails if
a page-byte or capacity equation is asserted rather than recomputed.

## R19-02 — retained generations and exact accounting

On a real APFS temporary volume, create genesis and at least 257 successive
right-frontier replacements in each index. Force leaf split, every internal
split, root growth, and updates at maximum legal height through synthetic page
fixtures. After every edge independently parse the selected log prefix and
recompute record count, transcript, current roots, exact selected length,
`F(length)`, materialized/charged/category totals, quota, `Wpeak`, and `Uafter`.

Assert all superseded page/root records remain byte-identical inside the
selected prefix, contribute to length/transcript/file charge exactly once, and
do not contribute to current live-tree subtotals. No path enumeration or
history walk is allowed in ordinary lookup. Mutate one byte in an old page,
restore mtime where supported, append a valid-looking excess record, truncate
at every frame byte, change padding, replace inode, hardlink/symlink, or alter
size/mtime/ctime independently. Restart must protect before ordinary authority.

Crash after header, each page record, receipt, log fsync, pending selector,
selector temp fsync, selector rename, selector-directory fsync, and reopen.
Require exact old-prefix/tail recovery before selector-directory fsync and new
prefix only afterward. Assert a stable selector never accepts a tail and a
pending selector never accepts bytes outside its exact edge bounds.

## R19-03 — acyclic intent/target/receipt/selector graph

Implement an independent schema dependency analyzer. It must derive the order
intent bytes → target records/external object → edge receipt → selector and
prove no target field contains receipt/selector/future digest. Freeze minimum
and maximum intent, receipt, selector v4, activation v5, checkpoint v6,
catalog-log identity, and immutable-file identity vectors, all root-reference
null/non-null cases,
1/15/16/17 permanent units, target-record/external-object partitions on the
16-unit boundary, 1/64/65 planned edges, and every edge/index enum.

Attempt the R12 cycle, placeholder digests, digest iteration, target naming its
receipt, receipt naming successor selector or its own final log transcript,
wrong base selector/log transcript, reordered target-record digest array,
receipt digest present in that array, omitted external identity, reused intent ID
with unequal preimage, and edge ordinal replay/skip. Each must fail before
selection. Kill the child at every creation/fsync/append/receipt/CAS boundary;
recovery may publish only the exact receipt or restart the exact edge, never
invent target bytes or grant ordinary authority from a pending transaction.

## R19-04 — 16-entry split-edge proof and concurrency

For every edge in R13 section 5, independently enumerate permanent external
files and log records at heights 1 and 8. Require maxima 9, 10, 9, 9, 2, 3,
and 4 as applicable and reject 17. Exercise maximum-depth adoption in the exact
order lifecycle-reserve → path-reserve → external-materialize → path-bind →
lifecycle-bind → storage-index → path-indexed → phase-commit.

Kill at every boundary and assert ordinary authority remains on the prior
phase until final commit. Specifically reject bound-but-unindexed visibility,
indexed path without storage entry, storage entry without byte-identical file,
combined path+lifecycle mutation, two sequence changes, skipped state, and a
prepared-binding or catalog-continuation R12 object.

Run 64 helper processes against the same transaction and 64 against distinct
transactions sharing frontier pages. Exactly one edge successor is selected;
all helpers converge on identical bytes or typed busy/retry. Assert four FDs,
eight seconds, no leaked descriptor/flock/key/cursor, deterministic
same-owner busy, and queued cancellation acknowledged only after stable cleanup.

## R19-05 — bounded lifecycle uniqueness

At empty, one-entry, split, maximum-height, and synthetic `Rmax` roots, prove
row-key non-inclusion/inclusion in at most eight reads. Exercise active primary
classified and unclassified imports, same row at a different canonical path,
same row with alternate class, same lifecycle digest with unequal UUID,
duplicate source row, replayed intent, genesis restart, and later allocation
consumption.

Require exactly one row-derived key regardless of class, exactly 581,632 or
696,320 reserve from selected provenance, transitions absent→reserved→bound→
imported, and genesis import with zero new reserve. Reject 352,256/466,944,
caller-supplied delta, zero-delta key, class-qualified duplicate keys, second
path, state skip/rollback, second reserve, allocation with a new row key, and
any uniqueness decision requiring a catalog/history scan.

## R19-06 — closed corrected 768-unit ledger and wide arithmetic

Write an independent operation simulator from the literal R13 category table.
For each operation/source-row provenance, count every external object, page,
work record, checkpoint, activation, selected selector revision, receipt, empty,
rounding, recovery, and fixed unit. Prove each unit has exactly one category
and row attribution and the category maxima sum to 768. Prove the fixed ledger
sums to 1,048,576 and contains no scale-dependent work.

Freeze exact totals:

```text
U(0)      = 1,048,576
U(1)      = 1,049,344
U(Rmax-1) = 337,769,973,100,288
U(Rmax)   = 337,769,973,101,056
Rmax+1    = rejected before multiplication or mutation
```

Exercise worst-case 40-pass merges, four path transitions for each of three
paths, sixteen immutable units,
maximum-height page replacements, all lifecycle transitions, crash receipts,
right-frontier rounding, and empty/final phase objects. Exhaust each category
independently and require the next unit to fail before append. Reject fallback
category, missing row attribution, shared object charged to a non-lowest row,
scale work charged fixed, counter overflow/underflow, and caller assertions.

Independently calculate exact catalog slot bytes, zero padding, `F` once for the
whole log, external charges, directories, lifecycle reserve, finalization,
quota, `Wpeak`, and `Uafter` in wide arithmetic for 0, 1, `Rmax-1`, `Rmax`, and
first-failing vectors. Require exact conservative maximum
`1,422,665,509,422,598,725,632` below `2^71` and `2^120`; reject unsafe JSON,
host `off_t`/quota conversion failure as a named local qualification blocker.

## R19-07 — finite-directory cursor and death recovery

On the actual qualified APFS volume, build directories with 0, 1, 31, 32, 33,
64, and 65 valid records plus mixed minimum/maximum names. Freeze raw offsets,
records, sentinels, lookahead results, rewinds, transcripts, and final blocks.
For a nonempty final main batch followed by zero lookahead, require rewind,
second zero at unchanged offset, final nonempty block selection with `eof=true`,
null sentinel, and no repeated/lost record. Test main-call zero plus confirming
zero separately.

Inject mutation and child death before/after main syscall, offset capture,
first zero, rewind, confirming zero, witness recapture, close, selector rename,
directory fsync, and reopen. After recovery every record appears exactly once
and selected EOF is terminal. A record/error/offset change after candidate
zero, inability to rewind, changed identity/time witness, sentinel mismatch,
unsupported ABI, or eight-second/four-FD breach must protect. Lexical rescan,
held-FD recovery, discarded lookahead, and treating a one-zero result as EOF
are forbidden.

## R19-08 — source identity and complete migration regressions

Repeat the independent R16 size/mtime/ctime/content/path witness suite before,
during, and after both source passes and before genesis. Include same-length
rewrite, truncate/restore, rename replacement, restored mtime with changed
ctime, hardlink, symlink, owner/mode change, and final recapture. Require exact
device/inode/type/size/mode/owner/group/link/mtime/ctime equality and body
digest before selected row authority.

Run every inherited A3–A8 directory/body intent, durable, abort, refund,
finalization, quota, protected-evidence, and compatibility test. Require the
4,096 directory transfer exactly once at A3→A4, immutable settlement/receipt
behavior, and no alteration of refund economics. The prior binary must reject
selector v4/catalog-log format before mutation; the new binary must forward-
recover every valid selected v4 state and reject every R4–R12 incompatible or
partially translated graph.

## R19-09 — post-fsync rollback oracle

Use subprocess barriers and real file/directory fsync. At prepared create and
temp fsync before rename, require old selector only. In the rename-before-
directory-fsync crash window, permit old or new complete graph according to
filesystem outcome. After directory fsync returns, require new selector only;
repeat after no-follow reopen verification. Inject a stale but internally
complete old selector at both post-fsync boundaries and require rollback
protection.

For the catalog log, cover every byte before/after pending-selector CAS, append,
frame completion, log fsync, receipt, final selector rename, directory fsync,
and reopen. Before final durable CAS, only the selected pending transaction may
validate/truncate/publish its exact tail. After it, base-prefix truncation or
old-selector selection is forbidden. No test oracle may accept “old or new” at
all boundaries.

## R19-10 — performance, product truth, and complete audit gate

At 1,024 physical primary rows plus maximum legal synthetic-height indexes,
measure every operation with six cold invocations. Require p95 ≤8 seconds,
four FDs, at most eight page reads per lookup, no directory/history scan, and
bounded memory. Record hardware, OS, filesystem, compiler, fixture geometry,
selected test count, duration, and peak RSS/FDs. Synthetic scale proves bounds,
not physical `Rmax` capacity.

Run targeted Swift tests, full `swift test`, Malibu Xcode tests, CLI/app bridge,
governance, compatibility, and the broader repository checks appropriate to
the combined Build 1 diff. Review the complete diff through independent native
GPT-5.6 Sol code, security, and architecture lanes. The gate is zero Critical,
High, and Medium findings across all lanes. Any architecture/contract/test
strategy change reopens this plan gate.

Acceptance reporting must separate implementation completion, fresh local
verification, physical Mac verification, signed-feed/release verification,
deployed service evidence, and production qualification. Catalog migration
evidence does not grant paid admission, trusted identity, pricing authority,
settlement, enforcement, or economic activation. Physical signed-feed →
preparation → real MLX → settled request remains a named blocker until that
exact journey runs on the required hardware and release chain.
