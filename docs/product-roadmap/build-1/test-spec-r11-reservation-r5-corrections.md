# Build 1 test specification R11 — reservation R5 corrections

Date: 2026-09-10. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This test specification pairs with
`reservation-search-progress-addendum-r5.md`. It retains every applicable R4
qualification and adds the exact regressions required by the failed frozen R4
code, security, and architecture audits. No result is claimed by this document.

All cases run against one frozen implementation manifest. Each result records
the exact command, base/head SHA, selected/pass/fail/skip counts, duration,
process soft/hard FD limits when relevant, measured counters, and SHA-256 of the
complete log and durable fixture manifest. A thrown-error test never substitutes
for a separately required real child death.

## R11-01 — closed codecs, direct paths, and size envelopes

Drive the production decoders for every allowed classifying, finalizing,
complete-active, and complete-allocating matrix cell. Add the R5 predecessor
index/progress, completed-projection, and install-v2 schemas. For each schema:

- round-trip canonical minimum and maximum accepted values;
- exact-at-limit and one-byte-over-limit behavior;
- duplicate/unknown keys, null substitution, omitted required keys, wrong
  phase, uppercase/short/long digest, invalid UUID/generation, and trailing data;
- safe regular file versus symlink, hard link, wrong owner/mode/type, same-byte
  new inode, in-place mutation, wrong directory, digest/body/path mismatch, and
  preexisting unequal exclusive-create collision;
- direct lookup counts proving that receipt, predecessor, install, and
  projection paths come only from validated UUID/digest fields and that no
  history directory is enumerated.

Use maximum previously accepted origin and entry strings. The class, receipt,
predecessor, install, projection, and active-index envelopes must not narrow any
R4-valid input. Invalid encoding fails before mutation and preserves all bytes.

## R11-02 — all-member phase graph

Build at least three sorted source members so the corrupted member can be before
the prefix, at the prefix, beyond the prefix, and different from the UUID being
mutated. Exercise unclassified, first-class pending, acknowledged class,
first-left pending, acknowledged left, finalizing, first complete, later complete
with dynamic allocation, and complete after original-member retirement.

For every phase, delete, replace, or mismatch each source membership row,
origin, class, left, acknowledgment, progress prefix/generation, source hash,
binding completion/ref, phase field, install digest, completed projection, and
current dynamic entry. Attempt each production mutation family through a
different healthy UUID: generic commit, first start, heartbeat, status/cancel,
result/seal/success binding, cleanup, reservation, allocation recovery,
retirement, migration progress, finalizing recovery, and catalog-triggered
journal work. Assert the first durable write counter remains zero and exact
index/primary/metadata bytes remain unchanged.

Positive controls prove every allowed cell and legal dynamic membership update.
Finalizing recovery must capture and validate source/progress/binding/install/
projection before its complete-index write. Corrupt each root after finalizing
capture and before final CAS with deterministic barriers; stale validation must
abort without a phase change.

## R11-03 — completed install and historical closure

Create a maximum-field migration with allocated, legacy, and protected source
members and allocated members with and without left evidence. Validate:

- exact source membership equals the completed projection and complete progress
  acknowledgment map;
- every historical origin/class/left is opened, hashed, and matched;
- prepared-index hash/generation, finalizing/completed generation sequence,
  source/progress hashes, binding lineage, install UUID/digest, projection
  digest, and finalizing/complete entry/ref equality;
- the first complete index is the exact permitted derivation from the projection
  plus the content-addressed install digest; and
- later allocation/retirement/binding changes preserve the immutable historical
  graph while validating the current graph separately.

Coherently replace the old UUID-named install pair, replace the content-addressed
install and projection together, alter membership, class/left refs,
prepared-index hash, binding refs, or any generation while keeping the other
files mutually plausible. Every mutation fails protected. Retire every original
source member, restart, and prove historical validation remains mandatory.
Also migrate an empty source, allocate the first member, start/finish/retire it,
and prove the empty historical graph and current dynamic graph remain distinct.

## R11-04 — bounded FD owner fence and graph validation

Run under an actual soft `RLIMIT_NOFILE` of 256 without raising it. Use exactly
1,024 fully active entries with safe stable owner paths present, then repeat with
all owner paths absent and with alternating present/absent paths. Exercise both
cutover and the largest origin/class/left completed graph.

Record baseline and peak total descriptors, reservation-owned descriptor delta,
opens, flocks, closes, unlocks, failures, elapsed time, and every budget check.
Assert total live descriptors remain below 256, the reservation-owned maximum is
constant rather than proportional to 1,024, every local FD closes exactly once,
and the cut completes within the unchanged eight-second call on the supported
healthy profile.

Inject `EMFILE` before the first owner, in the middle, at the last owner, while
opening class/left evidence, and during final locked revalidation. Each attempt
returns typed bounded unavailable, releases every FD/flock, creates no owner,
and leaves source/format/progress/index and all metadata byte-identical. Release
the injected descriptors and retry successfully under the same limit. Repeat
with substituted/unsafe owner paths and a real busy owner at first/middle/last.

## R11-05 — actual prior-binary fence

Before R5 source changes, build and retain the minimum supported pre-v4 binary
and every additional binary claimed compatible. Record source tree, compiler,
executable, and manifest SHA-256. A fixture wrapper or current source compiled
with a flag is not an actual prior binary.

Pause each prior-binary production writer immediately before its final journal
validation: generic commit, queued start, heartbeat, status/cancel, result,
seal, success-binding/terminal, cleanup, allocation/recovery, retirement, and
catalog-owned reservation/reconcile. Exercise pre-source, source-only,
post-format/pre-progress, post-progress/pre-v4, classifying, pending metadata,
finalizing, and complete states.

Resume after the new binary publishes the fence. Assert every old mutation
rejects v3 before changing primary/result/seal/binding/index/owner-ack bytes or
launching work. A prior writer already in the journal lock must make cutover
return bounded busy until that write completes. A prior writer acquiring an
owner after its sequential probe but while cutover holds the journal lock must
reject after release. Safe read/control failure is explicit. Any claimed
compatible binary that crosses the fence fails the release gate.

## R11-06 — global allocating-intent gate

Table-drive every R4 allocation recovery row and all new hostile forms: all
absent; primary only; primary+origin; primary+origin+class; origin/class without
primary; class without origin; changed bytes; malformed primary; wrong initial
hash; origin/class field or digest mismatch; `allocatedGeneration` unequal to
the primary selector or origin allocation generation; owner present/busy/unsafe;
left or other sidecar present; empty/nonempty/unsafe receipt directory; changed
index; capacity; and budget expiry at every boundary.

After each unresolved form, issue a matching and nonmatching real reservation.
Assert a typed busy/protected/capacity/budget result as applicable and zero new
UUIDs, primary, origin, class, owner, sidecar, receipt directory, predecessor,
or index member. Recovery may proceed past no unresolved allocating UUID,
regardless of whether its tuple is decodable. The all-absent row removes only
the intent. Exact suffix rows activate only when all three generation values and
all frozen fields/hashes match. Restart each row and prove the same result.

## R11-07 — departed-primary rollback, pending stabilization, cancellation, and retirement

For an allocated UUID with an anchored left, replace the primary with its exact
immutable initial queued bytes. Separately stop after the first-left receipt and
after its index intent, then roll the primary back. Invoke real reserve, run,
check, status, cancel, cleanup reservation, and maintenance/retirement. Assert no
reusable result, replacement allocation, worker launch, ordinary queued status,
cancel success, or retirement. Anchored rollback and a pending receipt whose
frozen nonreusable primary no longer matches both fail protected and preserve
all evidence.

For each departure boundary—truthful primary, receipt, intent, class, left,
progress acknowledgment, and final index—invoke reserve and retirement directly
after restart. When recovery is valid, it uses the already held exact UUID owner,
never attempts a second flock, installs only the frozen suffix, recaptures, and
then restarts the decision. Busy or corrupt recovery preserves membership and
pending refs.

Use a barrier with a starter holding the owner before its first primary write.
A queued cancel must return typed `ModelCatalogTransactionError.busy`; it may
not return the unchanged record as success. After release, cancellation records
durable cancel truth. Repeat with pending metadata, a live started owner, and a
fully completed left. Preserve the existing valid live-owner cancel-request
behavior only for nonqueued primary with completed metadata.

## R11-08 — authenticated publication recovery and two UUIDs

Pause UUID A and UUID B with simultaneous content-addressed pending receipts.
For class-only and later first-left publication, validate the exact predecessor
index/progress snapshots, derived immediate intent successor, current monotonic
descendant, and direct receipt paths. Advance B's acknowledgment while A is
pending, then recover A. Repeat in the opposite order and with unrelated binding
progress.

Alter one dimension at a time: receipt old-index hash/generation, archived old
index bytes, prior-progress hash/bytes, target UUID/origin/generation, immediate
successor generation, unrelated pending ref, old acknowledgment, added
acknowledgment, class/left bytes or refs, prefix, source lineage, and current
index/progress generation. Add coherent cross-UUID receipt substitution and
replay from an older valid generation. Recovery must accept only an exact
predecessor or proven monotonic merge, preserve every old acknowledgment and
unrelated pending ref, and mutate only the target's permitted suffix.

Crash after predecessor index, predecessor progress, publication receipt,
intent index, class, left, progress acknowledgment, and final index. Unreferenced
prepared predecessors/receipts remain nonauthoritative retained history and are
never found by enumeration.

## R11-09 — real child death and deterministic durability boundaries

For every boundary below, run both a thrown-error case and an independent child
that calls `_exit` immediately after the production boundary callback. Restart
in a fresh process and invoke the real public operation that owns recovery.

- cutover: source, mandatory format, initial progress, classifying index;
- classification/departure: receipt predecessor files, receipt, intent, class,
  left, progress acknowledgment, final entry index;
- allocation: before intent, allocating index, primary, origin, class, active
  index, and lost response after active;
- finalization: completed projection, install receipt, finalizing index, complete
  index; and
- retirement after pending recovery and before retirement certificate/index.

Assert exact forward completion or protected byte preservation from the closed
state table. No recovery launches a worker, creates an allocation owner,
acknowledges heartbeat/success, regenerates missing acknowledged metadata from a
primary, or restarts a begun durability bundle as a new UUID. Lost response after
active reuses the same UUID. Capture child PID/exit status and prove it was a
real process death, not an in-process thrown substitute.

## R11-10 — maximum shape, no reread, and shared budgets

Create exactly 1,024 sorted production-valid allocated records of exactly
4,194,304 primary bytes and exactly 2,048 valid identity-bound events. Use the
controlled cooperative profile from R4: at most 256 KiB per chunk, 25 ms delay,
and complete read plus strict validation of one record within two seconds. Put a
plausible exact queued candidate last.

Across repeated unchanged eight-second reservation/migration calls, record per
UUID primary bytes/chunks/decodes, metadata bytes/opens, index/progress decodes,
fsync latency, prefix/map advancement, elapsed time, and budget checks. Once a
UUID's class/left acknowledgment is durable, every later call must read and
decode zero bytes of that UUID's 4 MiB primary. Only unclassified bodies advance;
the complete graph validator reads bounded metadata. Force budget expiry after
each durable boundary and prove the next call resumes from exact progress
without rereading acknowledged bodies. The last queued candidate is returned
only after every preceding negative is durably classified and validated.

If one complete record cannot fit the original call budget, require bounded busy
with no false progress, as R4 specifies. Do not shrink the fixture, lower event
count, remove cooperative delay, raise the deadline/FD limit, or combine partial
runs into a pass.

## R11-11 — reservation, retirement, and owner concurrency

Use deterministic subprocess barriers around search absence, final allocation
CAS, allocation recovery, first primary, pending receipt, progress update,
retirement recapture, and final retirement CAS. Cover:

- reserve/reserve for the same tuple and for different tuples;
- a matching queued candidate inserted after another search capture;
- allocation versus allocation recovery and retirement;
- pending UUID A while unrelated UUID B starts, heartbeats, cancels, completes,
  and publishes binding/result/seal state;
- finalizing versus every membership mutation; and
- retirement of a terminal entry interrupted at receipt, intent, class, left,
  progress, and final-index boundaries.

Assert at most one surviving matching UUID, no allocation past any unresolved
intent or possible candidate, no global pending gate on B's valid heartbeat, no
cross-UUID owner acquisition, frozen membership through finalizing, exact
preservation of unrelated refs, bounded completion, and no deadlock. Run the
relevant Swift concurrency sanitizer/race-capable checks available to the
package and report their exact capability; do not label unavailable tooling as
passing.

## R11-12 — owned catalog quick, verify, and concurrency composition

Run the actual parsed app/CLI-owned quick and verify paths, including their
shared 10-second/1,800-second outer budgets and at-most-eight-second transaction
view. Do not call the store directly as a substitute. Cover classifying,
finalizing, first complete, unresolved allocation, pending publication,
rolled-back departure, and completed dynamic membership.

Required cases:

- quick and verify during a valid incremental migration retain durable progress
  and emit explicit incomplete/unavailable when the complete projection cannot
  be established; they never emit false `[]`, false reusable action, or false
  recovery absence;
- shared budget expires before and after class, left, progress, index,
  recommendation pointer, and cleanup-reservation writes; no helper renews the
  work budget and already durable truth remains recoverable;
- action-side reservation or reconcile creates a cleanup obligation, and the
  final complete inventory includes it exactly;
- UUID A remains pending while catalog reconciliation legitimately advances B;
  A's receipt/ref and both progress histories are preserved;
- graph corruption in an untouched source member makes quick/verify fail before
  any catalog-triggered transaction mutation or artifact hashing; and
- after valid completion, quick and verify preserve the same action/recovery
  truth as the standalone paths while concurrent heartbeat, cancel, allocation,
  and retirement barriers run.

Re-run the applicable catalog-read completeness CC-01–CC-10, lifecycle
CR-01–CR-13, actual argv bridge, command bootstrap/composition, and model
management tests against the same final manifest. Existing catalog response,
stderr/stdout, JSONL, option/FD ownership, hash, and final-inventory limits stay
unchanged.

## R11-13 — regression, evidence, and audit gate

Run the focused reservation-migration, retention, transaction, catalog-read,
catalog bridge, command bootstrap/composition, and app model-management suites
first. Then run package-wide `swift test` and every applicable Build 1
compatibility/governance/Xcode gate required by the repository and current
landing plan. Preserve the unchanged healthy-capacity reservation fixture and
the R4 prior-binary, cancellation, cleanup, migration, binding, retention, and
maximum-shape requirements.

Freeze the final source/test hashes before review. Three new independent reviews
must inspect the complete diff as it will land: code, security, and architecture.
Acceptance is zero Critical, zero High, and zero Medium in every lane. Low/Info
may be carried explicitly. An interrupted, skipped, timed-out, stale, or
aggregate-only run is not a pass. This evidence does not qualify physical MLX,
release signing/feed publication, deployment, enforcement, settlement, or
economic activation.
