# Build 1 reservation search progress — test specification R31

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Governing candidate: `reservation-search-progress-addendum-r25.md` together
with unchanged R24/R23 requirements. R31 supersedes R30 where named and
otherwise incorporates every R30/R29 test. Skipped, interrupted, timed-out,
zero-selected, fixture-only, mocked, historical, or non-Darwin runs cannot pass
a stronger claim.

## R31-01 — frozen inputs, scope, and finding traceability

Require failed-review commit
`e45f80e6ad3b075e63a3568f2c526faf2272aa27` and review SHA-256
`36fb0a20f3d0f118d244865f2d6904c732631e503bc90c965af7c485cab03e14`.
The frozen reviewed R24/R30 byte hashes are
`9bbaf6ad3edcfe3cbab33da045914fa5a52f4f209f2dc9ee7cd2cb6589eb5321`
and `6d5586836618a5d4b110a4f393e9368c7646141149c6998e87d371027ba0783f`.
Record origin/main, R23/R29/R24/R30/R25/R31 hashes, toolchain/macOS/APFS/SQLite
versions, and all unrelated dirty paths. The author diff contains only R25 and
R31. Parse the disposition table and require one non-cyclic mapping for each of
R24-PLAN-H1/H2/H3/H4/M1 to R31-03/04/02+05/06/07 respectively. Approval gives
no authority to edit source, activate economics, deploy, release, or claim
hardware qualification.

## R31-02 — exact schema v25 and retained metadata row

Extract R23 Appendix A bytes, require 43,652 bytes and SHA
`70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f`,
then execute the three R25 byte transformations. Each replacement/insertion
anchor must occur exactly once. Require 44,213 bytes, SHA
`2bcde8dd97fa1cb063ad09b41db8b895ec64cf6fa2fabd38b15c4d1dc671547e`,
24 non-internal tables, 11 non-auto indexes, application ID 1297109587, user
version 25, and successful exact DDL execution in SQLite. Reject a reordered
statement, CR, trailing whitespace, second insertion, changed bound, version
23/24, extra index/trigger/view/statistics table, or any single changed byte.

Execute B3 with a minimum and maximum legal exact intent. Require one and only
one `bootstrap_authority` row, byte-identical intent BLOB, independently
computed SHA, 32-byte nonce/IDs, and literal retention policy. Test every
CHECK/UNIQUE bound and a second row. Install the permanent authorizer and prove
INSERT/UPDATE/DELETE are denied after B3 in normal, recovery, maintenance, and
qualification phases. Startup must reject a missing row, extra row, wrong raw
nonce, byte/SHA mismatch, bootstrap/meta mismatch, database identity mismatch,
or equivalent decoded intent with different bytes.

Require B3 to insert exactly 1,560 logical rows with the exact
1/1/495/6/1,024/1/32 split. Crash after every statement and prove atomic
zero-or-complete B3. Reject 1,559/1,561, omitted/duplicated metadata, or a
counter/row-set splice.

Independently regenerate the frozen R24 registry, dispatch, and semantic
streams. They must remain exactly 495/68,992/
`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`,
1,309/`af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`,
and 97,959/`0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
Run all R30-02 record, DML, counter, mutation, compiler, and first-over tests
unchanged. Any registry/dispatch/semantic change fails this correction.

## R31-03 — pre-create/post-create state and codec closure

Generate the complete 30-field custody-operation-v3 ordinal/type/null table
from R25 section 4.3 and compare two independent encoders/decoders. Require
domain/schema/protocol `macprovider-r25/custody-operation-v3`,
`custody_operation_v3`, and 3. At L0, both leaf-derived fields must encode the
single canonical null tag, postcreate link count must be null, and the
path/placement/precreate-count fields must be present. At L1 both leaf fields
must be 32-byte SHA values and postcreate must equal precreate+1. In later C
states those values remain fixed; a first C0 for an already published leaf has
equal precreate/postcreate observations. Mutate every field and
ordinal; try placeholder zero SHA, path SHA in an identity field, non-null L0,
null L1/C, wrong phase pairing, wrong prior SHA, v2 domain, protocol 2, and
trailing bytes. Each rejects before a filesystem effect or SQL DML.

On a captured root-owned test hierarchy, inject a crash at every boundary:
before/within/after L0 temp write, temp fsync, rename, parent fsync, create,
leaf fsync, parent fsync, leaf fstat, L1 temp write/fsync/rename/parent fsync,
and C0 publication. Assert the exact recovery table:

- no complete L0 plus no leaf may retry; no complete L0 plus a leaf protects;
- complete L0 plus absent leaf and current link count equal to precreate creates
  once and requires postcreate=precreate+1;
- complete L0 plus an exact pristine leaf and current count precreate+1 adopts
  under exclusive lock and
  records its observed identity only in L1;
- complete L0 plus any other leaf protects without mutating it;
- L1/C plus missing or different leaf protects and never recreates;
- L1/C plus exact leaf resumes the one successor.

Instrument open flags and order. L0 durability must precede the only
`O_CREAT|O_EXCL`; leaf fsync and parent fsync must precede L1 durability.
Published opens must omit CREATE/TRUNC. Search production code and syscall
traces for a path that predicts, invents, accepts from a caller, or writes a
leaf identity before successful create/fstat; require none. Create all 1,024
registered leaves, restart after each boundary for selected ordinals including
1, 2, 1,023, and 1,024, and reject the first over before create. Earlier lock
identities must remain valid after every later authorized creation.

## R31-04 — stable placement identity and path replacement attacks

Independently encode the 14-field placement vector. Require relative path SHA
`f17dbae407d2b854f2a2714bc52bec0997556d1bab0503dfc1ada974d15fcf64`,
268-byte preimage, and digest
`a278cc0e972bfa9e4138b67c25b16a4799508b386a87f218b3a5c9bd5aefe207`.
Mutate/reorder/omit each retained field and require mismatch. Demonstrate that
size/mtime/ctime/link count are absent from the serialized tuple.

On Darwin/APFS capture the parent before and after each of the first through
1,024th regular-leaf creates. Prove at least mtime or ctime changes on the
first create, while device, inode, type, permission bits, UID/GID, birthtime,
flags, custody-root binding, relative path, and placement digest stay constant.
Assert link count remains in 2...1026 and changes only by exactly +1 across a
successful serialized create boundary; it remains equal across every other
operation. Restart, reopen from custody root, and reproduce
the same digest.
Then test parent rename, unlink/recreate, symlink, mount/device change, inode or
birthtime change, mode/UID/GID/link/flag change, ACL/xattr, subdirectory create,
unregistered leaf, hard link, leaf rename, and fstatat/fstat races. Every case
must protect. A timestamp-only change caused by an authorized regular-leaf
create must not invalidate older leaf identities; it also must not excuse any
retained-field mismatch.

Encode the revised artifact-lock golden vector and require 333 bytes and SHA
`42fbdb037c2c1adad5af9f989a2cba31740af29311f4ac8c5cf520ba6762d744`.
Repeat R30-04's unlink/recreate flock bypass, receipt/SQL splice, worker,
completion, replacement, GC, cross-database, and lazy-read races using this
identity. Same path on a new inode must reject even when exclusive lock
succeeds.

## R31-05 — bootstrap crash, retention, backup, and identity vectors

Implement `tuple_v1` independently twice. Require the v25 bootstrap preimage
to be 305 bytes with ID
`64037a80513491ca37860906a07cccc02f0fe820d4f723d436de725fbc65a12c`,
and the database preimage to be 344 bytes with ID
`093b75a7a504aa6aee4cbcf5d7dfe9aff5f945216c48d223aea8af2a6fc25b3f`.
Mutate every field/type/order/domain and the schema/version/nonce operands.
R24 values, schema 23, user version 23, and a second random nonce after durable
intent must reject.

Inject CSPRNG failure and crash before/after every intent prefix/write/fsync/
rename/parent fsync, candidate mkdir, B3 statement/commit, each B4 row/mask,
B5, B6, B7 rename/parent fsync, every B8 prefix/full/rename/fsync/reopen point,
and the first selected startup. Before complete intent there is no identity;
after complete intent every recovery uses the same bytes. From committed B3
onward require the exact file and row at every point. P6 must retain intent and
advance directly to B7. P6a without intent must protect. P7/P8/S must retain
it. Exercise hot-journal recovery at every legal B3/B4 point and prove the row
is atomic with schema creation.

Create and restore a supported backup. Independently verify exact main bytes,
retained intent bytes, row, envelope lengths/SHAs, schema/registry/semantic,
root/lock identities, and stopped-original condition before selection. Then
try missing intent, raw main copy, re-encoded intent, nonce splice, row splice,
changed envelope, partial main, new root, missing/recreated lock, live original,
and stale format fence; each rejects. Fresh replacement/new root must generate
unequal nonce/bootstrap/database values. Offline whole-authority destruction
may remove retained bytes; normal cleanup, GC, replacement, VACUUM/ANALYZE
denial, and backup deletion may not.

## R31-06 — root daemon descriptor handoff and recovery

Run entitlement/install-identity tests with a real root launch-daemon test
fixture and a provider-UID broker/worker on a physical macOS test host. Fixture
simulation may validate codec logic but cannot pass cross-UID authority. Prove
the provider UID cannot traverse the 0700 parent or directly open the 0600
leaf, while the authenticated daemon can open it. Prove the daemon returns an
`O_RDONLY`, non-writable FD already holding `LOCK_SH`; the worker receives it at
203; broker and daemon close all duplicates after accepted; and replacement
cannot acquire `LOCK_EX` until worker exit. Attempt writes/truncation through
the worker descriptor and require denial without identity change.

Generate the full 32-field lock-handoff record and 31-field signed-ticket
ordinal tables from R25.
Round-trip with two independent codecs. Mutate each database/permit/slot/
request/model/artifact/custody/catalog/lock/audit/process/boot/time/FD/key/signature
field, null rule, phase, predecessor, and domain. Test expired, replayed,
duplicate, cross-slot, cross-generation, cross-request, cross-artifact,
cross-database, and writable FD offers. All reject before artifact open or
worker acceptance.

Exercise actual XPC connections from the approved broker, provider app, CLI,
old binary, wrong UID/team/cdhash, unsigned helper, and approved worker. The
daemon must use public NSXPC PID/UID plus the single-use challenge and
`MACH_RCV_TRAILER_AUDIT` Mach message to derive audit identity, ignore asserted
identity as authority, and expose no generic path/open/flags/mutation method.
Compile/link against the selected public macOS SDK and fail if any private
`xpc_connection_get_audit_token` or equivalent SPI is referenced. Replay,
forward, delay, duplicate, cross-connection, wrong-port, PID-reuse, UID, boot,
pidversion, and challenge substitutions must deny before path access.
Try absolute/relative paths, caller FDs, symlink/hard-link/recreated leaf, and
confused-deputy requests; require denial. The only accepted caller FD is the
worker's returned proof duplicate for the one live ticket; verify it is FD 203,
read-only, exact-identity, unusable as path selection, and closed by the daemon.
Verify the worker's independent connection and audit identity before accepted
publication.

Crash daemon, broker, and worker at each of the five handoff steps and every
record prefix/fsync/rename/parent-fsync boundary. Restart with empty memory and
walk the 32 fixed SQL slots/direct record paths only. Cover offered before
spawn, after spawn before accept, accepted before worker record, worker record
before SQL running, SQL running before finalize, and finalize before deletion.
Require exact completion or quarantine; no enumeration, `waitpid` inference,
timeout-as-absence, leaf recreation, or GC/replacement on ambiguity. The 33rd
live handoff rejects. Reuse of a slot requires incremented generation and no
nonterminal old record. Reboot recovery may use verified boot change plus
canonical exclusive lock under retained R23 rules; it may never infer prior
worker completion merely from reboot.

Repeat cancellation, exact one-request request/pin binding, trailing/second
frame, half-close, output, terminal completion, process identity, heartbeat,
lazy artifact read, replacement, and GC races. Physical actual-MLX execution is
required for the lazy-read qualification; deterministic workers are integration
evidence only.

## R31-07 — complete Swift readiness and authority inventory

From the exact dirty production tree enumerate declarations and call edges in
all R23/R24 files plus these exact roots:

- `MacProviderCLI.swift`: `localRuntimeTargetAuthorities`,
  `runDraftModelArtifactPreflight`, `runModelArtifactPreflight`,
  `requireContainedDurablePathIfOwned`, `resolveVerifiedLoadPath`,
  `runModelCatalogPreflight`, `runServeStartupPreflights`, `ServeCommand.run`,
  `SelfTestCommand.run`, `SelfTestCommand.modelLoadPath`, `isExistingDirectory`,
  and every call to resolver `verifiedExistingArtifact`, `artifactURL`,
  `validatedContainedDirectory`, `contains`, `adoptVerifiedStaging`,
  `canonicalArtifactHash`, and `snapshotURL`;
- `AutotuneRecommend.swift`: `CachedModelArtifactResolver.durableStore`,
  `verifiedArtifact`, `prefetchedArtifactPreservingExisting`, both
  `verifiedExistingArtifact` overloads, `snapshotURL`, `prefetchSnapshotURL`,
  `AutotuneArtifactPrefetchReceipt.validatedArtifacts`,
  `AutotuneRecommendationBenchmarker.prefetchArtifacts`, `benchmarks`, every
  resolver edge, `ModelArtifactVerifier.canonicalArtifactHash`, both
  `inspectCanonicalArtifact` overloads, and their enumeration/hash helpers;
- every production caller and consumer of `DurableModelArtifactStore.artifactURL`,
  `validatedContainedDirectory`, `contains`, `adoptVerifiedStaging`, direct root
  access, `ModelCatalogVerifiedArtifactObservation`, and the verifier APIs.

Require every production Swift file to parse. Check in a sorted path manifest
and declaration/call-edge manifest produced from compiler AST/SIL, with stable
toolchain/path/hash metadata. A second generator must find the same call graph.
Text grep is diagnostic only. Any unclassified callsite, indirect wrapper,
dynamic dispatch edge, new file, or source/toolchain change reopens the gate.

After B8 instrument open/openat/lstat/fstatat/enumeration/read/hash and durable
store entrypoints beneath durable/custody roots. Exercise serve startup, runtime
target selection, draft and primary preflight, coordinator join, donor mode,
self-test, catalog list/actions, app readiness/economics, autotune prefetch,
receipt reload, candidate benchmark, adoption, cancellation, and recovery.
With broker unavailable, stale, corrupt, wrong generation/database/custody/lock
identity, malformed, cancelled, or timed out, each path must return the required
typed unavailable/needs-preparation/protected state and produce zero trapped
durable/custody calls. Cache/path existence cannot restore ready.

With a valid broker snapshot, all consumers must use identical database,
catalog, custody, lock, readiness, config/byte, and freshness values. Provider
staging paths must be component-confined, disjoint from durable/custody roots,
and typed `UntrustedPreparationInspection`. Their hashes may drive local
download/probe feedback but cannot mint readiness, catalog identity, pricing,
admission, or settlement. Attempt path aliases, symlinks, root overrides,
hardlinks, stale prefetch receipts, and durable paths disguised as staging;
each rejects or routes to broker.

Run targeted SwiftPM tests, then full `swift test`. Run applicable Malibu Xcode
tests through the repository's generated project; a Swift CLI run does not
substitute for Xcode app tests. Report zero-selected, skipped, timeout, and
fixture-only evidence literally and never as acceptance.

## R31-08 — retained accumulated verification and final gates

R30-01/02/03/04/05/06/07 and every retained R29 section still run, with these
substitutions: R31-02 replaces schema assertions; R31-03 replaces the
pre-lock-null portion of R30-04; R31-04 replaces parent/lock golden identity;
R31-05 replaces bootstrap deletion/identity/backup cases; R31-06 replaces
broker direct-open and handoff cases; R31-07 expands the Swift inventory. All
other exact DML counts, generation-50 predicates, journal/page bounds,
authorizer/VACUUM/ANALYZE denial, staging confinement, request framing,
cancellation, app behavior, rollback, distribution, and first-over tests remain.
The maximum-shape fixture includes a 65,536-byte bootstrap row/file, 32 maximum
8,192-byte handoff records and simultaneous publication prefixes. Prove the
new external peak is at most 655,360 bytes and the inherited 448 MiB main-file
and 64 MiB rollback-journal limits still hold. The 33rd handoff, second retained
intent, oversized record/ticket, or any retained handoff history rejects.

After implementation, run the targeted suites followed by the broader SwiftPM,
Xcode app, script/dist, and integration checks appropriate to the complete
changed surface. Independently audit the complete diff in native GPT-5.6 Sol
code, security, and architecture lanes. Fix and repeat until the combined diff
has zero Critical, High, and Medium findings. Record commands, selected-test
counts, durations, failures/retries, exact commits/diffs, reviewer artifacts,
and remaining qualification blockers.

The acceptance report must separately label implementation completion, local
fixture verification, real cross-UID macOS/XPC verification, actual MLX
inference/lazy-read verification, release-asset verification, deployed service
evidence, and production qualification. None may be inferred from another.

## R31-09 — author-time oracles required before review

Before requesting plan review, record fresh evidence for all of the following:

1. exact schema extraction/transformation/execution/hash/table/index oracle;
2. two independent v25 bootstrap/database/placement/lock tuple encoders;
3. Darwin parent metadata oracle showing authorized child creation changes
   mtime/ctime but preserves the placement tuple;
4. Darwin descriptor oracle showing a read-only inherited FD can retain flock
   lifetime while pathname reopen/write is denied by permissions, explicitly
   labeling same-UID or fixture limits;
5. exact source/callsite inventory for the MacProviderCLI/autotune names above;
6. R24 registry/dispatch/semantic byte identity; and
7. `git diff --check` plus a path diff proving only R25/R31 were authored.

An oracle failure must be reported, not edited out. These author-time checks
prove plan reproducibility only. They do not authorize implementation or count
as cross-UID, XPC, actual-MLX, app, release, deployment, or production evidence.

### R31 author execution record

Fresh author-time checks ran on Darwin 25.5.0 arm64 with Python 3.14.7 /
SQLite 3.53.4, Node, and Apple Swift 6.3.3:

- exact schema transformation produced 44,213 bytes, SHA
  `2bcde8dd97fa1cb063ad09b41db8b895ec64cf6fa2fabd38b15c4d1dc671547e`,
  24 tables, 11 indexes, user version 25, and application ID 1297109587;
- independent Python and Node tuple encoders agreed on bootstrap 305 bytes /
  `64037a80513491ca37860906a07cccc02f0fe820d4f723d436de725fbc65a12c`,
  database 344 /
  `093b75a7a504aa6aee4cbcf5d7dfe9aff5f945216c48d223aea8af2a6fc25b3f`,
  placement 268 /
  `a278cc0e972bfa9e4138b67c25b16a4799508b386a87f218b3a5c9bd5aefe207`,
  and lock 333 /
  `42fbdb037c2c1adad5af9f989a2cba31740af29311f4ac8c5cf520ba6762d744`;
- the Darwin directory oracle observed mtime and ctime changes and, unexpectedly,
  link-count change from 2 to 3 after one regular-child create, while device,
  inode, mode, UID, GID, and flags remained stable. The draft was corrected to
  exclude link count from persistent placement identity and constrain it only
  at the serialized create boundary. Python on this host does not expose Darwin
  birthtime; implementation tests must use Darwin `stat` directly;
- the corrected inherited-FD oracle gave child FD 203 access mode O_RDONLY,
  returned EBADF on write, blocked a separately opened nonblocking exclusive
  flock while only the child remained, and allowed exclusive flock after child
  exit. This was a same-UID fixture and does not pass the required root/provider
  XPC test. An earlier attempt combined `preexec_fn` duplication with an
  incompatible `pass_fds` set and the child received EBADF; it is a failed
  author attempt, not acceptance evidence;
- exact R24 extraction reproduced 495 records/68,992 bytes and registry SHA,
  1,309 dispatch bytes and SHA, the 27,602-byte R23 semantic body SHA
  `c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6`,
  and the 97,959-byte semantic tuple SHA. A first extractor incorrectly used
  only the fenced DML payload and produced 95,050 bytes/wrong SHA; the corrected
  extractor uses every byte between the Appendix C and D headings as required;
- the production Swift file-set remained 191 paths with manifest SHA
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
  All 191 passed fresh `xcrun swiftc -frontend -parse`. The focused direct-read
  inventory contained 45 current occurrences and SHA
  `46054a41ff3edb7120a564d963340a7d70174292a4eabe866bd9f61516e38bfc`;
  this grep hash is supporting evidence only, not the required AST/SIL manifest.
- public SDK inspection found `NSXPCConnection.processIdentifier` and
  `effectiveUserIdentifier`, `NSFileHandle: NSSecureCoding`,
  `kSecGuestAttributeAudit`, and `xpc_fd_create`/`xpc_fd_dup`, but no public
  XPC audit-token getter. R25 therefore uses the explicit Mach audit-trailer
  challenge binding above and prohibits the private SPI; this header check is
  feasibility evidence, not an implemented authentication test.
