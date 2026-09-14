# Build 1 reservation search progress R7 — independent plan gate (Sol)

Date: 2026-09-11. Reviewer: independent GPT-5.6 Sol plan-gate lane.

Verdict: **FAIL / NOT APPROVED FOR IMPLEMENTATION**. Architectural status:
**BLOCK**. Findings: **0 Critical, 4 High, 1 Medium, 0 Low**.

R7 correctly makes the global-versus-target validation replacement explicit and
adds a rooted absent-target allocation admission. The combined R4–R7 contract is
still not implementable. New retirement roots are simultaneously full-validation
events and bounded target-local operations; immutable B+tree update objects are
absent from the lifecycle charge; all-absent allocation refund has contradictory
row semantics; and the v1 migration lacks the deterministic tree and authenticated
checkpoint definition required by its own crash tests. R13 also requires an
illegal simultaneous shared-admission fixture.

## Frozen inputs and source inspected

The review independently recomputed and matched the requested SHA-256 values:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r7.md` | `fa1a9178b2d2779a79285ae4952867a4b78e8c6a64a56d55191472f83ff24293` |
| `test-spec-r13-reservation-r7-corrections.md` | `cdbb44bf913fa53c23c50fc10823996cc99422810a6b04258d3911a37ecdd225` |
| Failed R6 review | `e985c269b23f373221ec9ba18d509dff17d9ee46f37cc711c470ebfe82d07ce6` |

The governing R4/R5/R6 plans matched `3bb911a0...`, `051eb952...`, and
`b26a480d...`; R11/R12 matched `96a51cb4...` and `61f2dc00...`; and the failed
R5 review matched `7b1e71fd...`. The three frozen R4 audits and current source
were inspected. The six governing source files still exactly match the R4
implementation manifest: bindings `60abe294...`, evidence `b49c13fa...`,
migration `5bc526e3...`, reservation migration `c8505d5d...`, retention
`0a6b4873...`, and transactions `65cbb0e9...`. No implementation or test was
edited.

## Critical (0)

None.

## High (4)

### R7-PLAN-H1 — every new retirement root is both globally validated and target-local

**Severity:** High. **Confidence:** High.

R7 says `validateReservationTransitionGraph` performs full body validation
"when a retirement root is first activated" and walks every applicable page and
named body (`reservation-search-progress-addendum-r7.md:126-135`). The same
section classifies retirement as an ordinary operation that validates only the
target and never opens unrelated detached objects (`:137-156`). Each retirement
then creates and selects a new v2 root (`:368-374`). A newly selected root is
necessarily being activated for the first time.

R13 preserves both incompatible branches: retirement must satisfy the ordinary
ten-open/eight-second bound at 1,024 pending rows (`test-spec-r13-reservation-r7-
corrections.md:57-75`), while each retirement publishes a new root and exercises
tree splits (`:223-232`). It never says whether the new root receives the full
walk required by R7.

**Consequence.** Following the full-validation rule makes ordinary retirement
open the unbounded historical tree and detached bodies, violating target-local
availability, ten opens, and eight seconds. Following the ordinary-operation
rule selects a root without the mandatory validation. This reintroduces the
global-versus-row inconsistency that R6-PLAN-H1 required R7 to close.

**Required correction.** Reserve full validation for genesis and named bulk
phase transitions. Define v2 root evolution as an inductive authenticated path
update from one already selected root: validate the target membership/nonmembership
proof and every replaced path node, derive one canonical successor, preserve
untouched child digests, and select it under the target CAS. State exact opens,
bytes, and descriptors for that path, and make R13 distinguish initial full-tree
activation from ordinary incremental root replacement.

### R7-PLAN-H2 — retirement B+tree objects are not included in the admitted lifecycle charge

**Severity:** High. **Confidence:** High.

R7's inventory recognizes every v1/v2 leaf or internal page at 1,052,672 bytes
and every root envelope at 20,480 bytes (`reservation-search-progress-addendum-
r7.md:251-267`). It also requires every retirement to create a new leaf path and
root while retaining the old immutable root and reusing only unchanged subtrees
(`:368-375`). Nevertheless its exact post-complete lifecycle reserve charges
retirement as only the 69,632-byte v2 certificate plus one 4,096-byte UUID
directory, for 73,728 bytes, and declares the full lifecycle exactly 352,256
bytes (`:269-284`). No charge covers the new leaf, changed internal nodes, root
envelope, or any new tree directory.

At even the first insertion, at least a new leaf and root envelope are durable;
later insertions can materialize a changed path whose length grows with tree
height. Because old content-addressed pages and roots remain retained, this is
permanent materialization, not atomic-write peak. R13 repeats the 352,256-byte
exact reserve while also requiring every retirement page/root to be inventoried
and never deleted (`test-spec-r13-reservation-r7-corrections.md:129-174,
223-232`).

**Consequence.** `materializedBytes` must rise by bytes for which no tranche was
reserved. The accounting equation can hold only by exceeding `chargedBytes`,
silently charging after admission, or omitting retained authority. Near quota,
the last admitted lifecycle is not guaranteed to close. R6-PLAN-H3 therefore
remains open.

**Required correction.** Freeze the exact canonical successor tree before the
retirement admission CAS. Include every newly materialized certificate,
directory, leaf, internal node, and root envelope in that retirement tranche,
using actual deterministic encodings or conservative height-aware maxima. Add
the same objects to `Wpeak` without double counting permanent charge. Recompute
the post-complete lifecycle reserve and independently assert the charge after
leaf split, internal split, and height growth.

### R7-PLAN-H3 — all-absent allocation refund has contradictory authoritative-row rules

**Severity:** High. **Confidence:** High.

The allocation protocol first publishes an absent-target reserved admission,
then changes it to `materializing` and creates the allocating row
(`reservation-search-progress-addendum-r7.md:196-207`). It says a crash after
materializing may perform R5's all-absent removal and refund the entire
unmaterialized charge (`:210-215`). Later it says the only refund is before any
body **or row successor** exists (`:224-227`). R5's retained all-absent recovery
is specifically removal of an already published allocating row
(`reservation-search-progress-addendum-r4.md:547-564`).

R13 contains the same contradiction: it asks for the all-absent suffix before
and after materializing CAS, then declares any row successor makes refund
illegal (`test-spec-r13-reservation-r7-corrections.md:100-110`).

**Consequence.** After death immediately following the materializing CAS, exact
absence of all bodies either leaves an unfinishable charged row forever or
requires a refund forbidden by the later rule and test. Implementations can
diverge on whether row creation is refundable, defeating consume/refund
idempotency and the global allocation gate. R6-PLAN-H2 is not closed.

**Required correction.** Define one closed abort transition. If the allocating
row with zero bodies is refundable, atomically remove that exact row and its
matching admission under generation/digest/absence CAS and decrement the one
charge exactly once; forbid refund after the first allocation body or directory.
If row publication is intended to make the reservation permanent, remove the
post-materializing refund branch and define a convergent way to finish it.
R13 must use the same boundary and include crash-before, crash-after, replay,
wrong-owner, and one-byte-materialized cases.

### R7-PLAN-H4 — paged v1 activation lacks the deterministic and durable transcript contract its tests require

**Severity:** High. **Confidence:** High.

R7 names tree paths and broad row shapes, but does not define the leaf capacity,
internal fanout, canonical split/packing algorithm, exact node/leaf schemas, or
empty-tree encoding (`reservation-search-progress-addendum-r7.md:319-340`). It
also permits authenticated enumeration and validation checkpoints without
defining their closed schema, direct path, digest/root binding, publication
order, or which concrete macOS directory identity/change-token and continuation
semantics establish an unchanged exhaustive enumeration across eight-second
calls and process death (`:342-363`). A rolling unkeyed transcript hash proves
only the rows presented to it; without a defined snapshot/change authority it
cannot prove that directory entries were not skipped or changed between slices.

R13 nevertheless requires tests to independently construct byte-exact roots at
the one-leaf boundary and multiple levels, reject false EOF/skipped ranges/token
changes, and resume only valid checkpoints after real death
(`test-spec-r13-reservation-r7-corrections.md:197-221`). Those expected bytes and
validity decisions cannot be derived from the proposed contract.

**Consequence.** Two conforming implementations can root different subsets or
different trees for the same v1 directory, and a restart cannot distinguish a
valid checkpoint from unselected mutable scan state. Activation may omit valid
historical retirement authority or become permanently unavailable. R6-PLAN-H4
remains open.

**Required correction.** Specify closed canonical leaf/node/root/checkpoint
formats, exact packing and split rules, canonical empty root, direct checkpoint
paths, digest chain, and the concrete platform primitive that proves one stable
enumeration. If the platform cannot provide a durable continuation/change token,
hold a protocol exclusion fence and restart enumeration after death; do not call
an unrooted checkpoint authenticated. Make R13 derive fixtures solely from those
rules and test insertion/deletion/rename both within and across calls.

## Medium (1)

### R7-PLAN-M1 — R13's maximum projection requires an illegal shared-admission combination

**Severity:** Medium. **Confidence:** High.

R7 permits `finalizationAdmission` only with frozen membership and **no**
`allocationAdmission` (`reservation-search-progress-addendum-r7.md:189-194`).
R13-01 asks one maximum projection to contain 1,024 pending rows and "both shared
admissions at their legal maximum" (`test-spec-r13-reservation-r7-corrections.md:
25-28`). Read literally, that fixture is rejected by the governing schema; if
the intent is separate maximum fixtures, the test does not say so.

**Consequence.** The exact maximum-encoding gate can pass only by accepting an
illegal state or by silently weakening the fixture. That leaves the 1 MiB schema
measurement non-reproducible.

**Required correction.** Split this into every legal maximum shape: allocation
admission with no finalization admission, finalization admission with no
allocation admission, and the maximum per-row publication state permitted in
each phase. Require rejection of the simultaneous pair.

## Low (0)

None.

## Disposition of frozen findings

| Frozen finding | R7 disposition |
|---|---|
| R4 allocation global gate and three-way generation findings | **Closed at plan level.** The rooted absent-target admission and retained generation equality are explicit; implementation evidence remains required. |
| R4 owner/FD, origin, primary-first departure, pending stabilization, rollback, queued-cancel, install-lineage, and prior-binary findings | **Closed or retained at plan level.** R7 keeps the governing corrections and R13 retains their hostile cases. |
| R4 global graph/finalization and R6-PLAN-H1 | **Open.** R7 resolves unrelated detached-body handling, but H1 leaves new retirement-root selection globally and locally inconsistent. |
| R5-PLAN-H1 | **Closed at plan level for publication evidence.** Target predecessors and selected projection bound unrelated pending fanout; H1 separately blocks retirement-root work. |
| R5-PLAN-H2 / R6-PLAN-H3 | **Open.** H2 shows retained retirement tree materialization is outside the exact lifecycle charge. |
| R5-PLAN-H3 | **Closed in authority shape, pending implementation.** Retirement v2 and its rooted membership bind dynamic departure lineage, subject to H1/H2. |
| R5-PLAN-M1 | **Closed.** Byte-equivalent pre-capture identity and strict post-capture identity remain coherent. |
| R6-PLAN-H2 | **Open.** The absent-target ledger exists, but H3 makes its only refund transition contradictory. |
| R6-PLAN-H4 | **Open.** Paged trees remove the flat 1 MiB ceiling, but H4 leaves deterministic exhaustive activation and crash recovery undefined. |
| R4/R5/R6 test-evidence findings | **Open as a gate claim.** R13 is broad, but H1–H4 and M1 describe contradictory or unspecified cases that it cannot validly prove. |

## Verification and gate decision

Verification was static and adversarial because R7 is a pre-implementation
plan. It included exact hash verification, all governing R4–R7 plans and failed
audits, the retained R11/R12 matrix, current source/manifest identity, transition
authority, allocation/refund idempotency, exact quota arithmetic, storage faults,
paged v1/v2 retirement, crash ordering, prior-binary fencing, and the eight-second,
open, and descriptor bounds. No test command was treated as evidence for
unimplemented R7 behavior.

Final recommendation: **REQUEST CHANGES / FAIL**. Correct R7-PLAN-H1 through H4
and R7-PLAN-M1, update the paired test specification, freeze new hashes, and
obtain a fresh independent zero-Critical/High/Medium plan gate before source or
test implementation.
