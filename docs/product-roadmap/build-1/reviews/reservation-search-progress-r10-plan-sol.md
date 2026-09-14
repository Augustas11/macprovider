# Build 1 reservation search progress R10 — independent plan gate (Sol)

Date: 2026-09-11. Reviewer: independent GPT-5.6 Sol plan-gate lane.

Verdict: **FAIL / NOT APPROVED FOR IMPLEMENTATION**. Architectural status:
**BLOCK**. Findings: **0 Critical, 6 High, 2 Medium, 0 Low**.

R10 materially improves R9: it supplies a direct pre-genesis selector and lock,
separates mutable progress from terminal results, adds complete file witnesses
and a second locked recapture, closes each allocation create/fsync/CAS suffix,
defines one root-relative path domain, and correctly separates the 393,216-byte
abort envelope from the reachable 126,976-byte maximum actual charge. It still
does not define a recoverable bootstrap after a pre-format crash, a legal empty
history, a resumable level-zero tree frontier, or bounded work roots for every
grandfathered history. It also leaves selected activation-work accounting and
body-intent authority incomplete, and its activation-lock wording reinstates a
global publication gate. Two smaller normative contradictions make the exact
test suite impossible without choosing behavior outside the reviewed plan.

## Frozen inputs and repository evidence

The requested hashes were independently recomputed and matched:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r10.md` | `4b82dd1e0fd849f1472fff86e1f5cd8c5f9bd966946c91b21d8951ca5d17c407` |
| `test-spec-r16-reservation-r10-corrections.md` | `2f0397aed4699f90a2a75abf6acf63f0d088fdadd00399f969d57913fcdf6168` |
| Failed R9 review | `0d4b565998f80b7694b2d2fa5644290987c73d17fc1719fc6d2a81620c24f8d4` |

`origin/main` was independently resolved to
`1d2c930bad81704dd0acc0322226725d8b64aceb`. The
`914f7cafcdbcfc1805a10f4f34167218341d5587..1d2c930b` path comparison matches
R10/R16: it adds `BYOMArtifactDigest.swift` and changes BYOM/SPEC surfaces, with
no committed change to the four named reservation files. Those reservation
files are part of the still-uncommitted Build 1 working tree, rather than files
present on `origin/main`; the applicable R4 hashes in
`implementation-reservation-r4.md` were checked and still match the current
retention, evidence, and reservation-migration files. This review therefore
evaluates the cumulative R4 working-tree implementation plus R5–R10, not a claim
that the reservation implementation has landed on main.

Current source confirms the implementation gap is real: the working-tree format
type has only the v2/v3 fields and the active index only the pre-R10 fields
(`ModelCatalogTransactionRetention.swift:6-39`), and its decoder accepts only
formats v2/v3 and active indexes v2–v4 (`:191-221`). Descriptor-relative,
component-by-component no-follow resolution and ACL checks already exist
(`ModelCatalogTransactionStorage.swift:56-94,125-183`), so R10's filesystem
primitives are feasible. No source or test was edited by this review.

The abort arithmetic was independently recomputed. Under the inherited
`F(n) = ceil(n/4096)*4096 + 4096`, the R10 lengths produce charges 8,192,
16,384, 32,768, and 8,192 as stated; the maximum cascade totals 126,976.
The three 1 GiB quotient/remainder pairs are also correct: 1,846/49,152,
37,449/4,096, and 8,456/32,768.

## Critical (0)

None.

## High (6)

### R10-PLAN-H1 — pre-format bootstrap death can permanently strand an unselected activation

**Severity:** High. **Confidence:** High.

The only durable selector for an activation UUID is the v4 format, but v4 is
published last. Before that publication, the activation/checkpoint/selector
live under an UUID-specific directory (`reservation-search-progress-addendum-
r10.md:71-85,103-147`). A death before format rename is declared to leave
"unselected equal-reusable objects" (`:149-150`), yet R10 defines no rule by
which the next process discovers and adopts that UUID, proves it is the unique
candidate, or discards an obsolete candidate after the old index/source changes.
Generating a new UUID cannot reuse those bytes because UUID is present in every
object. R16 compounds this gap by treating any competing activation UUID as
protected while requiring every pre-format crash suffix to recover
(`test-spec-r16-reservation-r10-corrections.md:72-92`).

The global lock prevents a second cooperative bootstrap while the first process
is alive, but process death releases it and leaves no selected record telling the
next invocation which UUID owned the attempt. A retry that chooses a new UUID is
then required to reject the old directory as a competitor. A retry that scans
and adopts it has no reviewed selection, stale-input, multiplicity, or cleanup
algorithm.

**Consequence.** Any crash, cancellation, ENOSPC, or EDQUOT after activation
directory/object creation and before v4 rename can wedge migration permanently
or force implementation-specific orphan adoption. The core R9-PLAN-H1 recovery
requirement is not closed.

**Required correction.** Define a pre-v4 bootstrap intent selected by existing
old-format authority, or derive one deterministic activation identity from the
frozen prior index/source/lock tuple. Specify exact discovery, uniqueness,
staleness, reuse, cleanup, and journal-lock CAS rules for every pre-format crash
suffix. Add real-death tests that restart with zero, one, and multiple orphan
activation directories and with changed old index/source bytes; every case must
have one deterministic, bounded outcome without treating an unselected object
as authority.

### R10-PLAN-H2 — the closed progress graph has no legal empty-history path

**Severity:** High. **Confidence:** High.

R10 explicitly permits zero names/rows (`reservation-search-progress-addendum-
r10.md:318-320`), and R16 requires a zero-name case
(`test-spec-r16-reservation-r10-corrections.md:153-158`). Row capture then enters
merge with an empty pass-zero capture-run set (`reservation-search-progress-
addendum-r10.md:292-300,322-331`). The run protocol can terminate only "when one
input remains," at which point that manifest becomes `sortedRunSHA256`
(`:344-355`). It defines neither an empty run manifest nor a zero-input phase
transition. Nevertheless entry to `building` requires non-null
`sortedRunSHA256` (`:295-297`), while the inherited tree has a canonical empty
root.

The terminal row binding is also not closed. Activation/checkpoint schemas name
`rowCaptureRootSHA256` (`:167-175,257-270`), but section 5 defines only
`model_catalog_retirement_v1_row_work_root.v1` (`:322-331`). R16 asks for both a
row root and a row-work progression but never states whether the terminal field
is the final work-root digest or a distinct closed object
(`test-spec-r16-...:48-55,121-151`).

**Consequence.** A valid empty v1 history cannot reach `building`, `ready`, or
genesis, and independent encoders cannot derive the exact terminal row bytes for
any history without inventing an alias or schema. R9-PLAN-H2 remains open.

**Required correction.** Define one canonical zero-row sorted-run authority and
its exact path/schema/digest, or define a direct zero-row transition that leaves
no run digest while amending every downstream nullability rule. State explicitly
whether `rowCaptureRootSHA256` equals the final selected row-work root; if it does
not, define the missing closed row-capture-root schema and publication edge.
Cover both zero and nonzero transitions with independent bytes and real-death
recovery.

### R10-PLAN-H3 — the level-zero tree frontier cannot resume within a row block

**Severity:** High. **Confidence:** High.

The retained run format emits row blocks of up to 4,096 rows
(`reservation-search-progress-addendum-r9.md:388-406`). R10's level-zero tree
frontier freezes only an array of row-block digests plus one
`nextInputOrdinal`; each output page records only first/last **input** ordinals
(`reservation-search-progress-addendum-r10.md:357-379`). The required leaf
packing is 64 rows. A single 4,096-row input block therefore emits 64 leaves, but
the selected root has no row offset within the block, no partial-leaf state, and
no unambiguous mapping from a page's input-ordinal range to its 64-row range.
Killing after any one of those leaves cannot distinguish the consumed prefix
from the remaining suffix. R16 expressly requires recovery after every leaf and
64/65 boundaries (`test-spec-r16-reservation-r10-corrections.md:177-185`).

**Consequence.** Recovery must rescan and potentially re-emit a selected prefix,
invent an unstated cursor, or repack leaves differently. The selected frontier
does not prove the exact deterministic 64-row construction and does not close
R9-PLAN-H2's partial-page finding.

**Required correction.** Define a level-zero cursor containing both row-block
ordinal and in-block row ordinal, plus any partial-leaf accumulator, or transform
the final run into fixed 64-row immutable inputs before tree construction.
Define exact successor/root fields and crash recovery at every row-block and
leaf boundary, including a 4,096-row block, a cross-block leaf, and final short
leaf. The independent test oracle must prove only the missing suffix is emitted.

### R10-PLAN-H4 — flat work roots and full predecessor validation cannot cover every legal grandfathered history

**Severity:** High. **Confidence:** High.

R7 deliberately permits a previously valid v1 history to force quota above
1 GiB and says no valid history may be constrained by a 1 MiB manifest
(`reservation-search-progress-addendum-r7.md:291-298,319-340,368-375`). R10
retains that compatibility rule and the 1 MiB work-object limit
(`reservation-search-progress-addendum-r10.md:35-43,60-65,87-91`). Its new roots
nevertheless flatten all name-block digests, all row/capture-run digests, every
merge input/output/completed group, and every tree level/page into arrays inside
single root documents (`:309-379`). Each selected generation also points to its
previous generation, and R16 demands traversal of every predecessor back to
generation zero at every crash boundary (`test-spec-r16-...:147-150`). No count
or byte proof bounds those arrays or chain traversal under 1 MiB and eight
seconds for every grandfathered history.

This is not hypothetical at the contract level: R7's active-row limit of 1,024
applies to the active projection, while its v1 retirement tree is height-growing
precisely so historical rows are not limited by one manifest
(`reservation-search-progress-addendum-r7.md:44-58,321-340`). R16's 1,024-row
final witness measurement therefore does not prove the inherited larger-history
claim (`test-spec-r16-...:229-233`).

**Consequence.** A valid existing history can exceed a root's canonical limit or
make restart validation exceed the caller deadline. Implementations must reject
a previously supported history, truncate authority, raise a limit/deadline, or
invent paged work indexes. This violates compatibility and boundedness.

**Required correction.** Page every potentially unbounded work collection and
give each page/root a closed fanout, size proof, and bounded traversal protocol.
Replace full-chain-on-every-restart validation with a reviewed bounded trust
anchor/checkpoint scheme while retaining crash integrity, or prove a hard
existing-history count bound from current authority and make it normative
without weakening compatibility. Add maximum legal grandfathered-history size
math and tests at every page/fanout/root boundary.

### R10-PLAN-H5 — selected activation work has no complete quota/accounting transition

**Severity:** High. **Confidence:** High.

R7 requires every existing activation object to be charged by actual canonical
length and defines `materializedBytes` as every retained in-scope object
(`reservation-search-progress-addendum-r7.md:230-249`). R10 makes checkpoints,
activation objects, work roots, blocks, manifests, and all predecessor
generations selected authority that must remain reachable (`reservation-search-
progress-addendum-r10.md:191-223,286-300,393-397`). It says those objects are in
`Wpeak` and retains the quota formula, but it defines no selected pre-genesis
counter or per-generation transition that moves each durable object from reserve
to `activationMaterializedBytes`; its checkpoint/selector schemas contain no
storage inventory or charge root (`:157-175,255-270,595-600`). R16 likewise
lists these objects in peak physical inventory but asserts accounting equations
only generically (`test-spec-r16-...:345-368`).

`Wpeak` is the transient additional volume needed for one write. It cannot account
for immutable selected checkpoints and work generations that persist across
later invocations and are required at genesis. Nor does R10 define how the quota
or `Uafter` is frozen before the source row count and complete work graph are
known.

**Consequence.** Long migrations can consume durable space outside selected
quota authority, two implementations can compute different genesis charges, and
capacity preflight can undercount already-selected work. A crash cannot recover
the exact logical storage balance from the selected schema.

**Required correction.** Add a content-addressed activation-storage inventory
root and exact counters to the selected checkpoint/activation pair, with one
atomic charge/reserve transition for every directory/object generation. Define
whether predecessor generations remain charged, when unselected candidates may
be removed, and how genesis imports the exact totals into projection capacity.
Provide closed equations and independent physical/logical inventories at every
write, selector CAS, crash suffix, and cleanup edge.

### R10-PLAN-H6 — allocation body intents rely on a nonexistent manifest and do not have closed authority

**Severity:** High. **Confidence:** High.

R10 says every body intent binds a relative path, digest, canonical length, and
charge through the existing body fields "and materialization manifest"
(`reservation-search-progress-addendum-r10.md:490-503`). No
`materializationManifest` field exists in the inherited closed
`model_catalog_allocation_admission.v2` schema, and R9 adds only phase, directory
path digest, and directory identity (`reservation-search-progress-addendum-
r8.md:145-157`; `reservation-search-progress-addendum-r9.md:218-231`). R10
defines no separate manifest schema, direct path, content digest, selection edge,
or decoder. The existing four SHA fields do not themselves encode the promised
relative path, byte length, or `F(length)` charge.

R16 asks an independent encoder to freeze the amended admission and exact
intent/durable charge transfers (`test-spec-r16-reservation-r10-corrections.md:
43-55,235-294`), but there are no reviewed bytes from which it can derive those
bindings.

**Consequence.** After an intent CAS, recovery cannot prove that the durable
candidate and charge are the exact object authorized before creation. Different
implementations may derive paths or charges from external state. The R9-PLAN-H4
trust and crash-suffix issue is not fully closed.

**Required correction.** Either add exact per-body relative-path, byte-length,
and charge fields to the closed admission for every intent, or define one closed
content-addressed materialization-manifest object and bind its digest from the
admission before A3. Specify its direct path, size limit, canonical schema,
publication/CAS order, and equality rules. R16 must encode those exact bytes and
prove recovery uses no caller or mutable external authority.

## Medium (2)

### R10-PLAN-M1 — the activation-lock lifetime contradicts the retained no-global-gate contract

**Severity:** Medium. **Confidence:** High.

R10 retains "no global publication gate" (`reservation-search-progress-
addendum-r10.md:35-43`), but then states that every compatible mutation route
safe-opens the frozen activation lock and that every later call acquires the
activation flock before the journal lock (`:126-153`). Its successor algorithm
holds that flock across bulk reads and content-addressed writes (`:202-215`). The
text never releases ordinary post-genesis routes from this protocol. Read
literally, every later allocation, retirement, publication, and control mutation
must serialize behind one long-lived-per-invocation global flock.

**Consequence.** A slow unrelated body read/build can block all other mutation
targets, contradicting the availability and operation-local validation design.
R16 retains the slogan but has no explicit post-genesis concurrency oracle that
would disambiguate the lock scope.

**Required correction.** State that the activation flock is acquired only for
pre-genesis bootstrap/progress/genesis operations, if that is intended. Define
the bounded post-genesis format/ready-selector validation under the existing
journal CAS without holding the activation flock across ordinary work. Add a
test that blocks one post-genesis target before its journal CAS while unrelated
target publication, heartbeat, status, and cancellation continue.

### R10-PLAN-M2 — the mutation-fence test forbids the migration engine that must make progress

**Severity:** Medium. **Confidence:** High.

R10 says every compatible transaction-root mutation route rejects before
mutation until genesis (`reservation-search-progress-addendum-r10.md:126-132`).
R16 then runs "every actual compatible mutation route" in generation zero,
middle states, and ready-before-genesis and requires rejection before write
(`test-spec-r16-reservation-r10-corrections.md:114-119`). The activation engine
itself is a compatible transaction-root mutation route and must create work,
checkpoint, activation, and selector successors in those exact states. Neither
document names an exception or separate route class.

**Consequence.** The literal acceptance test either rejects the migration engine
and prevents progress or silently exempts it outside the reviewed contract.

**Required correction.** Partition routes explicitly into the sole authorized
activation-continuation/genesis route and ordinary transaction mutations. Define
the former's exact v4/selector/lock preconditions and require every other writer
to reject. Enumerate the production entrypoints in R16 and assert the correct
result for each class.

## Low (0)

None.

## Disposition of the R9 findings

| R9 finding | R10 disposition |
|---|---|
| R9-PLAN-H1, no selected pre-genesis activation/CAS | **Partly closed.** The v4 format, direct selector, lock path, schemas, and joint CAS are concrete. R10-PLAN-H1 leaves pre-format restart/adoption undefined; R10-PLAN-M1/M2 leave lock and route scope contradictory. |
| R9-PLAN-H2, checkpoint mutability and unrooted partial work | **Partly closed.** Mutable checkpoint pointers and merge/tree/verification roots are a sound direction. R10-PLAN-H2/H3/H4 leave empty input, row-terminal identity, leaf-level continuation, and scale unresolved. |
| R9-PLAN-H3, incomplete source witness/final interval | **Closed by plan.** R10 binds size, mode, owner, link, mtime, and ctime from name capture through row/verification reads and performs two final metadata recaptures. R16 covers before/during/after and same-inode mutation. Implementation evidence remains future work. |
| R9-PLAN-H4, incomplete A4/A5 crash suffix and directory charging | **Crash phases and 4,096-byte directory edge are structurally closed; authority still open.** Intent-before-create and durable-after-fsync are exhaustive, but R10-PLAN-H6 leaves the promised per-body manifest/bindings undefined. |
| R9-PLAN-H5, envelope treated as reachable actual charge | **Closed by plan.** The 126,976 actual maximum, 454,656 refund, and 8,456-history arithmetic are correct and R16 rejects the old 393,216 actual-charge oracle. |
| R9-PLAN-M1, undefined timestamp/path domains | **Closed by plan.** `capturedAt` is removed, and the root-relative encoding/domain/join rules are exact and distinct from the configured absolute path. |

## Verification and gate decision

This was a static adversarial plan review because R10/R16 explicitly authorize
no implementation. It covered exact hashes and base revision, the cumulative R4
working-tree source, all governing R4–R9 addenda and R11–R16 tests, current
descriptor/storage mechanics, bootstrap crash recovery, selector/checkpoint
authority, empty and maximum histories, merge/tree restartability, source/path
witnesses, allocation intent authority, storage accounting, lock scope, and
abort arithmetic. No historical or fixture result was treated as fresh R10
implementation evidence.

Final recommendation: **REQUEST CHANGES / FAIL**. Correct R10-PLAN-H1 through
H6 and M1–M2, update the paired test specification, freeze new hashes, and run a
fresh independent zero-Critical/High/Medium plan gate before source or test
implementation.
