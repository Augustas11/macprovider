# Build 1 reservation search progress — test specification R32

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

Governing candidate: `reservation-search-progress-addendum-r26.md` together
with every unchanged R25/R24/R23 requirement. R32 supersedes R31 where named
and otherwise incorporates every R31/R30/R29 test. Skipped, interrupted,
timed-out, zero-selected, fixture-only, mocked, historical, or non-Darwin runs
cannot pass a stronger claim.

## R32-01 — frozen inputs, scope, and finding closure

Require exact parent commit
`40d159d9b27e2a31b746ea3821f4bf6204081e5e`, review SHA-256
`b14dcf4546c0208514141d1b1730baef1885219b5840bd7290d8d187232bcb5a`,
R25 SHA-256
`75d7ae4cc0dabe7e8f22a6ca1ba4bff4a0338a72fc49a042c59d6a087787d9d2`,
and R31 SHA-256
`7a3995baa5c5d89653176b3b3598e41d63d2d7d2a4b30b09188ef4818c345641`.
Record fetched `origin/main`, including the required read-only reconciliation
of `7c0aad111e44cb320641bcefae3bf56851e9aaaa`, toolchain/macOS/APFS/SQLite
versions, and unrelated dirty paths. Require the author diff to contain only
R26 and R32. Parse R26's disposition table and require one non-cyclic mapping
for each R25-PLAN-H1/H2/H3/H4/M1. Approval grants no source, deployment,
release, economic activation, or hardware qualification authority.

## R32-02 — exact schema v26 and retained accumulated registries

Extract R23 Appendix A and reproduce 43,652 bytes / SHA-256
`70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f`.
Apply the three R25 transformations to reproduce 44,213 bytes / SHA-256
`2bcde8dd97fa1cb063ad09b41db8b895ec64cf6fa2fabd38b15c4d1dc671547e`.
Apply the four R26 transformations in exact order; every anchor occurs once.
Require 44,295 bytes, SHA-256
`b8c641a2f6ba8dfa73174c9bc04b5c2e552649a42fa0e09cbfb39b140bb3b86d`,
application ID 1297109587, user version 26, 24 tables, 11 indexes, and clean
execution with the qualified SQLite. Reject reordered transformations, CR,
changed whitespace, version 25, missing database generation, any intent bound
other than exact 603, extra table/index/trigger/view/stat table, or one changed
byte.

Execute B3 with the exact 603-byte intent and generation 1. Require one
immutable `bootstrap_authority` row, exactly 1,560 total B3 inserts and the
inherited 1/1/495/6/1,024/1/32 split. Reject 602/604/65,536-byte BLOBs,
generation 0/overflow, missing/second row, byte/SHA/nonce/ID mismatch, partial
transaction, and 1,559/1,561 totals. Prove the permanent authorizer denies
later insert/update/delete in runtime, recovery, maintenance, and qualification.

Independently regenerate the R24 registry, dispatch, and semantic streams.
Require exactly 495 / 68,992 /
`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`,
1,309 / `af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`,
and 97,959 /
`0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
Run all retained compiler, ordinal, exact DML, external-effect, counter,
generation-50, mutation, first-over, VACUUM/ANALYZE denial, journal, and page
oracles unchanged except for the v26 schema values above.

## R32-03 — executable root intent ownership and trust boundary

Install a real test `TrustedCustodyDaemonV5` as UID 0 with a distinct
provider-UID broker on a physical macOS host. Prove root creates and captures
the mode-0700 `bootstrap-intents` directory and the provider UID cannot
traverse, open, read, write, rename, link, unlink, chmod, chown, enumerate, or
replace it or a mode-0600 leaf. Prove only the daemon uses component-wise
no-follow opens and only the exact derived 20-digit-generation/source-index
path. Before B7 it must open only the exact provider candidate path from R26;
after B7 it must open only the fixed final path and reproduce the same
directory identity. Both present rejects. Instrument syscalls and reject an
absolute path, `..`, separator,
uppercase/short/long source hex, unpadded/overflow generation, caller FD,
caller flags/mode, symlink, hard link, alternate mount/device, replaced parent,
ACL/xattr, and generic operation request before leaf access.

Exercise approved broker, provider app, CLI, old broker, wrong UID/team/cdhash,
unsigned helper, PID-reuse, and forwarded/replayed connections. Require the
daemon to bind public NSXPC PID/UID to the kernel audit trailer through the
single-use challenge, derive pidversion/code with public APIs, and deny every
mismatch before root access. Compile/link against the selected public SDK and
fail on private `xpc_connection_get_audit_token` or equivalent SPI. Test
timeout, duplicate message, wrong port, wrong boot, connection invalidation,
and challenge theft. Fixture authentication cannot pass this physical
cross-UID gate.

Generate exact create/read/export/restore/retire request tuples and the 23-field
signed receipt tuple from R26. Two independent codecs round-trip them. Mutate
every field/type/order/domain/null rule, operation, request UUID, audit-bound
identity, backup binding, relative path, byte length, daemon key, and
signature. Each rejects before file or SQL effect. Create/read/export/restore
response bytes must match the receipt SHA and request; retire must return no
intent bytes and must prove absence after parent fsync. Replaying a read receipt
for create/export/restore/retire, another backup, generation, source, directory,
database, broker, boot, or request rejects. Derive each constructible legal
maximum from its closed field bounds; separately reject request byte 3,073,
receipt byte 1,025, and XPC-value byte 4,097 before allocation or root access.
For restore, mutate the
embedded export receipt independently. For retire, cover every reason/state/
lease/successor null rule and compare daemon-direct main/format/lease facts.

For create/resume, crash the daemon and broker before/after nonce generation,
temp create, every prefix write, temp fsync, rename, parent fsync, final reopen,
response serialization, and response delivery. For every partial length
1...602, require no response and no main; restart must direct-validate the
root-owned temp, unlink it, parent-fsync, retire that incomplete nonce, and draw
a fresh nonce. A complete valid 603-byte temp resumes rename without a new
nonce. After final durability every retry returns exactly the same bytes and
never draws another nonce. A temp over 603, temp plus final, main before final
receipt, final mismatch, second temp/final, or changed candidate identity
protects without deletion. Statically inspect and runtime-trace broker ordering
so no main open/create precedes valid receipt delivery. Verify owner root,
group wheel, mode 0600, regular type, link count one, byte length 603, no
ACL/xattr, same device, and exact bytes before success.

For read, crash at every open/read/validation/receipt-sign boundary and require
idempotent exact output or protection. For export, require stopped broker,
zero live serving slots/FDs, exact main/format/envelope values, and a signed
backup-bound receipt. For restore, test exact existing idempotence and absent
leaf creation under a stopped maintenance lease. Reject live original,
new/replaced root, changed candidate directory, raw main, missing/changed
envelope, stale/revoked key, altered 603 bytes, existing different leaf,
overwrite/truncate attempt, and different path. Crash every restore publisher
boundary and require one exact resume or protection. No test may expose a
private signing key.

Test deletion directly. Pre-main exact cancelled prefix may be removed and its
nonce retired. Selected, candidate-with-main, live-backup, live-worker, or
not-yet-drained old intent cannot be removed. After irreversible forward
replacement and drain, the daemon may delete only the exact old derived leaf
and parent-fsync. Crash before/after unlink/fsync and retry by the same path.
No enumeration, online GC, or ordinary cancellation may remove it.

## R32-04 — fixed intent codec, identities, bootstrap, and backup

Implement R23 `tuple_v1` twice independently. Generate the complete 20-field
ordinal/type table. Require the exact 113-byte golden path and path SHA
`b72d90e1fa0224f307bad960ed543e2b97b3e3c3d1a7f89f3b5ae78dfe827c75`.
Require the R26 bootstrap preimage 305 bytes / SHA
`7d4fc8547fe7d914363b401991b60446681e7551f546328de5404f798490e39c`,
database preimage 344 bytes / SHA
`55f0a242ffab0afcdc03474f3d32a230d7e1000013375032561afeea53f3bca0`,
and full intent 603 bytes / SHA
`f3ca14bafd5a3f53274068a8cacc5f761e7c55a8acab91a0a7df911e1db8301d`.
Byte-compare the full hex vector in R26. Independently derive serialized length
from domain, field count, tags, fixed payload lengths, and exact literal/path
lengths; do not fill a buffer to reach 603.

Mutate every field, type, order, domain, digest, database generation, nonce,
ID, directory identity, version, constant, path byte, and trailing byte.
Attempt 0...602, 604...65,536, 65,537, padded, duplicate, omitted, uppercase,
alternate numeric/string, null, and extension encodings. All reject before
allocation beyond 603, root access, main creation, SQL, or receipt. There is
exactly one legal encoded length, so the same constructed 603-byte vector is
both minimum and maximum legal shape.

Run the entire bootstrap crash matrix from CSPRNG through B8 and first selected
startup. Before B3 the broker has only daemon-returned bytes/receipt; after B3
the file, receipt, immutable row, `protocol_meta`, and recomputed IDs agree.
Crash each B3 statement, each B4 mask/row, B5, B6, B7, and hot-journal boundary.
P6 retains intent and advances to B7; P6a without root intent protects. A
broker direct-open attempt must fail by permissions and static policy. A
daemon outage or wrong receipt makes readiness unavailable and creates no
catalog read or external effect.

Create a supported stopped backup containing main bytes, immutable row, exact
603 intent bytes, signed export receipt, exact format-v6 bytes, and envelope
component lengths/SHAs. Restore it under R32-03, then prove selected startup.
Try missing intent, reconstructed equivalent values, changed nonce/path/
generation, row/receipt/envelope splice, new root, concurrent original,
partial main, stale format, and revoked daemon key; each rejects. Fresh
forward replacement must use generation +1 and unequal nonce/bootstrap/
database IDs.

## R32-05 — canonical format-v6 selection and startup

Two independent JCS implementations emit the exact 11-key format object in
R26. Require exactly 785 bytes and SHA-256
`483d1677d7846df3c4e0ff838039226f59925b7a0ae55c9cda14c00a58608c83`.
Byte-compare the complete R26 JSON vector. Mutate/omit/add/reorder every key;
try duplicate keys, version 5/7, floats, negative/overflow generation,
uppercase/short hex, alternate leaf, whitespace, CR/LF, BOM, escaping, and
noncanonical JSON numbers. Require rejection before SQLite authority.

B7 must obtain a fresh daemon read receipt, compute exact format-v6 bytes, and
commit only their SHA with ready state. B8 may create only
`format.json.tmp-v6`, must write exact prefixes, fsync, rename, parent-fsync,
reopen format, re-read root intent, then release R4. Crash before/after every
prefix/write/fsync/rename/parent-fsync/reopen/release boundary. Exact old R4
format resumes preselection; exact full temp resumes rename; exact format-v6
requires the full selected proof. Bad prefix, `.tmp-v5`, final version 5,
missing intent SHA, format/intent/row/SQL/ID mismatch, both candidates, or
unknown bytes protects without time-based choice.

At every normal startup, validate canonical format first, call daemon by typed
generation/source, verify receipt and 603 bytes against format, then open SQL
and compare immutable row/meta/format SHA plus independent identity
recomputation. Instrument ordering. No SQL catalog row may be returned before
the complete chain passes. Backup/restore repeats the same format/receipt/
envelope proof.

Test compatibility explicitly. A selected R4 instance may only build a fresh
schema-v26/format-v6 candidate. A selected or temporary format 5, schema 25,
bootstrap-intent-v1, or v2 intent missing generation/path bindings rejects;
none is migrated in place. Restore accepts only exact schema 26 plus format 6.

## R32-06 — root-owned serving-worker publication and restart

Run the real root daemon/provider broker/worker fixture. Prove the provider UID
cannot traverse or mutate root `serving-workers`. Trace the five R26 steps and
assert the daemon, never broker, creates the first direct record before the
broker's prepared-to-running SQL CAS. The daemon returns exact accepted
handoff and worker-record SHAs; mutate either and require the CAS to roll back.
The broker must contain no direct worker-record open/write/rename/unlink path.

Crash daemon, broker, and worker before/after every effect and every direct
record prefix/fsync/rename/parent-fsync. Cover prepared/no record,
offered/no worker, accepted/no worker record, worker record before SQL running,
SQL running before finalize, finalized handoff with live worker, every
heartbeat successor, cancellation, termination, completion, terminal SQL CAS,
and deletion. Restart with empty memory and walk exactly 32 SQL slots and their
derived handoff/worker paths. Require the unique R26 matrix successor or
quarantine. Enumeration, `waitpid`, timeout, PID alone, `kill(pid,0)`, or
reboot alone cannot establish completion.

Authenticate each worker heartbeat independently. Mutate audit token, PID/
pidversion/start/cdhash/process group, boot, permit, slot/generation, request/
pin, predecessor SHA, and sequence; reject without publishing. Test provider
direct record injection, symlink/hard-link/recreated record, stale heartbeat,
duplicate terminal, record deletion, cross-slot replay, 33rd live slot, and
slot reuse before old terminal removal. Each protects and revokes dispatch.
Repeat exact one-request framing, FD 203 read-only shared-lock lifetime,
cancellation, lazy artifact reads, replacement, and GC races. Actual MLX is
required for physical lazy-read acceptance; a deterministic worker remains
fixture evidence.

## R32-07 — irreversible B8 boundary and forward recovery

Construct every pre-B8 state with R4 selected and every post-B8 schema-v26/
format-v6 state. Before the final parent fsync/reopen, inject any candidate
failure and require R4 to remain authority, with candidate retained/protected
for exact forward recovery. After selection, remove/corrupt the daemon intent,
main, format, row, receipt, worker record, and journal in turn. Require V5
protection and readiness/serving unavailable; no R4 open, write, selection,
fallback, projection, pricing, admission, or settlement effect may occur.

Exercise only allowed post-B8 recovery: same hot-journal successor, supported
same-version/same-identity stopped restore, and fresh schema-v26 generation+1
forward replacement. Prove new IDs for replacement and no dual serving. Try
schema 23/25, format 5, stale R4 selector, restored R4 files, old receipts,
manual format rewrite, copied SQL, and an asserted “rollback” command; all
reject. Instrument runtime file access and require zero R4 authority calls
after B8. Crash at the format boundary and require old R4, exact format-v6, or
protection only; timestamp and file presence alone cannot decide.

## R32-08 — exact bounds, migration inventory, and retained gates

Populate every bounded table to its legal maximum using the retained exact DML
registry and one 603-byte intent row. Publish one selected plus one candidate/
prefix root intent, 32 maximum 8,192-byte handoffs plus their prefixes, and the
785-byte format/temp pair. Require corrected-object peak at most 526,097 bytes,
format pair at most 1,570 bytes, main at most 448 MiB, rollback journal at most
64 MiB, and exact row/counter agreement. Reject the 604th intent byte, third
intent generation, second temp for a path, 33rd handoff, record overflow,
unbounded history, page 114,688 begin, and page 131,072 first-over cases under
the inherited hard-fail rules.

Regenerate the complete production Swift AST/SIL inventory from
`phase3-binary/Sources/macprovider-cli` and
`phase3-binary/app/Sources/Malibu`. It must include every R31 named
MacProviderCLI, AutotuneRecommend, ModelCatalogRead, DurableModelDiscovery,
ModelCatalogLocalInspection, durable-store/verifier, app, preflight, self-test,
serve, prefetch, benchmark, and adoption path. After B8 each direct durable/
custody read remains absent or is mapped to the exact broker/custody boundary;
the new bootstrap operations exist only in the root daemon/client and no app,
CLI, autotune, worker, or broker direct-open bypass exists. A second compiler
based generator must agree; grep is supporting evidence only.

Run every retained R31/R30/R29 acceptance test not explicitly replaced above,
including exact transition/DML/counter, generation-50, journal/VFS, staging
confinement, custody, request framing, cancellation, app truthfulness,
distribution, first-over, actual-MLX, and physical-Mac journey cases. Run
targeted SwiftPM tests, full `swift test`, applicable generated-project Malibu
Xcode tests, script/dist, and Docker integration only when their actual runtimes
are available. Report selection counts, duration, failure/retry, fixture/
mock/real boundaries, and every blocker literally.

Review the complete implementation diff independently in native GPT-5.6 Sol
code, security, and architecture lanes. Fix and repeat until all three report
zero Critical, High, and Medium findings. The acceptance report separately
labels implementation, local fixture verification, real root/provider XPC,
actual MLX inference, physical-Mac end-to-end, release assets, deployed
services, and production qualification. None may be inferred from another.

## R32-09 — author-time reproducibility record

Before plan review, run and preserve:

1. exact R23-to-R25-to-R26 DDL extraction, transformation, SHA, execution,
   table/index/application/user-version checks;
2. independent Python and Node R26 bootstrap/database/intent tuple encoders;
3. independent Python and Node JCS format-v6 encoders;
4. exact R24 registry/dispatch/semantic extraction and hashes;
5. Darwin component-open/create/prefix/reopen/replacement oracles and public SDK
   header checks, explicitly labeled same-UID where no root fixture is used;
6. exact production Swift path manifest, parse count, and reproducible focused
   inventory command/output hash; and
7. `git diff --check` plus exact two-path diff from parent.

The R26 author run produced schema 44,295 /
`b8c641a2f6ba8dfa73174c9bc04b5c2e552649a42fa0e09cbfb39b140bb3b86d`,
24 tables, 11 indexes, app ID 1297109587, user version 26; bootstrap 305 /
`7d4fc8547fe7d914363b401991b60446681e7551f546328de5404f798490e39c`;
database 344 /
`55f0a242ffab0afcdc03474f3d32a230d7e1000013375032561afeea53f3bca0`;
path 113 / `b72d90e1fa0224f307bad960ed543e2b97b3e3c3d1a7f89f3b5ae78dfe827c75`;
intent 603 /
`f3ca14bafd5a3f53274068a8cacc5f761e7c55a8acab91a0a7df911e1db8301d`;
and format 785 /
`483d1677d7846df3c4e0ff838039226f59925b7a0ae55c9cda14c00a58608c83`.
Python and Node bytes agreed.

The final remote-tracking check observed `origin/main` at
`7128d1206afcf3cc857479e1d776ddc4899b020a`. The delta after the required
`7c0aad111e44cb320641bcefae3bf56851e9aaaa` reconciliation is limited to
SPEC-038/039 implementation/prompt/runbook work and has no Build 1 authority
path overlap. This is reconciliation evidence, not permission to rebase the
frozen reviewed parent or claim implementation.

The registry/dispatch/semantic oracles reproduced the frozen values in
R32-02. The Darwin filesystem oracle passed exact derived-path, exclusive
create, 0600/regular/one-link, prefix resume, no-follow, and replacement
rejection in a same-UID temporary hierarchy; it is not real root/provider XPC
acceptance. The SDK surface remained feasible without private SPI. The final
Swift inventory command was:

~~~text
find phase3-binary/Sources/macprovider-cli phase3-binary/app/Sources/Malibu -type f -name '*.swift' -print | LC_ALL=C sort
xcrun swiftc -frontend -parse <each manifest path>
rg -n --no-heading --sort path -e 'CatalogAuthorityBrokerV5|TrustedCustodyDaemonV5|bootstrap_authority|bootstrap_intent|serving_worker_v1|artifactURL|validatedContainedDirectory|adoptVerifiedStaging|verifiedExistingArtifact|canonicalArtifactHash|inspectCanonicalArtifact|snapshotURL|localRuntimeTargetAuthorities|runDraftModelArtifactPreflight|runModelArtifactPreflight|requireContainedDurablePathIfOwned|resolveVerifiedLoadPath|runModelCatalogPreflight|runServeStartupPreflights|prefetchedArtifactPreservingExisting|prefetchSnapshotURL' phase3-binary/Sources/macprovider-cli phase3-binary/app/Sources/Malibu
~~~

It produced 191 LF-terminated sorted paths, manifest SHA-256
`ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`,
191 successful parses and zero failures, and 100 focused records / SHA-256
`c2ad58e2eb95423ac15d2be8be5467932ab75e61380690d2d9a798c2cc5db917`.
The focused output is supporting author evidence, not the required checked-in
AST/SIL gate. `git diff --check`, exact path diff, and final artifact SHA-256
values are appended to the review handoff after final bytes exist; embedding a
file's own SHA inside itself would make the artifact hash self-referential.

Two failed author attempts are preserved rather than counted as evidence. The
first registry script searched for a nonexistent R24 Appendix D heading and
raised `ValueError`; the corrected extractor takes the first fenced text block
from R24 Appendix C through EOF and reproduced the 1,309-byte dispatch. An
intermediate tuple script added database generation but still used the earlier
19-byte placeholder intent leaf, producing an inapplicable 509-byte tuple; it
was discarded. The final independent Python and Node encoders both use the
113-byte registered root path and agree on the 603-byte vector above.
