# Build 1 test specification R18 — reservation R12 corrections

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This specification pairs with
`reservation-search-progress-addendum-r12.md`, SHA-256
`8ad7d3780b58177afb62383a46cc4be97d6c400cb6d57a91bd2241d6f1648375`.
It closes R11-PLAN-H1 through
H5 and R11-PLAN-M1/M2 without weakening any retained R11–R17 case. No source or
test implementation or passing result is claimed.

All cases use production codecs and public entrypoints against one frozen
manifest. Independent encoders, arithmetic, tree/path proofs, state machines,
filesystem walkers, and syscall tracers share no production helper. Every run
records base/head, fixture/log SHA-256, selected/pass/fail/skip counts, duration,
soft FD/quota limits, read/page/descriptor counts, filesystem/OS profile, and
whether inference/hardware was involved. Skipped, interrupted, timed-out,
zero-selected, fixture-only, or historical evidence is not a fresh pass.

## R18-00 — frozen inputs and writer inventory

Require exact input hashes from R12 and base
`1d2c930bad81704dd0acc0322226725d8b64aceb`. Recompute the R4 source hashes and
the complete production authority-writer/wrapper inventory required by R11.
Fetch origin immediately before implementation. Any conflicting reservation,
SPEC, schema, storage, or active decision-path change reopens the plan gate.

## R18-01 — wide arithmetic and maximum-history representability

Use an independent four-limb implementation. Freeze canonical vectors for 0,
1, `2^32-1`, `2^32`, `2^53-1`, `2^64-1`, every R10/R11 charge, `2^120-1`, and
one-overflow operation. Exercise add/subtract/compare/multiply/round-up and
filesystem conversion with carries/borrows across every limb. Reject floats,
strings, negative/oversize/missing/extra limbs, leading-limb overflow, alternate
base, unsafe scalar amount, underflow, and saturation.

Independently compute the full R12 object/directory/lifecycle/finalization bound
for 0, 1, `Rmax-1`, `Rmax`, and `Rmax+1` rows. `Rmax` must fit one selected
storage catalog and `wide-v1`; `Rmax+1` must fail only the frozen source-row
ceiling before write. Also freeze exact-cost sparse production transitions at
the last passing and first failing value for each object-count, one-file,
catalog-entry, and `2^120` bound. Include the old certificate-only value
9,007,199,254,732,800 and prove the added root/control/reserve charges do not
use a JSON number above `2^53-1`. Run host-capacity overflow as a typed local
qualification blocker, never as accepted history.

## R18-02 — one rooted storage catalog and mutable selector extent

Independently encode empty, one-entry, 32/33-entry, fanout 255/256/257, maximum-
height sparse catalogs, every wide subtotal, and fixed-extent root. Require one
selector storage-root field, consecutive ordinals, exact right-edge packing,
child subtotal equality, catalog transcript, and height at most eight. Reject a
second accounting root, missing current/next-root charge, duplicate ordinal,
unsafe subtotal, alternate packing, digest/path mismatch, or selected bytes
outside catalog/fixed extent/Wpeak.

Perform bootstrap plus at least two intent/stable selector renames. At each
prepare, rename, directory-fsync, reopen, and next-call boundary freeze old/new
path identity and bytes. Legal inode changes preserve the one logical extent
charge. Inject child death before/after every boundary and accept only the old
or new complete graph. Replace `active.json` with equal bytes/different inode,
unequal bytes, old selector, symlink, hard link, wrong owner/mode, and replace
its parent directory before both recaptures; require protected state. Prove no
immutable inventory check compares the current selector to the bootstrap inode.

## R18-03 — bounded global path proofs

With the independent B+ tree, freeze roots/proofs at 0, 1, 15, 16, 17, 255,
256, 257 and maximum sparse entries/height. Test inclusion and non-inclusion at
first/middle/last/gap keys with at most eight page reads. Exercise
`reserved -> materialized -> bound`, death at each CAS, exact equal reuse,
unselected equal adoption, prior bound path, unequal same path, and synthetic
path-key collision. Skip/reorder/rebind/double-charge must fail.

For every protocol object, independently derive the UUID/revision/intent/
ordinal/digest path and prove injectivity across maximum ordinals and revisions.
An identical tuple with equal bytes is reused without recharge; unequal bytes
protect. Instrument production over maximum-depth fixtures: no whole catalog,
storage history, directory, or prior generation is enumerated. Every selected
storage entry must have either the registry proof or protocol-path proof.

## R18-04 — closed codecs and independent canonical vectors

Generate minimum, maximum, empty, exact byte-limit, and one-over vectors for
every R12 root, leaf, node, entry, work root, cursor/head, phase transaction,
catalog continuation, fixed extent, storage catalog/partition, path registry,
wide value, pending intent, activation/checkpoint, and selector. Independently
freeze every digest/transcript domain and every allowed collection/entry pair.

Reject duplicate/unknown/omitted fields, implicit null, null outside the exact
table, wrong enum/type/order/domain/path, unsafe integer, malformed digest/UUID,
non-NFC name, traversal, overlong entry/page/root, invalid empty boundary,
unlisted collection pair, inconsistent count/range/transcript, or noncanonical
JSON. Insertion-order permutations must encode byte-identically. This gate may
not call a production encoder from the oracle.

## R18-05 — split phase transactions and 16-entry proof

For every R12 `operationKind`, generate the worst legal sequence height, path-
registry height, storage-catalog height, and final-control suffix. Independently
enumerate each register, catalog-continuation, materialize, bind, sequence-root,
work-root, checkpoint/activation, and complete edge. Assert each intent has
1–16 entries, the declared maxima (12 ordinary, four commit, 16 final control)
are not exceeded, and no edge appends two sequences.

Run maximum-depth merge close (completed-group plus output-run), tree level
close (completed-level plus next-level input), verification close, empty path,
and genesis. Kill the child before/after intent CAS, every object/page fsync,
directory fsync, catalog continuation, registry state, prepared binding,
sequence successor, work root, activation/checkpoint, and stable selector CAS.
After restart, every intermediate is rooted and charged by the selected phase
transaction, is invisible to ordinary phase authority, and resumes only its
missing suffix. Phase completion before all planned objects bind, alternate
target binding, orphan continuation, intent 17, combined sequence append, or
reuse under another transaction fails.

Race 64 helpers at every edge. Exactly one selector revision wins; all helpers
converge without double charge, duplicate registry transition, or process-owned
recovery. Measure every maximum edge under eight seconds, four simultaneous
FDs, 160 direct authority objects, and no descriptor/key/lock retained across
calls. A timeout or over-limit result blocks implementation.

## R18-06 — lifecycle reserve table and accounting

Independently derive deltas for activation work/control, completed/retired/non-
primary history, classified active primary, unclassified active primary, and
later allocation. Require respectively 0, 0, 581,632, 696,320, and 581,632 as
the applicable table rows. Freeze lifecycle keys from independent domain bytes.
Explicitly submit 352,256 and 466,944 and require rejection as superseded.

For each row, kill/race before and after reservation, materialization, binding,
and genesis import. Exactly one nonzero delta is charged and bound to one key;
replay, changed provenance/class, alternate key, nonzero delta on zero operation,
or second row adoption fails. Genesis imports exact aggregate and per-row key
without adding reserve. Later lifecycle consumes the imported reservation under
R8–R10. At every edge assert the wide materialized/work/lifecycle/slack/charged/
quota and free-space equations with an independent filesystem inventory.

## R18-07 — exact directory cursor and lookahead

Compile the exact attrlist/options from R12 and independently calculate the ABI
minimum/maximum aligned record sizes, batch buffer, lookahead buffer, and
lookahead record bound. On every supported filesystem profile run 0, 1, 31, 32,
33 and mixed minimum/maximum-name records plus 8,192 and sparse large-name
directories. Trace syscall arguments, returned record count, record lengths,
and `lseek` values.

Assert the batch returns and selects at most 32, every returned batch record is
selected, `batchAfter` is persisted, lookahead's first record is the exact
sentinel, all lookahead records remain reachable after exact rewind, and the FD
closes. At 33 records, the second invocation begins with the sentinel for record
33. Repeat close/reopen/seek after real child death following open, initial seek,
batch syscall, offset capture, lookahead syscall, rewind, witness recapture,
close, and selector CAS.

Exercise EOF double-zero, `ERANGE`, `EINVAL`, `EIO`, `ESTALE`, `ENOTSUP`, bad
returned-attrs bitmap, malformed attrreference/length/alignment, record above
maximum, offset overflow/negative/non-round-trip, nonmoving non-EOF offset,
failed rewind, and mutation/inode replacement between all steps. Each rejects
or marks the filesystem unsupported before v4; no record is discarded, no
lexical rescan occurs, and no FD survives. The complete call stays inside eight
seconds and four FDs on the actual volume.

## R18-08 — retained crash, mutation, admission, and route gates

Re-run R17-01, R17-03, R17-05, R17-07 through R17-09 unchanged except that R12
wide values, catalog/path roots, split transaction states, and exact directory
algorithm replace their R11 counterparts. Preserve deterministic bootstrap,
zero-row authority, exact in-block tree cursor, two independent source passes,
storage verification, route classes, activation/journal lock order, no lock
across work, ordinary writer fence, no wrapper bypass, and sole genesis.

Re-run R16-05 through R16-07 for inline allocation admission v3, root-relative
paths, A3–A8 deaths, exact directory transfer, actual abort charge/refund, quota,
and 1 GiB arithmetic. Require 126,976 maximum retained abort charge, 454,656
refund, 8,456 maximum-shape aborts, 37,449 minimum aborts, 1,846 successes,
581,632 successful lifecycle, 696,320 unclassified closure, and 1,073,152
finalization. No R12 wide/accounting mechanism changes those economics.

Mutation tests retain same-inode/same-length rewrite, restored mtime with changed
ctime, truncate/restore, chmod/chown/link change, same-byte inode replacement,
rename/symlink/type/certificate/origin substitution, directory mutation during
scan, and namespace re-resolution immediately before genesis. Absence of a
fresh demanded proof is protected, never inferred valid.

## R18-09 — complete suites, audits, and acceptance boundary

Run every applicable R11–R17 case not explicitly replaced above, then focused
codecs, migration, transactions, retention, catalog reads, CLI bridge, command
composition, Malibu model management, package-wide `swift test`, applicable
Xcode tests, and Build 1 governance/compatibility checks. Freeze complete diff,
source/test hashes, commands, counts, logs, and hardware profile. Fresh
independent GPT-5.6 Sol code, security, and architecture audits must each report
zero Critical, High, and Medium findings before acceptance.

Stop on stale baseline; unsafe amount; multiple accounting roots; maximum-
history overflow; selector inode frozen as immutable; unbounded path lookup;
unclosed codec; intent above 16; unrooted split; invented lifecycle delta;
discarded directory record; cursor/rewind ambiguity; weakened source or route
fence; raised deadline/FD/page/body/quota limit; changed A3–A8/refund arithmetic;
selected deletion; or stale/skipped/timed-out/zero-selected/fixture-only evidence
called passing. This corrective suite does not prove physical MLX inference,
signed feed/release, deployed services, production enforcement, settlement, or
economic activation.
