# Build 1 reservation search progress — test specification R21

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. Governing plan candidate:
`reservation-search-progress-addendum-r15.md`.

Every result must be fresh. Skipped, timed-out, interrupted, zero-selected,
fixture-only, synthetic-only, or historical runs are not passing evidence for a
claim they do not execute.

## R21-01 — independent literal codecs and acyclic commitments

Create a test-only implementation sharing no production encoder, model,
reference, digest, base64url, wide integer, framing, page, selector, budget, or
reachability helper. Freeze literal JCS and digests for carrier header, both
record-reference variants, root references, edge intent, target descriptor,
continuation, edge/abandon receipts, external descriptor, identity, storage,
path, lifecycle, budget entry, embedded lease/control authorization, selector
v6, activation/checkpoint substitutions, carrier audit, and all retained R14
work/sequence/page schemas.

Generate minimum, maximum, one-over, unknown-field, duplicate-field, wrong
order/canonicalization, non-NFC, padded base64url, uppercase hex, float,
negative, `2^53-1`, `2^53`, wide-limb overflow, and every single-field illegal
null/enum cross-product. Require independent maximum vectors to prove edge
intent <=24,576, pending selector <=49,152, fixed selector <=65,536, page/body
<=65,536, record count 16 accepted/17 rejected, and tree target count 14 per
carrier/17 per logical mutation/18 rejected.

Build a field-level dependency graph, including every nested reference and
digest preimage. Require the exact topological order
base selector -> intent -> pending selector -> target -> receipt -> carrier ->
between-edge selector -> next pending selector/intent.
Exercise two and 64 consecutive same-tree edges whose later base roots refer to
the prior selected carrier. Any intent reference to a future root/carrier/
receipt, multi-edge descriptor array, digest placeholder, iterative digest,
MMR field, external intent, or intent that hashes its containing selector is a
test failure.

Freeze `targetCoordinateOrderSHA256` from coordinates only and reject a
preimage containing target bytes/digests. Require receipts to contain the prior
work accumulator; only the successor selector may fold the new carrier digest.
A receipt that directly or indirectly contains its own carrier digest fails.
Freeze the three selector-only exception vectors. Intent selection and audit
cursor advancement must have zero targets/objects/units/charge and no receipt;
bootstrap directory selection is legal only before the carrier directory
exists. Any other receipt-free or zero-unit mutation fails.

## R21-02 — carrier format, address boundaries, and direct authority

On production macOS, create minimum and maximum carriers and require exact
lengths 73,800 and 1,057,380, checked `off_t`, full-file digest, full identity,
record transcript, exclusive final rename, and four-FD compliance. Exercise
ordinal 0, 1, hex rollovers, last legal carrier ordinal
433,647,385,996,387, first protocol carrier rejection
433,647,385,996,388, filename-only `2^53-1`, and filename rejection at `2^53`.
Sparse vectors prove codec/address arithmetic only.

Reject short/long/uppercase/path-traversal names, wrong ordinal/predecessor,
wrong pending/base selector or intent, nonzero padding, truncation, trailing byte, payload
overflow, same-path unequal bytes, duplicate final, symlink, hardlink, inode
replacement, same-size rewrite with restored mtime but changed ctime, and
missing-after-fsync.

Construct current storage/path/lifecycle/budget/sequence/work roots whose eight
page path records occupy eight distinct carriers. Verify exactly eight B+ page
reads, at most eight complete carrier hashes and 8,459,040 hashed bytes, four
FDs, and no directory/history scan. Mutating any current carrier protects.
Mutating an unvisited superseded carrier is reported as not-yet-audited until
the incremental audit reaches it; then it protects. Do not claim eager
historical verification.

## R21-03 — selector, carrier, external, directory, and tail crash oracle

Inject death after every syscall/byte boundary in each R15 section 6 table:
selector temp create/write/fsync/rename/directory-fsync/reopen for both the
pending-intent and between-edge selectors; external temp
create/write/fsync/exclusive rename/directory-fsync/identity recapture; mkdir,
parent fsync, no-follow reopen, empty check; carrier temp/header/each slot/file
fsync/exclusive rename/carrier-directory fsync/reopen/hash; successor selector
write/fsync/rename/directory-fsync/reopen.

For every boundary, assert the exact old/pending/successor disk outcomes. A
target before pending-only selector authority fails. After selector-directory
fsync, the old selector fails. After external/carrier directory fsync, only the
exact intent candidate may resume. Same-path unequal, missing candidate,
identity change, stale predecessor, receipt mismatch, and charge mismatch
protect.

Exercise no-pending exact `head+1` cleanup with directory fsync, pending exact
`head+1` adoption, pending unequal `head+1` protection, and clutter at
`head+2`. Require no enumeration, no selected carrier removal, no tail
truncation, and later collision protection. Verify A3 directory intent/durable,
the exact 4,096 charge and A4 transfer, then every A5 primary/origin/class/
lineage intent, file fsync, directory fsync, identity recapture, and receipt
suffix.

## R21-04 — authenticated trees and bounded continuation

Independently construct storage, path, lifecycle, budget, and sequence trees at
heights 1–8 with non-rightmost full leaves and full ancestor chains. Verify
unsigned lower-bound, 17/16 and 9/8 leaf splits, 65/64 internal splits,
separator derivation, ranges/counts/subtotals, stopped cascades `2h-1`, and root
growth `2h+1`. Height eight emits exactly seventeen pages.

Storage/lifecycle must use 32-entry leaves and 17/16 splits; path/budget/
sequence must use 16-entry leaves and 9/8 splits. Freeze a 3,328-byte maximum
budget entry and a complete 16-entry budget leaf <=65,536, then reject either a
seventeenth entry or a byte-overflowing page.

Freeze a two-carrier mutation: fourteen pages + continuation receipt, then
three pages + edge receipt. Local references may point only to lower slots;
the second carrier uses full carrier references for first-carrier pages. Kill
64 helpers after every page, receipt, carrier fsync, carrier-directory fsync,
and selector CAS. One wins; the rest converge or return typed busy/retry.
Ordinary root authority remains old until the final receipt/root selector.

Reject missing/mixed continuation, changed creation order, wrong frontier,
premature root, 15 tree pages in one carrier, 18 logical pages, three carriers,
future/local-forward reference, duplicate unequal key, separator/child reorder,
range/count/subtotal mismatch, and a record/external target mixed with pages.

## R21-05 — selected row/fixed budgets and complete lease accounting

Build the selected budget tree with one entry for every row and one fixed entry.
For each category, independently recompute the transition count, unit limit,
control limit, exact byte limit, and selected entry. Enumerate the full state
space rather than sampling. The independent totals must be:

```text
row transitions = 16+32+16+12+24+64 = 164
row unit limit = 3,116; row control limit = 6,232
fixed transitions = 32+64+32+32+32+128 = 320
fixed unit limit = 6,080; fixed control limit = 12,160
units(R) = 9,367R + 18,323
units(Rmax) = 4,119,650,166,965,693 < 2^52
carrierCount(R) <= 986R+1,928
carrierCount(Rmax) = 433,647,385,996,388 < 2^49
```

Generate every named source/merge/tree/verification/materialization/abort and
fixed transition and compare its independently counted targets, carriers,
reserve pages/receipts, close pages/receipts, continuations, external objects,
units, and bytes with the selected production entry. Exercise the first unit,
last unit, first-over unit, first-over byte, eighth abort generation, and ninth
generation protected transition for every provenance.

For reserve, require the old selected entry to authorize the exact control
maximum before target creation. Crash after each control page/carrier. A
partial reserve retains old root plus selected control continuation and grants
no ordinary lease. Final reserve increments reserved counters and selects one
open lease. Target edges increment only selected lease consumption. Commit
close moves consumed reserved to spent and releases unused operation/abort
reserve. Abandon close also records the exact abandoned subset. All equations
must balance for units and bytes after every selector revision.

Freeze the lease authorization JCS/digest independently. Mutating consumption
must not change authorization identity. The target budget entry must be
computable before page wrapping and must contain only the authorization digest,
never a future receipt/carrier reference. Exercise a between-carriers selector
with null intent and a separate next-intent CAS.

Reject absent post-bootstrap row, multi-row/mixed fixed scope, wrong lowest-row
attribution, category substitution, caller delta, second open lease, lease
digest mismatch, expiry extension, consumption above reserve, abandoned above
spent, control charge from the new rather than prior entry, missing page/
receipt/continuation charge, partial reserve granting authority, double close,
double release, selected-unit refund, overflow/underflow, and aggregate-only
selector claims.

## R21-06 — genesis bootstrap and exact ceilings

For R=0,1,31,32,33,1,024 and synthetic Rmax, independently simulate every
budget entry insertion and the eight named bootstrap publications. Require
`19*(R+1)+64` as unit ceiling, `2*(R+1)+6` carrier ceiling, exact byte preflight,
selected decrement after every edge, unchanged source witness, all R+1 entries,
and zero unused bootstrap state before ordinary work.

Kill after every bootstrap page, continuation, receipt, carrier, selector and
directory fsync. Resume byte-identically or protect. Reject zero-debit entry,
ordinary work before close, a later absent-row exception, duplicate entry,
wrong row/fixed key, scope substitution, omitted directory charge, bootstrap
reuse, source mutation, one-over source row, first unsafe history ordinal, and
host `off_t`/quota/inode failure after v6 publication.

Independently calculate the maximum carrier-byte product
461,817,120,190,713,364,480 and all exact external object/lifecycle/quota/Wpeak/
Uafter additions in wide arithmetic. Smaller sparse or synthetic inputs cannot
be reported as physical Rmax capacity.

## R21-07 — unique external taxonomy and codec cross-products

For every R15 section 5 row, create the real file/directory where applicable
and freeze minimum/maximum external descriptor, identity, storage entry, path
entry, sequence reference, category/scope, and lifecycle transition vectors.
Independently encode every generated external schema and `run_manifest.v5`.
Require capture/merge row-block roles to select distinct object kinds and
categories.

Generate the complete Cartesian product of object kind × carrier class ×
content codec × file type × length-null × digest-null × identity-present ×
path/storage-present × path class × budget scope/category. Accept exactly the
table rows and reject every other product. Specifically reject external run
manifest/tree page/intent, catalog record as external, directory with bytes,
regular file with null bytes, protocol carrier/directory in path/storage,
fixed extent with identity/path, ambiguous row block, unknown kind/category,
absolute/dot/dot-dot/non-NFC path, unsafe length, and external object referenced
only by a record digest.

## R21-08 — forward abandon, cancellation, retries, and economics

Inject cancellation, permanent failure, and death after lease reserve; each
target/continuation carrier; external fsync/directory fsync; path reserved,
materialized, bound, indexed; lifecycle reserved/bound/spent; storage ordinary;
each of the eight compensation steps; budget-close continuation; abandon
receipt; and pending clear.

For each state, run the exact eight-step queue. Inapplicable steps must select
zero-delta completion in order. Applicable tree mutations may use two carriers
but one intent at a time. Verify work accumulator continuity, roots before/
after, retained/invisible object state, lease counters, control counters,
selected unit/byte charge, lifecycle release, pending-clear condition, and
generation. No mutable receipt mark or unlisted `abandoned` lifecycle/path
state is allowed.

Run classified and unclassified A3–A8 matrices with 581,632/696,320 reserve,
exact 4,096 directory transfer, A5 body ordering, A6 spend boundary, immutable
receipt/settlement state, historical holds, caps, and unchanged refund
arithmetic. Before A6 release only the exact unspent reserve; at/after A6
release zero. Retry preserves receipts and advances generation. Eighth failed
retry selects the documented result; ninth selects protected. Reject old-root
rollback, deletion/truncation cleanup, selected-object refund, ordinary
visibility of retained-abandoned paths, cancellation success before stable
null-pending selector and FD/flock closure, and protected-to-abandoned
laundering.

## R21-09 — phase, audit, finite-directory, and compatibility matrices

Generate every legal selector/activation/checkpoint phase row and every
single-field illegal cross-product. Require one current work root, monotonic
prior result roots, null later roots, zero irrelevant counters, legal operation
kind, and null pending at ready. Budget, continuation, audit, and abandon edges
must not advance product phase.

For incremental audit, snapshot heads at 0,1,2,255,256 and synthetic maximum.
Walk at most eight carriers or eight seconds per invocation. Verify predecessor
ordinal/digest/identity and cursor transcript. Inject missing/mutated carrier at
first/middle/last and require protection only when reached. Add new head while
an older snapshot audit proceeds; completion must qualify only the frozen
snapshot. Reject MMR fields/proofs, directory enumeration, skipped carrier,
cursor rewind, alternate predecessor, and an eager-history claim without a
completed audit.

Repeat finite-directory 0,1,31,32,33,64,65 cases, double-zero EOF, rewind,
actual supported ABI startup qualification, and death at every syscall/CAS.
Repeat source size/mtime/ctime/content/path changes before, during, between
passes, and before bootstrap.

Old binaries reject selector v6 without mutation. New binaries reject mixed
v1–v5/v6 graphs, MMR or batch references, external intents, incompatible
receipt/reference versions, unknown object kinds, stale selector after
directory fsync, and a partial translation. Every byte-valid pending v6 state
must forward-complete, abandon, or protect exactly as specified.

## R21-10 — performance, broad verification, and audit gate

At 1,024 physical primary rows plus synthetic height-eight trees and maximum
carrier ordinals, run six cold invocations for lookup, reserve, two-carrier
mutation, close, recovery, abandon, and incremental audit. Record hardware,
OS, filesystem, compiler, fixture geometry, selected test count, duration, p95,
RSS, bytes hashed, page reads, carrier opens, and FD peak. Require p95 <=8
seconds and <=4 FDs. Current lookup additionally requires <=8 pages/carriers
and <=8,459,040 hashed bytes. Audit is separately bounded and cannot substitute
for lookup evidence.

Run targeted Swift tests, full `swift test`, Malibu Xcode tests, CLI/app bridge,
governance, compatibility, and maximum-shape checks. Review the complete
implementation diff independently through native GPT-5.6 Sol code, security,
and architecture lanes. Required gate: zero Critical, High, and Medium findings
in all lanes.

Acceptance reporting separates implementation, fresh local verification,
physical Mac verification, signed feed/release verification, deployed services,
and production qualification. Reservation evidence cannot prove paid admission,
trusted identity, pricing, settlement, or activation. Physical signed feed to
trusted preparation to real MLX to correctly settled request remains blocked
until that exact release/hardware journey runs.
