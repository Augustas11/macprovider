# Build 1 reservation search progress R12/R18 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: plan and test specification only. No source or test implementation was
authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 8 High, 1 Medium, 0 Low.**

R12/R18 makes real progress: the wide integer is closed, the selector is no
longer incorrectly tied to its bootstrap inode, the path registry introduces a
bounded lookup shape, and the directory cursor now names concrete syscalls and
buffers. The proposal still cannot be implemented as written. Its storage-node
geometry exceeds the retained page limit, persistent catalog metadata has no
coherent retained-byte accounting, the phase transaction contains a digest
cycle, and a maximum bind edge exceeds the sixteen-entry ceiling. The promised
independent encoders also still lack exact schemas, the maximum-history
coefficient is asserted rather than derivable, lifecycle-key uniqueness has no
bounded selected index, and the directory algorithm rejects the ordinary case
where a nonempty final batch is followed by EOF.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r12.md` | `8ad7d3780b58177afb62383a46cc4be97d6c400cb6d57a91bd2241d6f1648375` |
| `test-spec-r18-reservation-r12-corrections.md` | `5924589af7ed8d41fe94bbd0189ed030524594a9a7dd8d79a7c57dd43bc6a459` |
| Failed R11 review | `e408b41b5062099ec4cb17901dfcc6e462ad203bf675e87c381caaf3e5232b63` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The current R4 reservation source
hashes still match the durable checkpoint, including bindings `60abe294...`,
evidence `b49c13fa...`, reservation migration `c8505d5d...`, retention
`0a6b4873...`, and transactions `65cbb0e9...`. Current production source still
uses the pre-R12 active-index and migration structures
(`ModelCatalogTransactionRetention.swift:6-39,109-145` and
`ModelCatalogTransactionReservationMigration.swift:48-112`). This review did
not treat any proposed R12 codec or state as implemented evidence.

The stated maximum arithmetic was recomputed:

```text
512 * 439,804,651,110 + 1,048,576 = 225,179,982,416,896 objects
upper-bound expression             = 948,584,186,728,694,423,552
2^70                               = 1,180,591,620,717,411,303,424
```

The arithmetic expression fits `wide-v1`; the findings below concern whether
the plan defines the terms and structures needed to make that expression true.

## Critical (0)

None.

## High (8)

### R12-PLAN-H1 — the storage catalog's required fanout cannot fit its required page limit

**Severity:** High. **Confidence:** High.

**Evidence.** A storage internal node must have up to 256 children and remain
at most 65,536 bytes. Each child carries three counters/range values, a
64-character digest, six `wide-v1` subtotals, and `selfChargeBytes`
(`reservation-search-progress-addendum-r12.md:135-149`). The canonical minimum
`wide-v1` object is already 79 bytes. Even ignoring every JSON key, separator,
counter, `selfChargeBytes`, and containing-node field, six wide values plus the
digest require `(6 * 79 + 64) * 256 = 137,728` bytes. The actual minimum child
encoding is therefore more than twice the page ceiling. R18 nevertheless
requires 255/256/257-fanout vectors and the 65,536-byte limit simultaneously
(`test-spec-r18-reservation-r12-corrections.md:46-54`).

**Consequence.** There is no conforming maximum-fanout node encoding. The first
independent codec vector must fail, so catalog height, read bounds, intent
counts, and maximum-history capacity derived from fanout 256 are invalid.

**Required correction.** Choose a fanout proved from the exact maximum
canonical child encoding and retain the 65,536-byte page ceiling, then
recalculate height, page-touch bounds, object-count bounds, intent cardinality,
and maximum sparse vectors. Freeze exact minimum and maximum node bytes before
implementation. Apply the same byte proof to path-registry and sequence nodes;
do not rely on entry-count fanout alone.

### R12-PLAN-H2 — superseded catalog pages are retained but cannot be represented by the selected catalog totals

**Severity:** High. **Confidence:** High.

**Evidence.** The catalog is persistent, catalog pages/roots are chargeable,
and those pages self-account rather than appear as storage entries
(`R12:112-175`). Parent subtotals include current child self charges exactly
once (`R12:143-175`), while all selected objects and prior generations must
remain retained (`R12:636-637` and retained R11 section 7.1). Each append
replaces a right-frontier page and the catalog root. The superseded page and
root remain on disk, but neither is an entry in the successor tree. If the
successor subtotal equals its current children, those retained bytes disappear
from accounting; if it carries the old bytes cumulatively, R18's required child
subtotal equality is false (`R18:46-54`). The history digest/count does not
provide a catalog of superseded page paths, identities, or charges.

**Consequence.** Exact physical/logical agreement at `ready` cannot hold after
the first catalog update. Production must leak uncharged selected metadata,
double-count live pages, walk historical generations, or delete selected
authority contrary to the retained contract.

**Required correction.** Define one cycle-free selected authority that names
and charges every retained catalog page/root version with bounded membership
and verification. Specify whether old metadata is live inventory or safely
collectible; if collectible, revise the retained-authority contract with an
independently proved grace/rollback boundary. Recompute catalog subtotals and
add a multi-generation right-frontier replacement oracle that reconciles every
physical protocol byte without a history walk.

### R12-PLAN-H3 — the phase transaction and its target objects form an uncomputable digest cycle

**Severity:** High. **Confidence:** High.

**Evidence.** The selected phase transaction's `targetBindingsSHA256` commits
every intended work root, checkpoint, activation, and phase change
(`R12:430-436,467-470`). Run, tree, and verification work roots in turn contain
`phaseTransactionRootSHA256` (`R12:393-428`), and the checkpoint contains
`activePhaseTransactionSHA256` (`R12:213-236`). Thus the transaction digest
depends on target object digests that depend on the transaction digest. The
plan provides no preimage-independent transaction identifier or staged binding
that breaks this cycle. R18 asks an independent encoder to freeze these bytes
without defining a computable order (`R18:81-94`).

**Consequence.** A conforming writer cannot construct the first transaction
and target graph. Choosing placeholder, iterative, or mutable digests would
create different authority across implementations and break recovery binding.

**Required correction.** Introduce a byte-exact immutable transaction intent
identifier that does not depend on target object digests, or define a one-way
staged graph in which target objects bind that intent and a later transaction
successor binds their final digests. Publish every digest formula and creation
order, and add independent cycle-detection plus minimum/maximum vectors.

### R12-PLAN-H4 — the maximum bind edge exceeds the sixteen-entry ceiling

**Severity:** High. **Confidence:** High.

**Evidence.** A bind changes one maximum-height path-registry entry to `bound`
and appends a prepared-binding record (`R12:480-483`). The registry update can
create eight pages plus a root (`R12:285-302`). The prepared-binding collection
uses the persistent sequence envelope (`R12:446-457`); at maximum height its
append creates eight pages plus a root under the retained R11 sequence rules.
Adding the phase-transaction successor yields at least 19 permanent objects,
before any other binding/control object. The claimed twelve-entry maximum
counts “one prepared binding” rather than its sequence pages and omits the
simultaneous registry path (`R12:498-504`). R18 repeats the twelve-entry claim
without an independent per-edge object equation (`R18:96-120`).

**Consequence.** A legal maximum-depth bind cannot be selected. Splitting it
ad hoc can expose a bound registry state without its binding record, or a
binding record without the registry state, after death.

**Required correction.** Split registry binding and prepared-binding sequence
append into explicit independently useful transaction states, or replace one
structure with a single authenticated transition that fits. Enumerate every
created permanent object, including all path, sequence, catalog, transaction,
and control successors, at every height. Add death and 64-helper races at each
new split edge and prove each intent has at most sixteen entries.

### R12-PLAN-H5 — the replacement schemas are still not independently encodable

**Severity:** High. **Confidence:** High.

**Evidence.** Several objects called “exact” still use prose rather than exact
JSON contracts. Storage-node children are described as “first ordinal” and
“page digest” without literal field names (`R12:140-145`). The path-registry
root similarly says “top page digest,” and its children say “first key/last
key/page digest” (`R12:285-298`). `activation_catalog_continuation.v1` lists
“activation UUID,” “target key/ordinal,” and “next level” without literal keys,
types, enum values, nullability, size limits, or a digest/transcript formula
(`R12:489-496`). The four added sequence collection kinds for cursor, head,
planned object, and prepared binding are never given literal `collectionKind`
values (`R12:446-457`). `rowCanonicalBytes` has no JSON representation or byte
limit, and `targetBindingsSHA256` has no closed preimage object/schema. Root,
leaf, and node transcript construction also does not say which ordered entry or
child digests are appended.

**Consequence.** Independent production and test encoders must invent field
names, byte representations, enum strings, and transcript preimages. Canonical
digests and recovery authority will diverge even before the digest cycle is
addressed. R18-04 cannot produce the required independent vectors.

**Required correction.** Publish complete literal field tables, JSON types,
nullability rules, enums, bounds, collection/entry pairs, and transcript
preimages for every R12 object and nested entry. Define byte fields (for
example, canonical base64 or structured JSON) and exact maximum lengths. Freeze
independent minimum, maximum, and one-over canonical vectors for every schema.

### R12-PLAN-H6 — the directory cursor rejects a normal nonempty final batch

**Severity:** High. **Confidence:** High.

**Evidence.** EOF is recognized only when the main batch returns zero twice
(`R12:601-602`). After any nonzero batch, step 6 treats the call as non-EOF and
requires lookahead to return at least one record (`R12:603-608`). When the main
batch consumed the last 1–32 directory records, the lookahead correctly returns
zero. The algorithm calls this unsupported instead of selecting the final raw
block and EOF. R18 covers “EOF double-zero,” but has no required case for a
nonempty batch followed immediately by zero lookahead (`R18:138-161`). Its 1,
31, and 32-entry cases cannot pass the written production algorithm.

**Consequence.** Every finite directory whose last records fit in the main
buffer fails before v4. The name scan cannot reach its terminal state on an
otherwise supported filesystem.

**Required correction.** Define zero lookahead plus an unchanged offset as the
candidate EOF transition, including whether a confirming second zero is
required and from which saved offset. Persist the nonempty final raw block and
EOF atomically. Add 1/31/32/exact-multiple final-batch vectors, mutation and
death after each EOF probe, and require no record loss or repeated selection.

### R12-PLAN-H7 — the grandfathered-scale object coefficient is not derived from a closed transition table

**Severity:** High. **Confidence:** High.

**Evidence.** R12 states eight category ceilings summing to 512 objects per row
and an additive 1,048,576 (`R12:67-83`), but supplies no operation-by-operation
table from which those values can be derived. It does not state how many
catalog versions, catalog-continuation versions, path-registry replacements,
phase-transaction successors, prepared-binding sequence pages, empty/final
objects, or protocol directories each row can create. H2 and H4 already show
omitted retained versions and pages. The exact upper-bound arithmetic at
`R12:86-96` therefore multiplies a claimed coefficient rather than a proved
complete count. R18 tells its oracle to “independently compute” the bound but
provides no normative inputs beyond the same category assertions
(`R18:27-44`).

**Consequence.** `Rmax` representability and the last-passing/first-failing
vectors cannot be independently reproduced. An implementation can exceed the
object or `2^120` bound while satisfying every specified local transition, or
reject a history that the plan promises remains compatible.

**Required correction.** Add the closed transition table required by the plan:
for every operation and source-row provenance, state exact maximum invocation
count and exact object/directory versions by kind, including all split and
recovery successors. Derive 512 and the additive constant algebraically from
that table after H1–H4 are corrected. Freeze independent totals for 0, 1,
`Rmax-1`, `Rmax`, and `Rmax+1`.

### R12-PLAN-H8 — lifecycle-key uniqueness has no bounded selected lookup authority

**Severity:** High. **Confidence:** High.

**Evidence.** A nonzero reserve is supposed to occur once per lifecycle key and
is derived partly from a prior path-registry inclusion proof
(`R12:525-546`). The path registry is keyed only by root-relative path and its
entry has no lifecycle key (`R12:279-305`). The storage catalog carries a
`lifecycleKey`, but it is ordered by storage ordinal and defines no bounded
lifecycle-key lookup (`R12:157-168`). At grandfathered scale, proving absence of
the same row/key at another path would require a catalog/history scan forbidden
by the eight-page and eight-second boundaries. R18 asserts second adoption and
alternate-key rejection without naming a selected proof structure capable of
making that decision (`R18:122-136`).

**Consequence.** Production cannot prove the one-reserve-per-row invariant in
bounded work. It can double-charge/reimport a lifecycle reserve, accept
conflicting classified/unclassified keys, or perform an unbounded scan.

**Required correction.** Add a selected authenticated lifecycle-key index with
closed inclusion/non-inclusion proofs and one-way state transitions, or key an
existing authenticated structure by a domain that includes lifecycle identity
and prove path uniqueness separately. Include classified/unclassified conflict,
same row at a different path, replay, collision, genesis import, and
maximum-height proof cases in the object-count and sixteen-entry derivations.

## Medium (1)

### R12-PLAN-M1 — the crash oracle permits selector rollback after durable directory fsync

**Severity:** Medium. **Confidence:** High.

**Evidence.** The selector CAS fsyncs the replacement and containing directory,
then reopens and verifies the installed bytes (`R12:257-266`). The plan also
rejects a rollback selector (`R12:268-275`). R18, however, says that at every
prepare, rename, directory-fsync, reopen, and next-call boundary, child death may
accept either the old or new complete graph (`R18:56-63`). Allowing the old
selector after the directory fsync/reopen boundary contradicts the durable CAS
and monotonic revision contract.

**Consequence.** A recovery implementation or test oracle may accept rollback
of selected progress and accounting after success was durably acknowledged,
masking a real persistence defect.

**Required correction.** Freeze boundary-specific outcomes: old only before
rename; old or new only in the explicitly justified rename-before-directory-
fsync crash window; new only after successful directory fsync and verified
reopen. Test a stale-but-complete old selector as rejection at every durable
post-fsync boundary.

## Low (0)

None.

## Disposition of the prior R11 findings

| Prior finding | Disposition in R12/R18 |
|---|---|
| R11-PLAN-H1 — maximum history outside accounting domain | **Open in substance.** `wide-v1` itself is closed and large enough, but H2/H7 show that the complete retained object count and rooted charge are not derived. |
| R11-PLAN-H2 — mutable selector invalidates frozen identity | **Resolved at plan level.** The fixed logical extent and live no-follow identity recapture avoid comparing later selectors to the bootstrap inode. M1 requires a stricter post-fsync oracle. |
| R11-PLAN-H3 — no bounded global path proof | **Partially resolved.** The path registry gives bounded path lookup, but H1/H4/H5 invalidate its maximum geometry and transition proof; H8 identifies the separate lifecycle-key lookup gap. |
| R11-PLAN-H4 — schemas not closed | **Open.** H5 lists remaining non-encodable objects and nested fields. |
| R11-PLAN-H5 — sixteen-entry cap incompatible with transitions | **Open.** H4 demonstrates a 19-object maximum bind edge before ancillary control. |
| R11-PLAN-M1 — lifecycle delta not normatively derived | **Partially resolved.** The numeric table and provenance mapping are explicit, but H8 leaves global uniqueness and bounded prior-state proof undefined. |
| R11-PLAN-M2 — directory cursor/lookahead undefined | **Partially resolved.** The syscall/offset/rewind mechanics are much clearer, but H6 leaves the normal final-batch EOF transition impossible. |

## Required next gate

Do not implement R12/R18. Revise the plan and test specification to close all
eight High and one Medium findings without raising retained page, intent, FD,
deadline, source, or compatibility bounds. Recompute hashes and run a fresh
independent GPT-5.6 Sol adversarial review against the then-current
`origin/main` and current reservation writer inventory. Implementation may
begin only after that review reports zero Critical, High, and Medium findings.
