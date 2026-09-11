# Build 1 reservation search progress — test specification R26

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Governing candidate: reservation-search-progress-addendum-r20.md. R26 replaces
R25. Every result must be fresh. Skipped, interrupted, timed-out, zero-selected,
fixture-only, deterministic-only, historical, or mocked execution cannot pass a
stronger claim.

## R26-01 — frozen inputs and governance

Recompute the R20/R26, R19/R25, failed R19 review, review commit, worktree HEAD,
and origin/main hashes. Confirm the failed-review hash is
fba7ebfb0e2732b0c6b34af05709a4d1b83fc3e54dfde03a823179b22256ce7f.
Inventory unrelated dirty files without modifying them. Prove no R20 database,
VFS, schema, semantic manifest, allocation engine, staging receipt, custody
daemon, or SQL GC is already implemented.

Require approved SPEC-001 and SPEC-044 changes covering the selected SQLite
authority, deterministic bootstrap, VFS, allocation, state/abort graph,
semantic manifest, trusted staging/custody, replacement, capacity, GC,
compatibility, failures, observability, and feature gate before source work.

## R26-02 — directory-bound VFS and connection profiles

Build the C VFS against the repository SQLite ABI. Run the relevant upstream
SQLite locking/WAL/crash tests plus independent Swift and C harnesses. Assert
bootstrap's first open has READWRITE|CREATE|FULLMUTEX|NOFOLLOW and later opens
have READWRITE|FULLMUTEX|NOFOLLOW without CREATE. Assert DELETE mode permits
only main+journal and WAL mode only main+wal+shm. The rollback journal must be
absent before the ready transaction.

Race replacement of every ancestor, retirement directory, main, wal, shm, and
journal before and after every xOpen/xAccess/xDelete/xFullPathname, recovery,
checkpoint, statement, commit, and close. Test symlink, hard link, bind/mount
escape, device drift, wrong owner/mode/link, absolute/relative/URI/encoded
separator/dot names, temp and super-journal names, and overlong names.
BoundDirectorySQLiteVFS must use the captured directory FD, reject every
mutation or auxiliary open outside the leaf allowlist, and never fall back to
the default pathname VFS. A test-only fault VFS must prove the checks, not a
cooperating pathname callback.

Test application ID, user version 20, page size, max pages, every PRAGMA,
defensive mode, extension disablement, SQLite minimum version, full startup
integrity checks, affected-row FK checks, and exact VFS error mapping.

## R26-03 — deterministic bootstrap and crash recovery

For R=0,1,31,32,33,1,023,1,024 build exact R4 sources. Independently compute
source_index_sha256, every typed bootstrap-source-row tuple,
source_rows_sha256, and bootstrap_id from raw digest operands and require a
single lowercase path. Mutate tuple order/type/count, JSON serialization,
integer encoding, evidence identity, and raw path byte count.
Start 64 processes: the old R4 lock permits one creator and every other process
direct-opens the same candidate after the lock handoff. No directory
enumeration syscall is allowed.

Kill immediately before/after every B0-B8 read, hash, mkdir, xOpen, DDL group,
row/registry insert, DELETE commit/journal fsync/removal, WAL conversion,
checkpoint, close, deterministic rename, ready WAL commit, database/WAL/
directory fsync, format temp/write/rename, and final parent fsync. Before B8,
R4 selects and the deterministic candidate resumes. After B8, only R20 selects.
Test exact candidate, incomplete legal phase, unequal source/schema/registry/
manifest, stale candidate from changed R4 source, unexpected leaf, second
candidate, collision, no space, and 1,025 rows. Never enumerate, guess, delete
an unequal candidate, fall back after B8, or create a missing selected DB.

Run the prior supported binary against v5 and require rejection before write.
Run R20 against R4 and require bootstrap rather than treating a candidate as
selected.

## R26-04 — six fixed-state authorities

Expand all fixed lines and prove family/global/local ranges:
source 32/0...31, merge 64/32...95, tree 32/96...127, verification
32/128...159, materialization 32/160...191, recovery 128/192...319.
Bootstrap six fixed_state rows.

For every entry, execute begin/progress/finish from its selected family-local
predecessor. Race unrelated families and the same family. Unrelated families
advance independently; exactly one same-family caller wins. Reject caller
strings not equal to the joined registry and fixed_state rows, skipped/repeated
local ordinals, global/local mismatch, wrong family, complete/protected reopen,
and a fabricated predecessor. Kill at every statement/WAL sync and require the
complete predecessor or successor.

## R26-05 — post-bootstrap allocation

For empty and partially full stores, assert SELECT MIN over idx_free_row_slots
via EXPLAIN QUERY PLAN and statement counters. Execute allocation begin,
progress, and finish with four external intents. Require exact change counts
8/10/3, or 8/3/4 for cancellation before publication. Exercise allocation
attempts 0...7; attempts 0...6 return free and attempt 7 selects exhausted.
Progress atomically creates four evidence rows, source_rows, row_state
A2/row-normal-76, and occupied slot.

Race 64 first allocators and fill through ordinals 1,023 and 1,024. Require
unique increasing ordinals, no scan, exact replay, bounded cancellation churn,
and catalog_full with zero writes at 1,025. Kill before/after each external
evidence validation and SQL statement. Reject wrong evidence
kind/path/digest/identity, stale source,
cross-row operation, missing intent, duplicate-different replay, source row
without occupied slot, occupied slot without source row, and freeing a selected
row.

## R26-06 — reachable cancellation, abort, retry, and economics

Model-check the complete allocation A1 cancellation and row A2 graph. Start
each row at A2,row-normal-76. For abort generations 0...7 execute all eight
slots in order. For generations 0...6, slot seven returns exactly to
A2,row-normal-76 and increments attempt+abort generation once. Generation
seven selects A8 terminal. A further abort request selects protected without a
receipt/refund.

Test cancellation at allocation begin, allocation progress, every A2 abort
slot, phase-A3 begin/progress, A4, each A5 body, and A6. Only allocation A1 and
row A2 release unused reserve. A3+ completes forward or protects with the full
charge retained. Reject any abort entry from a non-A2 coarse state or fine
state other than row-normal-76, every abort-to-normal edge except slot seven,
generation skip/reuse, second refund, ninth receipt, and reuse of a normal
semantic slot.

For every operation, independently ledger maximum, consumed, released, and
abandoned charge per commit. Require terminal equality, transition charged-byte
deltas, and row-state accumulated consumption. Reject under-accounted terminal
rows, double release, A3+ release, arithmetic overflow, nonzero replay changes,
and a finish digest that does not reference its exact finish transition.

## R26-07 — semantic manifest, exact DML, and external effects

Independently expand 495 manifest lines and Appendix C. Require unique keys,
exact field count/order, exact normalized bytes/digests, and complete mapping of
all 174 row names, 320 fixed names, and allocation. For every line compare
production dispatch with the independent expected SQL statements, bind types,
old/new predicates, external template, evidence kind, charge equation,
base/incumbent change counts, replay result, and protection branch. Fail on a
human default or a name matched by zero/two rules.

Execute every manifest entry from a legal predecessor. Observe sqlite3 total
changes per statement and transaction. Require generic begin 3+K, allocation
begin 8, generic progress 4+E+special, allocation progress 10, generic finish
3, allocation abort finish 4, initial activation 6, and replacement 8; every
operation stays at or below 12. Test zero-row predicates, thirteenth row,
reordered statement, omitted meta/event/domain update, extra update, trigger,
cascade, wrong intent, external work before begin or after failed begin,
external replay, evidence substitution, and charge drift.

## R26-08 — atomic catalog replacement

Create an active A and verified/pending B for the same model/release. Execute
the exact replacement progress transaction: two custody-event inserts, two
custody-current updates, one catalog-slot CAS, transition, operation, and meta.
Require total_changes=8 and either the entire A-active/B-pending predecessor or
A-released/B-active successor after every kill/WAL boundary.

Test initial activation at six changes, A-only cancellation, stale incumbent,
stale pending, model/release mismatch, artifact/custody/source/binding/
operation substitution, second pending, digest collision, concurrent
replacement, cancellation race, and serving during switch. Cancellation must
compare and preserve every active column byte-for-byte. Serving must never
observe a partial pair.

## R26-09 — authenticated staging source and root custody

Install the reviewed test-signed daemon on a physical supported Mac. Test
registerStagingSource and copy using the audit-token UID, configured provider
UID, daemon-derived getpwuid_r home, canonical handoff path, signed catalog
envelope, and root-owned source receipt/token. Test both interactive and
headless configured accounts.

Reject cross-user token, wrong audit UID, unconfigured UID, arbitrary path/FD,
MACPROVIDER_MODEL_ARTIFACT_ROOT passed directly, home/mount/device change,
symlink/hard link, stale/replaced source, wrong transaction/catalog/model/
release/artifact/manifest, guessed/replayed token, old receipt generation, and
source mutation before/during registration or copy. An external model root may
only be unprivileged-copied into the canonical handoff; failure returns
trusted_custody_source_unsupported without adoption.

Run C0-C6 on the actual supported Build 1 artifact. Require two complete
content passes, manifest and identity transcript equality, root:wheel modes,
SF_IMMUTABLE, fsync/rename durability, direct root/receipt evidence, and actual
MLX open. Attempt every same-user flag/write/truncate/rename/unlink/link/swap/
xattr mutation before and after final recapture. Absence or incompatible daemon
must keep adoption disabled.

## R26-10 — recoverable GC lease and blocked I/O

Populate queued/checking/deleting/done/protected candidates. For every checking
candidate independently derive the helper UUID and result path. Kill the parent
before/after claim, child spawn, lock, each syscall, result write/fsync, reap,
event insert, cursor/meta update, and COMMIT. A restart must direct-open a valid
result or nonblocking-acquire the same daemon lock and resume the same cursor.
It must never strand checking or repeat a selected deletion prefix.

Race two reclaimers and a live original child. Busy daemon lock makes no event
and permits fair selection of peers. After child death, exactly one reclaimer
acquires. Test eight failed claims, 16 successful quanta for 4,096 entries,
terminal/protected first-over, event generation 64/65, and fairness with
concurrent enqueue. EXPLAIN QUERY PLAN must use idx_gc_fair.

Use a real FIFO read while holding the artifact lock and the supported APFS
fault harness. Require kill/reap/release within seven seconds when the kernel
permits. If unreaped, require blocked-kernel-io, no replacement child, honest
busy state, continued unrelated work/heartbeat, and lost host qualification.

## R26-11 — all-table lifetime and physical capacity

Independently derive every section 9 formula for S=1,024 and R=0,1,1,024 plus
first-over.
Exercise table-specific caps and protocol_meta counters under concurrency and
crash recovery. Verify verification_state overwrites one current row and is
removed atomically with custody receipt. Verify one GC lifecycle per artifact,
8 custody and 64 GC events per artifact, and no re-adoption after done.

Populate all tables and indexes to their exact R=1,024 maximum using maximum
legal scalar widths and references, including complete file identities and all
protocol_meta counters. VACUUM at 4,096-byte pages. Require main
database <=448 MiB, 16,384 emergency pages free, WAL <=64 MiB, no unknown file,
and all terminal/protection/GC transactions to complete after begin admission
closes. Exercise pages 114,687/114,688/114,689 and 131,071/131,072/131,073,
disk full, WAL/checkpoint failure, and every maximum 12-row transaction. A
smaller fixture or larger limit cannot pass.

Assert no custom carrier/page codec/B+ tree/promoted root exists in production
or fixtures and no test assumes rows per page. Record the pinned SQLite version,
APFS/macOS profile, database page count, freelist, all index sizes, WAL high-water
mark, and exact file set.

## R26-12 — canonical external codecs

Generate independent golden bytes and SHA-256 for minimum/maximum
custody_receipt_v1, every custody-entry file type, every legal gc_result truth
table row, and staging_source_receipt_v1. Assert daemon_protocol_version and UID
are u63, source token bytes length 32, path counts use raw bytes, and every
digest has exactly the Appendix D target.

Mutate tuple tag/order/count, integer sign/overflow, bool, NFC/UTF-8/NUL,
UUID/SHA/token/path length, path bytes, every null, enum, phase/outcome pair,
root-identity truth-table branch, content/tree/manifest/identity digest, and
trailing bytes. Swift, daemon C/Swift, and independent Python results must be
byte-identical.

Generate every Appendix A row digest from an independent DDL parser. Prove the
integer/bool/text/bytes/UUID/SHA classification is total and nonoverlapping,
exercise every legal NULL branch, and compare every SHA field with its section
10 target and direct foreign-key/reference. Reject hexadecimal text in a BLOB,
unreferenced finish/predecessor/evidence/current heads, a searched-by-digest
substitute, and any schema column absent from the scalar or target registry.

Retain R25's finite SHA continuation oracle exactly: 1,676 completions,
approximately 43.8678 GiB aggregate suffix work, u32 word bounds,
count/tail/IV/finalization invariants, one-shot equality, and recorded
hardware/resource ceilings.

## R26-13 — complete callsite migration and no bypass

Reproduce Appendix E's normalization over the frozen inspected tree and require
199 declarations with SHA-256
ee8c3d647aa4e06e32681de466a882f116edde3f2f440dc3c0a4fee1cda38373 and
68 bypass matches with SHA-256
2d15574a6dc9064501da011b2ec80e543f6a443fdf327b9efc6162fd8ad1a2b0.
If concurrent source work changes either input, record the new manifest and
reopen the plan gate rather than silently accepting a different callsite set.

Instrument every row of section 11's migration matrix. Before B8, compare the
R4 adapter with current behavior. After B8, execute every public store API,
ModelsSubcommand action/read, transaction action constructor, binding/evidence/
archive path, MacProviderCLI adoption, AutotuneRecommend adoption, serving,
cleanup, and GC entrypoint and assert only CatalogAuthorityV5,
TrustedCustodyClient, or CatalogGarbageCollector is reached.

Run a syntax-aware inventory plus a literal search over production Swift.
References to active.json, progress.json, maintenance.json, reservation
sidecars, captureIndexReceipt, recaptureIndexReceipt, direct active
adoptVerifiedStaging, and gcInactive must be absent after B8 except the exact
reviewed R4MigrationReader allowlist. Inject an open tracer and assert no R4
authority file is opened after B8. Delete/disable the adapter and prove the v5
build still compiles and passes.

## R26-14 — compatibility, observability, broader checks, and gate

Verify typed CLI/app states for busy, full, protected, migration required,
authority unavailable, trusted source unsupported, daemon unavailable,
artifact changed, verification incomplete, GC blocked, cancelled before
commit, and cancelled after active commit. Metrics must expose section 12
fields without paths, bytes, source token, provider/operator secrets, or keys.

After SPEC and plan approval, run targeted VFS/schema/codec/bootstrap/
allocation/state/manifest/replacement/custody/GC/capacity/migration tests,
then full swift test, Malibu Xcode tests, CLI/app bridge, governance checks,
actual supported-artifact preparation and MLX open, valid coordinator
admission, and correctly settled request. Docker integration counts only with
an available Docker runtime.

Review the complete landing diff through independent native GPT-5.6 Sol code,
security, and architecture lanes. The gate is zero Critical, High, and Medium.
Any change to authority, schema, VFS, manifest, DML, allocation, state graph,
economics, source/custody, replacement, GC, capacity, migration, or tests
reopens the plan gate.

Acceptance reporting must separately label implementation, local fixtures,
physical custody/filesystem qualification, signed release/feed evidence,
actual MLX inference, coordinator admission, settlement, deployed services,
and production qualification. R20/R26 approval alone completes none of them.
