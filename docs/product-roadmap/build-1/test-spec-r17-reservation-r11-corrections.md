# Build 1 test specification R17 — reservation R11 corrections

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. This specification pairs with
`reservation-search-progress-addendum-r11.md`, SHA-256
`2c0a8ac095f277331f9cd65c41217bc2fe5fba742c5c143b7576ac01ef253e8b`.
It closes R10-PLAN-H1 through H6 and R10-PLAN-M1/M2 while retaining every
applicable R11–R16 case. No source/test implementation or passing result is
claimed.

All cases use production codecs and actual CLI/app entrypoints against one
frozen source/test manifest. Test-only independent encoders, digest builders,
quota calculators, page builders, and state-machine oracles must not call
production encoders or transition helpers. Every command records repository
base/head, exact selected/pass/fail/skip counts, duration, soft FD/quota limits,
read/page/descriptor counters, and complete log/fixture SHA-256. Injected Swift
errors and real child-process `_exit` deaths are separate. A skipped,
interrupted, timed-out, zero-selected, fixture-only substitute, or historical
run is not a fresh pass.

## R17-00 — frozen inputs and current baseline

Recompute and require exact SHA-256 for:

| Input | SHA-256 |
|---|---|
| R10 plan | `4b82dd1e0fd849f1472fff86e1f5cd8c5f9bd966946c91b21d8951ca5d17c407` |
| R16 test spec | `2f0397aed4699f90a2a75abf6acf63f0d088fdadd00399f969d57913fcdf6168` |
| failed R10 review | `677ee0df66c9d0351c6ab6d9a3b315772686de20109045185bdba3f9edf569af` |
| R11 plan | `2c0a8ac095f277331f9cd65c41217bc2fe5fba742c5c143b7576ac01ef253e8b` |

Pin reconciliation to `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`. Recompute the
`914f7caf..1d2c930b` path comparison and the R4 implementation hashes. Require
no merged reservation-path conflict and prove the merged BYOM artifact digest
cache remains outside transaction authority. Fetch origin again immediately
before implementation; any later reservation, SPEC, schema, or active external
decision-path change reopens the plan gate.

Inventory every production catalog-authority writer and wrapper before source
edits. Freeze its symbol, file, route class from R11 section 3, lock order, and
first possible write. Fail if a writer cannot be classified or can reach an
authority write without the shared fence.

## R17-01 — deterministic bootstrap and orphan recovery

Use an independent binary encoder to compute the bootstrap seed from exact old
format, index, source, configured-root, and canonical lock-identity bytes. Freeze
the full seed and lowercase RFC 9562 v8 UUID. Flip each input bit, domain byte,
length prefix, field order, UUID version bit, variant bit, or renderer and
require a different expected path or rejection. Production output must match
the independent vector.

Run the actual supported prior binary against the candidate v4 bytes and
require rejection before mutation. For each bootstrap suffix below, inject
thrown error, cancellation, deadline, ENOSPC, EDQUOT, and real death:

```text
lock create -> lock fsync -> lock-directory fsync -> activation directories ->
checkpoint create/fsync/dir-fsync -> activation create/fsync/dir-fsync ->
storage root create/fsync/dir-fsync -> selector temp/fsync/rename/dir-fsync ->
v4 temp/fsync/rename/.retention-v2-fsync
```

Restart with zero, one complete, one incomplete, and one unequal candidate set
at the deterministic path. Zero creates; complete reuses without rewrite;
incomplete creates only absent suffixes; unequal protects without deletion.
Repeat with 1, 2, 1,024, and 65,536 unrelated well-formed activation UUID
directories and assert identical direct-read count, no enumeration, no
selection, and no deletion. Include unrelated incomplete and hostile symlink
directories.

Change old index, source, configured root, and lock identity independently
before v4 CAS. A changed authoritative tuple derives a new UUID and ignores the
old candidate. A changed tuple after the final locked recapture makes that CAS
fail. Force a synthetic seed collision with unequal frozen tuple bytes and
require protected state. Race 2, 8, and 64 processes: all derive one UUID,
exclusive-create or equal-reuse only, and exactly one complete v4/selector graph
is selected. Death before format rename leaves old authority; death after it
selects complete generation zero. This is the R10-PLAN-H1 oracle.

## R17-02 — closed schemas and selector intent CAS

Independently encode minimum, maximum, exact-limit, and one-byte-over bytes for:

- selector v2, activation v3, checkpoint v4, and v4 format;
- storage root v1 and each storage entry kind;
- sequence leaf, node, and root v1 for every collection kind;
- run manifest v2, tree-build root v2, and amended work roots; and
- allocation admission v3.

Reject duplicate/unknown/omitted fields, implicit null, wrong type, unsafe
integer, negative count, uppercase/malformed digest or UUID, noncanonical JSON,
BOM, whitespace, trailing bytes, wrong direct path, filename/digest mismatch,
wrong collection/entry schema, traversal, symlink, hard link, wrong owner/mode,
and over-limit bytes. Insertion-order permutations must encode identically.

Freeze one stable selector, its pending-intent successor, and its stable
completion. Assert selector revisions are `n`, `n+1`, `n+2`; the intent retains
the old activation/checkpoint pair; only reviewed counters and intent change;
and completion selects the exact candidate pair/storage root/history append and
clears the intent. Reject a selector that binds current storage from inside its
candidate activation/checkpoint, a candidate storage root that omits either
control object, a digest cycle, changed prior storage/history binding, alternate
base selector, or selected candidate before all fsyncs.

For history accumulators independently append across 0, 1, 2, 53, 54, 1,024,
and maximum-safe generations. Freeze peak heights/digests/count and current
accumulator digest. Restart validates current triple, one immediate predecessor,
and the append proof with bounded reads. Corrupt each peak, prior binding,
generation, or leaf field and require protected state without a full walk.

## R17-03 — empty history and terminal identities

Run actual activation with zero source names. Independently freeze:

```text
empty name-block sequence root
empty row-block sequence root
empty capture-run sequence root
zero-row row-work root
canonical empty run manifest v2 and its two empty sequence roots
canonical empty v1 retirement root
empty row-verification sequences
```

Assert `rowCaptureRootSHA256` equals the zero-row row-work-root digest, not a
sequence root. The state path is generation-zero `capturing_names`, then
`capturing_rows`, `merging` with the selected empty run, `building` with the
canonical empty root, `verifying`, `ready`, and genesis. Each is a separate
selector successor; no phase skip occurs. Storage verification still covers
all selected activation/control inventory.

Kill before and after every empty root/run/selector fsync and CAS. Recovery
chooses one old or new complete graph and reaches the same bytes. Reject an
empty page, nonzero ordinal/count, non-null boundary, absent sorted-run digest,
alternate zero-row digest, row-capture alias, or direct `capturing_rows` to
`building` transition. Repeat with one row to prove the zero special case
cannot accept nonempty history. This is the R10-PLAN-H2 oracle.

## R17-04 — paged sequences and grandfathered scale

Use an independent persistent-sequence implementation with leaf capacity 16,
fanout 256, 3,072-byte entry ceiling, 65,536-byte pages, and 16,384-byte roots.
Freeze append bytes and digests at entry counts:

```text
0, 1, 15, 16, 17,
4,095, 4,096, 4,097,
65,535, 65,536, 65,537,
16,777,216, 16,777,217,
6,898,896,491, 13,743,895,348, 9,007,199,254,740,991
```

The last cases may use a deterministic sparse page store, but must execute the
production root/page transition and path validator rather than replace them
with a fixture-only assertion. At every boundary require only the right-edge
path changes, old pages remain byte-identical, interior pages are full, final
pages use exact short packing, and lookup returns the exact ordinal. Reject
skip/duplicate/overlap/reorder, alternate packing, wrong ordinal range/count,
wrong child digest, wrong transcript, entry 3,073 bytes, page 65,537 bytes, and
append beyond the safe count.

Independently recompute and assert:

```text
maximum rows                         439,804,651,110
name/row/capture blocks              13,743,895,348
merge pass output counts             429,496,730; 13,421,773; 419,431;
                                     13,108; 410; 13; 1
total merge outputs                  443,351,466
tree levels                          6,871,947,674; 26,843,546;
                                     104,858; 410; 2; 1
total tree pages                     6,898,896,491
work-sequence levels at max count    5
generic levels at 2^53-1 entries     8
```

Exercise each R11 collection kind and independently derive its sequence-root
binding from the amended name/row/run/tree/verification work root. A work root
containing an embedded unbounded array, a run manifest with flat output blocks,
or a phase root without exact sequence count/transcript fails.

On every supported local filesystem type, run the actual `getattrlistbulk(2)`
startup qualification with 0, 1, 31, 32, 33, 8,192, and a sparse large-name
directory. Freeze raw offsets and one-record sentinel digests. Close and reopen
the no-follow directory FD, seek every first/middle/block/EOF offset, and require
the exact sentinel and remaining transcript across real child death. Insert,
delete, rename, reorder where the test filesystem permits, replace the directory
inode, and alter the persisted offset; each must fail directory witness or
sentinel validation. Production name scan consumes at most 32 raw records,
persists one successor, and closes every FD. It must never rescan a selected
prefix, use lexical last-name continuation, serialize `telldir`, or keep an FD
across calls. A volume that fails qualification must reject before v4 selection
with a typed unsupported result and remains an explicit hardware/filesystem
qualification blocker.

Externally sort raw name blocks through the rooted merge protocol. Kill after
each scan block, lookahead sentinel, EOF, sort output, and final name-root CAS.
Recovery consumes only the missing suffix. Independently derive the final UUID
order and reject duplicate names, invalid UTF-8, false EOF, skipped/repeated raw
record, or a final name root before scan EOF and merge completion.

For merge passes 1 through 7, create a 32-input group whose total output spans
more than one invocation. Independently freeze every input cursor/head, 32-row
output block, output sequence successor, transcript, exhaustion transition,
run manifest, and completed-group entry. Kill after every selected step. Assert
at most one input FD is open, only the missing output suffix is produced, and
the group cannot complete while any cursor/head remains. Reject a replayed or
skipped row, duplicate UUID across inputs, changed heap tie order, 33rd input,
partial output block selection, or whole-group same-call fallback.

At process restart instrument direct reads/decodes. It must read current v4,
selector, activation, checkpoint, storage root, one history predecessor/proof,
and at most one sequence page per level for the demanded operation. It must not
walk old generations or unrelated collection entries. Exercise missing/corrupt
current, right-frontier, immediate-predecessor, and old nondemanded pages. The
first three protect immediately; the last is detected by incremental storage
verification or direct audit and cannot be used as authority meanwhile.

Run every 32-row capture/merge/verification unit and every bounded tree or page
unit at maximum legal body/input size under the unchanged eight-second
deadline, soft FD 256, at most four simultaneous FDs, and at most 160 activation
authority reads. Assert zero surviving FD, directory stream, cursor, key, or
lock after every call. A timeout blocks implementation; it does not permit a
larger page, flat manifest, higher deadline, or reduced validation. This is the
R10-PLAN-H4 oracle.

## R17-05 — exact level-zero and higher-level continuation

Build final sorted runs whose row-block shapes include:

```text
1; 63; 64; 65; 4,095; 4,096; 4,097 rows
63+1, 63+2, 1+63, 4,095+2, and multiple 4,096-row blocks
```

For every leaf independently freeze start/end block ordinal, start/end in-block
row ordinal, first/last global ordinal, row count, UUID boundaries, page ordinal,
digest, and successor cursor. Kill after input reads, page create, file fsync,
directory fsync, storage intent, and selector completion. Recovery emits only
the missing suffix. In a 4,096-row block, kill after each of 64 leaves and prove
the next cursor advances by exactly 64. For a cross-block leaf, prove neither a
row omission nor replay.

Reject row ordinal outside the block, mismatched global ordinal, a selected
partial leaf, 65-row leaf, premature final short leaf, cursor advance before
page selection, page not named by the sequence root, and alternate restart
packing. At higher levels repeat at 255/256/257 children and require the exact
next input-page ordinal and retained one-child final node. This is the
R10-PLAN-H3 oracle.

## R17-06 — selected storage accounting and crash recovery

Use an independent inventory encoder and physical filesystem walker. Freeze
storage-root bytes for 0–16 entries of every class, all canonical-length values
around 4,096 boundaries, and every MMR peak-count boundary. Independently run
the self-length fixed-point algorithm and require convergence in at most four
iterations, exact `F(selfCanonicalLength)`, and stable re-encoding. Reject a
duplicate path anywhere in history, wrong cumulative count/directory/materialized
value, omitted root self-charge, wrong fixed-control maximum, digest on mutable
selector control, absent digest on content-addressed/adopted files, or a root
that lists itself as a batch entry.

For every permanent activation directory, work block, run, sequence page/root,
tree page/root, verification block/root, checkpoint, activation object, adopted
v1 authority, and final ready-control object, execute:

```text
stable selector -> intent CAS -> candidate create/adopt -> file fsync ->
containing-directory fsync -> storage-root create/fsync -> stable selector CAS
```

Inject error, cancellation, timeout, ENOSPC, EDQUOT, and real death before and
after every arrow. At intent selection assert only:

```text
charged += plannedCharge + lifecycleReserveDelta
workReserved += plannedCharge
lifecycleReserved += lifecycleReserveDelta
```

At stable completion assert only:

```text
materialized += plannedCharge
workReserved -= plannedCharge
```

At every boundary independently inventory disk, Wpeak, Uafter, quota,
available capacity, candidate/unselected bytes, and selected counters. Assert:

```text
materialized + workReserved + lifecycleReserved + spentSlack == charged
charged <= quota
quota == roundUp4096(max(1 GiB, charged + finalizationReserve))
availableCapacity >= 536,870,912 + Wpeak + Uafter
```

Repeat both CAS operations and prove no double charge, materialization, reserve,
or lifecycle increment. A second process must recover the exact intent without
process ownership. Race 64 helpers; exactly one selector transition wins and all
converge. Unequal candidate bytes/identity, extra object, changed path, wrong
root, stale selector, missing fsync, or insufficient capacity protects without
refund or deletion.

At `ready` require null pending intent, zero work reserve, complete storage
verification, and byte-for-byte agreement between selected inventory and
physical authority. Genesis copies exact counters into v2 capacity. Selected
predecessor generations remain charged and present after genesis; only proved
unselected temporaries can be removed. This is the R10-PLAN-H5 oracle.

## R17-07 — allocation admission v3 body authority

Independently encode v3 at every admission-bearing A1–A5 and A7 phase and
terminal admission absence at A6/A8. Freeze exact directory and four body
relative paths, root-relative path digest, canonical body bytes/digests/lengths,
`F(length)` charges, and the sum within 581,632. Flip base path, UUID, filename,
slash, normalization, digest domain, body byte, length, charge, duplicated
legacy digest, or phase and require rejection before write.

For directory, primary, origin, class, and lineage repeat every R16-05 intent,
create, fsync, durable-CAS, cancellation, storage, and real-death suffix. Remove
all caller body/path arguments on recovery and prove production derives the
same candidate solely from selected v3. Supply conflicting caller arguments and
mutable catalog bytes and require they are ignored or rejected, never adopted.
Instrument directory enumeration and require zero enumerations for authority.

Before each intent, assert the one selected v3 entry matches the next ordered
object. After each durable CAS assert the exact R10 charge transfer, including
the sole 4,096 directory delta at A3→A4 and no re-charge by a body. Reject a v2
admission entering any v3 materialization phase, a v3 admission with an external
manifest reference, creation before intent, later body before earlier durable
state, or an A3+ abort/refund. This is the R10-PLAN-H6 oracle.

## R17-08 — route fence and lock concurrency

Generate a test from the frozen production-writer inventory. At generation
zero, every middle phase, pending intent, ready-before-genesis, and after
genesis, invoke every symbol through its lowest public CLI/app/HTTP entrypoint
and directly where tests permit.

- The activation continuation may write only its selected intent suffix and
  selector successor.
- Genesis may write only the inactive v2 slot and v5 index after ready proof.
- Every ordinary catalog writer rejects before its first authority write until
  genesis and proceeds only from exact v5/v2 activation bindings afterward.
- Heartbeat, cancellation, status, result, catalog reads, and readiness remain
  available but cannot mutate catalog authority.

Use file-operation tracing to prove route boundaries. A wrapper bypass, writer
missing the common classifier, activation writing an ordinary catalog path,
operational route writing authority, or activation engine rejected by its own
fence fails.

Block source hashing, a 32-way merge, tree page construction, and verification
in separate processes. During each block, require the process holds neither
activation nor journal flock. A helper may finish the selected pending intent;
heartbeat/cancel/status/read calls finish; and no ordinary catalog writer crosses
the fence. Instrument locks for every CAS: activation flock first, journal lock
second, both released in the same call. No lock survives error/death; no
post-genesis route opens activation.lock. Block an ordinary post-genesis target
before its journal CAS and require an unrelated target publication plus all
operational routes to complete. This is the R10-PLAN-M1/M2 oracle.

## R17-09 — incremental verification and preserved closed findings

Run row verification passes 1 and 2 at 0, 1, 31, 32, 33, 4,095, 4,096, 4,097,
and the maximum sparse grandfathered count. Each selected block covers a
consecutive range of at most 32 rows and binds exact namespace, R10 full witness,
descriptor-before/read/descriptor-after/path-after results, rolling transcript,
and sequence root. Kill at every read/object/root/intent/selector boundary.
Recovery performs only the missing suffix.

Mutate each source identity field and body independently before open, during
each read chunk, before descriptor-after, before pathname-after, between passes,
and immediately before genesis namespace re-resolution. Include same-inode
same-length rewrite, truncate/restore, restored mtime with changed ctime,
chmod/chown where permitted, link-count change, same-byte inode replacement,
rename/path replacement, symlink/type substitution, and certificate/origin swap.
The affected demanded path blocks selection. A cooperative catalog writer is
blocked by v4 before mutation throughout both passes. No pass relies on a
process-held global lock.

Storage verification targets the selected prior root/count/materialized total,
processes at most 64 inventory entries per selected block, advances its target
to that stable prior root, and recomputes physical charge and MMR transcript.
Assert each selected verifier successor adds no more than 16
inventory entries and decreases backlog by at least 48. Exercise live tails of
0, 1, 15, 16, 17, 47, 48, 49, 63, and 64 entries. At 16 or fewer, independently encode the
`storage-close` intent and require its final CAS to validate the complete tail
plus candidate control suffix in at most 32 entries, with the resulting
transcript equal to the selected inventory count/MMR/materialized bytes.
Corrupt/missing historical authority must be found before `ready`; no verifier
object may require itself as verified input. Genesis revalidates ready roots,
final control suffix, current namespace, v4/selector/index/source, and exact
v2/v5 bytes in one bounded CAS. This preserves the R9-H3 source-witness outcome
without requiring an unbounded same-call scan.

Re-run R16-05 through R16-07 unchanged for root-relative path, A3–A8 crashes,
abort envelope/actual charge, refund, quota, and 1 GiB arithmetic. Require exact
126,976 maximum actual abort charge, 454,656 refund, 8,456 maximum-actual aborts,
37,449 minimum aborts, 1,846 successes, fixed bundle ceilings, and R10 free-space
equation. A path-domain change, 393,216 used as actual retained charge, weakened
ctime/source check, or changed ceiling fails.

## R17-10 — retained suites, independent audits, and stop gate

Re-run every applicable R11-01 through R11-13, R12-01 through R12-08, R13-01
through R13-11, R14-01 through R14-08, R15-01 through R15-09, and R16-00
through R16-08 with these replacements:

- R17-01 replaces orphan/bootstrap recovery;
- R17-02/R17-04 replace flat roots and full predecessor walks;
- R17-03 replaces undefined empty history;
- R17-05 replaces the incomplete level-zero cursor;
- R17-06 replaces selected activation-work accounting;
- R17-07 replaces the nonexistent body manifest; and
- R17-08/R17-09 close route/lock scope and make complete verification bounded.

Retain primary-first departure, exact origin binding, same-owner stabilization,
frozen finalizing membership, global unresolved-allocation gate, target-local
publication, content-addressed lineage/install, target-only predecessor v2,
sequential actual-prior-binary fence, no wrapper bypass, no authority deletion,
no economic activation, and real-death recovery.

Run focused codecs, reservation migration, transactions, retention, catalog
read, CLI bridge, command composition, Malibu model-management, package-wide
`swift test`, applicable Xcode tests, and every Build 1 governance/compatibility
gate. Freeze final source/test hashes. Fresh independent GPT-5.6 Sol code,
security, and architecture audits of the complete diff must each report zero
Critical, High, and Medium findings.

Stop on a stale baseline; nondeterministic bootstrap; orphan scan/adoption;
illegal empty graph; in-block cursor ambiguity; flat unbounded authority;
unbounded restart/genesis work; selector/control digest cycle; selected bytes
outside accounting; create before intent; v2/undefined body authority;
activation lock across bulk work or calls; mutation-fence bypass; weakened
source witness; changed A4/A5 or abort arithmetic; raised deadline/FD/input/
document/quota limit; missing real-death case; authority deletion; or stale,
skipped, interrupted, timed-out, zero-selected, or fixture-only evidence called
passing. Physical MLX, signed feed/release, deployment, production enforcement,
settlement activation, and economic activation remain outside this corrective
test specification.
