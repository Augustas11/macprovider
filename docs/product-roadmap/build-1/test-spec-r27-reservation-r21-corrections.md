# Build 1 reservation search progress — test specification R27

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Governing candidate: `reservation-search-progress-addendum-r21.md`. R27
supersedes R26. Every result must be fresh. Skipped, interrupted, timed-out,
zero-selected, fixture-only, historical, or mocked runs cannot pass a stronger
claim.

## R27-01 — frozen inputs and governance

Recompute the failed R20 review SHA-256 and require
`a9f0f5258fba1d517f30b7f6d25cca1d2f44d5cf16a79b5481b0dd072e8e3e95`.
Record review commit `3a0b5e1011dedc0414c18b8a8c102d01f969f70a`, current HEAD,
fetched origin/main, R21/R27 hashes, SQLite library version, Swift compiler,
macOS/APFS profile, and unrelated dirty paths. Confirm R21/R27 modify only the
two planning documents. Require approved SPEC-001 and SPEC-044 changes before
source implementation; plan approval authorizes no identity, pricing,
admission, settlement, reward, enforcement, deployment, or release.

## R27-02 — directory-bound VFS/open profiles

Build the C VFS against the repository SQLite ABI. Test the bootstrap
READWRITE|CREATE|FULLMUTEX|NOFOLLOW profile and the selected
READWRITE|FULLMUTEX|NOFOLLOW profile with CREATE absent. Race every ancestor,
directory, main, journal, WAL, and SHM at xOpen/xAccess/xDelete/xFullPathname,
recovery, checkpoint, commit, and close. Reject symlinks, hard links, wrong
owner/mode/link/device, separators, URI parameters, dot names, temp names,
super-journals, and unknown leaves. Prove `openat` CREATE uses
O_CREAT|O_EXCL|O_NOFOLLOW without O_TRUNC, existing recovery leaves omit CREATE,
and the captured directory FD prevents ancestor substitution. Run applicable
upstream SQLite lock/WAL/crash/short-read tests plus independent C and Swift
fault harnesses.

## R27-03 — complete deterministic bootstrap

Independently encode the R21 bootstrap/source/intent tuples and compare every
byte and SHA. Exhaustively crash after candidate mkdir, every prefix-intent
write, intent fsync/rename/directory fsync, main create/header write, every DDL,
journal write/sync/recovery, metadata insert/commit, intent delete/fsync, WAL
conversion/checkpoint, candidate rename, ready commit, and format publication.
Directly construct E0 through E6 and require the specified unique resume edge.
Malformed prefix, wrong intent, identity drift, non-page-aligned main, invalid
header, non-hot journal, partial committed schema, duplicate intent, unexpected
leaf, or both final and candidate protects without deletion. Before B8 R4 alone
selects; after B8 V5 alone selects and missing V5 main never invokes CREATE.

## R27-04 — fixed registry, recovery mapping, and cursors

Two independent expanders must emit exactly 495 registry entries: allocation 1,
row 174, and fixed 320 split 32/64/32/32/32/128. Require all and only the 128
recovery entries to carry exactly one `legacy-inspect-readonly` intent and no
new evidence; every other fixed entry carries none. At S=R=1,024 verify
`32S+16R+128=49,280`. Exercise first/last/first-over cursor for each family:
source/tree/verification/materialization 32, merge 64, recovery 128. Inserting
or updating materialization cursor 33 or 64 must fail its DDL CHECK.

## R27-05 — exact mutation manifests and accounting

Compile the normalized manifest to parameterized SQL and golden-compare SQL,
bind order/types, statement count, per-statement `changes()`, total changes,
charge deltas, protocol counters, open-operation count, and WAL reservation.
Exercise standalone templates with exact totals: allocation success 10,
allocation cancel 3, staging register 6, custody verified/pending 9, initial
activation 7, replacement 9, generic finish 3, allocation-aborted finish 4.
Prove named special progress replaces generic progress and cannot be composed
with it. For each statement force zero and two affected rows and require total
rollback. Crash before/after every statement and recover the same operation by
UUID with no repeated external effect, evidence, receipt, charge, or refund.

## R27-06 — schema-bound ownership and concurrency

Execute Appendix A with foreign_keys ON and run integrity_check and
foreign_key_check. Seed two rows A/B with different transaction, model, release,
artifact, custody event, and operation. Reproduce every R20 counterexample by
cross-splicing one component at a time into row_slots, staging_sources,
custody_events, custody_current, catalog active/pending, gc_candidates, and
gc_events; each commit must fail `SQLITE_CONSTRAINT_FOREIGNKEY`. Replace only a catalog
binding digest with an arbitrary 32-byte value and require startup, serving,
replacement, and GC semantic-integrity checks to protect before use. Test all-null
catalog tuples and exact all-non-null tuples succeed. Run concurrent first-slot,
last-slot, same-operation replay, differing replay, and replacement contenders;
only one open-operation slot and one exact winner may commit.

## R27-07 — allocation and reachable abort terminal

Exercise eight allocation cancellation attempts: attempts 1–7 return the slot
to free, attempt 8 makes it exhausted, and no source/evidence is created. Test
allocation success at ordinals 0, 1,023 and catalog-full at 1,024 rows. For each
abort generation 0–7 traverse all eight registered row steps, crash/replay each
commit, and verify only slot seven can retry. At generation seven require
A8,row-abort-terminal and exactly eight abort receipts. Repeated later aborts
must return byte-identical `retry_exhausted_v1` tuple bytes with SQLite
`total_changes()==0` and unchanged operations, transitions, evidence, receipts,
charges, and refunds. Retired/protected rows return their distinct zero-write
outcomes.

## R27-08 — staging, custody, replacement, and serving lifetime

Test canonical provider UID staging registration, token/caller/catalog/source
binding, unsupported override, cross-user/mount/release/model replay, drift at
every C0–C6 boundary, cancellation before/after publication, two content passes,
immutable flags, and direct receipt recapture. Exercise initial activation and
replacement crash boundaries and prove whole old or whole new catalog tuple.

With actual supported MLX inference, acquire a shared serving pin, switch the
active tuple, and attempt GC before the model open, during lazy weight access,
during generation, after cancellation, and after completion. GC's exclusive
lock must fail while any provider duplicate is held and succeed after the last
close. Kill daemon and provider separately; daemon death must not release the
provider FD and provider death must release it. A catalog change between first
snapshot and post-pin recheck closes/retries. Enforce the 15-minute capability
and two-second SQLite snapshot limits. Record model, artifact, OS, chip, RAM,
MLX/runtime, and receipt context; fixture inference is insufficient.

## R27-09 — bounded authoritative GC

Model-check the complete 4,096-entry path. Enqueue is generation 1; 16 successful
checking/result pairs plus eight failure checking/result pairs end at 49 in all
legal interleavings. Generation 50 is the first-over protected control event,
does not increment result_count, and 51 fails DDL. Independently assert successful_quanta<=16, failure_count<=8,
result_count<=24, one lifecycle per artifact, maximum 1,024 candidates and
51,200 events. Crash after every checking/result/cursor/fairness commit; recover
by deterministic helper UUID and direct result path. Exercise live child, dead
child, duplicate helper call, six-second kill, unreaped kernel I/O, active and
serving-pinned artifacts, immutable flag failures, and first-over table/counter
writes. No SQLite transaction spans daemon deletion.

## R27-10 — hard WAL bound and recovery reserve

First reproduce R20's retained-reader case exceeding 64 MiB. Under R21, hold a
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

## R27-11 — all-table/page maximum shape

Populate every table and every index at its Appendix A/section 9 maximum using
maximum-width legal values, including 1,024 rows, 186,688 operations, 560,064
transitions, 49,280 intents/evidence, 8,192 custody events, and 51,200 GC events.
Verify every protocol counter and COUNT(*), run ANALYZE, integrity_check, and
foreign_key_check, VACUUM at 4,096-byte pages, and require main plus indexes at
or below 448 MiB. For every table, counter, cursor, ordinal, generation, UNIQUE,
and composite owner key, attempt the first-over value and require rejection.
Measure maximum 12-row transactions and all rollback/recovery states on the
pinned APFS/SQLite profile. Arithmetic or sparse fixtures do not qualify the
physical bound.

## R27-12 — codecs and reproducible CLI/app inventory

Golden-test tuple_v1 and every Appendix D receipt at minimum, maximum, and each
nullable position. Reject negative/overflow integers, non-NFC/invalid UTF-8,
NUL, wrong byte lengths, alternative nulls/tags/enums, reordered/missing/extra
fields, floats/maps/arrays/trailing bytes, wrong digest target, and path
character-count substitution. Recompute row digests and every composite binding
from independent code.

Run the Appendix E Swift parser over exactly the two declared production roots
with the pinned toolchain. Require stable regeneration and a checked-in manifest
before source edits. Assert the three app files ModelTransactionControl.swift,
ModelTransactionPayload.swift, and ModelTransactionRequest.swift appear with
their pending/payload/cancellation surfaces. After B8, every banned symbol or
literal must be absent or syntax-mapped to the exact pre-B8 R4MigrationReader or
non-authoritative app transport allowlist. Runtime fault injection must prove no
legacy authority open/write, direct adoption, or enumerating GC occurs.

## R27-13 — compatibility, observability, and acceptance boundary

Test old R4 authority before B8, resumable candidate construction, irreversible
V5 selection after B8, backup/restore with database identity and WAL recovery,
and typed failures for schema/registry/manifest mismatch, corruption,
protection, full capacity, unsupported custody, stale pin, and GC unavailability.
Metrics must expose bounded counters/headroom, WAL reserve/result, operation and
GC state, replay, and protection code without paths, model bytes, tokens, or
secrets.

Targeted unit and fault tests run first, then fresh `swift test`, required Xcode
Malibu app tests, distribution checks, and applicable physical MLX/custody
journeys. Three independent GPT-5.6 Sol lanes audit the complete implementation
diff for code, security, and architecture until each reports zero Critical,
High, and Medium findings. Implementation completion, local verification,
physical-Mac qualification, and production qualification are reported
separately. R21/R27 approval completes none of them.
