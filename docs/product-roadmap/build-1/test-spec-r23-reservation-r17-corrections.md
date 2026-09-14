# Build 1 reservation search progress — test specification R23

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. Governing candidate:
`reservation-search-progress-addendum-r17.md` plus the explicitly retained R16
clauses named by R17 section 1.

R23 supersedes R22 where they conflict and incorporates every R22 case not
changed here. In particular, root-promotion topology, A0...A8 economics,
historical audit bounds, compatibility, observability, physical evidence and
acceptance labeling remain mandatory.

All evidence must be fresh. A skipped, interrupted, timed-out, zero-selected,
fixture-only, synthetic-only, or historical run cannot pass a claim it does
not execute. Production and independent encoders may share only frozen byte
fixtures, never models, schema tables, serializers, digest helpers, state
generators, or reference validators.

## R23-01 — frozen input and current-code boundary

Recompute and record the SHA-256 of R17, R23, the R16 failed review, and
`origin/main` `1d2c930bad81704dd0acc0322226725d8b64aceb`. Prove by source search
that the working implementation remains R4 and contains no selector v8,
custody protocol, fresh verification head, stable/state lease pair, six-root
selector, or per-mutation checkpoint/activation graph. Historical R4 passing
tests are baseline only.

## R23-02 — generation-zero and carrier-directory intent

Using a test-only JCS encoder, freeze complete generation-zero and revision-one
65,536-byte selectors for R=0,1,31,32,33,1,024. Require the exact v8 key set,
directory intent schema, UTF-8/base64/path digest, parent identity, mode 448,
expected absence, charges, bootstrap phase and all nulls. Generation zero must
carry the intent and null directory identity; revision one must clear the
intent and select the captured identity. Freeze complete bootstrap close with
`unitLimit=21*(R+1)+50`, `carrierLimit=2*(R+1)+6`, the exact encoded candidate
byte limit, and exact consumed/released units, carriers and bytes. Prove each
pair sums to its selected limit and fixed/per-entry allowances cannot cross
categories.

Start from the actual R4 graph. Run the actual supported prior binary and
require it to reject the v4 fence/v8 selector without mutation. Inject death
after every create/open/no-follow check, lock, mkdirat, file/directory fsync,
identity capture, selector temp/write/fsync/rename/directory-fsync, old-source
revalidation and format-fence boundary. Pre-fence selects R4; post-fence selects
generation zero; post-revision-one fsync selects the exact empty directory.
Reject parent mismatch, traversal, symlink, wrong mode/type/owner/link count,
nonempty candidate, missing selected directory, identity drift, unequal retry,
double directory charge, nonzero unused bootstrap authority, missing released-
carrier accounting, or ordinary work before close.

## R23-03 — lease identity, mutable state, and ownership

Independently encode authorization, every mutable lease state, budget entry,
control authorization, receipt, pending selector and terminal selector for
63-edge commit, 64-edge commit, 63-edge A1/A2 abort and 64-edge A1/A2 abort.
Require one stable `leaseAuthorizationSHA256` across the entire trace and a new
`leaseStateSHA256` for each selected counter/state change. At each step directly
lookup the selected budget entry and require both open digests to equal the
selector lease; at close require both null and its JCS digest to equal
`targetBudgetEntrySHA256` before root promotion.

Mutate independently every debit, consumed/abandoned counter, state, edge
ordinal, entry generation, close outcome, projected entry, predecessor selector
and base-state digest. Each stale or substituted combination rejects before
temp-file creation. The 65th edge rejects. Replaying the 63rd/64th selected edge
converges without a second debit. A second lease, closed reuse, category swap,
transaction swap, or stable-identity rewrite rejects.

Race 64 helpers after each pending/successor boundary; kill the lock holder and
resume from another process. Exactly one advances, others converge or return
typed retry/busy. No PID, task, expiry, wall time or heartbeat appears in bytes.
Every returned call has released flock and descriptors and stayed within eight
seconds/four FDs.

## R23-04 — standalone codec, null, reference, digest and taxonomy gate

Implement an independent RFC 8785 encoder and declarative schema registry from
R17 sections 5 and 6 literals only. Freeze minimum, maximum, empty, generation-zero,
ordinary pending, continuation, close, abort, protected and terminal vectors
for every selector/embedded/reference/record/leaf-value/evidence schema.

For every object generate missing, duplicate, unknown, reordered-semantic,
wrong schema/version, illegal null/non-null, wrong union member, local selected
reference, forward local reference, inconsistent carrier length/digest/
identity, non-NFC, padded base64url, uppercase hex, traversal path, negative,
float, `2^53-1`, `2^53`, u64wide carry/overflow and invalid enum cases. Accept
only the exact matrix. Prove carrier-to-carrier-record equality and local-root
promotion field by field; prove no selected object contains a local reference
and no receipt contains its own future carrier digest.

Generate every descriptor-kind coordinate cross-product and every physical
class x object kind x content codec x path class x length/digest x identity x
index combination. Accept exactly the R17 matrix. Specifically require the
new binding record for `binding-publish`; reject free-form target binding,
external artifacts, external run/page/work objects, protocol files in ordinary
indexes, ordinary objects with artifact custody fields, and adopted artifacts
without all custody/fresh-verification fields.

Enumerate every field ending `SHA256`; fail if it lacks exactly one R17 digest
rule or matches two. Freeze each domain/preimage independently. Reject R14/R15/
R16 envelopes, selector v7, `carrierLengthBytes`, expiry leases, MMR/batch/
transaction-intent keys, digest-only pages, storage-ordinal record references,
and mixed versions.

## R23-05 — selected progress graph and corrected capacity

Build an independent semantic generator from the named 174 per-row and 320
fixed R16 transition literals plus R17 P0...P6 expansion. For every logical
mutation require pending selector; target records/pages; receipt; activation;
checkpoint; carrier durability; promotion; successor selector; six equal
selected roots; matching last receipt; predecessor activation/checkpoint; and
release of resources. Omission, fusion, root-only advance, checkpoint-only
advance, or a carrier used before selection fails.

For every changed-root subset from empty through all six roots, encode the
activation/checkpoint `rootSnapshot.v1` branches. Unchanged roots must use only
selected carrier-addressable references; changed roots must use paired
lower-slot local roots/promotions. Resolve them against the enclosing complete
carrier and require equality with the successor selector. Reject a nested
local anywhere else, a forward/sibling-carrier local, a snapshot with zero or
two branches, or a checkpoint activation/receipt reference that is not a lower
slot in the same carrier.

Inject death at every P0...P6 syscall/durable boundary for source capture,
merge group, run close, every tree level, both row-verification passes, storage
verification, A3/A4, all four ordered A5 bodies, adoption, binding, A6, retry,
audit, budget reserve/close and A1/A2 terminal abort. Recovery must select the
old, pending or exact successor graph; it may never treat an unselected carrier
as progress. Mutate one of six roots or either selected record and require
protection.

Independently derive, rather than copy, the 21 ordinary and 42 control units per
mutation, at most two carriers for 17 pages/target records + two receipts +
activation + checkpoint,
six conservative carrier permits, and exact formulas:

```text
units(R) = 10,983R + 20,231
Rmax = 410,051,864,458
units(Rmax) = 4,503,599,627,362,445
units(Rmax+1) = 4,503,599,627,373,428
carrierCount(R) <= 1,046R + 1,928
carrierCount(Rmax) <= 428,914,250,224,996
units(1,024) = 11,266,823
carrierCount(1,024) <= 1,073,032
```

Exercise R=0,1,31,32,33,1,024,Rmax,Rmax+1 with checked wide arithmetic. Sparse
Rmax proves codec arithmetic only. Candidate preflight must include both
directory charges, all activation/checkpoint records, carrier rounding,
custody/adoption transfer, lifecycle reserve, Wpeak/Uafter, quota, inodes,
free space and safe `off_t`. Reject the first over-limit byte/unit/edge/row and
unknown transition before v8 selection.

## R23-06 — SPEC-001 fresh verification before adoption

Use the production `DurableModelArtifactStore` preparation path and actual
supported Build 1 artifact on the physical Mac. Record signed model/release/
digest, hardware, RAM, OS/runtime/filesystem, artifact file/byte counts,
preparation receipt/seal, verification chunks/checkpoints, full current digest,
identity recapture, immutable flags, fresh receipt and timings. A small fixture
does not pass this case.

For every manifest file corrupt content, append/truncate, replace inode, change
mode/owner/flags, rename, add an entry, remove an entry, change symlink/type,
and restore timestamps at each boundary: before a chunk, after a chunk, before
checkpoint fsync, after final byte, during first recapture, before/after
immutability, before final recapture, before fresh receipt, before pending CAS,
after pending and before terminal. Require digest or identity/flag rejection
before selected adoption. Normal mutation/unlink/rename must fail while the
immutable flag and pin are active. Clearing the flag must invalidate identity.

Kill/restart after every chunk record/head and recapture boundary. Recovery
must resume from the selected checkpoint and predecessor digest, never skip or
double-count a byte. Independently calculate every SHA-256 compression state,
tail and final padding for lengths 0,1,55,56,63,64,65,64 MiB-1,64 MiB and
64 MiB+1, split each at every legal boundary, and require byte-identical file
digests and canonical artifact digest versus fresh one-shot SPEC-001
verification. Reject a modified continuation word, byte count, tail, file
digest sequence root or premature padding. Cancellation before pending preserves the
incumbent and selects legal abandon only after non-reference proof. Cancellation
after pending follows A3+ forward completion.

Measure every hashing/recapture call: <=64 MiB hashed per call, <=8 seconds,
<=4 FDs, descriptors/flocks released. The total verification may span many
calls. The final reservation call performs no payload hash/copy/publication,
but must finish exact identity/flag/custody/pending selection within eight
seconds. Six cold physical runs report p95. If the actual manifest recapture or
immutable filesystem support misses the contract, hardware/filesystem
qualification is blocked rather than weakening the test.

## R23-07 — custody, GC, serving and replacement races

Freeze every custody record/head state and null matrix independently. Verify
the global lock order custody -> activation -> journal with static lock-order
instrumentation and runtime inversion detection. Race GC with adoption at:
before verifying pin, after pin, every hash/checkpoint, verified transition,
pre-pending validation, each activation-lock/CAS/fsync boundary, terminal
selector, active custody transition, serving open, replacement, drain,
release and abandon.

GC must retain verifying, verified, pending-adoption, active and
replacement-pending artifacts. It must retain any artifact referenced by a
pending or selected catalog graph even if custody advancement crashed. It may
delete only after a selected released or `abandoned-unverified|abandoned-verified`
successor plus direct proof of
no catalog reference and, for replaced active artifacts, a valid drain receipt
with open count zero and completed ordinal at least last accepted. Mutate every
custody state/null combination, terminal reason, replacement binding and drain
counter/reference and require rejection. Corrupt, missing, stale or forked custody evidence
protects and never authorizes delete. A keep set sampled before the lock must
have no authority.

After legal release, inject death after every immutable-flag clear, manifest
entry unlink, directory removal and fsync. Resume only the exact absent prefix
in reverse depth/manifest order. Add an unexpected name, symlink, changed
identity or path escape and require protection without recursively deleting it.
The terminal custody head and records must survive artifact removal.

Run two simultaneous replacements and cancellation at every boundary. Exactly
one selected successor wins; the incumbent remains active until the winner is
terminal and drained; the loser becomes the appropriate unverified/verified
abandon state only if never pending.
Exercise process death between terminal catalog and active custody in both
directions and require deterministic equal completion. Serving must direct-open
active custody/fresh receipt and revalidate the requested entry identity/flag;
mutations block serving and protect. No release occurs while an old activation
request remains open.

## R23-08 — preserved root promotion, abort, and A3+ economics

Repeat R22 root-promotion topology and terminal-abort crash matrices against
v8/v3 references and v5/v4 receipts. Slot 7 alone atomically promotes the
closed budget root, selects abort receipt/A8, and clears pending. Receipt lists
only slots 0...6. A ninth slot or receipt that claims its own future clear
rejects.

For classified and unclassified provenance, inject cancellation/failure/death
at A3, A4, each A5 intent/durable suffix, adoption, binding and A6. Each resumes
the byte-exact forward path or protects, preserves full admitted
581,632/696,320 charge, transfers A4 4,096 once, preserves ordered A5 receipts,
and transfers A6 spent slack once. No post-A3 refund, available lifecycle,
retained-abandoned result, old-root rollback, artifact deletion, or false
rollback UI is legal. Typed `cancelled_after_commit` reports active artifact and
retained charge. A1/A2 alone use abort/refund.

## R23-09 — broader verification and independent audit

Run targeted Swift tests, complete `swift test`, Malibu Xcode tests, CLI/app
bridge, governance, prior-binary compatibility, maximum-shape measurement, and
the actual physical prepared-artifact verification/adoption/MLX-open case.
Report exact commands, selected/executed counts, duration, failures, skips,
timeouts, peak FDs/RSS, hardware and fixture/real-service boundaries.

Review the complete implementation diff independently through native GPT-5.6
Sol code, security and architecture lanes. The gate requires zero Critical,
High and Medium findings in every lane. Any material architecture, contract,
scope, capacity, custody, integrity or test-strategy change reopens this plan
gate.

Acceptance separates implementation completion, fresh local verification,
physical Mac/filesystem verification, signed-feed/release evidence, deployed
services and production qualification. Reservation fixtures do not satisfy
the real signed-feed -> trusted preparation -> valid admission -> actual MLX ->
correct settlement journey.
