# Build 1 reservation search progress R14/R20 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: exact R14 plan and R20 test specification, inspected independently
against R4–R13 and the current Swift reservation implementation. No source or
test implementation was authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 7 High, 2 Medium, 0 Low.**

R14 makes real progress. Immutable bounded batch carriers remove R13's
single-file `off_t` failure, the arbitrary-key B+ tree page counts now include
full copy-on-write split cascades, record references bind batches and slots,
and the external intent prevents the fixed selector extent from becoming a
descriptor-size bottleneck. The gate nevertheless remains closed. The
multi-edge intent has a cross-edge digest cycle, the budget reservation cannot
yet represent or authorize its own state transitions, the advertised unit
limits still lack a closed derivation, and several supposedly exhaustive
schemas and lifecycle transitions contradict one another. The crash oracle also
covers only the batch sub-protocol, not the intent, external-object, directory,
and budget publications on which recovery depends.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r14.md` | `465956bd3112649956d0de79b765c9ce5e1580c215f6d4696174bd804676d1ca` |
| `test-spec-r20-reservation-r14-corrections.md` | `401d82c4b31a573e05aa1ade6a12881616e474130929a112e3e05616179b21da` |
| Failed R13 review | `f9875f9f279f7029410eb4725ebffbf9d7baeabc857126aa0d15bfaed0f6004a` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The current R4 source remains the
frozen implementation: bindings `60abe294...`, evidence `b49c13fa...`,
reservation migration `c8505d5d...`, retention `0a6b4873...`, storage
`33cf0850...`, and transactions `65cbb0e9...`. It still stores an array-based
`model_catalog_active_index.v4` and reservation progress array
(`ModelCatalogTransactionRetention.swift:6-30`,
`ModelCatalogTransactionReservationMigration.swift:65-78`), scans the legacy
directory during bootstrap (`ModelCatalogTransactionRetention.swift:146-160`),
and uses sorted-key `JSONEncoder` rather than the proposed independent RFC 8785
codec (`ModelCatalogTransactionRetention.swift:114-125`). No selector v5,
batch/MMR, authenticated budget tree, intent v2, or continuation engine exists
in current source. Existing R4 tests therefore remain evidence for the old
implementation only; they cannot approve R14.

Independent arithmetic reproduced the corrected values:

```text
16 * 128^7                         = 9,007,199,254,740,992
safe admitted count                = 9,007,199,254,740,991
8,192 * 439,804,651,110 + 8,388,608
                                    = 3,602,879,710,281,728 < 2^52
minimum one-record batch            = 8,228 + 65,572 = 73,800 bytes
maximum sixteen-record batch        = 8,228 + 16*65,572 = 1,057,380 bytes
```

## Critical (0)

None.

## High (7)

### R14-PLAN-H1 — later edges reintroduce an intent-to-target digest cycle

**Severity:** High. **Confidence:** High.

**Evidence.** The intent ID hashes the complete intent and every planned-edge
descriptor (`R14:323-355`). Target pages bind that intent ID (`R14:353-357`).
Each descriptor contains an exact `baseRootReference` (`R14:333-351`). R14 then
requires all affected budget keys to be updated through separate single-tree
edges (`R14:274-282`), and other logical transactions likewise advance path,
lifecycle, storage, sequence, work, and phase roots over multiple edges. The
second update of the same tree must use the first edge's newly created root as
its base. That root reference contains the digest of a page whose bytes contain
the intent ID. The dependency is therefore:

```text
intent ID -> later descriptor -> prior target root digest -> prior page bytes
          -> intent ID
```

Using the original selected root for every edge would break sequential update
semantics and lose the earlier update. R20's cycle test checks only the stated
coarse order `intent -> target -> receipt -> batch -> selector`
(`R20:23-25`); it does not require a two-edge same-tree vector that exposes this
back-edge.

**Consequence.** A canonical intent cannot be constructed for the mandatory
multi-key budget reservation or any multi-edge same-tree mutation. An
implementation must iterate a digest, omit the actual prior root, reread
mutable state, or silently split one logical intent into a different protocol.
Crash replay cannot reproduce byte-identical targets from the specified
preimage.

**Required correction.** Remove digest-bearing later-edge base references from
the intent dependency graph. One valid design would reference an earlier
planned output by `(edgeOrdinal,targetIndex)` and define its root digest as a
derived runtime value that is excluded from the intent preimage; another would
make every root-changing edge a separately selected intent. Freeze the exact
construction order and prove it with two and 64-edge same-tree vectors whose
pages bind the final intent ID. Extend the cycle analyzer to traverse every
nested root/reference edge, rather than only schema classes.

### R14-PLAN-H2 — budget reservation has neither a prior authorization path nor a complete selected lease state

**Severity:** High. **Confidence:** High.

**Evidence.** R14 says a budget reserve must occur before an operation writes
target bytes, yet that reserve itself emits budget-tree pages, batch records,
receipts, and a lease (`R14:274-289`). No already-selected allowance or exact
bootstrap edge authorizes those bytes before the new budget root and lease are
selected. The external intent is also written, fsynced, selected, charged, and
counted before the budget reserve (`R14:359-369`), directly contradicting the
before-write rule.

The selected `budget_leaf.v1` has only `used`, `limit`, `generation`, and
`lastTransactionIntentID` (`R14:268-272`). It has no leased, consumed, released,
or aborted counters, although the plan requires unused lease units to be
decremented and aborted units to be incremented (`R14:287-289`). The immutable
`budget_lease.v1` record has a state and counters (`R14:534`), but R14 never
defines its successor-generation chain, which record reference is current, or
how a leaf proves the sum of live leases. A selected partial multi-key reserve
can therefore have updated budget leaves without a selected lease that explains
them.

**Consequence.** A crash or cancellation during budget reservation can leave
selected protocol bytes without prior quota authority, double-release a lease,
or make `used` indistinguishable from reserved, consumed, and abandoned units.
The budget tree cannot prove that selected carrier work was authorized before
materialization, which is the central storage/economic trust boundary of this
migration.

**Required correction.** Define a nonrecursive authorization seed for intent
and budget-control publications, with an exact fixed or previously selected
key and a closed maximum. Give each budget key selected counters for every
state needed by the equations, or define an authenticated lease index and a
byte-exact invariant that derives those counters. Specify immutable lease
successors, current-reference selection, partial multi-key reserve recovery,
and atomic release/consume rules. Add crashes after every budget page and lease
publication, including the first-ever row and fixed-key bootstrap, and require
production selected bytes to balance before any ordinary target is written.

### R14-PLAN-H3 — the 8,192-per-row and fixed ceilings remain assertions rather than closed worst-case derivations

**Severity:** High. **Confidence:** High.

**Evidence.** The category table arithmetically sums to 8,192, but its
transition counts are not derived from the final R14 state machine
(`R14:291-319`). For example, `transaction` assumes 64 events at eight units,
while a legal arbitrary-key update alone can select nineteen units and its
budget-tree update can itself split across continuation batches
(`R14:243-257`). The table does not map each R14 operation kind and every
register/materialize/bind/index/phase/abandon successor to its target pages,
budget pages, receipts, external objects, intent, carrier charge, and retry
maximum. “Six,” “forty,” “twelve,” and “sixty-three” transitions are asserted
without a reachability proof from the phase graph. The fixed table is only a
list of ten numbers (`R14:307-309`).

R20 samples a maximum path, lifecycle, storage, merge, tree, verification,
phase, crash, and abandon case (`R20:121-126`) but does not enumerate every
reachable operation/phase/provenance/cascade product and independently sum its
actual selected production graph. A sample cannot prove the global coefficient
or fixed allowance.

**Consequence.** A legal source history or recovery path can exhaust a category
before completion even though preflight admitted it, or a malicious sequence
can consume more selected pages than the authoritative budget permits. Treating
that failure as host qualification would incorrectly hide a deterministic
protocol undercount.

**Required correction.** Publish the closed transition graph and a literal
operation table. For every legal transition, state its maximum call count per
row/fixed activation, target-tree height/cascade, continuation count, budget
self-update count, intent/external/receipt count, and abandon/retry allowance.
Derive each category limit and both totals from that table with checked wide
arithmetic. R20 must exhaustively generate all legal transition rows and the
first-over-budget path, then compare the independent sum with the selected
production budget tree.

### R14-PLAN-H4 — the exhaustive external-object taxonomy contradicts its codecs and budget classes

**Severity:** High. **Confidence:** High.

**Evidence.** Section 6 classifies `run-manifest` as an external immutable file
with storage ordinal and identity (`R14:450-456`), while section 8 defines
`run_manifest.v4` as a catalog work/control record with the common record
coordinates (`R14:521-533`). The sequence registry also references a run by
external `runSHA256,storageOrdinal,immutableIdentitySHA256` (`R14:551-554`). It
is impossible to tell whether there are one or two authoritative run-manifest
objects and which bytes the reference authenticates.

The allegedly closed budget column introduces `transaction-bytes` and `fixed
transaction`, neither of which is one of the ten exact budget category literals
(`R14:291-309,457-464`). Directories require null length/content digest
(`R14:176-189,466-470`), but the supposedly exact storage and path entries list
`objectSHA256,canonicalLength` without a directory nullability matrix
(`R14:580-587`). The taxonomy also uses `source-capture/merge` for `row-block`
without an exact discriminator selecting one category (`R14:452`).

**Consequence.** Two independent encoders can charge, index, and authenticate
different objects while satisfying different parts of R14. A run can be
double-stored or omitted, directory entries cannot be closed-decoded, and a
carrier or fixed extent can consume a budget category that does not exist.
R20-07 cannot freeze an expected legal cross-product from this source.

**Required correction.** Assign every physical object exactly one carrier
class and exactly one canonical content schema. Remove the duplicate
run-manifest representation or distinguish two kinds and bind them explicitly.
Replace every prose budget label with a closed category/scope key, give
row-block a deterministic discriminator, and publish the complete null/type
matrix for regular files, directories, carriers, and fixed extents in storage,
path, receipt, and planned-object records. Recompute charge/accounting vectors
after the taxonomy is unique.

### R14-PLAN-H5 — the “literal codec registry” still requires implementers to invent normative bytes

**Severity:** High. **Confidence:** High.

**Evidence.** `transaction_intent.v2` names `plannedBudgetDebits`, but R14 gives
that nested object no exact field list, ordering, count bound, scope rule, or
encoding (`R14:323-351`). `plannedEdges` similarly has no normative 1–64 bound
after R14 replaces R13; R14 only remarks that 64 descriptors need not fit the
selector, while inherited R12 states a different 16-entry intent ceiling
(`R14:359-365`; `R12:463-468`). The edge-kind and target-index enum is not
updated for `budget-reserve`, `continuation`, and `abandon`. The receipt's
`targetWorkRootReference` union, pending transaction's continuation/lease
references, page-record envelopes and transcript preimages, path/storage entry
nulls, lifecycle/path state compatibility, and selector/activation/checkpoint
reference types are not enumerated byte-exactly (`R14:384-432,513-647`).

R20-01 demands an independent encoder sharing no production helper
(`R20:10-25`), but it cannot generate one unique vector for these missing
objects and states. Saying “same exact envelope” or inheriting nonconflicting
R4–R12 rules does not resolve a case where R14 changed the field graph, version,
or enum.

**Consequence.** Independent implementations can produce different intent IDs,
page digests, pending-state selectors, phase legality, and recovery outcomes.
The acceptance oracle would have to consult production code or choose new
rules, invalidating its independence.

**Required correction.** Publish literal field/type/nullability/enum/limit and
digest-preimage tables for every nested object and union introduced or changed
by R14. Resolve the 16-versus-64 edge limit expressly. Enumerate operation and
edge kinds, target indexes, every reference variant, all page/root fields, and
all legal selector/activation/checkpoint/pending combinations. Require minimum,
maximum, one-over, unknown-field, and every illegal single-field cross-product
vectors before production codec work begins.

### R14-PLAN-H6 — the crash oracle omits the publications surrounding the batch protocol

**Severity:** High. **Confidence:** High.

**Evidence.** The normative crash table begins only after pending intent has
already been selected and covers temp batch through selector reopen
(`R14:656-678`). It does not define restart authority for intent-file create,
write, fsync, exclusive rename, intent-directory fsync, identity recapture, or
the selector update that first selects pending state (`R14:359-369`). It also
omits activation/batch/intent/materialization directory creation, external
object publication, path/storage indexing, budget-tree and lease publication,
and final intent storage/path indexing. Section 7 supplies desired semantic
destinations, but not old/candidate/new disk outcomes or exact adoption rules
at those filesystem boundaries (`R14:475-511`).

R20 mentions intent and external-object crash injection (`R20:100-112,
155-173`) but has no normative boundary table against which to decide whether a
candidate is removed, adopted, retained-abandoned, protected, or selected.

**Consequence.** Recovery can adopt an alien same-path intent/object, delete a
durable but unreferenced object that should remain charged, double-charge it,
or expose a selector whose referenced directory entry was not durable. The
batch-only table is insufficient to prove whole-transaction crash safety.

**Required correction.** Extend the old/candidate/new restart table to every
filesystem and selector boundary for intent, directory, external object,
budget/lease, path/storage, batch, and final phase publication. State the exact
identity/path/descriptor comparison, durability precondition, charge state,
and only legal forward successor at each boundary. Add same-path unequal,
inode-replacement, missing-after-fsync, and stale-selector outcomes to R20 for
each class.

### R14-PLAN-H7 — forward abandon contains unencodable and contradictory terminal states

**Severity:** High. **Confidence:** High.

**Evidence.** The abandon table says a reserved/materialized/bound path becomes
state `abandoned` and a storage-indexed/path-not-indexed case also sets the path
state to `abandoned` (`R14:480-489`). The closed path enum contains no such
state; it contains `retained-abandoned` (`R14:499-503`). It says a continuation
receipt is “marked continuation abandoned,” but continuation receipts are
immutable and there is no exact abandon-successor reference or state schema
(`R14:243-257,374-406,480-484`). A lease-only abandon receipt must release the
lease, yet H2's selected budget/lease state cannot represent that transition.
The selector can clear pending only after an abandon receipt, but no exact
mapping says which ordinary roots advance to the compensating path/lifecycle/
storage/budget roots and which remain at the transaction base.

The economic rule is also not byte-exact at the boundary: the table says a
lifecycle-reserved state releases the economic reserve, while the prose limits
release to the “unspent” lifecycle reserve without defining when reserved or
bound becomes spent (`R14:482-505`). R20 asks for “the exact forward successor”
(`R20:155-173`), but more than one incompatible successor satisfies the prose.

**Consequence.** Cancellation and permanent failure can leave a pending
transaction uncleared, release an already consumed reserve, hide a selected
object without selecting the compensating root, or fabricate a state rejected
by the closed decoder. This can alter inherited A3–A8 refund/settlement
behavior despite the plan's compatibility assertion.

**Required correction.** Publish an exact abandon receipt/successor schema and
a complete state-transition table for each selected edge/chunk boundary. Use
only declared enum literals. For every row give the base and successor root
references, lease counters, lifecycle reserve/spent/release delta, path/storage
visibility, retained charge, pending-clear condition, and retry generation.
Map those byte-exact transitions to the inherited A3–A8 equations and freeze
vectors for classified/unclassified and every provenance.

## Medium (2)

### R14-PLAN-M1 — MMR work limits and the maximum-shape oracle disagree

**Severity:** Medium. **Confidence:** High.

**Evidence.** R14 first says membership needs at most 51 merge steps, then sets
and describes a 53-step limit (`R14:30-46,149-165`). More materially, that
limit is per record lookup. An eight-page B+ lookup can require a membership
proof for every page, and each proof can hash a full 1,057,380-byte batch and
open merge-event batches. R20-10 instead requires “53 MMR steps” for the whole
operation alongside eight B+ page reads (`R20:201-205`). It neither measures
the per-page proofs nor states an aggregate bound for a lookup, update,
continuation, or recovery operation.

**Consequence.** The maximum-shape test can reject a correct per-record
implementation, or pass an implementation that performs hundreds of
unmeasured batch hashes and misses the eight-second/RSS requirement. The result
would not establish bounded authenticated lookup.

**Required correction.** Choose the exact peak/merge maximum and distinguish
per-record from per-operation counts. Derive aggregate batch opens, bytes
hashed, membership merges, and page reads for every operation class, including
17-page continuations and recovery. Instrument R20 against those exact bounds
and retain the eight-second test as measured hardware evidence rather than
silently changing the algorithmic count.

### R14-PLAN-M2 — R20 addresses one batch ordinal beyond the protocol maximum without a required outcome

**Severity:** Medium. **Confidence:** High.

**Evidence.** `U(Rmax)` is the maximum protocol-unit count. Even in the
worst case of one record per batch, legal zero-based batch ordinals end at
`U(Rmax)-1`. R20-02 nevertheless asks address derivation at both
`U(Rmax)-1` and `U(Rmax)` without saying the latter must be rejected
(`R20:38-51`). R14 separately allows the filename codec up to `2^53-1`
(`R14:72-77`), so a path codec alone would accept the impossible extra batch.

**Consequence.** Two conforming tests can disagree on whether the one-over
history is a valid sparse address or the required first failure. This weakens
the maximum-format proof that replaced R13's `off_t` defect.

**Required correction.** Separate filename-domain vectors from protocol-history
vectors. Require `U(Rmax)-1` as the last legal worst-case history ordinal,
`U(Rmax)` as the first protocol-history rejection, and `2^53-1`/`2^53` as the
independent filename/JCS boundary. State that sparse metadata proves addressing
only, not selected history or physical capacity.

## Low (0)

None.

## Disposition of the R13 findings

| Prior finding | Disposition in R14/R20 |
|---|---|
| R13-H1 — one catalog file exceeds `off_t` | **Resolved at the carrier-address level.** Bounded immutable batches are individually representable. R20's final history boundary remains ambiguous under M2. |
| R13-H2 — arbitrary-key B+ page count | **Resolved at the local algorithm level.** The 17-page root-growing cascade and 14+3 continuation are correct. H1 prevents the required multi-edge root graph from being constructed as specified. |
| R13-H3 — selected per-row/fixed authority absent | **Open.** A budget tree now exists, but H2/H3 show its lease state, authorization order, and category ceilings are not closed. |
| R13-H4 — external taxonomy incomplete | **Open.** More object kinds are listed, but H4 identifies contradictory run-manifest representations, undefined categories, and directory null rules. |
| R13-H5 — target descriptors incomplete | **Open.** Coordinates are materially improved, but H1 finds a cross-edge cycle and H5 finds missing nested codec/enum bounds. |
| R13-H6 — selected prefix unauthenticated | **Resolved in architecture direction.** Immutable batches plus an MMR remove partial append/truncation. M1 requires exact aggregate proof-work bounds. |
| R13-H7 — no coherent abort transition | **Open.** Section 7 adds forward states, but H6/H7 show missing crash rows and unencodable successors. |
| R13-H8 — codecs not closed | **Open.** The literal tables are much better, but H4/H5 list objects for which an independent encoder must still invent bytes or legality. |
| R13-M1 — false tree capacity | **Resolved.** R14 uses the correct `16*128^7` value and caps at `2^53-1`. |
| R13-M2 — missing adversarial proof | **Open.** R20 adds most requested families, but H1-H7 and M1-M2 identify acceptance oracles that still cannot prove the claims. |

## Approval decision

The implementation gate remains closed. R14/R20 has **7 High and 2 Medium**
findings and therefore does not meet the required zero
Critical/High/Medium threshold. No finding was downgraded to obtain a pass, no
acceptance criterion was weakened, and no source/test implementation is
authorized by this review.
