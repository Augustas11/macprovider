# Build 1 reservation search progress — test specification R25

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. Governing candidate:
`reservation-search-progress-addendum-r19.md`. R25 replaces R24. It preserves
the Build 1 product outcomes, A0-A8 economics, finite SHA workload, truthful
acceptance labels, physical-model boundary, and complete targeted/broader
verification. It does not preserve withdrawn R16-R18 carrier/selector tests.

Every result must be fresh. Skipped, timed-out, interrupted, zero-selected,
fixture-only, deterministic-only, historical, or mocked execution cannot pass
a stronger claim. The physical custody daemon, actual supported artifact,
actual MLX open, app Xcode tests, Docker integration, deployed services, and
production qualification remain separately labeled.

## R25-01 — frozen boundary and governance

Recompute SHA-256 for R19, R25, R18, R24, the failed R18 review, worktree HEAD,
and `origin/main`. Confirm R18/R24/review input hashes and base named in R19.
Prove source is still the R4 array/scan implementation and no R19 database,
format-v5 fence, tuple codec, transition registry, custody daemon, or SQL GC
exists. Record all unrelated dirty files without modifying them.

Require reviewed SPEC-001 and SPEC-044 amendments before source
implementation. Their conformance map must cover R19 authority, migration,
trusted custody, A1/A2 refund, A3+ forward completion, failure codes,
observability, compatibility, physical qualification, and feature gate.

## R25-02 — complete logical schema and codec

Extract Appendix A by the normalization rule and independently compute its
digest. Create it with the production Swift SQLite path and an independent
Python `sqlite3` harness. Require identical table/index/column/order/type/
not-null/default/PK/FK/CHECK inventory and zero trigger/view/unknown object.
Require application ID, user version, page size, max pages, all pragmas,
STRICT behavior, defensive mode, disabled extensions, integrity check, and
foreign-key check.

Independently implement tuple-v1 in Swift production and Python tests. Freeze
minimum/maximum values for null, u63, bool, NFC text, bytes, UUID, SHA, path,
file identity, every table row identity, schema digest, registry digest, and
format-v5 JCS. Mutate tag, column count/order, length, truncation, trailing
bytes, integer sign/overflow, bool 2, text NFC/UTF-8/NUL, UUID/SHA length, path
absolute/empty/dot/dotdot/double slash/escape, unknown enum, every nullable
branch, file type/length pairing, and every self/raw/path/predecessor digest.
Production and independent results must agree byte-for-byte.

Independently encode/decode `custody_receipt_v1`, every custody-entry transcript
step, and `gc_result_v1`. Freeze their exact direct paths and minimum/maximum
tuples. Reject reordered/extra/missing columns, wrong tuple tag, unknown phase
or outcome, bad path shard/UUID, wrong transcript order, directory content
digest, regular-file null digest, counter overflow, illegal after-root null,
and receipt/reference bytes that do not match the recorded evidence identity.

For every table and both external tuple codecs enumerate all columns and demonstrate one DDL or application
constraint for scalar type, maximum, enum, null rule, relation, digest target,
and reference context. Generate a completeness report that fails on any
unclassified column, `*sha256` matching zero/two digest rules, foreign key
without direct lookup, registry line absent from SQL, or human default.

## R25-03 — executable bootstrap and prior-binary behavior

For R=0,1,31,32,33,1,024 build an R4 source fixture and execute B0-B8. Validate
one complete bootstrap transaction, exact source order/transcript, one row per
source, exact evidence references, registry count 174/320, meta generation 1,
page geometry, schema/registry hash, final DB identity, and ready state. No
operation/transition/custody/GC row may exist and no bootstrap null exception
may be needed.

Inject process death immediately before and after every mkdir/open/no-follow/
source read/identity comparison, DDL statement group, source insert, commit,
DB/journal/fsync, quick/integrity/foreign-key check, close, directory rename,
parent fsync, WAL conversion/checkpoint, format temp/write/fsync/rename, and
format-parent fsync. Before B8 only R4 selects; an exact candidate resumes.
After B8 only R19 selects; missing/drifted/corrupt R19 protects and never falls
back or reconstructs. Unequal candidates, unexpected names, symlinks, hard
links, cross-device paths, owner/mode/link drift, source mutation, SQLite
runtime/pragma/schema mismatch, a 1,025th row, DB/WAL/page limit, no space, and
u63 overflow reject at the stated side-effect boundary.

Run the exact supported prior binary against the selected v5 fence and require
read-only rejection before any write. Run the new binary against R4 without v5
and require migration rather than treating an unselected v2 candidate as
authority.

## R25-04 — atomic operation and accounting graph

Expand Appendix B independently and require exactly 174 ordered unique row
lines and 320 ordered unique fixed lines. Validate every normal, abort and fixed
from/to state and the expanded-byte digest without production constants. For
R=0,1,31,32,33,1,024 derive:

```text
semanticSlots=174R+320
operationRows<=174R+320
selectedTransactions<=522R+960
R=1,024 => 178,496 slots and at most 535,488 selected commits
```

Execute begin/progress/finish for every registry entry on a legal predecessor.
Begin must atomically reserve/open, progress apply the one semantic transition,
and finish atomically close/terminal. Each operation has exactly three selected
steps. No reserve-open, closing, lease-removal, selector, pending, continuation
or fourth step is reachable. Mutually exclusive branches leave slots unused;
no slot is reused for the same row/fixed scope.

At every statement and WAL sync boundary kill the process. Reopen selects the
complete predecessor or successor. Exact replay converges without a second
step/charge. Race 64 processes on one semantic slot, different row slots and
row versus fixed: exactly one caller selects a given slot, generations remain
linear, and disjoint callers complete through SQLite serialization. Reject
wrong UUID/scope/row/registry ordinal/name/predecessor/authorization/base
generation/prior SHA/from/to, duplicate-different replay, normal-to-abort or
abort-to-normal edge, generation-nine abort, skipped cursor, unknown registry
line, wrong external-intent kind/evidence/root/path/path digest/length/content,
external mutation before begin, ninth row change, any opaque transition
payload, post-finish fourth step, second open row operation, and second open
fixed operation.

For every registry entry independently generate its closed economic charge
rule. Non-materialization metadata is zero; A3 is the selected directory
charge; each A5 body is its direct evidence length; adoption/lifecycle uses the
current SPEC-governed delta. Prove SQLite page/WAL bytes never enter product
charges. Test A1/A2 exact release and A3+ exact abandoned-and-charged remainder.
Exercise 63/64/65-page headroom, 64-MiB volume margin, page/WAL/max-page limits,
disk full, checkpoint and I/O failure races, exact/over economic charge, u63
overflow and every charge equality. Failed commits select no economic delta.

## R25-05 — physical store bounds without carriers

Assert no R19 code can create `.mcc`, selector, local reference, root promotion,
custom B+ page, or custom lease object. The historical recovery names in the
registry may only inspect/migrate/reject legacy evidence.

Build the R=1,024 maximum product fixture using maximum legal primary evidence
already covered by the reservation measurement, then execute every legal R19 semantic slot with realistic maximum direct references. Record main DB,
WAL, SHM, page count, WAL frames/checkpoints, FDs, RSS, per-call duration,
selected changes, and total duration. Require main DB <=512 MiB, WAL <=64 MiB,
no unknown sibling, <=4 simultaneous FDs, <=8 row changes, no opaque transition payload, and every control call within eight seconds. Exact first-over cases
must fail atomically. This proves only the R19 metadata store, not artifact
download/hash, MLX, or production throughput.

## R25-06 — root-owned custody and full freshness

Do not enable trusted adoption until the custody daemon has approved SPEC,
code-signing/XPC security review, installer/release evidence, and a physical
supported-volume run. Test XPC rejection for unsigned, wrongly signed,
wrong-UID, stale-version, arbitrary-path/FD, path traversal, mount escape,
symlink, hard link, socket/file-type, oversized and replayed requests. Verify
the daemon has no network entitlement/access and reads no operator secret.

On a physical supported Mac, use the actual Build 1 artifact. Execute C0-C6,
two full content passes, current SPEC-001 digest, source pre/post recapture,
canonical manifest/identity transcript, fsync/rename/parent-fsync, root:wheel
ownership, modes, link counts and `SF_IMMUTABLE`. Freeze the root and receipt
direct evidence rows. Kill/restart at every file copy/hash/identity/flag/fsync/
receipt/rename/reopen boundary; recovery must return only the same final direct
references or clean the exact temp before selection.

Attempt as the provider UID to clear flags, chmod, chown, write, truncate,
rename, unlink, hard-link, symlink-swap, replace, add an entry, restore
timestamps, change xattrs, escape the root, and mutate every manifest entry:
before its copy, between copy passes, after final recapture, immediately before
SQLite adoption, during SQLite adoption, and before MLX open. Before hardening,
source drift must reject. After C6 every same-user mutation must fail at the
kernel boundary; otherwise the host is unqualified and adoption remains
feature-gated.

Validate the custody matrix for every state/null/reference combination.
`verified -> pending-adoption -> active` must be acyclic, predecessor-linked,
and selected atomically through `artifact_current`. Every receipt/root lookup
uses path+length+content+full identity, never a bare digest or enumeration.
With an incumbent active, admit one replacement pending, then atomically retire
the incumbent and activate the replacement. Reject a second pending, second
active, stale incumbent, or partial switchover; cancellation before the pending
commit preserves the incumbent byte-for-byte.
Absent/incompatible daemon must emit `trusted_custody_unavailable` and must not
write pending/active state. Cancellation before C6 leaves no selected artifact;
after C6 leaves a truthful inactive verified artifact; after A3 completes
forward and returns `cancelled_after_commit_model_active`.

Run six cold physical copies/verifications and six cold adoption/MLX-open
calls. Report artifact size/count, durations, FDs, RSS, filesystem, chip, RAM,
OS, daemon version, catalog identity, and model identity. Preparation duration
is separate from the eight-second metadata control bound. A fixture cannot
pass this claim.

## R25-07 — A0-A8 economics and recovery

For classified and unclassified rows exercise cancellation, ordinary failure,
process death, retry, and concurrency at every Appendix B step. A1/A2 finish
must release exact unused steps/physical reserve and select A7/A8. A3+ must set
forward-only, retain the full admitted economic charge, run to A6 or protect,
and never expose abort/refund/available state. Verify consumed, released and
abandoned counters sum exactly to maxima and economic charge is independent of
physical DB byte consumption.

Exercise generation 0...7 abort evidence and ninth-failure protection. Replay
every terminal commit/abort/protection and require no second debit, activation,
refund, custody transition, or user-visible success. Missing wallet/rewards or
coordinator state has no bearing on reservation authority.

## R25-08 — indexed GC, fairness, and blocked I/O

Create 10,000 candidates spanning queued, checking, deleting, done, protected,
corrupt, stale custody, active, pending, released, missing receipt, huge
manifest, and blocked-I/O cases. Use `EXPLAIN QUERY PLAN` and SQLite statement
status to prove selection uses `idx_gc_fair` and examines O(log N)+one candidate,
not a table/artifact scan. Enqueue/claim/cursor/complete/fairness changes must
be atomic and predecessor-linked. Every candidate directly resolves custody,
root, receipt and drain evidence.

Each invocation processes one candidate, <=256 entries, <=8 MiB manifest/path
bytes, <=1,024 syscalls and <=6 seconds. No DB connection/global lock is held
during filesystem work. Race GC with adoption, serving, replacement, drain and
release; unrelated calls and the five-second heartbeat must continue. Prove no
candidate gets a second quantum until all eligible peers in its old round are
claimed/ineligible, including concurrent enqueue and wrap.

Run a real child that holds the artifact flock and blocks in FIFO `read(2)`;
require supervisor SIGKILL, reap and lock release by seven seconds. Run the
supported local-APFS metadata fault harness. If the kernel prevents reap,
require `blocked-kernel-io`, no replacement child, honest busy state for that
artifact, and loss of host GC/adoption qualification while unrelated artifacts
and heartbeat continue. Never report this case as meeting the lock-release
bound.

Kill at every flag clear, unlink, root removal, file/parent fsync, daemon-result
write, SQLite event insert and COMMIT. Resume exactly the selected reverse-depth
prefix. Unexpected name/identity/link/symlink/mount/path/cursor/evidence or a
new catalog/custody reference protects before further deletion.

## R25-09 — finite SHA continuation oracle

Generate the exact R19 boundary sets. Record count, ordered-set digest,
aggregate suffix bytes, RSS, duration and hardware. Require exactly the known
1,676 completions and about 43.8678 GiB, while independently enforcing <=4,096
completions, <=96 GiB, <64 MiB writable extra RSS and <30 minutes.

Compare every resumed result with one-shot SHA-256 using an independent
implementation. Test all eight words at `2^32-1` and reject `2^32`; mutate every
word/count/tail bit, byte order, tail length, total modulo 64, non-IV zero and
sub-block states, count overflow, padding legality, clone isolation, and
0/1/55/56/63/64/65/1-MiB/64-MiB/final-byte boundaries. Skipped boundary or
fixture-only results cannot pass actual artifact verification.

## R25-10 — compatibility, rollback, observability, and failures

Verify only an exact unselected candidate before B8 may be removed/reused.
After B8, old code rejects and new code never falls back to R4. Exercise
operator backup/restore with exact identity/schema/registry/source/custody
preservation and reject partial/stale/mismatched restore.

For every typed failure verify CLI JSON, app decoding/copy, retryability,
action availability, no false readiness, and no external mutation after the
documented boundary. Metrics must expose every R19 field listed in section 10
without path, model bytes, source payload, secrets or keys. Busy, protected,
full, daemon unavailable, artifact changed and kernel-I/O blocked must remain
distinct.

## R25-11 — implementation and acceptance gates

After plan and SPEC approval, run focused schema/codec/bootstrap/transaction/
custody/GC/economics tests, then complete `swift test`, Malibu Xcode tests,
CLI/app bridge, governance checks, the R=1,024 physical metadata measurement,
the actual supported-artifact custody/adoption/MLX-open journey, and applicable
Docker integration only when Docker is available. Record exact commands,
selected/executed counts, duration, failures, skips, timeouts, FD/RSS, hardware,
artifact/catalog identity, daemon/release version, and mock/fixture/physical/
service boundary.

Review the complete landing diff through independent native GPT-5.6 Sol code,
security, and architecture lanes. Each must report zero Critical, High and
Medium findings. Any change to authority, DDL, codec, transition registry,
accounting, custody privilege, freshness, GC, economics, test strategy, or
feature gating reopens the plan gate.

Acceptance reporting must distinguish implementation, local verification,
physical custody/filesystem qualification, signed feed/release evidence,
actual MLX inference, valid coordinator admission, correctly settled request,
deployed services, and production qualification. Until the fresh signed-feed
to trusted preparation to admission to MLX to settlement journey executes,
Build 1 remains incomplete. Reservation metadata fixtures cannot satisfy it.
