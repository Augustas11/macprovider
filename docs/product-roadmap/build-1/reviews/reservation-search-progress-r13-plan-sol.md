# Build 1 reservation search progress R13/R19 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: plan and test specification only. No source or test implementation was
authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 8 High, 2 Medium, 0 Low.**

R13/R19 closes several concrete R12 defects: the proposed page encodings now
fit 64 KiB, retained catalog generations have one apparent charge domain, the
intent/target/receipt ordering removes the R12 digest cycle, lifecycle identity
is row-keyed, and the EOF and post-fsync selector oracles are materially
clearer. It is still not implementable as written. The one-file log cannot
represent the advertised maximum on macOS, arbitrary-key B+ tree insertion
does not satisfy the claimed page/intent budgets, and the selector/intent
schemas cannot represent the plan's per-row or fixed-ledger accounting. The
external object taxonomy, deterministic recovery inputs, partial-append
authentication, rollback state machine, and exact codec set also remain open.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r13.md` | `82f77bedc27f37dece83bdfb13181abf31217f739dde01ff758c660b771d22cd` |
| `test-spec-r19-reservation-r13-corrections.md` | `721dbe79d8d18e2c1c4999f748ee5dd8575c2da237ed8c60a2d1f324557d9a82` |
| Failed R12 review | `58110df61aadb1cd5511cc10ab5a4c3d698c9bf731a5f63b5323f79c07872b37` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The current R4 reservation
source is unchanged from the durable checkpoint for the core reviewed files:
bindings `60abe294...`, evidence `b49c13fa...`, reservation migration
`c8505d5d...`, retention `0a6b4873...`, storage `33cf0850...`, and
transactions `65cbb0e9...`. Current source still uses the existing active-index,
sidecar, whole-file replacement, and reservation-migration implementation; it
does not implement selector v4, catalog slots, the three R13 indexes, or the
R13 recovery protocol. Existing R4 tests are therefore historical/current-R4
evidence, not implementation evidence for R13.

Independent arithmetic used by this review:

```text
U(Rmax)                         = 337,769,973,101,056 records/units
U(Rmax) * 65,572               = 22,148,252,676,182,444,032 bytes
largest signed 64-bit off_t    =  9,223,372,036,854,775,807 bytes
max full slots in signed off_t =        140,660,221,388,012
16 * 128^7                     =      9,007,199,254,740,992 entries
```

The page-size spot check reproduced the stated 1,865-byte maximum path entry
and 30,394-byte maximum 16-entry path leaf. The findings concern the complete
transition and authority design, not those two corrected encodings.

## Critical (0)

None.

## High (8)

### R13-PLAN-H1 — one catalog-log file cannot represent the promised maximum history on macOS

**Severity:** High. **Confidence:** High.

**Evidence.** R13 requires one file, one fixed 65,572-byte slot per protocol
record, `U(Rmax) = 337,769,973,101,056`, and no silent lowering of the stated
history bound (R13:31-64,82-113,662-679). Multiplying the exact values requires
`22,148,252,676,182,444,032` bytes before external objects. Signed 64-bit
`off_t` can address only `9,223,372,036,854,775,807` bytes, or
140,660,221,388,012 complete slots. R13 and R19 call conversion failure a local
qualification blocker (R13:123-126; R19:162-167), but this is deterministic for
the upper half of the advertised compatible domain on every target Mac, not a
machine-specific qualification uncertainty.

**Consequence.** A conforming implementation must reject supported histories
well below `Rmax`, contrary to the compatibility invariant, and cannot execute
the required last-passing maximum vector. Wide arithmetic does not make the
file offset or APFS file representable.

**Required correction.** Replace the one-file ordinal space with an exact
bounded shard/segment design whose selector, transcript, direct addressing,
identity, charging, rollover, crash recovery, and FD proof cover `Rmax`; or
normatively reduce the supported source-row/history contract and reopen the
product compatibility decision. Add last-slot/first-rollover, maximum-segment,
and final representable history vectors on the actual host ABI. A guaranteed
architecture limit cannot be accepted as a qualification-only test result.

### R13-PLAN-H2 — arbitrary-key B+ tree insertion exceeds the stated page and budget equations

**Severity:** High. **Confidence:** High.

**Evidence.** Path and lifecycle indexes are ordered by hashes, so insertions
are not right-frontier appends (R13:259-345). R13 nevertheless counts every
path/lifecycle transition as at most eight replacement pages and says a split
creates one page at each level (R13:453-470,629-640). In a copy-on-write B+
tree, inserting into a full non-right-frontier leaf creates two successor leaf
pages. Each full ancestor likewise creates two successor pages until a
non-full parent absorbs the extra child. At height eight, a legal cascade below
a non-full root can require fifteen new pages; at height seven a root-growing
cascade creates fifteen pages. The receipt makes the corresponding reserve
edge sixteen records. R19 instead requires maxima nine/ten and rejects the
larger legal graph (R19:99-117). Storage-ordinal and sequence right-frontier
appends can reuse an unchanged full left page; arbitrary hash-key insertion
cannot.

**Consequence.** Valid path/lifecycle reserves fail the proposed test or are
published with missing split pages. The 96-page path and 24-page lifecycle
per-row ledgers undercharge legal cascades. An implementation that follows the
claimed eight-page bound will corrupt ordering/reachability or silently reject
source layouts admitted by preflight.

**Required correction.** Define the exact copy-on-write split/pivot/occupancy
algorithm for arbitrary keys and derive the maximum created pages for every
height and cascade. Recompute the 16-record edge proof and per-row category
budgets. Split an insertion across authenticated recovery-only continuation
edges if any required external object plus pages and receipt exceeds sixteen.
Add adversarial full-leaf/full-ancestor cascades, root growth, non-rightmost
insertion, duplicate/collision, death, and 64-helper races to R19.

### R13-PLAN-H3 — the selected schemas cannot enforce the claimed per-row and fixed ledgers

**Severity:** High. **Confidence:** High.

**Evidence.** R13 says every unit is attributed to one deterministic source-row
ordinal and category and that per-row category counters are stored/decremented
(R13:622-650). The exact intent's `sourceBudgetDebits` entries contain only
`category,units`; they contain no row ordinal or row range (R13:384-405,
599-603). The exact selector stores only aggregate `category,used,limit`
entries (R13:475-499). It has no per-row authority. The fixed ledger separately
claims selected sub-ledger counters, but the selector schema has no fixed
sub-ledger fields and section 7 gives those sub-ledgers no exact category names
or ordinals (R13:652-660). R19's independent simulator can count an idealized
ledger but cannot prove production selected the same row/category attribution
(R19:135-167).

**Consequence.** One row can consume another row's allowance, replay can move a
debit between rows, shared work cannot be proved charged to the lowest row, and
scale work can consume the fixed allowance without any selected-state
violation. The asserted 768 coefficient and 1,048,576 fixed cap are not
enforceable authority.

**Required correction.** Add an exact bounded selected budget authority keyed
by source-row ordinal and category, plus exact fixed sub-ledger enums/counters.
Bind each intent/receipt debit to those keys and define atomic updates,
inclusion/non-inclusion proofs, shared-range attribution, genesis import, and
replay behavior. Include its pages/records in every split, intent, FD, time,
capacity, and byte equation. Derive the coefficient from a closed
operation-by-operation transition table rather than category prose.

### R13-PLAN-H4 — the closed object taxonomy cannot represent inherited migration objects

**Severity:** High. **Confidence:** High.

**Evidence.** Storage and path entries are restricted to twelve object kinds
covering source certificates, a prepared artifact, receipt bodies, fixed
extents, and a migration directory (R13:217-233,273-285). Inherited R10-R12
work requires immutable raw-name blocks, name blocks, row blocks, run
manifests/row blocks, tree pages, row-verification blocks, and
storage-verification blocks. Their sequence entries continue to carry external
`blockSHA256`, `runSHA256`, and `pageSHA256` values (R12:346-368; R13:565-603),
so they did not all become catalog-log records. None has a legal R13 object
kind. The immutable-identity contract also says the shared `fileType` is the
literal `regular` while later describing directory identities, without a
closed directory value (R13:127-145).

**Consequence.** Required external work cannot enter the path/storage indexes,
be charged, or be verified at genesis. An encoder must invent object kinds and
identity semantics, violating closed decoding and making R19-01 impossible.

**Required correction.** Inventory every inherited external file and directory
kind and assign an exact object-kind, path/storage class, identity schema,
content/canonical-length/nullability rule, charge category, target binding, and
lifecycle rule. Alternatively move a named kind into the log and revise its
references and accounting explicitly. Freeze independent vectors for every
legal cross-product and reject every illegal cross-product.

### R13-PLAN-H5 — the intent does not contain enough target identity to make recovery deterministic

**Severity:** High. **Confidence:** High.

**Evidence.** Each planned edge names only an ordinal, edge kind, target index,
maximum counts/bytes, and a coarse target-binding enum (R13:393-405). It does
not name the target path key, storage ordinal, lifecycle row/key for each edge,
sequence collection/ordinal, source-row ordinal, or expected operation payload.
Those values determine the page/object bytes. A logical operation may contain
multiple path or sequence edges with the same enums. Nevertheless, recovery is
required to replay a pure codec from the base roots and embedded intent and
recompute byte-exact targets after process death (R13:724-735). The receipt is
created after the targets and therefore cannot make an ambiguous intent
deterministic.

**Consequence.** Two different valid target graphs share one permitted intent
preimage. Recovery must reread mutable source/checkpoint context and invent the
mapping, accept whichever tail exists, or protect a legitimately fsynced edge.
The promised intent-to-target graph is acyclic but not a complete commitment.

**Required correction.** Give every planned edge a complete preimage-independent
target descriptor: target key/ordinal/range, source-row attribution, object
kind/path binding, base proof/root, sequence collection and ordinal, and exact
operation input reference. Define derivation and creation order without future
digests. Add pairs of otherwise-identical multi-edge intents that differ in
only one target coordinate and require different intent IDs and byte-exact
recovery outcomes.

### R13-PLAN-H6 — partial-append recovery cannot authenticate the previously selected prefix

**Severity:** High. **Confidence:** High.

**Evidence.** Before append the selected stat identity can match the selector.
After any partial append, legitimate size, mtime, and ctime differ from that
base identity. R13 then says recovery validates the base identity, truncates an
arbitrary tail, and resumes (R13:724-733), but does not define how it
distinguishes a pure append from an overwrite inside the selected prefix plus a
tail. Rechecking device/inode/mode/owner/link is insufficient; rechecking the
old mtime/ctime is impossible after the legitimate append; and validating the
prefix transcript requires walking an arbitrarily large log, violating the
eight-second bounded-recovery contract. The one selected transcript is a
continuation value, not an authenticated random-access tree for old slots.
R19 mutates old bytes and tests tails separately but does not require the
combined overwrite-plus-partial-tail crash that exposes this ambiguity
(R19:56-77,205-220).

**Consequence.** Recovery can launder corruption of a previously selected
historical slot into a new stat identity, or it can make every ordinary partial
append crash unrecoverable. Current-root page checks do not cover superseded
selected records.

**Required correction.** Add bounded authenticated prefix membership (for
example, segment seals plus a selected Merkle/MMR index) or an enforceable OS
mechanism that makes writes below the selected offset impossible and is proved
across reopen/crash. Define exact recovery validation for every tail length and
metadata transition. Add overwrite of live and superseded prefix slots during
partial append, timestamp changes, truncation, and subsequent forward recovery
tests without a history scan.

### R13-PLAN-H7 — selected multi-edge work has no coherent cancel/abort transition

**Severity:** High. **Confidence:** High.

**Evidence.** R13 forbids deletion or truncation of selected log bytes and
allows only forward path/lifecycle states (R13:31-47,281-287,326-331,
780-785). Between edges it says recovery may perform a “protected rollback”
before an external object is indexed (R13:468-473), and cancellation must reach
a stable selector with no unaccounted tail (R13:737-742). No abort edge/state,
abort receipt, terminal pending-transaction state, compensating budget rule, or
external-file disposition is defined. Lifecycle reserve is already selected
on the first adoption edge; path entries may be reserved/materialized; neither
index permits rollback or an aborted terminal state. Truncating them contradicts
selected-prefix immutability, while leaving them selected prevents clearing the
pending transaction under the stable-selector rule.

**Consequence.** Cancellation or an unrecoverable later edge either leaks
reservation/quota and permanently blocks the transaction, deletes selected
authority, or exposes a partial object graph. The existing refund/abort
economics cannot be shown unchanged.

**Required correction.** Specify exact forward-only abort/abandon states and
receipts for every edge boundary, including lifecycle reserve disposition,
path/storage visibility, immutable external file retention/charge, budget
debits, retry identity, and when pending state may clear. Include those records
and index updates in all unit/intent/byte bounds. Add cancel, permanent failure,
and death tests after each selected edge, especially after lifecycle reserve,
external fsync, path bind, storage index, and path indexed.

### R13-PLAN-H8 — several objects still lack byte-exact closed codecs

**Severity:** High. **Confidence:** High.

**Evidence.** R13 calls the codecs closed but leaves normative bytes to
interpretation. `receiptTranscriptSHA256` has no domain or preimage and its
placement raises an unresolved self-inclusion question (R13:413-436).
Selector `state`, activation `state`, operation-kind compatibility, target-work
reference variants, all root-range/count consistency rules, and many
activation/checkpoint null/phase combinations are deferred to “R10-R12
monotonic state/result rules” without an exact transformed table
(R13:475-563). Section 6 applies name-based transformations such as replacing
every `*SequenceRootSHA256` or catalog-record `*SHA256`, but does not publish
the resulting literal schema tables or distinguish external digests from log
references for every field (R13:565-611). The sequence maximum is asserted
from a generic 3,072-byte cap even though R19 requires exact per-collection
vectors. The directory identity conflict in H4 is another concrete codec
ambiguity.

**Consequence.** Independent encoders can produce different receipt digests,
null matrices, reference shapes, and phase authority while satisfying the
prose. Crash recovery and compatibility decoding cannot prove byte equality.
R19-01/R19-03 cannot be implemented independently without consulting or
inventing production choices.

**Required correction.** Publish literal field/type/nullability/enum/limit
tables and digest/transcript preimages for every final R13 schema and nested
object. Give each activation/checkpoint phase an exact legal matrix, enumerate
every transformed R12 field explicitly, and define the receipt transcript
without self-reference. Generate minimum, maximum, one-over, and illegal-cross-
field vectors from those tables with an independently reviewed encoder.

## Medium (2)

### R13-PLAN-M1 — the stated path-index capacity is arithmetically false

**Severity:** Medium. **Confidence:** High.

**Evidence.** R13 states `16 * 128^7 = 72,057,594,037,927,936`
(R13:296-301). The exact product is `9,007,199,254,740,992`, eight times
smaller. It still exceeds the proposed maximum unit count, but it equals
`2^53`, one above the largest JCS-safe integer even though page/root counts are
declared safe integers.

**Consequence.** The normative capacity claim and maximum-full-tree vector are
wrong, and an independent implementation may admit an unencodable entry count.

**Required correction.** Correct the equation, cap representable entry counts
at both the product and `2^53-1`, and freeze the last safe/first unsafe root
vectors. Recompute all path height and occupancy claims from the corrected
value.

### R13-PLAN-M2 — R19 omits the adversarial cases needed to prove its new architecture

**Severity:** Medium. **Confidence:** High.

**Evidence.** R19 requires the plan's stated nine/ten-record index maxima rather
than independently deriving arbitrary-key split cascades (R19:99-117). It
allows `off_t` failure to remain a qualification blocker instead of proving the
normative maximum (R19:162-167). It does not require per-row selected-budget
proof, fixed sub-ledger decoding, external object-kind coverage, ambiguous
same-enum planned edges, combined prefix overwrite plus partial append, or a
cancel/abort oracle at every selected multi-edge state. These are exactly the
trust and recovery boundaries introduced by R13.

**Consequence.** The proposed suite can pass while the High findings above
remain in production. Passing would not prove grandfathered capacity, exact
accounting, crash recovery, or safe cancellation.

**Required correction.** Add the concrete negative and maximum-shape cases from
H1-H8, and require production selected-state evidence rather than simulator-only
accounting. Keep host/hardware blockers separate from a passed normative
capacity test.

## Low (0)

None.

## Disposition of the R12 findings

| Prior finding | Disposition in R13/R19 |
|---|---|
| R12-PLAN-H1 — page geometry over 64 KiB | **Resolved for the listed page encodings.** Spot checks reproduce the path maxima. H2 requires new split-count equations; H8 still requires complete per-schema vectors. |
| R12-PLAN-H2 — retained catalog versions unaccounted | **Partially resolved.** One selected prefix gives a coherent one-file charge, but H1 makes the file unrepresentable at the promised bound and H6 leaves crash-time prefix authentication unresolved. |
| R12-PLAN-H3 — digest cycle | **Resolved as a dependency direction.** Intent → targets → receipt → selector is acyclic. H5 shows the intent is not yet a complete deterministic target commitment; H8 identifies an undefined receipt transcript. |
| R12-PLAN-H4 — bind edge over sixteen | **Partially resolved.** Splitting indexes/sequences is sound in principle, but H2 shows arbitrary-key insertions do not obey the claimed page maxima and H7 lacks terminal abort states. |
| R12-PLAN-H5 — replacement schemas not independently encodable | **Open.** H4 and H8 identify missing object kinds, contradictory identity semantics, undefined transcript bytes, and incomplete final schema matrices. |
| R12-PLAN-H6 — final nonempty directory batch rejected | **Resolved at plan level.** The two-zero lookahead and rewind path now selects the final nonempty block. |
| R12-PLAN-H7 — coefficient not derived | **Open.** H2/H3 show omitted page work and no selected per-row/fixed-ledger authority. |
| R12-PLAN-H8 — no bounded lifecycle uniqueness lookup | **Resolved in lookup shape.** The row-keyed authenticated index supplies bounded inclusion/non-inclusion. H2/H3 still invalidate its update and accounting proof. |
| R12-PLAN-M1 — post-fsync selector rollback accepted | **Resolved at plan level.** R13/R19 require new-only after directory fsync and reopen. |

## Approval decision

The implementation gate remains closed. R13/R19 has **8 High and 2 Medium**
findings, so it does not meet the required zero Critical/High/Medium threshold.
No finding was downgraded to obtain a pass, no acceptance criterion was
weakened, and no source/test implementation is authorized by this review.

