# Build 1 reservation correction test specification R33

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R33 tests exact R27 on author base
`c9c46b03799a9314eb6a73a452ca21562af01d93`, fetched `origin/main`
`7128d1206afcf3cc857479e1d776ddc4899b020a`, and failed review
`reservation-search-progress-r26-plan-sol.md` SHA-256
`ea22bd66871f033f0bb690311148eb3b090e95731cebbd37f09c770d5d837d46`.
The reviewed R26/R32 hashes are
`358e63153db080ee22424e567ab312c1465b2b89e3489519447322aba320c42d`
and `80b4b213e81e89c674d450b176d3d3c39ac9d8b0cf15025abdcf1ea9d10cd1a8`.
Every retained R29-R32 test remains required unless R33 supplies a stricter
replacement. A skipped, zero-selected, fixture-only substitute, timeout, or
historical run is never a fresh pass.

## Acceptance map

| ID | claim proved | level |
|---|---|---|
| R33-01 | exact schema/registry/identity derivation and no hidden DML change | independent executable oracle |
| R33-02 | canonical 20-digit generation interoperates across SQL/tuple/path/JCS/RPC/receipts at 2^53 and Int64 max | unit + cross-language |
| R33-03 | exact 619-byte intent/temp publisher has one successor for every crash/collision | unit + Darwin filesystem |
| R33-04 | raw-XPC exact-message authentication, caps, FD rules, PID/exec/reuse rejection | root/provider physical Mac |
| R33-05 | request-bound receipt, authority-root golden, and acyclic backup envelopes reject splices | unit + integration |
| R33-06 | worker v3/RPC/CAS lifecycle and 32-slot restart recovery are closed | root/provider + actual MLX |
| R33-07 | signed stopped-state/zero-lease/maintenance proofs safely export/restore/retire | destructive isolated integration |
| R33-08 | parent-fsync/restart B8 has one authority successor and zero postselection R4 access | crash harness + syscall trace |
| R33-09 | frozen 1.8.123 app/CLI/headless/updater/installer fail closed after B8 | signed release assets + Xcode/Mac |
| R33-10 | all current/new roots and authority bypasses are inventoried on eventual base | AST/SIL/binary/static |
| R33-11 | signed package install/upgrade/failure/uninstall preserves anchors and keys | package/release physical Mac |
| R33-12 | storage, connection, record, backup, main, journal, and first-over limits hold | maximum-shape physical Mac |

Plan approval requires an independent native GPT-5.6 Sol verifier to inspect
R27/R33 and report zero Critical, High, and Medium. Implementation acceptance
later requires complete-diff independent code, security, and architecture
audits at the same zero threshold.

## R33-01 — exact schema, registry, identities, and rows

Two separately implemented Python programs extract R23 Appendix A, reproduce
its 43,652 bytes/SHA, apply the exact R25, R26, then R27 substitutions, and
require exactly:

~~~text
schema bytes     44448
schema sha256    434b4d4eb9370e6707ec12d6ca2ea584f47d2f970c4d633a96a87e7d14aa5e06
application_id   1297109587
user_version     27
tables           24
explicit indexes 11
~~~

Execute the stream with the production-linked SQLite and independent Python
SQLite. Query `sqlite_schema`, every table/index SQL byte, PRAGMAs, and
`integrity_check`. Insert the full legal B3 fixture: one protocol row, one
bootstrap row with generation `00000000000000000001` and 619 bytes, 495
registry rows, six fixed rows, 1,024 row slots, one GC row, 32 serving slots.
Require 1,560 inserted logical rows. Zero/two bootstrap rows, any generation
negative vector, 618/620-byte intent, later bootstrap insert/update/delete,
1,559/1,561 rows, and schema 26 reject.

Re-expand all 495 transition records and require registry
68,992/`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`,
dispatch 1,309/`af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`,
semantic 97,959/`0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
Execute every registered DML descriptor and exact `sqlite3_changes()` guard,
including generation-50 and all serving templates, proving no schema-v27
substitution silently changed row accounting.

The independent tuple encoder requires bootstrap 305 bytes/SHA
`2b3972d7b5d1866b4d6974ab0a5a8e871c4812c678c8a42d593ca423d4dab815`
and database identity 344 bytes/SHA
`251788668b16ed037dc126fc0f3fffad4e6786ab6ce8b30b87f9ee59004f0b3b`.
Change each operand, domain, schema text, type tag, order, version, nonce, or
candidate identity independently and require a different digest/rejection.

## R33-02 — one exact generation representation

Run identical vector files through Swift `DatabaseGenerationV1`, Python,
Node BigInt/string-only code, Go, SQLite CHECKs, tuple codec, relative path
builder, JCS selector, every RPC/receipt/witness/envelope decoder, and backup
restore. Accept exactly the five R27 positive vectors, including 2^53-1,
2^53, 2^53+1, and Int64 max, without conversion through IEEE-754. For each,
assert SQL bytes == tuple text bytes == path fragment == JSON string == DTO
`canonical20` == receipt/witness/envelope bytes.

Reject `0`, JSON numeric `1`, `9007199254740993`, JSON exponent/decimal,
19/21 digits, sign, whitespace, NUL, non-ASCII digits, unpadded form,
`00000000000000000000`, `09223372036854775808`, SQLite numeric affinity,
tuple u63 tag, duplicate JCS key, and a parser that round-trips to different
bytes. Increment max must return typed overflow before a path, SQL, or RPC
effect. Confirm all five legal format objects are exactly 806 bytes and remain
distinct in Node. Generation-1 bytes/SHA must equal R27's exact JCS and
`bcc1bb0f65f72bf8980dc5fb7db1f42153f679a17435411dfb7b69f7b20019c0`.

## R33-03 — intent codec, exact paths, and crash closure

The exact generation-1 intent is 619 bytes, SHA
`97c8ea16ed0c9acc384d529a67d2541203e40c7cb872d9786ae24dbe905c3638`.
Two independent encoders must emit this complete vector:

~~~text
6d616370726f76696465722d7232372f626f6f7473747261702d696e74656e742d763300000000140300000013626f6f7473747261705f696e74656e745f7633010000000000000005030000001430303030303030303030303030303030303030310400000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f062b3972d7b5d1866b4d6974ab0a5a8e871c4812c678c8a42d593ca423d4dab81506251788668b16ed037dc126fc0f3fffad4e6786ab6ce8b30b87f9ee59004f0b3b06111111111111111111111111111111111111111111111111111111111111111106222222222222222222222222222222222222222222222222222222222222222206434b4d4eb9370e6707ec12d6ca2ea584f47d2f970c4d633a96a87e7d14aa5e0606d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63060640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee06333333333333333333333333333333333333333333333333333333333333333301000000004d50525301000000000000001b010000000000001000030000000644454c455445010000000000000001030000001164617461626173652d6c69666574696d650400000071626f6f7473747261702d696e74656e74732f30303030303030303030303030303030303030312d313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131312e696e74656e742d763306bf22af8e0fb36f4df477331045d08fd90cf12350b98dadd85ece2ee5df43c48f
~~~

Require final path 113 bytes/SHA
`bf22af8e0fb36f4df477331045d08fd90cf12350b98dadd85ece2ee5df43c48f`
and temp path 121 bytes/SHA
`b743e2bf5240340a207adbbc055735e625350724345e39b167f05721f4265b52`.
Decoder rejects every one-field/type/order/domain/path mutation and any length
other than 619 before allocation.

On APFS, crash after temp create at every prefix length 0...618. Restart must
direct-open only the exact temp, compare it with the deterministic prefix,
unlink/parent-fsync it, retire its nonce, and construct a new identity. Explicit
coverage counters require all 619 cases; 0...602 cannot be summarized away.
Crash at exact 619, fsync, rename, parent fsync, reopen, and reply serialization;
exact 619 resumes/returns one identity without new randomness. Exercise wrong
prefix at every offset, length 620, temp+final, correct temp plus wrong final,
symlink/hardlink/FIFO/device, owner/mode/flags/xattr/ACL drift, parent replacement,
same-name `O_EXCL` collision, alternate `.tmp`, dual source/candidate paths,
and main existing before receipt. Every ambiguous state protects and never
unlinks evidence. Cancellation/error closes every FD.

## R33-04 — real raw-XPC identity and resource bounds

Build and codesign the C shim, protocol library, authorityd, broker, CLI, and
Malibu app from the exact implementation diff. Confirm the public SDK symbols
and link targets. Install the root daemon and provider LaunchAgent on a disposable
physical Mac using separate UID-0/provider/test-attacker accounts.

Instrument authorityd so an accepted request records ordered booleans only:
message delivered; connection/global cap acquired; exact XPC dictionary type;
`SecCodeCreateWithXPCMessage` succeeded; designated requirement/CDHash/UID
accepted; body length checked; tuple decoded; root opened. Assert bad identity,
4,097-byte ordinary body, 262,145-byte metadata body, extra key, wrong XPC type,
wrong/multiple FD, and unknown method never reach tuple decode/root-open. The
claim begins after libxpc delivery; no test claims pre-transport allocation.

Exercise approved broker/worker; same UID unsigned binary; copied body from an
approved process; broker passing bytes to attacker; attacker passing bytes to
broker; connection held across `exec`; peer exit with queued message; delayed
invalidation; forced PID churn/reuse; stale message reply; Team ID/designated
requirement/CDHash/version mismatch; old/new upgrade overlap; key rotation;
replay and same UUID/different bytes. Only the exact same received-message
execution may pass. Never accept PID equality alone.

Open 64 global/8 per-UID connections then first-over; run 32 global/4 per-UID
in-flight and first-over; submit a second request on one connection; cancel and
invalidate at every handler stage. Require zero application queue, bounded
memory, `resource_exhausted`, prompt counter recovery, no leaked FD, and later
at-limit success. Repeat for 10,000 hostile cycles under leak/fd/memory tools.
Offer may return exactly one read-only FD; accept may carry exactly one FD;
authenticated broker startup may receive exactly one provider-root directory
FD; all other calls/replies carry none. Verify descriptor access mode, CLOEXEC, inode,
flock, handoff binding, duplicate lifetime, and closure on every outcome.

## R33-05 — receipts, root identity, and backup construction

Two independent tuple implementations reproduce the 59-byte authority-root
path digest
`148e1b60fb4d76b59bd145b6e515a4bf77f9d1edf3f13c2cf86eaaf001979ae4`
and the 336-byte synthetic root tuple digest
`b1fe4bf7e7a17761822264c9d7562c28e6cee25d7c6c538ecf455a686794f992`.
Also require the provider-root golden relative path 21 bytes/SHA
`94023778ffccea6ea05fe42fbe22768945b3b1ea1ac54e103ba441c3f0443ded`
and tuple 263 bytes/SHA
`02f196c7c4a5772e0c5ecd6f443c71a9d48b5a664b64b403c2bfabeb10ec4227`.
Change each of its 15 fields, path byte, parent component, installer receipt,
inode/device/birthtime, owner/mode/flags, or replace a component between
`fstatat` and `fstat`; reject before a root leaf effect. Authorized creation of
a child may change directory timestamps/size but not the stable identity.

For every daemon method generate a legal request and receipt. Reuse the same
request UUID while changing every field one at a time; request tuple SHA and
receipt signature must change and the old receipt must reject. Verify the
receipt's authenticated code/UID, database/generation, request identity,
predecessor/successor, root, payload, expiry, key ID, and signature. A receipt
for create/read/export/restore/retire/worker operation cannot authorize any
other operation or later predecessor.

Independently construct unsigned backup bytes, hash them, construct the export
request, verify that request-bound daemon receipt, then construct/sign final
envelope and compute final SHA. Assert there is no hash cycle and that both
independent encoders emit identical bytes. Recompute at restore without using
stored asserted hashes. Splice each component/length/hash, unsigned bytes,
export receipt, receipt request SHA, backup UUID, root, database, generation,
main, format, intent, schema/registry/dispatch/semantic, artifact-lock set,
lease proof, broker/daemon key, final signature, or final SHA. Each rejects
before leaf creation. 262,144 bytes accepts; 262,145 rejects.

## R33-06 — worker v3, CAS witness, and full lifecycle

Generate the complete 37-field worker ordinal table from R27 into a checked-in
fixture. Independently encode the maximum record and require exactly 1,486
bytes/SHA `e17519ab19ecb088bdb59c2675283574518120ef5e01e9a1e00d2d0342908fee`;
bytes 1,487...8,192 are invalid because padding/extra fields are unregistered,
and 8,193 rejects before write. Require maximum worker final/temp paths 85/93
bytes and handoff final/temp paths 84/92. Reject v1/v2 domain/schema/protocol, missing
artifact-lock/database/generation/request fields, wrong null state, invalid
terminal state, bad signature, predecessor splice, heartbeat non-+1, and
terminal bytes after a terminal record.

For each of the eight RPCs assert exact domain/schema/field count/order/types,
authenticated actor, request tuple SHA, database/generation, slot/generation,
permit, request bytes/SHA, pin, handoff, worker, CAS witness, predecessor, and
returned full object bytes. Flip every field independently. Request mutation,
splice, wrong actor, stale deadline/boot/key, same UUID/different bytes, replay
at another slot/generation, second request under one permit, and ciphertext or
artifact substitution reject before inference or root mutation.

For every existing serving DML template, construct predecessor/successor row
digests and broker witness. Test deterministic witness-ID derivation, Ed25519
reconstruction after crash, commit generation +1, issuer requirement/CDHash/key,
request SHA, prior witness, and root predecessor. Crash before sign, before
BEGIN, each SQL statement, before commit, after commit/before send, after send,
before/after root successor fsync, and before reply. Restart broker/daemon in
both orders. A precommit or replayed witness never advances root; a committed
witness is reconstructed byte-identically and advances at most once. Daemon
never opens SQLite; broker never opens root worker/handoff directories.

Run offer -> accept -> prepared-to-running CAS -> finalize -> three heartbeats
-> terminating CAS -> terminal -> terminal/free CAS -> delete against actual
MLX inference with request/artifact/model/hardware context recorded. Repeat for
complete, cancel, worker failure, deadline expiry, malformed completion,
disconnect, process exec, PID reuse, crash, and reboot. Provider signature or
PID alone never proves work or process death. Verify one exact request and no
failover to another provider/artifact.

Fill all 32 slots and assert the 33rd rejects before spawn. Crash with each slot
at a different lifecycle point, restart with empty memory, and iterate exactly
0...31 through recovery. Normal or abnormal terminalization must either prove
process/lock closure or leave that slot typed protected. The closed successful
fixture must finish with 32 free rows, generations incremented exactly once,
zero handoff/worker final/prefix leaves, no live artifact FD/process, and
reusable slots. Run the first-over/recovery fixture repeatedly under race and
leak instrumentation.

## R33-07 — stopped maintenance and destructive crashes

Generate exactly 32 ordered free entries in `lease_set_zero_v1`; duplicate,
omit, reorder, make one nonfree, alter row SHA/generation, or set any connection,
operation, snapshot, backup, or client count nonzero and reject. Flip every
broker-state-witness field and signature. Require close rc 0, last commit,
integrity/FK pass, main and parent `F_FULLFSYNC` rc 0, journal/WAL/SHM absent,
monotonic sequence/predecessor, same boot, and <=5-second freshness. Broker
cannot reopen SQLite after witness without invalidating it.

Daemon direct-checks root/provider identities, main/format bytes, journal
siblings, its XPC counters, all 32 derived handoff/worker paths, artifact-lock
FDs, backup sessions, and maintenance path. Instrument SQLite opens in the
daemon and require zero. Issue one 30-second maintenance lease; stale, replay,
wrong purpose/request/witness/root/key/boot/sequence, second lease, live worker,
live reader, backup, or journal rejects. Crash before/after active prefix/fsync/
rename/parent-fsync and consumed prefix/fsync/rename/parent-fsync, then before/
after each restore/retire filesystem effect and receipt. Every state has one
idempotent successor and never performs the destructive effect twice.

Export/restore one exact stopped database to the same authority root and prove
identity preservation. New root, recreated artifact lock, concurrent original,
raw copied main, missing intent, partial envelope, stale receipt, or different
generation rejects. Retire pre-main cancellation, drained forward replacement,
and explicit whole-authority destruction separately. Ordinary GC/cancel cannot
obtain a lease or delete selected intent.

## R33-08 — B8 crash table and no R4 resurrection

Crash at every byte 0...805 of `format.json.tmp-v6`, temp fsync, rename, while
parent fsync is entered, immediately after successful parent fsync, before and
after fresh reopen, daemon read, SQL open, validation, and R4 release. Restart
from a new process and freshly captured parent FD. The only successors are:

| durable observation | successor |
|---|---|
| exact old R4 final, absent/partial temp | preselection R4; discard/retain exact temp per prefix rule |
| exact old R4 final, full valid temp | resume rename and parent fsync |
| exact final format-v6 | selected V5; validation failure protects V5 |
| malformed/dual/unregistered state | protected; no authority guessed |

The crash during parent fsync is classified solely by the freshly reopened
durable bytes. No test consults an in-memory reopen-success bit. Instrument
every R4 pathname and all legacy selectors after exact v6 becomes observable;
require zero open/openat/stat/read/write/rename/unlink/enumeration calls and no
readiness, economics, serving, or saved-cache fallback. Exact v6 with missing
intent/daemon/row/key or corrupt SQL remains selected-and-protected, never R4.

## R33-09 — frozen shipped predecessor incompatibility

Fetch only the repository release manifest's immutable, signed/notarized
version-1.8.123 assets and record their SHA-256 without modifying them: standalone
CLI, Malibu.app and embedded CLI, provider/headless/watchdog plists, updater
metadata, installer, uninstaller. If an asset is unavailable, this gate is
blocked rather than fixture-substituted.

On selected format-v6 under syscall tracing, launch every frozen CLI command
that can inspect, prepare, recommend, adopt, read, serve, report status/economics,
repair, update, or uninstall; launch Malibu onboarding/model-management/status/
economics/serve paths through Xcode UI tests; bootstrap headless/watchdog; run
old updater/repair; attempt old installer downgrade/uninstall. Require a clear
unsupported/protected result, zero R4 authority syscall/effect, zero serving,
no stale readiness/economics, no schema/main/format/intent write, and no
downgrade. Separately test new binary against malformed old formats/receipts.
Swift CLI tests do not substitute for Xcode app tests.

## R33-10 — complete eventual-base inventory

From the eventual implementation base, sort every production `.swift`, `.c`,
`.h`, plist, entitlement, Package.swift, project.yml, installer/uninstaller,
update, distribution, and signing script under the old CLI/Malibu roots and all
five new R27 roots. Record manifest bytes/SHA, compiler/toolchain versions, and
parse/compile every entry. Generate AST/SIL call edges plus literal/symbol/path
inventory for every accumulated direct durable/custody/R4 selector and all
authority/broker RPCs. No source root, generated file, package payload, or app-
embedded binary may be omitted.

Record the literal `ModelRuntime.swift` path overlap between `7c0aad11` and
`7128d120`; inspect and classify its SPEC-038/039 scheduler hunks. Re-run the
entire compiler inventory rather than reuse the prior 191-file hash. Fail on
any post-B8 app/CLI/headless direct durable URL/open/hash/adopt/readiness path,
any broker root-worker access, daemon SQLite access, old challenge/NSXPC path,
unregistered wire decoder, generation JSON number, or unreviewed product root.

## R33-11 — package, signing, upgrade, and uninstall

Build release configuration and inspect the package bill of materials. Require
literal versioned binaries, two correct plists/Mach services, root/provider
UIDs and modes, hardened runtime, required minimal entitlements, matching Team
ID/designated requirements/CDHashes, no writable executable parent, no secret
material, and all five target roots in build/test/sign manifests. Compare
standalone and Malibu embedded CLI byte identity after final signing as the
existing release gate requires.

On a clean physical Mac test fresh install, root-owned provider-placement
component symlink/replacement, provider attempt to rename/unlink `data-v5`,
startup directory-FD splice, root-anchor replacement, same-version repair, old->new upgrade,
new daemon/old broker and inverse overlap, key overlap/retirement, failure after
each install/plist/bootstrap step, reboot, B8 then failed upgrade, downgrade,
ordinary uninstall, and explicit stopped destruction. Before B8 rollback may
restore prior signed artifacts. After B8 incompatible artifacts cannot launch
authority or mutate R4/V5. Uninstall with any live database/intent/worker/backup/
maintenance lease refuses; successful explicit destruction fsyncs retirement
receipts before deleting keys/anchors. Inspect package payload and final disk
ownership/modes after every case.

## R33-12 — exact bounds and broader acceptance

Construct exact-at-limit then first-over fixtures for: 619-byte intent and two
generations; 806-byte format pair; 32 handoff final/prefix pairs at 524,288;
32 worker final/prefix pairs at 95,104; one active/consumed maintenance pair;
24,576 root manifest; 653,398 total daemon protocol files; 262,144 backup metadata; 64/8 connections;
32/4 in-flight RPCs; one request per connection; 4,096 normal body; 448 MiB
main; 64 MiB journal; 1,024 rows; 32 slots; every inherited SQL/event/counter
maximum. Require no hidden history, temp, tombstone, replay log, or third
generation and exact typed rejection before crossing write.

Run targeted unit suites, full `swift test`, Xcode Malibu tests, distribution
tests, package/signing checks, actual MLX one-request inference, and the physical
root/provider suite. Then run the broader repository tests appropriate to the
changed surface. Record exact commands, selected test counts, exit codes,
durations, hardware/chip/RAM/OS/Swift/SQLite/MLX/artifact identity, and logs.
Docker-dependent tests require a live Docker runtime. Actual MLX and Xcode are
separate from deterministic fixtures. Production qualification, release,
deployment, admission, pricing, settlement, rewards, and hardware-wide claims
remain blocked unless their separate evidence exists.

## Author-time oracle record

Fresh author-time results:

~~~text
git rev-parse HEAD
# c9c46b03799a9314eb6a73a452ca21562af01d93
git fetch --prune origin && git rev-parse origin/main
# 7128d1206afcf3cc857479e1d776ddc4899b020a
sha256sum reservation-search-progress-r26-plan-sol.md R26 R32
# ea22bd66...d837d46 / 358e6315...0c42d / 80b4b213...cd1a8
python3 independent_schema_tuple_jcs_oracle.py
# schema 44448/434b4d4e...a5e06; SQLite 1297109587/27/24/11
# bootstrap 305/2b3972d7...ab815; database 344/25178866...f0b3b
# final path 113/bf22af8e...c48f; temp 121/b743e2bf...5b52
# intent 619/97c8ea16...c3638; format 806/bcc1bb0f...019c0
# root path 59/148e1b60...9ae4; root tuple 336/b1fe4bf7...4f992
# provider path 21/94023778...3ded; provider tuple 263/02f196c7...c4227
# worker maximum 1486/e17519ab...08fee; worker/handoff paths 85/93 and 84/92
SDK=$(xcrun --sdk macosx --show-sdk-path)
rg public-xpc-and-security-symbols SDK
# all R27 named public entry points declared
git diff --name-status 7128d120..origin/main
# empty
~~~

These are plan-shape oracles. No source implementation, root/provider package
fixture, full Swift/Xcode suite, actual MLX, signed predecessor launch, release,
deployment, or production acceptance is claimed. After the final two artifacts
are written, author scope must show only R27/R33 relative to the author base,
`git diff --check` must be clean, and final file hashes are reported outside
the files to avoid self-reference.
