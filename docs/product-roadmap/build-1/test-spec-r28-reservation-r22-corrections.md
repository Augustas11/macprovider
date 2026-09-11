# Build 1 reservation search progress — test specification R28

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Governing candidate: `reservation-search-progress-addendum-r22.md`. R28
supersedes R27. Every result must be fresh. Skipped, interrupted, timed-out,
zero-selected, fixture-only, historical, or mocked runs cannot pass a stronger
claim.

## R28-01 — frozen inputs and governance

Recompute the failed R21 review SHA-256 and require
`176d16e59e897f5aef94afa258e04e4ca32ca1e2b64f1964b92b20fdfa5468e1`.
Record review commit `3ab079f7d2c9d8522546c59e3857bdb4d1f30017`, current HEAD,
fetched origin/main, R22/R28 hashes, SQLite library version, Swift compiler,
macOS/APFS profile, and unrelated dirty paths. Confirm R22/R28 modify only the
two planning documents. Require approved SPEC-001 and SPEC-044 changes before
source implementation; plan approval authorizes no identity, pricing,
admission, settlement, reward, enforcement, deployment, or release.

## R28-02 — directory-bound VFS/open profiles

Build the C VFS against the repository SQLite ABI. Test the bootstrap
READWRITE|CREATE|FULLMUTEX|NOFOLLOW profile and the selected
READWRITE|FULLMUTEX|NOFOLLOW profile with CREATE absent. Race every ancestor,
directory, main, journal, WAL, and SHM at xOpen/xAccess/xDelete/xFullPathname,
recovery, checkpoint, commit, and close. Reject symlinks, hard links, wrong
owner/mode/link/device, separators, URI parameters, dot names, temp names,
super-journals, and unknown leaves. Prove `openat` CREATE uses
O_CREAT|O_EXCL|O_NOFOLLOW without O_TRUNC, existing recovery leaves omit CREATE,
and the captured directory FD prevents ancestor substitution. First compile a public-header `/tmp` prototype and record the synthetic absolute
`xFullPathname` plus main/journal/WAL/SHM callback trace. Run applicable upstream
SQLite lock/WAL/crash/fork/short-read/FULLFSYNC tests plus independent C and
Swift fault harnesses. On a copied non-authoritative maximum fixture, prove the
closed qualification authorizer permits exactly the embedded VACUUM ATTACH and
one null TEMP_DB; named/second ATTACH and authority VACUUM fail. Measure both
as-grown and copied VACUUM states through the same VFS byte/page limits.

## R28-03 — complete deterministic bootstrap

Independently encode the R22 bootstrap/source/intent tuples and compare every
byte and SHA. Exhaustively crash after candidate mkdir, every prefix-intent
write, intent fsync/rename/directory fsync, main create/header write, every DDL,
journal write/sync/recovery, metadata insert/commit, intent delete/fsync, WAL
conversion/checkpoint, candidate rename, ready commit, and format publication.
For each imported row and all 16 missing-evidence masks, assert exact
`5+popcount(mask)` changes, cursor/count CAS, and whole predecessor/successor.
Directly construct E0/E1/E2/E3/I(n)/I(R)/P5/P6/P6a/P7/P7r/P8p/P8f/P8r/S and
require the specified unique resume edge. Malformed prefix, wrong intent, identity drift, non-page-aligned main, invalid
header, non-hot journal, partial committed schema, duplicate intent, unexpected
leaf, or both final and candidate protects without deletion. Before B8 R4 alone
selects; after B8 V5 alone selects and missing V5 main never invokes CREATE.

## R28-04 — fixed registry, recovery mapping, and cursors

Two independent expanders must emit exactly 495 registry entries: allocation 1,
row 174, and fixed 320 split 32/64/32/32/32/128. Require all and only the 128
recovery entries to carry exactly one `legacy-inspect-readonly` intent and no
new evidence; every other fixed entry carries none. At S=R=1,024 verify
`32S+16R+128=49,280`. Exercise first/last/first-over cursor for each family:
source/tree/verification/materialization 32, merge 64, recovery 128. Inserting
or updating materialization cursor 33 or 64 must fail its DDL CHECK.

## R28-05 — exact mutation manifests and accounting

Compile the normalized manifest to parameterized SQL and golden-compare SQL,
bind order/types, statement count, per-statement `changes()`, total changes,
charge deltas, protocol counters, open-operation count, and WAL reservation.
Exercise the 16 bootstrap masks and standalone templates with exact totals:
bootstrap B4 `5+popcount(mask)`, allocation success 11, allocation cancel 3,
staging register 7, custody verified/pending 10, initial activation 8,
replacement 11, generic finish 3, allocation-aborted finish 4, GC enqueue/check
4 each, GC result 6, and first-over protection 5.
Prove named special progress replaces generic progress and cannot be composed
with it. For each statement force zero and two affected rows and require total
rollback. Crash before/after every statement and recover the same operation by
UUID with no repeated external effect, evidence, receipt, charge, or refund.

## R28-06 — schema-bound ownership and concurrency

Execute Appendix A with foreign_keys ON and run integrity_check and
foreign_key_check. Seed two rows A/B with different transaction, model, release,
artifact, custody event, and operation. First reproduce R21 H2 against extracted R21 DDL: unrelated staging/root/receipt
evidence and generation-2 current with generation-1 event commit FK-clean. Against
R22, cross-splice evidence typed-owner role/table, row/transaction/model/release/artifact/custody
generation/operation UUID/operation row/evidence reference, custody
predecessor generation/event, creating operation scope/registry ordinal, current
generation/event, catalog active/pending generation, and GC generation/event.
Each commit must fail `SQLITE_CONSTRAINT_FOREIGNKEY`; each digest relationship
that cannot be enforced by SQLite must protect during startup semantic checking. Replace only a catalog
binding digest with an arbitrary 32-byte value and require startup, serving,
replacement, and GC semantic-integrity checks to protect before use. Test all-null
catalog tuples and exact all-non-null tuples succeed. Run concurrent first-slot,
last-slot, same-operation replay, differing replay, and replacement contenders;
only one open-operation slot and one exact winner may commit.

## R28-07 — allocation and reachable abort terminal

Exercise eight allocation cancellation attempts: attempts 1–7 return the slot
to free, attempt 8 makes it exhausted, and no source/evidence is created. Test
allocation success at ordinals 0, 1,023 and catalog-full at 1,024 rows. For each
abort generation 0–7 traverse all eight registered row steps, crash/replay each
commit, and verify only slot seven can retry. At generation seven require
A8,row-abort-terminal and exactly eight abort receipts. Repeated later aborts
must return byte-identical `request_outcome_v1` bytes with a valid deterministic daemon signature with SQLite
`total_changes()==0` and unchanged operations, transitions, evidence, receipts,
charges, and refunds. Retired/protected rows return their distinct zero-write
outcomes.

## R28-08 — staging, custody, replacement, and serving lifetime

Test canonical provider UID staging registration and every receipt semantic-owner
field. Kill/reboot after intent prefix/final fsync and every C0-C7 entry copy,
manifest cursor, fsync, chmod/chown/flag cursor, second pass, receipt prefix,
root rename, receipt rename, parent fsync, direct recapture, SQL acknowledgment,
and intent removal. Directly construct each legal leaf state; exact replay has
one successor, malformed state protects, and cancellation/reclamation uses no
enumeration. Repeated failures must never exceed one temp root, one temp receipt,
and two intent leaves. Exercise initial activation/replacement crashes and prove
whole old or whole new catalog tuple.

With actual supported MLX inference, require the daemon and trusted worker to retain shared-lock duplicates while the
provider receives only the nonce-bound socket. Attempt GC
before model open, during lazy weight access/generation, after cancellation,
after completion, and during daemon restart recovery. Mutate every pin field,
signature/key ID, audit identity, boot session, socket attachment/count/peer,
and first-frame nonce. Duplicate exact handshake may resume once but never
spawn twice. Stop/hang the worker and retain/duplicate every provider-visible FD;
at the 15-minute continuous deadline the daemon must TERM/KILL, validate
PID/pidversion/start identity, reap the exact child, then release the lock.
Exercise provider death, daemon death/restart, PID reuse, audit-token reuse,
deadline/catalog-switch race, parent-death pipe, and an unreaped kernel-I/O
worker; the latter must retain the lock/record and quarantine capacity rather
than report expiry. The 33rd concurrent worker rejects before spawn. Record
model, artifact, OS, chip, RAM, MLX/runtime, and receipt context; fixture
inference is insufficient.

## R28-09 — bounded authoritative GC

Model-check the complete 4,096-entry path and all legal mixtures of 16 success
and eight failure attempts. For attempts 1...24, independently derive helper
UUID from custody generation/event, attempt ordinal, checking generation, start
phase/cursor; require exact retry identity and pairwise difference between every
quantum. Reject stale cursor, wrong checking generation, duplicate helper with
different bytes, and second result. Enqueue is event 1 and normal work ends at
or below 49.

Execute generation 50's literal four statements: owned control evidence insert,
protected event with exact event-49 predecessor, terminal-candidate CAS with
unchanged success/failure/result counts, and protocol generation/event/evidence
counter CAS. Compare SQL/binds/changes; exact replay returns byte-identical
`gc_first_over_control_v1` with zero writes. Generation 51, a second distinct
control, wrong owner/predecessor/counter, and evidence first-over must roll back.
At full shape assert 16/8/24 caps, one lifecycle per artifact, 1,024 candidates,
and 51,200 events. Crash after every check/result/control/fairness commit;
recover only by stored attempt tuple and direct result path. Exercise live/dead
child, six-second kill, unreaped I/O, serving worker, immutable failures, and no
SQLite transaction spanning daemon deletion.

## R28-10 — hard WAL bound and recovery reserve

First reproduce R20's retained-reader case exceeding 64 MiB. Under R22, hold a
hostile reader while driving maximum legal mutations. Prove the VFS returns
SQLITE_FULL before xWrite/xTruncate would make the WAL exceed 67,108,864 bytes;
measure with fstat after every write and crash. An inherited oversized WAL is
readable for recovery but no mutation begins until a busy=0 TRUNCATE checkpoint
reduces it. Begin must reject WAL over 16 MiB, free space below 128 MiB, an open
operation, or a reservation over 48 MiB. Force each declared 16/16/8-MiB phase
delta boundary and first-over byte. After disk-full, quota, busy reader, and
process death, recover the same directly addressable operation, checkpoint,
finish/protect, and prove no duplicate external effect. `journal_size_limit`
alone must fail this test.

## R28-11 — all-table/page maximum shape

Populate every table and every index at its Appendix A/section 9 maximum using
maximum-width legal values, including 1,024 rows, 186,688 operations, 560,064
transitions, 49,280 intents, 49,280 evidence rows, 35,840 maximum-width typed owner rows, 8,192
custody events, and 51,200 GC events.
Verify every protocol counter and COUNT(*), run ANALYZE, integrity_check, and
foreign_key_check, VACUUM at 4,096-byte pages, and require main plus indexes at
or below 448 MiB. For every table, counter, cursor, ordinal, generation, UNIQUE,
and composite owner key, attempt the first-over value and require rejection.
Measure every legal transaction (maximum 12 rows), the as-grown and governed
offline-VACUUM copies, one open custody operation, and 32 maximum-width serving
worker records on the pinned APFS/SQLite profile. Arithmetic or sparse fixtures do not qualify the
physical bound.

## R28-12 — codecs and reproducible CLI/app inventory

Golden-test tuple_v1 and every Appendix D codec at minimum, maximum, and each
nullable position. Reject negative/overflow integers, non-NFC/invalid UTF-8,
NUL, wrong byte lengths, alternative nulls/tags/enums, reordered/missing/extra
fields, floats/maps/arrays/trailing bytes, wrong digest target, and path
character-count substitution. Recompute row digests and every composite binding
from independent code.

Run the Appendix E Swift parser over exactly the two declared production roots
with the pinned toolchain. Require stable regeneration and a checked-in manifest
before source edits. Assert the app files ModelTransactionControl.swift, ModelTransactionPayload.swift,
ModelTransactionRequest.swift, ModelManagement/ModelCatalogRead.swift, and
ModelManagement/ModelManagement.swift appear. Require exact classifications for
`MalibuCatalogReadRunner`, `catalog-read.lock`, fd 199/200 arguments and
descriptors, `MalibuTransactionFiles`, read/cancel/busy calls, and cache/nonce
consumers as transport or snapshot consumption only. After B8, every banned symbol or
literal must be absent or syntax-mapped to the exact pre-B8 R4MigrationReader or
non-authoritative app transport allowlist. Runtime fault injection must prove no
legacy authority open/write, direct adoption, or enumerating GC occurs.

## R28-13 — compatibility, observability, and acceptance boundary

Test old R4 authority before B8, resumable candidate construction, irreversible
V5 selection after B8, backup/restore with database identity and WAL recovery,
and typed failures for schema/registry/manifest mismatch, corruption,
protection, full capacity, unsupported custody, stale/invalid pin, serving supervisor quarantine, and GC unavailability.
Metrics must expose bounded counters/headroom, WAL reserve/result, operation and
GC state, replay, and protection code without paths, model bytes, tokens, or
secrets.

Targeted unit and fault tests run first, then fresh `swift test`, required Xcode
Malibu app tests, distribution checks, and applicable physical MLX/custody
journeys. Three independent GPT-5.6 Sol lanes audit the complete implementation
diff for code, security, and architecture until each reports zero Critical,
High, and Medium findings. Implementation completion, local verification,
physical-Mac qualification, and production qualification are reported
separately. R22/R28 approval completes none of them.

## Author-time reproducibility record

These are plan-shape checks, not implementation or acceptance evidence.

- `shasum -a 256` reproduced the frozen failed-review SHA
  `176d16e59e897f5aef94afa258e04e4ca32ca1e2b64f1964b92b20fdfa5468e1`.
- A Python 3.14.1 / SQLite 3.53.4 extractor executed Appendix A with
  `foreign_keys=ON`: normalized DDL SHA-256
  `34636b0142704056425e100e77a613af098819fc4f3fb1ae3675aa41d76230a5`,
  22 tables, `integrity_check=ok`, and empty `foreign_key_check`.
- The R21 ownership oracle freshly reproduced its FK-clean unrelated-evidence
  and generation/event splice. The R22 fixture committed the valid source,
  staging, two-generation custody, current-custody, candidate, checking, and GC
  result graph; staging evidence, custody evidence, and generation/event splices
  failed `SQLITE_CONSTRAINT_FOREIGNKEY`, while predecessor-generation splice
  failed its CHECK.
- The executable registry/count oracle returned allocation 1, row 174, fixed
  320 split 32/64/32/32/32/128, total 495, intents 49,280, operations 186,688,
  transitions 560,064, typed owners 35,840, and GC events 51,200. All six fixed
  cursor first-over inserts failed.
- A file-backed SQLite authorizer run observed exactly one
  `SQLITE_ATTACH("",NULL)` and completed `VACUUM`; named ATTACH remains denied.
- `swiftc -frontend -dump-parse` initially bus-faulted on `ModelRuntime.swift`,
  as the prior review also observed. Two immediate single-file reruns and one
  complete 191-file rerun passed. The exact sorted file-set hash remained
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
