# Build 1 reservation search progress — test specification R30

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Governing candidate: `reservation-search-progress-addendum-r24.md` together
with the unchanged portions of R23. R30 supersedes the contradictory clauses
identified below and otherwise incorporates every R29 requirement. Skipped,
interrupted, timed-out, zero-selected, fixture-only, mocked, or historical runs
cannot pass a stronger claim.

## R30-01 — frozen inputs, scope, and governance

Require commit `a7a13dfe52db450c786ab36d8608cb1a9eeccc70` and exact failed-review
SHA-256 `09b93232b98287ce3623e88a877f13c00949a2ec968d7afe741d31f13430c199`.
Record fetched origin/main, R23/R29/R24/R30 hashes, Appendix bytes/digests,
SQLite/Swift/compiler/macOS/APFS identities, and unrelated dirty paths. The
author diff must contain only R24 and R30. Approved SPEC-001 and SPEC-044
changes remain prerequisite to source work. Approval grants no pricing,
admission, settlement, reward, enforcement, deployment, release, or physical
qualification authority.

## R30-02 — 495 complete records and independent semantic generation

Extract R24 Appendix A and execute it in a clean process. Its stdout must be
byte-identical to Appendix B: 68,992 bytes, 495 LF-terminated records, SHA-256
`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`.
Reject CR, blank/header/comment/trailing-space lines, terminal LF omission,
non-ASCII, escape interpretation, field count other than 20, noncanonical
integer, illegal `-`, duplicate primary/name/family-local key, or unsorted
scope/ordinal order.

A second implementation must be written independently in Swift test code from
the displayed loop/range definitions; it may not invoke, translate, import, or
copy the production generator. It emits its own full 495-line stream and must
byte-compare to Appendix B before comparing the digest. A third reader treats
Appendix B only as data, projects fields 1...18 and 20 into an exact Appendix-A
SQLite database, reads rows back in primary-key order, and compares every
stored scalar plus field-19 dispatcher metadata. Production binary embedded
bytes, bootstrap insert bytes, startup reconstruction, and both independent
oracles must agree.

Assert counts allocation 1, row 174, fixed 320 split 32/64/32/32/32/128;
128 recovery intents; external row records 16 with exact 1/4/1/1/1/8 split;
and S=R=1,024 intent total 49,280. Exercise every legal graph edge and reject
every unregistered edge, wrong family/local/global ordinal, state, effect,
external template, evidence role, charge, or any one of the seven count fields.
For each of 20 field positions mutate one record while retaining all others and
require registry digest/startup failure. Mutate every record at least once.

Recompute R23 Appendix C as 27,602 bytes/SHA
`c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6`.
Extract R24 Appendix C as 1,309 bytes/SHA
`af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`.
Encode the three-field R24 semantic tuple independently; require 97,959 bytes and
SHA `0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
Swap fields, change a registry or dispatch byte, use the fenced payload instead of the full
Appendix-C body, omit LF, or use the R23 digest; each must reject before DML.
Compile all branch SQL and bind types. Allocation must prove 8/11/3/3/4 and
checkpoint 8/11 exactly; zero/two affected rows and branch substitution roll
back.

## R30-03 — database identity, crash lifecycle, backup, and rotation

Independently implement `tuple_v1` for R24 bootstrap and database domains.
Golden vector must reproduce 305-byte bootstrap preimage and bootstrap ID
`9e96ec3b9eea6de1bac0bc4699589a1176048a0fb7415b782170f5d0975d56c3`,
then 344-byte database preimage and identity
`0f9b6f86e77cf781a88b142d95ac50d37efce922dfa7f7fc3d288e6db4b93091`.
Mutate, omit, duplicate, reorder, mistype, null, or length-change every field;
change domain/version, Appendix digest, literal SQLite profile, candidate
identity, or nonce. Every case must reject.

Inject CSPRNG failure/short read. Crash before nonce, after nonce but before any
write, after each intent prefix/write/fsync/rename/parent fsync, candidate mkdir,
B3 statement, B4 mask, B5/B6/B7, candidate rename, format publication, and hot
journal recovery. Before a complete intent no identity exists; after it every
recovery derives the same bytes and never requests randomness. Exact E0/E1
cleanup retires the identity and leaves no signed external record.

Exercise normal mutations, candidate rename, restart, and hot-journal recovery:
identity must remain stable. Attempt a second selected replacement using the
same nonce/bootstrap/database identity and reject before main creation. A fresh
unequal nonce must rotate. Replay old staging/custody/worker/pin/completion/GC/
request-outcome bytes against the new identity; all reject before file/process/
inference/delete/sign actions.

Create an authenticated offline backup envelope and restore with the original
broker stopped and exact artifact-lock parent/leaves retained; identity must be
preserved after full SHA, schema, FK, integrity, registry, semantic, and lock
checks. Try raw database copy, new root, missing/recreated lock, changed envelope,
partial main, concurrent original, and stale fence; each must reject. Disaster
recovery to a new root must use fresh replacement and rotate identity.

## R30-04 — canonical artifact-lock inode and executable bypasses

On Darwin first reproduce the defect: take shared `flock` on a leaf, unlink it,
create the same pathname with another inode, and acquire exclusive `flock` on
the replacement. Record both device/inode pairs. R24 validation must reject the
replacement by path/parent/leaf identity comparison even though exclusive lock
succeeds.

Test bootstrap creation/capture/fsync of root-owned mode-0700 `artifact-locks`.
For first artifact creation require a durable `lock-create-pending` intent then
exact `openat` flags `O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, mode 0600.
Existing publication must omit CREATE/TRUNC and require the stored identity.
Crash before/after intent, create, leaf fsync, identity update, parent fsync,
receipt, custody SQL, and intent removal. Only an exact pending intent may adopt
a pristine orphan; published ENOENT never recreates.

Golden-test the seven-field lock tuple: path SHA
`ea55b0d4bf6c4c83771d2971832992a197c41e8a97fce608e952bb5a4816e394`,
333-byte tuple, identity
`199c369d4b9af4c07b9e9c648937bb9009cd07e956969327527d64ec49d40058`.
Mutate database/artifact/path/path SHA/parent/leaf identity and reject. Directly
test symlink, hard link, rename, unlink/recreate, inode reuse, wrong owner/GID/
mode/type/device/link/size/flags/ACL/xattr, parent replacement, fstatat/fstat
race, before/after-flock replacement, and wrong artifact path.

Verify the complete SQL chain lock→custody receipt content/evidence→typed owner→
custody event/current→catalog→serving slot. Cross-splice two artifacts,
databases, receipts, generations, or inodes. Direct startup validation must
reject every splice. Worker record and completion carry the same identity;
replacement authorization binds old/new identities; GC result/control binds
it. Missing R24 identity fields after B8 reject.

Generate the complete field-ordinal table for every R24-amended codec directly
from R23 Appendix D plus R24 section 4.3, then compare two independent encoders.
Require the R24 prefix, `-v2` domain, `_v2` schema, protocol 2, database identity
immediately after protocol, and every artifact-lock insertion at its named
position. Exercise the one permitted pre-lock null in `custody_operation_v2`.
Wrong ordinal, null after lock-create-pending, extra null, R23 domain, v1 schema
or protocol, omitted signature coverage, and mixed-version records reject.

Race worker spawn, broker copy close, heartbeat, lazy weight reads, cancel,
completion, process exit, replacement, and GC. The worker must hold exactly one
shared-lock open-file description through exit; broker/provider retain none.
Replacement/GC must direct-open, identity-check, acquire exclusive, and recheck.
Exclusive on a new inode is never proof. Restart from empty memory direct-opens
only SQL/receipt-derived paths. Any process/lock/path ambiguity quarantines the
slot and retains artifact/lock. No online transition may unlink or recreate a
published leaf; first-over 1,025th lock creation rejects.

Physical-Mac acceptance repeats the race with actual supported MLX lazy weight
reads. Fixture locks do not qualify that claim.

## R30-05 — readiness authority and full Swift inventory

Reproduce current behavior from the dirty 191-file tree:
`ModelCatalogLocalInspection.inspect` derives `DurableModelArtifactStore.artifactURL`
and calls `ModelArtifactVerifier.inspectCanonicalArtifact`; `DurableModelDiscovery.discover`
uses that entry or its direct fallback to emit `readinessState=ready`. Enumerate
every live reference/call edge in `ModelCatalogReadCommand.swift`,
`BYOMDiscovery.swift`, `ModelCatalogEconomics.swift`, and
`ModelCatalogTransactions.swift` plus app snapshot consumers.

Extend the reproducible Appendix-E target manifest with the exact R24 files,
types, methods, properties, constructors, direct URL/validation/verifier calls,
and all consumers. Parse every production Swift file, fail on an unclassified
reference, and compare stable path and target-manifest hashes. Independently use
SwiftSyntax/compiler AST or SIL call-graph output; text grep alone cannot pass.

After B8, fault the broker as unavailable, stale, corrupt, wrong generation,
wrong database identity, wrong custody/lock identity, and protected. Exercise
CLI catalog read, BYOM discovery, local actions, economics, and Malibu app.
Each must return typed unavailable/needs-preparation/protected output and must
perform zero open/stat/enumerate/hash calls under durable/custody roots. Saved
cache and path existence cannot restore `ready`. A valid single broker snapshot
must give identical generation/readiness/economics inputs to every consumer.
Provider-owned staging inspection remains separately typed and must not mint
catalog readiness, identity, pricing, or admission.

## R30-06 — permanently denied ANALYZE and as-grown qualification

Install the permanent R24 authorizer over exact Appendix A. `ANALYZE`, qualified
ANALYZE, `PRAGMA optimize`, direct sqlite_stat DDL/DML/read, and prepared/reused
variants must return `SQLITE_AUTH`. Capture the first denied action and prove no
sqlite_stat object or row appears. Run the same checks at bootstrap, selected
runtime, recovery, maintenance, and qualification; there is no authorizer-off
phase.

R30 replaces only R29-11's successful `ANALYZE` phrase with an explicit denial.
Populate every table/index to its reachable maximum through legal DML with
maximum-width values and fragmentation. Verify exact counts, page_count,
main-file fstat size <=448 MiB, journal high-water <=64 MiB, integrity check,
foreign-key check, every first-over, and golden `EXPLAIN QUERY PLAN` for fixed
queries without statistics. VACUUM remains denied. No ANALYZE, optimize,
statistics, VACUUM, sparse fixture, or copied prebuilt database may improve the
physical result.

## R30-07 — retained R29 coverage and corrected traceability

All R29 sections remain required with these substitutions: R30-02 strengthens
R29-04/05 registry generation; R30-03 extends R29-03/06/13 identity and restore;
R30-04 extends R29-08/09 serving/custody/GC lock proof; R30-05 extends R29-12
inventory; R30-06 replaces only the successful ANALYZE clause in R29-11.
R29-01/02/03/05/06/07/08/09/10/11/12/13 otherwise run unchanged, including the
rollback VFS, all bootstrap masks/crashes, DML/FK/generation-50, cancellation,
request framing, real MLX, bounded journal, full maximum shape, codecs, app,
distribution, three audit lanes, and qualification boundaries.

Mechanically parse disposition tables. R22-H4 must resolve to R29-09/R29-12 and
contain request/channel assertions. R22-M4 must resolve only to R29-05 and
contain generation-50 predicates. R23-H1/H2/H3/M1/M2/L1 must resolve to
R30-02/03/04/05/06/07 respectively. Missing, duplicate, irrelevant, or cyclic
references fail the plan gate.

## R30-08 — author-time reproducibility record

These are plan-shape checks, not implementation or physical qualification.
They were run on Darwin 25.5.0 arm64 with Python 3.14.7 / SQLite 3.53.4 and
Swift 6.3.3:

- Failed-review SHA reproduced exactly.
- R24 before this R30-only author record was 104,268 bytes with SHA-256
  `9bbaf6ad3edcfe3cbab33da045914fa5a52f4f209f2dc9ee7cd2cb6589eb5321`.
- R24 Appendix A emitted Appendix B byte-for-byte: 495 records, 68,992 bytes,
  registry SHA `d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`.
  Independent data parsing reproduced allocation/row/fixed and intent splits.
- R23 Appendix C remained 27,602 bytes with its declared digest. The exact
  three-field semantic tuple was 97,959 bytes and hashed to
  `0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
- Independent tuple encoding reproduced the bootstrap/database/lock preimage
  lengths and golden hashes in R24.
- The legacy lock oracle acquired exclusive lock on a recreated same-path inode
  while the old shared lock remained; R24 identity comparison rejected the new
  inode.
- Permanent authorizer denied ANALYZE first at sqlite_stat schema creation and
  left zero statistics objects.
- Both omitted readiness files and all four consumers were present in the exact
  191-file set; its LF path-manifest SHA remained
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
  The first 191-file `swiftc -frontend -dump-parse` batch parsed 190 files and
  the compiler crashed on `ModelRuntime.swift`; immediate exact-file retries
  with both `-parse` and `-dump-parse` returned zero. This is recorded as a
  transient failed attempt, not erased or represented as an uninterrupted
  all-files dump pass. A subsequent fresh `-parse` batch passed all 191 files.

The implementation gate remains closed until an independent GPT-5.6 Sol review
of exact R24/R30 hashes reports zero Critical, High, and Medium findings.
