# Build 1 reservation search progress R22/R28 — independent adversarial plan review

Date: 2026-09-11. Reviewer: native GPT-5.6 Sol, high reasoning.

## Verdict

**REQUEST CHANGES. Architectural status: BLOCK.**

Exact finding count: **0 Critical, 7 High, 4 Medium, 0 Low**.

R22/R28 do not meet the mandatory zero-Critical/High/Medium reservation gate.
The SQLite/VFS/custody/serving/GC implementation remains unauthorized. This
review changes no source, test, SPEC, release, deployment, or operator-secret
file.

## Frozen inputs and independent checks

- Reviewed commit:
  `9d9618887cf3cef0e23e520fffc507c94687ce15`.
- Reviewed parent / failed-review commit:
  `3ab079f7d2c9d8522546c59e3857bdb4d1f30017`.
- R22 SHA-256:
  `13e6dad30f4440adcff84578156b6c7405044a40a3e03eea8ca044894d7e7e91`.
- R28 SHA-256:
  `89a5b2c5edb3542662c614d7bdee9dfa0219376931831544201d4c5c437052a1`.
- Frozen R21 review SHA-256:
  `176d16e59e897f5aef94afa258e04e4ca32ca1e2b64f1964b92b20fdfa5468e1`.
- Exact raw LF Appendix A bytes SHA-256:
  `34636b0142704056425e100e77a613af098819fc4f3fb1ae3675aa41d76230a5`.
- The reviewed commit changes exactly R22 and R28. `git diff --check` passed.
- Live local tracking `origin/main` had advanced from R22's frozen
  `c123ae2d2d08053612d940b3077994f7c4d709d7` to
  `7c0aad111e44cb320641bcefae3bf56851e9aaaa`. That later SPEC-039/PagedKV
  delta is not part of this pinned review. Dirty Build 1 and BYOM work was
  preserved and inspected only as working-tree evidence.
- Python 3.14.7 linked SQLite 3.53.4. The extracted 37,709-byte Appendix A
  created 22 tables with `integrity_check=ok` and no foreign-key violations.
- A fresh valid R22 source/staging/custody/current/GC graph returned no
  foreign-key violations. Staging evidence, custody receipt, creating-operation
  ordinal, current generation/event, and GC custody-event substitutions each
  failed `SQLITE_CONSTRAINT_FOREIGNKEY`. R21 H2 is corrected in DDL shape.
- The exact Appendix E roots contained 191 sorted Swift files with file-set
  SHA-256
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
  All 191 individual `swiftc -frontend -dump-parse` commands passed. A discarded
  broader sweep entered `.build` and failed on dependency sources; it is not
  evidence about the declared inventory.
- The revised GC helper preimage includes attempt, checking generation, phase,
  and cursor. R21 H3 is corrected in plan shape. R22 adds the missing
  generation-50 owned-control transaction, but R22-PLAN-M4 finds that its
  candidate CAS does not make the legal budget predicates literal.

### Executable counterexamples

The macOS POSIX-lock oracle opened one file three times, retained the locking FD
and the proposed master FD, and probed a conflicting byte-range lock from a
second process. It observed:

```text
conflict_before_sibling_close blocked
conflict_after_sibling_close_with_lock_fd_and_master_retained acquired
```

The qualification authorizer oracle permitted the one empty-name ATTACH and
denied schema-changing authorizer actions, exactly as R22's prose requires. The
same SQLite build then observed an internal create-table action on the generated
`vacuum_<random>` schema and returned:

```text
vacuum_result DatabaseError not authorized
attach_events [(SQLITE_ATTACH, '', None, None, None)]
first_denied_schema_event (SQLITE_CREATE_TABLE, 't', None, 'vacuum_<random>', None)
```

The daemon-restart oracle orphaned a worker by exiting its original parent and
then called `waitpid` from a replacement process. It observed
`replacement-daemon-waitpid ECHILD`; after TERM, the worker was reaped by its
actual owner rather than the replacement daemon.

## Critical (0)

None.

## High (7)

### R22-PLAN-H1 — retaining one master FD does not preserve POSIX locks when a sibling FD closes

**Evidence.** R22 lines 80-90 require each local SQLite file to own an FD, use
process-owned `fcntl` byte-range locks, and retain one master FD so sibling
closes cannot discard those locks. On macOS, closing any descriptor for the same
file releases the process's record locks for that file. The executable oracle
above retained both the locking FD and master FD, closed only a third sibling,
and a second process immediately acquired the conflicting range. The same
close hazard applies to process-owned SHM byte locks.

**Consequence.** An ordinary SQLite file-handle close can silently discard main
or WAL/SHM exclusion while live sibling handles remain. Rollback and WAL
concurrency, recovery, and the hard byte-bound qualification can therefore run
without the exclusion R22 claims.

**Required correction.** Define and prototype a process-level inode owner that
defers every descriptor close capable of releasing record locks until no local
lock survives, or use a supported lock primitive whose close semantics match
the design. Specify aggregate `xLock`, `xUnlock`, `xCheckReservedLock`,
`xShmLock`, fork, close, and error transitions, then make R28 reproduce this
exact sibling-close oracle before upstream lock/WAL qualification.

### R22-PLAN-H2 — serving-worker records are not discoverable after daemon restart

**Evidence.** R22 lines 458-463 persist
`serving-workers/<permit-uuid>.worker-v1` and say a restarted daemon
direct-opens each SQL-referenced record without enumeration. Appendix A has 22
tables but no serving-worker, permit, request-to-permit, or record-path index.
The only durable permit UUID is inside the direct file whose name cannot be
derived after the daemon's in-memory used-permit cache dies.

**Consequence.** A replacement daemon cannot find a legal orphan worker record,
retain or reacquire its custody lock, signal its process group, or quarantine
the artifact. It must either enumerate the forbidden directory or let GC and
new adoption proceed without proving the old worker absent.

**Required correction.** Add a bounded durable SQL or independently
direct-addressable supervisor index that exists before spawn and binds permit,
request, artifact, record path, worker identity, state, and lock recovery. Give
every crash boundary one direct successor and require R28 restart tests to start
with empty process memory and directory enumeration disabled.

### R22-PLAN-H3 — a restarted daemon cannot `waitpid` and reap the previous daemon's worker

**Evidence.** R22 lines 454-463 require launchd to restart the daemon, then have
the new daemon kill and `waitpid` the exact old worker before releasing its
lock. Once the original daemon exits, that worker is reparented. A newly
launched daemon is not its parent and `waitpid(workerPID, ...)` returns
`ECHILD`, as the executable oracle reproduced. The parent-death pipe may make
the worker exit but does not transfer wait ownership to the replacement daemon.

**Consequence.** The exact-reap predicate that gates lock release and quarantine
is unimplementable across the stated crash boundary. The new daemon cannot
distinguish an exited-but-not-yet-reaped worker under another owner from the
completion proof R22 requires.

**Required correction.** Put each worker under a stable supervisor/reaper that
survives or is owned by launchd, or define a launchd-managed per-worker service
with an authenticated completion primitive the restarted daemon can validate.
Separate signal authorization, observed process disappearance, true reap
ownership, lock custody, and uninterruptible-I/O quarantine in R28.

### R22-PLAN-H4 — the signed serving pin does not bind request bytes or define a one-request channel

**Evidence.** R22 lines 444-450 say the pin binds the request, but Appendix D's
`serving_pin_v1` binds only `request_uuid`; unlike `request_outcome_v1`, it has
no `request_sha256`. The only exact socket frame is the initial 32-byte nonce.
There is no request frame codec, length bound, UUID/digest field, response or
completion framing, EOF rule, or one-request-close state machine. Two different
request byte strings with the same request UUID produce the same signed pin and
may be written on the same nonce-authenticated socket. R28-08 mutates the nonce
and tests duplicate spawn, but never mutates payload bytes or sends a second
inference on the existing channel.

**Consequence.** The cryptographic object cannot prove which request the
dedicated worker is serving, and a valid permit can be reused for different or
multiple request bytes before its deadline. Independent Swift/daemon/worker
implementations have no byte-exact protocol to reject the substitution.

**Required correction.** Add the canonical request digest and immutable
request parameters to the pin, and define bounded request/response/completion
frames plus exact one-request lifecycle, cancellation, truncation, trailing
data, and replay behavior. Add independent codec tests and payload-substitution,
second-request, oversized, partial-frame, and half-close vectors to R28-08/12.

### R22-PLAN-H5 — root consumption of provider staging lacks a confined component-walk contract

**Evidence.** R22 lines 518-535 derive a pathname under the provider's home and
reject arbitrary caller paths, but do not say how the root daemon opens each
provider-controlled ancestor and manifest entry. There is no captured staging
root FD, component-by-component `openat`/`O_NOFOLLOW` walk, stable ancestor
identity, owner/mode/link policy, hard-link rejection, same-volume proof, or
pre/post-copy race check. The stronger no-follow parent-FD rules in custody
section 6.2 apply only after this handoff. R28-08 tests receipt fields and
custody C0-C7, not staging ancestor/entry substitution.

**Consequence.** A provider can replace a derived ancestor or entry with a
symlink/hard link or race the root daemon between transcript capture and copy,
causing privileged reads outside the authorized staging tree or binding the
receipt to bytes other than those consumed.

**Required correction.** Specify a captured-FD, component-wise no-follow walk
for the canonical staging root and every manifest entry, with exact UID,
device, file type, mode, link-count, identity, and race predicates. Add
ancestor, leaf, symlink, hard-link, mount/volume, rename, and copy-time mutation
vectors to R28-08.

### R22-PLAN-H6 — the catalog-binding authority digest has two incompatible definitions

**Evidence.** R22 lines 424-428 define domain
`macprovider-r22/catalog-binding-v1` over model, release, artifact, custody
generation, custody event, row, transaction, and creating operation. Lines
701-713 instead define domain `macprovider-r22/catalog-binding` and omit custody
generation while calling the digest registry closed. Both definitions govern
startup, serving, replacement, and GC recomputation.

**Consequence.** The producer and four consumers can compute different binding
bytes for the same SQL row. Choosing the second definition also restores the
generation omission that R21 H2 explicitly required R22 to close.

**Required correction.** Publish one exact domain and ordered typed tuple in
the closed digest registry, include custody generation, remove the conflicting
definition, and add independent golden vectors that every producer and consumer
must match.

### R22-PLAN-H7 — the registry grammar contradicts the literal DML change counts

**Evidence.** The complete DML table at lines 321-333 and R28-05 require staging
register 7 changes, custody verified/pending 10, initial activation 8, and
replacement 11. The supposedly complete machine-readable mapping at lines
372-378 instead assigns staging progress 6, custody progress 9, and calls
activation/replacement seven-/nine-row templates. Appendix C itself enumerates
the 7/10/8/11 statements. R22 says production dispatch and both registry and
semantic-manifest digests are generated from these bytes with no human defaults.

**Consequence.** No single expander can simultaneously reproduce the registry,
Appendix C, R28's golden totals, and the runtime `changes()` guard. A literal
implementation either rejects every affected progress transaction or hashes a
non-normative correction.

**Required correction.** Make each mapping record name the exact Appendix C
template and 7/10/8/11 count, regenerate both authoritative digests, and add an
author-time expander that fails this revision before plan review.

## Medium (3)

### R22-PLAN-M1 — the qualification authorizer still rejects SQLite's internal VACUUM schema actions

**Evidence.** R22 lines 125-135 permit one empty-name ATTACH but deny every
schema-changing statement. SQLite 3.53.4 then reports internal
`SQLITE_CREATE_TABLE` and other schema actions against its generated
`vacuum_<random>` schema. The restrictive executable oracle returned `not
authorized`. R28's author-time record proves only that a more permissive
authorizer completed VACUUM; R28-02 does not state the internal action matrix
that distinguishes legal VACUUM work from caller-authored schema mutation.

**Consequence.** The governed maximum-shape VACUUM profile cannot execute under
the normative closed state machine, so the required physical measurement is not
reproducible through the reviewed VFS/authorizer boundary.

**Required correction.** Freeze the exact internal authorizer action/database/
table/source sequence for the pinned SQLite build, allow only that sequence
during the one embedded VACUUM, and continue to reject caller-authored schema
and named/second ATTACH. Make R28 install that exact restrictive authorizer.

### R22-PLAN-M2 — R22 embeds the superseded Appendix A digest

**Evidence.** Exact extraction gives Appendix A SHA-256
`34636b0142704056425e100e77a613af098819fc4f3fb1ae3675aa41d76230a5`, matching
R28 and the review input. R22 lines 869-870 instead declare the old R21 digest
`edf42410f061176e2b3e3a15d9d60c3b47611784ea3207ac2531fafb94acf0c5`.
Bootstrap intent and `protocol_meta.schema_sha256` bind this value.

**Consequence.** Implementations can bind the schema to two different authority
identities; a literal bootstrap either records a digest that does not match its
DDL bytes or rejects the generated database during validation.

**Required correction.** Replace the embedded value with the exact R22
Appendix A digest and make R28 compare R22's declared value, extracted bytes,
bootstrap intent, and `protocol_meta` value as one invariant.

### R22-PLAN-M3 — the complete Swift migration matrix omits active CLI lock/lifetime consumers

**Evidence.** Appendix E lines 1387-1408 calls its matrix complete and lists the
app-side FD producer plus a grouped `ModelsSubcommand.swift /
ModelCatalogReadCommand.swift` row. Dirty production Swift also contains
`Sources/macprovider-cli/ModelCatalogRead.swift`, which declares and validates
FDs 199/200, and `ModelTransactionContext.swift:364-410`, where
`ModelCatalogReadLease.start` validates the pipe and lock, reopens
`catalog-read.lock`, compares identity, and checks the inherited flock. Neither
file nor those authority-bearing declarations appears in the matrix. R28-12
requires the app runner and arguments but does not require these CLI consumers.

**Consequence.** The generated file/declaration manifest can pass while a live
receiver and lock-path open remain semantically unclassified at B8. The cutover
can retain an R4 authority dependency or remove a required transport guard
without violating the stated inventory test.

**Required correction.** Add both CLI files and every option, validation,
lease, reopen, identity, flock, lifetime, and callsite declaration to the exact
pre-B8/post-B8 matrix and R28 syntax-aware assertions.

### R22-PLAN-M4 — generation-50's candidate CAS does not encode the legal attempt-budget predicate

**Evidence.** R22 lines 567-576 permit first-over protection only after the
legal attempt budget, with event 49 as predecessor. Appendix C lines 1055-1060
instead parameterize the candidate's old state and all three counters as
`:terminal-state`, `:success`, `:failure`, and `:results`; it does not require
`result_count=24`, the legal success/failure total, or the one closed terminal
state derived from the 24th result. Appendix A constrains ranges but not this
cross-column budget relationship. R28-09 says wrong counters roll back, without
stating the exact accepted count predicate the manifest must compile.

**Consequence.** Two implementations can disagree on whether an event-49
candidate with non-budget counters is eligible for the only generation-50
control. One may mint protection early while another rejects it, and both can
claim to substitute the placeholders in Appendix C.

**Required correction.** Replace the placeholders with the exact old-state,
`result_count=24`, and success/failure predicates implied by the legal terminal
trajectory, or publish a closed finite set if multiple terminal combinations
are intended. Require R28 to test every accepted combination and first-under,
wrong-sum, and wrong-state rejections.

## Low (0)

None.

## R21 finding disposition

| R21 finding | R22/R28 result |
|---|---|
| H1 VFS ABI/path/locking | **Open.** Synthetic path and local I/O address the public-path mismatch, but R22-PLAN-H1 disproves the lock-close premise. |
| H2 typed ownership/generation FKs | **Closed in plan DDL shape.** Fresh valid and splice fixtures behaved as R28-06 requires; R22-PLAN-H6 separately finds a conflicting binding digest. |
| H3 per-quantum GC helper UUID | **Closed in plan shape.** Attempt/generation/phase/cursor are in the preimage and pairwise/replay qualification is required. |
| H4 enforceable serving lifetime | **Open.** The provider no longer receives the lock, but R22-PLAN-H2/H3 make daemon-crash recovery undiscoverable and unreapable. |
| H5 serving/outcome codecs/auth/FD binding | **Open.** Pin/outcome signing and the sole attachment are defined, but R22-PLAN-H4 leaves the actual request and channel lifetime unsigned and unframed. |
| H6 bootstrap crash machine | **Closed in recovery topology.** B4 and P5-S are named and tested; R22-PLAN-M2 must still correct the bound schema digest. |
| H7 custody temp/reclamation | **Closed in plan shape.** Exact C0-C7 paths, intent predecessors, forward-only rename recovery, and bounded reclamation are present. |
| M1 governed VACUUM | **Open.** R22-PLAN-M1 reproduces failure under the literal authorizer. |
| M2 complete app inventory | **Open.** App producers are added, but R22-PLAN-M3 finds the active CLI consumers omitted. |
| M3 generation-50 GC transaction | **Open.** The owned-control rows and zero-write replay now exist, but R22-PLAN-M4 leaves the eligibility counters/state parameterized rather than literal. |

## Gate decision

The exact R22/R28 revision is rejected. Revise the normative plan and test
specification, recompute every embedded and artifact digest, and rerun an
independent native GPT-5.6 Sol gate. Do not begin the R22 Swift/C/daemon/SPEC
implementation until a fresh review reports zero Critical, High, and Medium
findings.
