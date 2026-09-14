# Build 1 reservation search progress R11/R17 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: plan and test specification only. No source or test implementation was
authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 5 High, 2 Medium, 0 Low.**

R11/R17 closes the prior empty-history, in-block tree cursor, bootstrap-orphan,
route-class, lock-scope, and inline allocation-body questions in useful detail.
It does not yet define an implementable bounded storage authority at the
grandfathered maximum. The selected accounting cannot represent the stated
maximum history, the mutable selector cannot retain the frozen file identity
required by its one-time inventory entry, and storage-path uniqueness has no
bounded membership proof. Several new paged schemas and multi-sequence
transitions also remain under-specified, so the independent R17 encoder and
crash oracle would have to invent normative behavior.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r11.md` | `2c0a8ac095f277331f9cd65c41217bc2fe5fba742c5c143b7576ac01ef253e8b` |
| `test-spec-r17-reservation-r11-corrections.md` | `5179135faac5a0a78124c61364b3ba17bdc4bf2ed2e74c842ca622876cf1064e` |
| Failed R10 review | `677ee0df66c9d0351c6ab6d9a3b315772686de20109045185bdba3f9edf569af` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The current R4 reservation source
hashes still match the durable implementation checkpoint, including retention
`0a6b4873...`, evidence `b49c13fa...`, reservation migration `c8505d5d...`,
bindings `60abe294...`, and transactions `65cbb0e9...`. Current source still has
the pre-R11 format/index models and decoders in
`ModelCatalogTransactionRetention.swift:6-39,191-221`; this review did not
treat the proposed schemas as implemented evidence.

The inherited maximum arithmetic was independently checked:

```text
2^53 - 1                                      = 9,007,199,254,740,991
439,804,651,110 * 20,480                     = 9,007,199,254,732,800
remaining representable charge               = 8,191
minimum F(canonical file)                     = 8,192
```

The local `getattrlistbulk(2)` manual confirms that iteration advances state on
the directory descriptor and documents resetting to offset zero with `lseek`;
it does not provide a requested-entry-count parameter or specify the R11
lookahead/partial-batch cursor construction.

## Critical (0)

None.

## High (5)

### R11-PLAN-H1 — the stated maximum grandfathered history cannot enter the selected accounting domain

**Severity:** High. **Confidence:** High.

**Evidence.** R11 retains the inherited maximum of 439,804,651,110 v1 rows and
the safe-number ceiling (`reservation-search-progress-addendum-r11.md:330-350`).
R8 derives that row maximum as `floor((2^53-1)/20,480)` from the v1 certificate
charge (`reservation-search-progress-addendum-r8.md:361-365`). R11 now requires
adopted v1 authority and every activation-created object to enter the selected
storage inventory and `activationChargedBytes` (`R11:433-456,479-515`), while
all canonical numeric fields remain at most `2^53-1` (`R11:348-350`). At the
stated row maximum the certificates alone consume
9,007,199,254,732,800 charge units, leaving 8,191. One content-addressed storage
root has minimum `F(length)` 8,192, before activation/checkpoint, sequence,
verification, fixed-control, adopted origin, directory, lifecycle reserve, or
finalization costs. The quota formula also adds finalization reserve to charged
bytes (`R11:498-500`), immediately exceeding the safe-number domain near that
boundary. R17 checks sparse sequence counts and per-batch arithmetic but never
proves a complete maximum-history charge fits (`test-spec-r17-...:141-227,
253-311`).

**Consequence.** A previously legal maximum v1 history cannot even select the
first complete R11 storage generation. Implementations must overflow/reject,
omit selected bytes, or silently lower the promised compatibility bound. This
keeps R10-PLAN-H4/H5 open in substance.

**Required correction.** Define a representable accounting domain that includes
the complete adopted baseline, every retained progress generation, lifecycle
reserve, and finalization reserve. Either use a closed wider/string integer
encoding throughout all affected contracts or derive and enforce a new exact
maximum from a proved worst-case end-to-end activation-storage formula while
preserving the promised compatibility outcome. Add independent full-cost
vectors at the last passing and first failing history sizes; sparse page-count
tests are not a substitute.

### R11-PLAN-H2 — one-time fixed-control inventory is invalidated by every selector rename

**Severity:** High. **Confidence:** High.

**Evidence.** Every storage file entry, including `fixed-control`, stores
device/file identity, mode, owner, group, and link count (`R11:433-443`). The
direct selector extent is inventoried once at bootstrap (`R11:511-515`). Yet
selector publication is an atomic prepared-file rename in the retained R10
protocol (`reservation-search-progress-addendum-r10.md:202-223`), and R11 uses
two selector replacements for each intent/stable successor (`R11:188-193,
488-509`). An atomic rename installs a different inode at `active.json`; the
bootstrap inventory's `deviceID/fileID` witness is therefore stale after the
first legal successor. The bootstrap order in R17 also creates the storage root
before selector/v4 publication (`test-spec-r17-...:58-63`), so it cannot observe
the final-path identity it claims to inventory. R17 rejects wrong identities
but has no positive oracle showing how legitimate selector replacement updates
or exempts this frozen entry (`R17:253-311`).

**Consequence.** Exact ready-time physical/logical agreement must reject every
nontrivial activation, or production must ignore a selected identity field and
weaken the no-follow replacement boundary.

**Required correction.** Separate logical fixed-extent charging from immutable
file-identity evidence, or define a bounded generation-aware control inventory
whose selected witness changes atomically with each rename without creating a
digest cycle. Specify bootstrap preparation order for final-path identities and
add positive/negative tests across at least two selector renames, crash before
and after rename/fsync, and hostile same-path replacement.

### R11-PLAN-H3 — global storage-path uniqueness has no bounded proof or lookup structure

**Severity:** High. **Confidence:** High.

**Evidence.** R11 requires every inventory path to be unique across the complete
previous-root chain (`R11:442-456`). The storage root contains only a bounded
batch, cumulative counters, a previous-root pointer, and an MMR of prior root
digests (`R11:422-451`). Neither the MMR nor cumulative counters provide a
membership or non-membership proof for a candidate relative path. Restart and
each invocation are nevertheless forbidden to walk prior generations and are
bounded to 160 direct authority objects and eight seconds (`R11:352-368`). R17
requires production to reject a duplicate path anywhere in history
(`test-spec-r17-...:255-263`) but supplies only an independent full filesystem
walker as its oracle, not a bounded production proof.

**Consequence.** A transition cannot distinguish a newly materialized path from
an already charged selected object without an unbounded history walk. It can
double-charge/re-inventory an old object, accept duplicate authority, or violate
the invocation bound.

**Required correction.** Add a selected authenticated path-membership index with
closed inclusion/non-inclusion proofs and exact update/crash/accounting rules,
or replace global path uniqueness with a derivation that proves each legal path
can occur in only one generation and defines byte-equal reuse without recharge.
R17 must exercise prior selected, unselected equal, digest-collision, and
maximum-depth membership cases within the same read/FD/deadline limits.

### R11-PLAN-H4 — the replacement page/work schemas are not closed enough for independent canonical encoding

**Severity:** High. **Confidence:** High.

**Evidence.** The sequence root has an exact field list, but leaf and internal
page schemas are described as “the same header,” “entries,” and “child entries”
without exact schema strings, JSON field names, nullability, allowed
`collectionKind`/`entrySchema` pairs, or domain-separated transcript encodings
(`R11:244-267`). The amended name/row/run/tree/verification roots are described
by replacement prose rather than complete exact schemas (`R11:269-328`). The
empty run manifest and merge-group work likewise name semantic values without a
complete canonical field list and digest domains (`R11:318-328,370-389`). R17
requires an independent encoder to freeze these exact bytes and reject unknown
fields (`test-spec-r17-...:82-111`) and to independently derive every sequence
binding (`R17:141-182`). Those bytes cannot be derived uniquely from the plan.

**Consequence.** Production and the independent oracle must share unstated
choices or disagree on canonical authority. Crash recovery, digest paths, and
cross-version compatibility cannot be reviewed before implementation.

**Required correction.** Publish complete closed schemas for every new leaf,
node, sequence entry, amended work root, merge cursor/head, run manifest, empty
object, and verification entry, including exact field names/order-independent
canonicalization, schema identifiers, enum tables, nullability, numeric bounds,
size limits, paths, and every transcript/digest byte domain. Freeze independent
minimum/maximum vectors from those contracts.

### R11-PLAN-H5 — the sixteen-entry intent cap is incompatible with unsplit multi-sequence phase transitions

**Severity:** High. **Confidence:** High.

**Evidence.** One selected intent may contain at most 16 permanent entries
(`R11:352-356,460-477`). A maximum-depth append can create a new leaf, one page
at each of up to seven internal levels, and a new sequence root: nine permanent
objects before its owning work root, activation, and checkpoint. The run-work
contract retains separate completed-group and output-run sequences
(`R11:271-276`) and says the post-exhaustion successor publishes the run
manifest and completed-group result (`R11:318-328`). Completing the inherited
run state also advances the output-run collection. Two maximum-depth sequence
appends alone can require 18 entries, before the manifest and control objects.
Tree level completion has the same risk when completed-level and next-level
input sequences advance together. No legal intermediate state, split-intent
ordering, or cardinality proof is defined. R17 merely asserts the 16-entry cap
for every object class (`test-spec-r17-...:265-272,385-393`).

**Consequence.** A legal large transition cannot fit the selected intent, while
splitting it ad hoc can leave a manifest or one sequence selected without its
paired phase authority after death.

**Required correction.** Inventory every phase transition at maximum sequence
height and prove its exact permanent-entry count. Where a transition exceeds
16, define closed intermediate states and separate selector CAS edges whose
objects are independently useful, rooted, charged, recoverable, and forbidden
from premature phase completion. Add real-death cases at every split edge and
maximum-height sparse fixtures.

## Medium (2)

### R11-PLAN-M1 — lifecycle reserve deltas are mutable accounting input without a normative derivation

**Severity:** Medium. **Confidence:** High.

**Evidence.** `lifecycleReserveDeltaBytes` is selected inside every pending
intent and directly increases charged and lifecycle-reserved counters
(`R11:460-496`). R11 does not state which intent kinds/phases may use a nonzero
delta, how it is derived from the inherited 352,256/466,944/696,320 reservation
classes, whether a row can add it more than once, or how it is consumed at
genesis. R17 checks arithmetic and replay but not an independent phase-to-delta
mapping (`test-spec-r17-...:274-305`).

**Consequence.** Two conforming implementations can charge different amounts
for identical adopted authority, or a replay/alternate intent kind can reserve
the same lifecycle twice while satisfying the local equation.

**Required correction.** Define a closed object/phase-to-reserve table, exact
zero/nonzero rules, uniqueness key, consumption/import rule, and independent
vectors for every source provenance and boundary. Reject any delta not derived
from the selected source row and prior reserve state.

### R11-PLAN-M2 — the `getattrlistbulk` cursor protocol does not define how a bounded batch and lookahead map to one resumable kernel offset

**Severity:** Medium. **Confidence:** High.

**Evidence.** R11 requires a call to consume at most 32 records, persist the
next kernel directory offset, and retain a one-record lookahead sentinel
(`R11:280-303`). `getattrlistbulk(2)` accepts a byte buffer rather than an entry
count and advances descriptor iteration for the entire returned batch. R11 does
not freeze the exact attribute list, buffer sizing proof that no call returns a
33rd record, the `lseek` capture/restore sequence used for lookahead, opaque
offset encoding/range, or behavior when one maximum record does not fit that
bound. R17 measures offsets and sentinels but leaves production free to invent
those mechanics (`test-spec-r17-...:184-202`).

**Consequence.** A legal call can advance past records the checkpoint did not
select, making restart skip entries, or the implementation can exceed the
32-record/read bound. Filesystem qualification cannot establish conformance to
an undefined cursor algorithm.

**Required correction.** Specify the exact attrlist/options, minimum and maximum
record sizes, buffer size, before/after `lseek` operations, lookahead rollback,
offset encoding and bounds, ERANGE/EOF handling, and the proof that every
returned record is either selected or remains reachable from the persisted
offset. Add 32/33 mixed-size record batches and death after syscall, offset
capture, lookahead, rollback, and checkpoint CAS.

## Low (0)

None.

## Disposition of the prior R10 findings

| Prior finding | R11 disposition |
|---|---|
| R10-PLAN-H1, pre-format bootstrap orphan | **Closed in design direction.** Deterministic identity and direct-path reuse give bounded recovery. The fixed-control bootstrap contradiction is a new storage-authority problem (R11-PLAN-H2). |
| R10-PLAN-H2, no empty-history path | **Closed by plan.** R11 defines the zero-row work root, empty run, empty retirement root, and complete phase path. |
| R10-PLAN-H3, no in-block cursor | **Closed by plan.** Block, row, and global ordinals identify exact leaf continuation. |
| R10-PLAN-H4, flat/unbounded work | **Partly closed.** Persistent sequences and incremental verification address traversal, but their schemas and maximum accounting remain unclosed (R11-PLAN-H1/H4/H5). |
| R10-PLAN-H5, selected activation accounting | **Still open in substance.** Intent equations are useful, but maximum representability, mutable controls, path membership, and reserve derivation are unresolved (R11-PLAN-H1/H2/H3/M1). |
| R10-PLAN-H6, nonexistent allocation body manifest | **Closed by plan.** Admission v3 carries inline path/length/charge authority and recovery rejects external authority. |
| R10-PLAN-M1, global activation lock | **Closed by plan.** Lock scope is limited to bounded selector CAS and ends after genesis. |
| R10-PLAN-M2, activation engine fenced by its own rule | **Closed by plan.** Three route classes explicitly separate activation, ordinary authority, and operational access. |

## Gate decision

This was a static adversarial plan review. It independently inspected R4-R11,
R11-R17 test specifications, the current cumulative reservation source, the
base revision, maximum-charge arithmetic, bootstrap and crash edges, storage
authority, page schemas, route fences, lock order, compatibility, and test
adequacy. Historical R4 tests were not treated as fresh R11 implementation
evidence.

The R11/R17 implementation gate does **not** pass. Correct R11-PLAN-H1 through
H5 and R11-PLAN-M1/M2, freeze the revised plan/test hashes, and run a fresh
independent GPT-5.6 Sol adversarial review. Do not implement the changed
reservation contract before a review reports zero Critical, High, and Medium
findings.
