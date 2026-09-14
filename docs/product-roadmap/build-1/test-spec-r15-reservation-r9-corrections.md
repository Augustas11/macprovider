# Build 1 test specification R15 — reservation R9 corrections

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This specification pairs with
`reservation-search-progress-addendum-r9.md`. It corrects R8-PLAN-H1 through H4
while retaining every applicable R4, R11, R12, R13, and R14 case. No test result
or implementation approval is claimed.

All cases use production codecs and real CLI/app entrypoints against one frozen
final source/test manifest. Each result records exact command, base/head SHA,
selected/pass/fail/skip counts, duration, FD limits, quota/free-space values,
read/body/descriptor counters, and SHA-256 of complete logs and fixtures.
Injected errors and real child `_exit` deaths are separate. No interrupted,
skipped, or timed-out command is a pass.

## R15-01 — closed codecs and exact canonical bytes

Implement an independent canonical encoder in test code. For every R9 schema,
freeze minimum, maximum, exact-limit, one-byte-over, canonical-byte, and SHA-256
fixtures. Cover path receipt, name block, row block, run manifest, work root,
verification block, checkpoint selector v2, checkpoint v2, activation v1, and
the amended allocation admission. Do not call production encoders to derive
expected bytes.

For each schema permute source-map insertion order and require identical bytes.
Reject duplicate/unknown/omitted fields; implicit instead of explicit null;
wrong type/domain; unsafe integer; uppercase or malformed UUID/digest; invalid
UTF-8; nonnormalized/root-relative/path-traversal path; wrong schema/state/kind;
noncanonical JSON; BOM; whitespace; and trailing bytes. Require every content-
addressed filename to equal SHA-256 of its canonical bytes and every direct path
to equal R9 section 7.1.

Freeze independent binary-domain digest vectors for configured root path,
namespace, row transcript, work-root transcript, and verification chain,
including zero, one, boundary, and maximum fields. Flip every length, ordinal,
count, UUID byte, digest byte, domain prefix, ordering, predecessor, input root,
or object digest and require rejection.

## R15-02 — no authority survives an invocation

Drive activation through the real `macprovider-cli` command and the Malibu
`Process` bridge for every R9 state. Force at least two invocations in name
capture, row capture, merge, build, and verification. Each invocation receives
one fresh eight-second caller budget and exits before the next begins.

Instrument journal-lock, activation-flock, file FD, directory FD, `DIR *`, and
secret-key lifetimes. At every normal, error, cancellation, deadline, and real-
death return require zero surviving handles/locks and zero persistent or logged
key bytes. Require the journal lock only around bounded checkpoint/activation or
genesis CAS recapture. Fail if it is held while scanning, reading a certificate
or origin, sorting, merging, building, or verifying.

Between every pair of invocations run heartbeat, status, live/queued cancel, and
read-only catalog control. They must finish under their inherited limits while
the durable activation fence makes every transaction-root mutation route,
including the actual prior binary, reject before write. Race two activation
invocations: exactly one nonblocking activation lock advances one generation;
the other returns typed busy with no byte change.

Kill the CLI and app child after every immutable create, file fsync, rename,
directory fsync, selector slot, selector, activation CAS, and genesis CAS.
Restart in a new process with no inherited descriptor/key and require progress
from only the selected activation/checkpoint/content hashes. No case may use a
serialized `telldir`/`seekdir` value or restart at entry zero after a selected
name capture.

## R15-03 — portable root/path replacement detection

Freeze an absolute transaction-root fixture with multiple parent components.
Independently encode the component receipt using `st_dev`, `st_ino`, file type,
mode, owner, group, link count, and POSIX modify/change seconds/nanoseconds.
Require component-by-component no-follow resolution from `/`, exact normalized
names, explicit null times on `/` and intermediate parents, exact non-null root
times, and an exact canonical path digest.

After initial receipt, independently replace each parent component and the root
pathname by rename plus an equal-byte tree. Also test symlink substitution,
directory/file type swap, chmod/chown where permitted, hard-link violation,
inode replacement with equal bytes, replacement before open, replacement after
open, and replacement immediately before final CAS. Selection must fail on the
new component identity even while the old FD remains valid.

For namespace hashing, create raw directory order different from UTF-8 byte
order. Independently sort and hash records using R9's exact binary encoding.
Insert, delete, rename, replace, duplicate-normalize, change type, change
identity, and add an unsafe entry during either complete scan and between scans.
Require failure. Timestamp-only and `st_gen` values are not accepted as proof.
The initial and final namespace hash and every component identity must match at
genesis. After the final namespace scan, mutate the root before the journal CAS;
the bounded under-lock component re-resolution/time-tuple comparison must fail
without rescanning the namespace under that lock.

Build the maximum valid namespace-only fixture permitted by the frozen quota
and run both required complete scans through production. Each must finish under
eight seconds with the soft FD limit 256 and bounded memory/work inventory.
Treat a timeout as failure; do not retain a directory stream or raise a limit.

## R15-04 — durable name and row capture

Create 0, 1, 4,095, 4,096, 4,097, and multiple-block name sets whose physical
directory order differs from UUID order. Independently derive every name block,
previous-block link, block/root ordinal, first/last UUID, path, byte length, and
digest. Require one complete selected name root only after EOF, both same-call
namespace hashes, all object fsyncs, directory fsyncs, and final path recapture.

Kill before the name-root checkpoint CAS and require restart of the namespace
scan with only unselected objects reusable. Kill after it and require the new
process to direct-open the selected name blocks without enumeration continuation.
Unequal digest collision, missing block, changed link/count/range/name identity,
unfsynced block, or block not named by the root is protected.

For each selected name block, capture rows in slices of 1, 4,095, 4,096, and a
short tail. Change the certificate or origin before open, during read, after
read, and after block write. Test same-byte inode replacement separately.
Require before/after portable identity, canonical body digest, exact UUID/name,
and exact origin binding. Checkpoint `nextNameOrdinal` advances only over one
durable consecutive range and survives real process restart. Skip, repeat,
overlap, alternate source root, or caller-supplied name fails before selection.

## R15-05 — deterministic merge, build, verification, and checkpoints

Create enough captured rows for more than 32 runs, multiple merge passes, 4,096
boundaries, 64-row leaf boundaries, 256-child boundaries, and a final short
group. Independently reproduce:

- creation ordinals reserved by predecessor checkpoints;
- capture-run and merge-run field sets;
- input order `(firstUUID, creationOrdinal, manifestSHA256)`;
- consecutive groups of at most 32;
- output row blocks of at most 4,096;
- exact `rowsSHA256`, work-root chain, and ordered object arrays; and
- final 64/256 v1 pages and exact tree work-root order.

Require byte-identical outputs on retry of one selected checkpoint. Duplicate
UUIDs in one block, across blocks, or across merge groups fail. Reject 33 inputs,
wrong pass/run/creation ordinal, reordered inputs/outputs, alternate grouping,
generation skip, changed predecessor/input root, omitted page, extra page, or
top-root-only transcript.

At every generation decode active selector, both slots, selected activation,
and every referenced immutable object. Require alternating slot, generation
`n+1`, exact previous digest, equal activation generation/state/frozen bindings,
closed nullability/cursor rules, and exact terminal count. Select an unfsynced
slot/object, highest-but-unselected generation, stale selector, wrong slot,
cross-activation object, non-null future field, null required field, cursor past
input, or changed immutable byte and require protected failure.

Inject death before/after every slot temporary/write/fsync/rename/directory-
fsync, selector boundary, activation CAS, leaf, each internal level, root, work
root, and verification block. Recovery must select exactly the checkpoint named
by activation, reuse only byte-identical objects, and execute only the missing
suffix.

Verification reopens first/middle/last and every row across bounded calls,
checks captured certificate/origin identity and bytes, and proves exact tree
membership. Omit/substitute/reorder a verification block, body, row block, page,
or root and require no genesis. After terminal verification mutate the root
path or namespace before either final recapture and require no genesis. Crash
before genesis leaves no R9 root selected; crash after selects exactly v1 and
the canonical empty v2/abort roots.

## R15-06 — explicit empty-directory crash state

Independently encode every legal allocation state and edge:

```text
A0 -> A1 -> A2 -> A3 -> A4 -> A5(primary) -> A5(origin) ->
A5(class) -> A5(lineage) -> A6
A1 -> A7 -> A8
A2 -> A7 -> A8
```

At A2 require row selected and all directories/bodies absent. A2→A3 must select
`directory_intent` and the exact lineage-directory path digest before `mkdir`.
Kill immediately before/after A3 CAS, mkdir, directory fsync, parent fsync,
portable identity capture, and A4 CAS. On restart, selected A3 plus absent or
exact empty directory may only converge to A4. Selected A4 must bind the exact
existing empty directory identity and may only create primary.

At A3/A4 place a wrong path, symlink, regular file, extra entry, wrong mode or
owner, changed inode, or nonempty directory. Require protected result with no
deletion/refund. Replace the directory after A4 and require identity failure.
Change any materialization phase/path/identity independently and reject before
write.

Prove abort/refund is permitted only at A1/A2. Race A2→A3 against A2→A7 and
require exactly one CAS. If A3 wins, even death before mkdir permanently forces
forward completion. One byte, A3, A4, or any A5 phase makes A7 illegal. A7/A8
retain the exact rooted abort, replay, owner, generation, charge, and global-
gate cases from R14 with shifted labels.

## R15-07 — exact abort cascades and disk inventory

Use an independent abort-tree encoder. Freeze old trees and insertion keys for
each R9 successor-shape row, especially:

1. height two, full leaf and 256-child top: write two leaves, two replacement
   level-one pages, one new level-two top, then root;
2. height three, full leaf and full non-top level-one page: write two leaves,
   two replacement level-one pages, one replacement level-two top, then root;
3. adjacent noncascading shapes that produce zero, one, or two internal pages.

At every step inventory exact old/new leaf, internal-page, receipt, directory,
and root paths. After each of the three internal-page writes inject ENOSPC,
EDQUOT, thrown error, deadline, cancellation, and real death. Selected A7 and
its fixed successor must survive; restart reuses equal objects and writes the
remaining exact suffix. Unequal collision or alternate split is protected.

Independently compute exact maxima 114,688; 184,320; 253,952; 323,584; and
393,216 for their applicable shapes. The two cascade fixtures must reserve and
retain exactly 393,216 at maximum canonical lengths. Fail any implementation
that freezes 323,584, omits the third internal page, changes charge after A7,
or removes an old page/root.

## R15-08 — quota, refunds, Wpeak, and 1 GiB feasibility

Independently implement `F(M)` and enumerate disk without production accounting.
Verify every 4,096 boundary and one byte each side. Require the R9 bundle table,
including 393,216 abort maximum, 581,632 success lifecycle, 696,320 source
closure, 1,073,152 finalization, and 3,158,016 fixed mutable footprint.

For minimum through maximum actual abort shapes, assert at A7 that gross/net
charge is 581,632 and unchanged. At A8 require one refund exactly
`581,632-retainedAbortChargeBytes`, including 552,960 at 28,672 retention and
188,416 at 393,216 retention. Repeat A8 and prove no second refund. Inventory
every retained receipt/directory/page/root in `materializedBytes`.

Freeze exact 1 GiB fixtures and independently prove:

```text
1,846 * 581,632 = 1,073,692,672; remainder 49,152
37,449 * 28,672 = 1,073,737,728; remainder 4,096
2,730 * 393,216 = 1,073,479,680; remainder 262,144
```

Exercise all-success, all-minimum-abort, all-maximum-abort, and mixed `S/Ai`
histories exactly at the logical headroom and one byte over. Admit the final
closure that fits and reject the next before row/object/charge. Assert v2 at
most 2,870 rows/height two and abort at most 37,449 rows/height three.

For every selected state assert gross minus refund equals charged, materialized
plus reserved remainder plus slack equals charged, and charged does not exceed
quota. Verify `Wpeak` 69,632 for a maximum page, 20,480 for receipt/root, and
4,096 for directory, with only the current permanent write removed from
`Uafter`. Test free space one byte below, exactly at, and one byte above
`536,870,912 + Wpeak + Uafter`. Include every activation block/manifest/
checkpoint temporary in peak inventory; after genesis remove only unselected
work.

## R15-09 — retained bounds, hostile concurrency, and gate

Re-run R11-01 through R11-13, R12-01 through R12-08, R13-01 through R13-11, and
R14-01 through R14-08 with these replacements:

- R15-02 through R15-05 replace R14's held live session, HMAC key, `DIR *`
  continuation, `st_gen` witness, vague path CAS, and incomplete work formats;
- R15-06 replaces A0–A6 and treats the empty directory as A3/A4 authority;
- R15-07/R15-08 replace every 323,584 abort maximum with 393,216 and require
  both three-internal-page cascades; and
- all retained maximum projections use the amended admission fields and legal
  mutually exclusive states.

Retain exact origin, primary-first departure, same-owner stabilization, frozen
finalizing membership, global allocating-intent gate, no global publication
gate, content-addressed lineage/install, target-only predecessor v2, byte-equal
pre-capture identity, strict post-capture identity, sequential prior-binary
fence, no wrapper bypass, 1,024 rows, 256 soft FD limit, four live reservation
descriptors, ten ordinary reads, body-byte ceiling, and eight-second calls.

Use deterministic subprocess barriers at every activation/checkpoint/namespace,
allocation-directory, abort-page, retirement, publication, finalization, and
membership CAS. Assert one surviving transition, no double generation/charge/
refund/root row, no mutation past the activation or allocation gate, no lost
heartbeat, and no deadlock.

Run focused codec, reservation migration, transaction, retention, catalog-read,
CLI bridge, command-composition, and app model-management suites; package-wide
`swift test`; and every applicable Build 1 compatibility, governance, and Xcode
gate. Freeze final source/test hashes. Fresh independent code, security, and
architecture reviews of the complete implementation diff must each report zero
Critical, High, and Medium findings.

Stop on any surviving cross-call handle/key; bulk journal lock; process-local
progress; filesystem cursor resumption; accepted path replacement; ambiguous
or unfsynced work; empty-directory ambiguity; refund after directory intent;
missing third abort internal page; wrong charge/refund/quota equation; capacity
admitted after search; authority deletion; unrelated-body fanout; non-target
mutation; global publication gate; raised limit; unverified prior binary;
missing real-death case; stale evidence; or a skipped, interrupted, or timed-out
command reported as passing. Physical MLX, signed release/feed, deployment,
enforcement, settlement, and economic activation remain outside this
specification.
