# Build 1 reservation search progress — test specification R20

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. Governing plan candidate:
`reservation-search-progress-addendum-r14.md`.

Every result must be fresh. Skipped, timed-out, zero-selected, fixture-only, or
historical runs are not passing acceptance evidence.

## R20-01 — independent literal codecs and arithmetic

Create a test-only implementation sharing no production encoder, model,
digest, base64url, wide integer, page, MMR, or framing helper. Generate literal
JCS bytes/digests for every R14 section 8 schema, all twelve inherited sequence
pairs with the explicit added fields, the three new pairs, all five index
families, header, frame, intent, descriptor, continuation/edge receipt,
selector v5, activation v6, checkpoint v7, identities, and budget lease.

Exercise every enum/null phase row, unknown/duplicate fields, non-JCS, float,
unsafe number, `2^53-1`, `2^53`, noncanonical wide limb, padded base64url,
invalid NFC/path, 65,535/65,536/65,537 bodies, 15/16/17 records, nonzero
padding, truncated header/slot, trailing byte, and wrong ordinal. Independently
freeze transcript preimages for receipt, descriptor, batch payload, complete batch content, MMR leaf,
node, and root. A cycle analyzer must prove intent → target → receipt → batch
header/content hash → selector, with no future digest edge.

Recompute exactly:

```text
16*128^7 = 9,007,199,254,740,992
admitted safe capacity = 9,007,199,254,740,991
U(Rmax) = 3,602,879,710,281,728 < 2^52
```

Require last-safe and first-unsafe root/count vectors. An asserted constant
without independent recomputation fails.

## R20-02 — segmented/batch maximum and host ABI proof

On the production macOS ABI, create minimum and maximum 16-record batch files
and require exact lengths 73,800 and 1,057,380 bytes, checked `off_t`
conversion, direct 16-hex address, and four-FD compliance. Use sparse/synthetic
metadata to prove address derivation at batch ordinals 0, 1, rollover hex
boundaries, `U(Rmax)-1`, and `U(Rmax)`, without claiming those sparse vectors
are physical capacity evidence.

Reject ordinal `2^53`, uppercase/short/long/path-traversal filenames, wrong
header ordinal, aliased hardlink/symlink, duplicate final path, payload length
overflow, and a host unable to satisfy exact object/quota preflight. Distinguish
format addressability from host qualification. No `off_t` failure is accepted
as the normative maximum-format result.

## R20-03 — MMR membership, mutation, and recovery

Generate 1, 2, 3, 255, 256, 257 and synthetic maximum-leaf peak states.
Independently recompute every carry, 53-slot peak vector, bagged root, and the
deterministic merge-event ordinal. Prove every chosen first/middle/last leaf in
at most 53 merge steps and at most four simultaneous FDs.

Mutate a live page batch, current root batch, work root, checkpoint, activation,
last receipt, and a superseded historical batch. Include same-size rewrite with
restored mtime, changed ctime, inode replacement, hardlink, symlink, short/full
rewrite, wrong merge-event base peaks, and forged sibling. Live references must
protect before authority. Superseded corruption must fail incremental storage
verification and any later direct proof; the test must not claim an unaccessed
historical byte is eagerly scanned.

Crash at every byte/boundary: temp create/write/fsync, header completion, final
rename, batch-directory fsync, reopen/hash, selector temp/write/fsync, selector
rename, selector-directory fsync, reopen. Require the exact R14 boundary table,
exclusive final paths, no truncation, old/new only in the documented selector
rename window, and new-only after directory fsync.

## R20-04 — arbitrary-key CoW B+ tree

For path, lifecycle, and budget trees, independently construct non-rightmost
full leaves and full ancestor chains at heights 1–8. Verify lower-bound,
17/16, 9/8, and 65/64 splits, separator derivation, range/count/subtotal
recalculation, stopped cascades `2h-1`, and root growth `2h+1`. Height eight
must produce seventeen pages, never eight.

Freeze a two-batch target: fourteen pages + continuation receipt followed by
three pages + edge receipt. Kill 64 helpers after every created page, receipt,
batch fsync, batch-directory fsync, selector CAS, and final root selection.
Exactly one successor wins; others converge or return typed busy/retry. Reject
duplicate unequal keys, collision, pivot/child reorder, missing continuation,
premature root publication, target over 14 pages in a continuation, and any
edge over sixteen records/external objects.

Repeat right-frontier storage/sequence tests to prove they use the same page
validation while retaining their simpler append behavior.

## R20-05 — complete descriptors and byte-exact replay

Construct pairs of intents differing only in target key, source row, range,
sequence collection, sequence ordinal, path, storage ordinal, lifecycle key,
base root, or operation input reference. Each pair must have unequal descriptor
and intent digests and byte-distinct deterministic targets where applicable.

For every edge kind, kill before/after each continuation and recover using only
the selected roots, intent, descriptor, and referenced immutable inputs.
Recovery must reproduce identical target bytes. Reject recovery that reads
caller arguments, current directory enumeration, mutable source/checkpoint
state, a future receipt, or an unreferenced object. Reject omitted coordinates,
illegal null matrix, reused intent ID, target digest placeholder/iteration,
wrong creation order, edge skip/replay, or mixed descriptors.

Exercise 1- and 64-edge intent files, the exact 1,048,576-byte maximum and
one-over, intent file/directory fsync and pending-selector crashes, same-path
unequal bytes, identity mutation, abandoned intent retention, and completed
storage/path indexing. Assert the selector stays within its fixed extent and
contains only the exact intent reference, never embedded descriptors.

## R20-06 — authoritative per-row/fixed budgets

Independently build and decode the selected budget tree. Import every row's ten
scale keys and the ten fixed keys. Exhaust each category separately and require
the next unit to fail before file creation. Prove aggregate sums 8,192 per row
and 8,388,608 fixed from the literal tables.

Exercise a maximum path transition, lifecycle transition, storage insertion,
40-pass merge, tree cascade, verification pass, phase close, crash, and abandon.
For each, independently simulate target pages plus budget-tree pages twice and
require a stable fixed point. Verify lease descriptor binding, generation,
expiry at revision +64, exact consumption, release of unused units, and no
release of already selected units.

Reject aggregate-only selector claims, missing row key, wrong category, shared
work not charged to lowest row, scale work charged fixed, fixed work charged
scale, fallback category, caller-selected delta, lease replay/extension,
counter overflow/underflow, unequal second simulation, and mutation without a
selected inclusion proof. Production selected-state bytes, not simulator-only
totals, are required evidence.

Test the genesis bootstrap exception separately: an absent row key can appear
only with its own exact source-capture debit in the same selected batch. Reject
zero-used insertion, debit in a later batch, duplicate bootstrap, fixed/scale
scope substitution, and replay with unequal page bytes.

## R20-07 — exhaustive external taxonomy

For every R14 section 6 row, freeze minimum/maximum identity and storage/path
entry vectors, create the real file/directory where applicable, and verify
content, canonical length, relative-path digest, no-follow stat identity,
charge category, storage class, path class, and lifecycle transition.

Reject every pairwise illegal cross-product: regular with null length/digest,
directory with bytes, fixed extent with identity/path entry, work record stored
externally, external object referenced only by catalog record digest, wrong
category, wrong class, unlisted kind, absolute/dot/dot-dot/non-NFC path, same
path unequal bytes, and mutable/replaced inode. Cover raw-name, name, row, run,
tree, both verification block kinds, four certificates, prepared artifact,
four receipt bodies, four directories, catalog carrier, selector, and lock.

## R20-08 — forward abandon, cancellation, and refund preservation

Inject cancellation, permanent failure, and process death after: budget lease,
each continuation, lifecycle reserve, path reserve, external file fsync, path
materialized, path bound, lifecycle bound, storage indexed, path indexed, and
phase commit. Require the exact forward successor in R14 section 7.

Verify selected batches/pages/objects remain charged and MMR-selected; unused
lease and unspent lifecycle reserve alone are released; retained objects are
ordinary-invisible; no selected bytes are truncated/deleted. Retry must advance
generation, preserve the abandoned receipt, reuse only byte-identical adopted
objects, and keep one lifecycle row key across classified/unclassified paths.

Run the full inherited A3–A8 matrix: exact 4,096 directory transfer once,
581,632/696,320 reserve by provenance, immutable receipt/settlement state,
historical holds, and unchanged refund arithmetic. Reject old-state rollback,
second reserve, deletion-based cleanup, abandoned object visibility, cancel
success before stable selector/fsync/FD closure, and laundering protected state
as abandon.

## R20-09 — phase matrices, EOF, source identity, compatibility

Generate every legal selector/activation/checkpoint phase row and every
single-field illegal cross-product. Require exactly one current work root,
monotonic prior result roots, zero irrelevant counters, legal operation kind,
and null pending transaction at ready. Exercise sequence collection/schema
pairs and reject all unlisted pairs.

Repeat R19 finite-directory cases for 0, 1, 31, 32, 33, 64, and 65 entries,
including double-zero EOF, rewind, child death at every syscall/CAS boundary,
and no repeated/lost record. Repeat source size/mtime/ctime/content/path witness
mutation before/during/between the two passes and before genesis.

Old binaries must reject selector v5 without mutation. New binaries must
forward-recover every byte-valid pending v5 state and reject partially
translated v1–v4 graphs, stale selector after directory fsync, incompatible
receipt version, unknown object kind, and mixed catalog-log/batch references.

## R20-10 — exact accounting, maximum-shape, and audit gate

Independently fold every batch carrier charge `F(length)` exactly once, every
external object/directory/fixed extent, lifecycle reserve, finalization,
quota, Wpeak, and Uafter in wide arithmetic for 0, 1, `Rmax-1`, `Rmax`, and
first failing row. Exercise batch counts at safe/JCS boundaries and ensure no
record is double-charged as both carrier bytes and a file.

At 1,024 physical primary rows plus synthetic height-eight indexes and MMR
leaf-count fixtures, run six cold invocations per operation. Require p95 <=8
seconds, at most four FDs, eight B+ page reads, 53 MMR steps, no directory or
history scan, and bounded peak RSS. Record hardware, OS, filesystem, compiler,
fixture geometry, selected test count, duration, RSS, and FD peak. Synthetic
maxima prove algorithms, not physical Rmax capacity.

Run targeted Swift tests, full `swift test`, Malibu Xcode tests, CLI/app bridge,
governance and compatibility checks. Review the complete diff independently
through native GPT-5.6 Sol code, security, and architecture lanes. Required
gate: zero Critical, High, and Medium findings across all lanes.

Acceptance reporting separates implementation, fresh local verification,
physical Mac verification, signed feed/release verification, deployed services,
and production qualification. This migration cannot prove paid admission,
identity, pricing, settlement, or activation. Physical signed-feed → trusted
preparation → actual MLX → correctly settled request remains blocked until the
exact release/hardware journey runs.
