# Build 1 reservation search progress — test specification R29

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Governing candidate: `reservation-search-progress-addendum-r23.md`. R29
supersedes R28. Every result must be fresh. Skipped, interrupted, timed-out,
zero-selected, fixture-only, historical, or mocked runs cannot pass a stronger
claim.

## R29-01 — frozen inputs and governance

Require failed-review commit
`748bd44a122d862c1fea5ca1d7f07b9f85a30b1b` and review SHA-256
`b5f316a49005bbc77b573544c40786ee3ecfc561a1414a2dd395d02f5324bed9`.
Record current HEAD, fetched `origin/main`, R23/R29 hashes, exact Appendix A/B/C
hashes, SQLite library/compiler/macOS/APFS identity, and unrelated dirty paths.
Confirm the author slice changes only these two documents. Require approved
SPEC-001 and SPEC-044 changes before source implementation. Plan approval grants
no identity, pricing, admission, settlement, reward, enforcement, deployment,
or release authority.

## R29-02 — one-owner rollback VFS and maintenance policy

First reproduce R22-H1 on macOS: with three opens of one inode, a conflicting
traditional `fcntl` byte lock is blocked before a sibling close and acquired
after that close although locking/master FDs remain. This counterexample must
stay in the record.

Build R23's C VFS against the repository SQLite header. Require public
`sqlite3_vfs` plus version-1 `sqlite3_io_methods`, one captured directory FD,
one synthetic main name, and only main/`-journal` leaves. Bootstrap uses
READWRITE|CREATE|FULLMUTEX; selected open omits CREATE. Verify `openat` flags
include O_EXCL/O_NOFOLLOW and never O_TRUNC. Reject WAL, SHM, super-journal,
TEMP_DB, null, URI, separator, dot, unknown, wrong-owner/mode/link/device, and
symlink identities.

Run two-process and sibling-close oracles for the distinct
`catalog-authority.lock` lifetime flock and main-file lifetime flock. A second
broker/connection must remain rejected during main open, journal create/delete,
commit/recovery/close, arbitrary sibling closes, fork, and owner crash. The lock
FD is opened once, never duplicated, and outlives SQLite. Test partial/short
read, disk full, checked write/truncate, F_FULLFSYNC, hot-journal recovery, fork
generation, and main/journal 512/64-MiB first-over writes.

First reproduce R22: permit its empty ATTACH, observe SQLite enter the generated
`vacuum_<random>` schema, and deny its internal schema action. Then install R23's
restrictive authorizer: `VACUUM` must stop at the empty ATTACH with SQLITE_AUTH;
named/empty ATTACH and DETACH also deny. Prove there is
no qualification exception or TEMP_DB callback and no test uses VACUUM to meet
the physical bound.

## R29-03 — complete rollback-only bootstrap

Independently encode every R23 bootstrap/source/intent tuple. Exhaustively crash
after candidate mkdir, each intent prefix, intent fsync/rename/parent fsync,
main create/header write, every DDL statement, B3 fixed-row seed, each of 16 B4
missing-evidence masks, journal write/sync/hot recovery, B5/B6 commits, intent
delete/fsync, candidate rename/parent fsync, ready commit, format prefix/fsync/
rename/parent fsync, and final reopen.

Construct E0/E1/E2/E3/I(n)/I(R)/P5/P6/P6a/P7/P7r/P8p/P8f/P8r/S and require the
one successor in R23. At B3 assert 495 registry rows, six fixed rows, 1,024 row
slots, 32 free serving slots, one meta and one GC meta. At B4 assert exact
`5+popcount(mask)`. No state may create WAL/SHM or change journal mode. Malformed
prefix/header/schema, cursor/count drift, unexpected leaf, both candidate/final,
non-hot journal, WAL/SHM, or identity drift protects without deletion. Before B8
R4 alone selects; after B8 V5 alone selects; missing selected main never CREATEs.

## R29-04 — registry, cursors, and closed state graphs

Two independent expanders must emit allocation 1, row 174, fixed 320 split
32/64/32/32/32/128, total 495. Exactly 128 recovery entries carry one
`legacy-inspect-readonly` intent; no other fixed entry does. At S=R=1,024 require
49,280 intents. Exercise family cursor first/last/first-over; materialization 33
and 64 must fail its literal DDL CHECK.

Exercise all post-bootstrap row allocation, A0...A8 abort, cancellation, retry,
protection, custody C0...C7, GC, and serving-slot states. Every legal state has
one successor or typed terminal. Every nonregistered state/edge must reject.

## R29-05 — exact DML, counts, and generation-50 predicates

Compile Appendix C and golden-compare SQL, bind order/type, statement changes,
total changes, counters, generation, charges, and replay. Exact totals:
B4 `5+popcount`; allocation success 11/cancel 3; staging 7; custody 10; initial
activation 8; replacement 11; generic finish 3; allocation-abort finish 4; GC
enqueue/check 4, result 6, first-over 5; every named serving prepare/running/
terminating/quarantine/free transition 2. Named special progress replaces
generic progress. Force zero and two affected rows for every CAS and roll back.

The registry expander must name exactly `staging-register-progress-full` 7,
`custody-verified-pending-progress-full` 10, `initial-activation-progress-full` 8, and
`replacement-progress-full` 11. Old six/nine/seven/nine names or counts must
make author generation fail before runtime.

For generation 50 execute literal predicates: event-49 predecessor; candidate
state deleting or blocked-kernel-io; `result_count=24`,
`successful_quanta=16`, `failure_count=8`; non-null legal cursor/phase;
`active_attempt_ordinal=24`; `active_check_generation=48`; exact event-48/49
helper; protocol counts <=51199/49279/25599; open count zero.
Assert only event/evidence/owner/generation advance. Exact replay is zero-write.
Generation 51, null/wrong cursor or phase, wrong attempt/check/helper, wrong state/counts, wrong predecessor/owner, and
each first-over counter must roll back.

## R29-06 — schema, typed ownership, catalog binding, and serving rows

Execute Appendix A with foreign keys ON. Require 23 tables, integrity_check ok,
empty foreign_key_check, user/schema version 23, and exact Appendix A digest.
Seed two unrelated rows and cross-splice every source/staging/custody/GC owner
field, operation scope/ordinal, generation/event/predecessor/current/catalog/GC
tuple. Each must fail an FK or deterministic startup semantic check before use.

Independently encode the one nine-field
`macprovider-r23/catalog-binding-v1` tuple and compare bootstrap, catalog writer,
startup, serving, replacement, and GC results. The no-`-v1` domain, omitted
custody generation, reordered field, or changed operation must fail. All-null
and complete catalog tuple rules remain.

Seed exactly 32 free serving slots. Test free/prepared/running/terminating/
quarantined CHECK matrices, partial worker tuple rejection, unique permit/request,
complete custody/operation FKs, slot 0/31, 33rd allocation, exact two-row CAS,
generation reuse, and concurrent contenders. A free CAS must null every optional
column and increment slot generation.

## R29-07 — allocation and zero-write abort terminal

Exercise eight allocation cancellations: attempts 1...7 return free; attempt 8
makes exhausted; no source/evidence appears. Exercise success at 0 and 1,023 and
catalog-full at 1,024. For each abort generation 0...7 traverse all eight steps
with crash/replay; only step seven may retry. At generation seven require A8 and
eight receipts. Later abort returns byte-identical signed `request_outcome_v1`
with `total_changes()==0`; no transition, evidence, receipt, charge, refund, or
external effect changes. Retired/protected use distinct zero-write outcomes.

## R29-08 — staging confinement, custody crashes, and worker restart

For provider staging, start at captured `/` and test every `getpwuid_r` home and
canonical component with `openat(O_DIRECTORY|O_NOFOLLOW)`. Mutate ancestor/leaf
before open, between stat/open, during each of two registration passes, during
copy, and before final rewalk. Test symlink, hard-link, `..`, slash/NUL, bind or
mount crossing, rename/replacement, wrong UID/mode/link/type/device, setuid/
setgid, changed size/mtime/ctime/birthtime, and manifest name substitution. No
privileged read outside the captured tree may occur. Exact unchanged source must
produce identical transcript/receipt/custody copy bytes.

Kill/reboot after every custody intent/temp/copy/fsync/flag/recapture/receipt/
rename/parent-fsync/SQL-ack boundary C0...C7. Directly construct each legal leaf
state. Replay has one successor; malformed state protects. Repeated failure
never exceeds one temp root/receipt and two intent leaves. Initial activation
and replacement remain whole-old or whole-new.

Before every spawn require a committed prepared serving slot and deterministic
record path. Crash before spawn, after spawn before record, after record before
running CAS, during each heartbeat, completion, TERM/KILL, record removal, lock
proof, and free CAS. Restart begins with empty memory and enumeration disabled;
it queries 32 SQL rows and direct-opens only derived paths.

The original parent may waitpid. A replacement must reproduce `waitpid=ECHILD`
and never treat it as proof. Validate proc_pidinfo PID/pidversion/start/status,
proc_pidpath/cdhash, boot UUID, heartbeat chain, kill0, exact process group, and
artifact flock. Closure requires public absent/changed/zombie observation plus
exclusive lock acquisition. Race PID reuse, late shared-lock acquisition,
permission failure, stale heartbeat, invalid record, daemon/provider death,
parent pipe EOF, stuck process, and kernel I/O. Any ambiguity quarantines; GC and
new serving/adoption stay blocked. The 33rd slot rejects before spawn.

## R29-09 — request pin, exact one-request channel, cancellation, and MLX

Independently encode every `serving_pin_v1`, `serving_worker_v1`,
`serving_request_v1`, `serving_response_chunk_v1`, `serving_completion_v1`, and
`serving_cancel_v1` field, including exact `request_sha256`. Mutate request bytes while retaining UUID; request SHA, slot generation,
catalog binding, nonce, audit token, worker identity, signature/key, boot,
deadline, and each FD count/type/peer. Send partial header/body, length 0, frame length 1,100,001, and request bytes 1,048,577, early EOF, trailing byte, two request frames, bytes after
`shutdown(SHUT_WR)`, second completion, bad sequence/chunk/output digest, >1 MiB
chunk, >64 MiB output, and replayed old-slot pin. All reject before a second
inference. Cancellation is authenticated XPC for the exact request and carries
no FD/payload.

On a physical Mac run the supported MLX model/profile through request→chunks→
completion while lazily reading weights. Attempt GC before open, during
inference, after cancel/completion, and recovery. The worker-held shared lock
must exclude GC until public process observation plus exclusive-lock proof.
Record model/artifact/OS/chip/RAM/MLX/runtime/receipt context. Fixture inference
cannot pass this physical acceptance.

## R29-10 — bounded rollback journal and recovery reserve

Run every <=12-row legal transaction with maximum-width values and crash after
every VFS write/sync/truncate. Require measured journal delta <=16 MiB and hard
failure before 67,108,865 bytes. Main first-over 536,870,912 also fails before
write. Before begin reject a hot/unrecovered journal, free space below 128 MiB,
main above 114,688 pages for new work, another open operation, or a second
connection. Recover inherited hot journal with mutation disabled; unrecoverable
or oversized journal protects. Prove no reader-retained journal is possible
because app/CLI/worker only receive copied RPC values.

## R29-11 — all-table reachable maximum shape

Populate every one of 23 tables and each index to its section-9 maximum through
legal DML with maximum-width values, including 32 maximum-width nonfree serving
rows and protected states. Include worst legal rollback fragmentation and crash
recovery. Verify all counters/COUNT(*), ANALYZE, integrity_check, FK check, and
every first-over key/counter/cursor/generation. The reachable as-grown main must
be <=448 MiB, leaving 64 MiB reserve; journal is <=64 MiB. Execute byte-exact
`VACUUM` and require SQLITE_AUTH. Sparse/arithmetic/VACUUMed fixtures do not
qualify the physical bound.

## R29-12 — codecs and reproducible complete Swift inventory

Golden-test tuple_v1 and all Appendix D codecs at minimum, maximum, every null,
field order, digest target, byte count, and enum. Reject negative/overflow,
invalid UTF-8/non-NFC/NUL, wrong UUID/SHA/signature sizes, alternative nulls,
maps/floats/arrays, missing/extra/trailing fields, and character-count paths.

Run the Appendix E parser over exactly both production roots with pinned
Swift. Require all files parse and stable file-set plus target manifest hashes.
The generated inventory must include CLI `ModelCatalogRead.swift` types/options/
readLockFD/readLifetimeFD/budget/events/read entrypoints and
`ModelTransactionContext.swift` contexts/loaders/path identity,
`ModelCatalogReadLease.start`, `ModelTransactionControlLease.start`, every
flock comparison, fd 199/200 and lifetime monitor. It must also include app
ModelManagement/ModelCatalogRead, ModelManagement, ModelTransactionControl,
Payload, and Request consumers. After B8 these are broker RPC transport or UI
orchestration only. Static and runtime gates prove no direct SQLite connection,
legacy authority write/open, direct adoption, custody lock, lifetime catalog
snapshot, or enumerating GC bypass.

## R29-13 — compatibility, rollback, observability, and acceptance boundary

Test R4 before B8, resumable candidate construction, irreversible V5 selection,
and backup/restore including serving slots and rollback recovery. Typed errors
cover schema/registry/manifest mismatch, corruption, full capacity, broker busy,
invalid/stale pin, supervisor quarantine, and GC unavailable. Metrics expose
bounded page/journal/table/slot headroom, operation/GC state, replay and
protection code without paths, model bytes, tokens, request bytes, or secrets.

Run targeted unit/fault checks, fresh `swift test`, required Xcode Malibu app
tests, distribution checks, and physical MLX/custody journey. Three independent
GPT-5.6 Sol lanes audit the complete implementation diff for code, security, and
architecture until each has zero Critical/High/Medium. Separate implementation,
local verification, physical-Mac qualification, and production qualification.
R23/R29 approval completes none.

## Author-time reproducibility record

These are plan-shape checks only, run on Darwin 25.5.0 arm64 with Python
3.14.7 / SQLite 3.53.4 and Swift 6.3.3:

- Exact failed-review SHA reproduced as
  `b5f316a49005bbc77b573544c40786ee3ecfc561a1414a2dd395d02f5324bed9`.
  R23 SHA before this R29-only record was
  `eb49d8ab8493edfc53527fb9ae2729e56983eeb76cb043d4b0ec959675c344b2`.
- Extracted Appendix A was 43,652 bytes, SHA
  `70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f`,
  created 23 tables, reported `integrity_check=ok`, empty FK check, and
  user_version 23. Seeding 32 free serving slots succeeded; ordinal 32 and
  partial prepared/quarantined rows failed CHECK.
- Exact Appendix B/C body hashes were
  `a8b2ba52cc55c66da33af305c6251308615a132235cf12da7617bcdd7b8e1bb8`
  and `c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6`.
- The live fcntl oracle reported `blocked` before sibling close and `acquired`
  after, with lock/master retained. The separate BSD-flock oracle reported
  `blocked` before and after unrelated sibling close and `acquired` only after
  owner unlock. An initial Python multiprocessing version failed because the
  3.14 spawn path lacked the `__main__` guard; it was discarded and replaced by
  independent subprocess probes.
- An orphan-worker oracle reported replacement `waitpid ECHILD`. The legacy
  VACUUM oracle entered `vacuum_<random>` then failed its internal schema action;
  R23 denied VACUUM at `SQLITE_ATTACH('',...)` with authorization denied.
- The literal generation-50 candidate CAS changed one row only for
  state deleting, 16/8/24, non-null cursor/phase, attempt 24, check 48, exact
  helper. Success 15, failure 7, result 23, done state, attempt 23, check 47,
  null cursor, and wrong helper each changed zero. Boundary meta changed one;
  each first-over counter changed zero.
- Registry arithmetic returned allocation 1, row 174, fixed
  32/64/32/32/32/128=320, total 495; intents 49,280; operations 186,688;
  transitions 560,064; typed owners 35,840; GC events 51,200. The four special
  progress counts were 7/10/8/11.
- Both CLI files are present in the exact 191-file production Swift set. Its LF
  path-manifest SHA is
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
  All 191 selected `swiftc -frontend -dump-parse` runs passed; zero failed.

These results are neither VFS implementation qualification nor physical MLX
acceptance. Failed attempts remain explicit and cannot be called passing.
