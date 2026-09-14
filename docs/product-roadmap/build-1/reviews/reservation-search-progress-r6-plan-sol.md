# Build 1 reservation search progress R6 — independent plan gate (Sol)

Date: 2026-09-11. Reviewer: independent GPT-5.6 Sol plan-gate lane.

Verdict: **FAIL / NOT APPROVED FOR IMPLEMENTATION**. Architectural status:
**BLOCK**. Findings: **0 Critical, 4 High, 0 Medium, 0 Low**.

R6 materially improves the R5 proposal: its target-only predecessor and current
state projection remove the 2 GiB unrelated-pending fanout, its file-identity
contract is honest, and retirement v2 can preserve a new dynamic member's
departure lineage. The complete retained contract is still not implementable.
The current-authority substitution conflicts with retained R5 all-member graph
validation, the prepaid charge has no representable state for an allocation
that has no row, the quota does not enclose or correctly charge all durable
reservation authority, and historical v1 retirement compatibility has no
complete bounded authoritative root.

## Frozen inputs and source inspected

The review independently recomputed and matched the three requested SHA-256
values:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r6.md` | `b26a480d801c3c9ebe8c2b282a05702315470ad7ef5d8af1482e6a094856869e` |
| `test-spec-r12-reservation-r6-corrections.md` | `61f2dc00b3b5d362783228c77cf1fe58c6928f33e67952b12d2e2cb0d4e1f2b2` |
| `reviews/reservation-search-progress-r5-plan-sol.md` | `7b1e71fd996e12383b7de82f0b5ef3dcdaf4e7b5d629674ff5975c844595d80c` |

The six governing source files still match the frozen R4 implementation
manifest: `ModelCatalogTransactionBindings.swift` `60abe294...`,
`ModelCatalogTransactionEvidence.swift` `b49c13fa...`,
`ModelCatalogTransactionMigration.swift` `5bc526e3...`,
`ModelCatalogTransactionReservationMigration.swift` `c8505d5d...`,
`ModelCatalogTransactionRetention.swift` `0a6b4873...`, and
`ModelCatalogTransactions.swift` `65cbb0e9...`. Source inspection traced the
active-index schema, allocation intent, publication/recovery, heartbeat,
cancel/commit, retirement, v1 certificate, file-evidence, and eight-second
budget seams. No source or test was edited.

## R6-PLAN-H1 — R6's bounded current root contradicts the retained closed-graph contract

**Severity:** High. **Confidence:** High.

**Evidence.** R6 says R4 and R5 remain governing, and its explicit replacement
list replaces R5 section 6's full predecessor snapshots, storage retention,
retirement, and the inode wording (`reservation-search-progress-addendum-r6.md:
20-34`). It does not replace R5 section 4. R5 section 4 requires every writer
to capture and revalidate one closed reservation graph, validates every source
member and every named origin/class/left body, makes any member mismatch protect
an unrelated writer, and requires every complete-phase mutation to validate the
closed historical graph (`reservation-search-progress-addendum-r5.md:154-191,
231-247,429-434`).

R6 instead declares the selected projection sufficient current all-member
authority and explicitly permits an ordinary UUID B mutation to open none of
UUID A's receipt, predecessor, lineage, origin, class, or left objects
(`reservation-search-progress-addendum-r6.md:75-95,279-297`). R12 codifies that
relaxation: corruption of A's detached bytes does not block B, and the retained
R11 graph cases are adapted to validate only the row while deferring body
failure until A is dereferenced (`test-spec-r12-reservation-r6-corrections.md:
38-61,140-151`). This is the exact behavior the retained R5 contract forbids.

The projection is a useful authenticated state commitment, but R6 does not
define the cutover invariant and inductive transition theorem that would replace
the stronger body-closed graph. It also does not state that a missing committed
body is an accepted unavailable value rather than an incomplete authority graph.
The current source makes this material: active membership presently carries
only digests and refs (`ModelCatalogTransactionRetention.swift:6-29`), and R5
was specifically introduced because those refs alone did not close the frozen
graph before unrelated mutation.

**Consequence.** No implementation can satisfy both documents. Retaining R5
reintroduces the 1,024-member body fanout and defeats R6's ten-open/eight-second
bound. Following R6 violates the retained all-member failure rule and leaves
R4-CODE-M1, R4-CODE-M2, and architecture H1 unresolved under the governing
contract. The test adaptations would bless the weaker branch without first
authorizing it.

**Required correction.** Explicitly replace the affected R5 section 4 and
acceptance clauses. Define one closed genesis transition from the fully
validated historical graph into the projection, an exact inductive CAS rule
that is the sole way to evolve it, and the semantics of a committed-but-missing
detached body. State separately which operations require only row preservation
and which dereference and validate target bodies. Update R12 to prove genesis,
every permitted delta, rejection of every other delta, and preservation of a
missing non-target row without claiming compliance with the superseded rule.

## R6-PLAN-H2 — prepaid closure and charge-only allocation state are not representable

**Severity:** High. **Confidence:** High.

**Evidence.** The R6 projection schema contains exactly one row per active
entry, and its listed row fields have no prepaid-closure balance, charge intent,
bundle kind, or deterministic bundle-digest reservation
(`reservation-search-progress-addendum-r6.md:55-68`). Section 5 nevertheless
requires a charge-only state/index CAS whose *target row* records the bundle
kind and deterministic target digests before any immutable object is written
(`:188-195`). At cutover and allocation, future class/left/retirement closure is
prepaid and must later be consumed without recharging (`:198-204`). No schema
field records the outstanding or consumed amounts needed to compute
`unmaterializedPrechargedClosureBytes` (`:206-212`).

The allocation case has no possible target row. The current source creates the
UUID and first row together in the allocating intent
(`ModelCatalogTransactionRetention.swift:451-489`). R12 instead requires
`charge-only state/index` before `allocating state/index` and requires zero new
UUID or index row when lifecycle admission fails
(`test-spec-r12-reservation-r6-corrections.md:70-76,168-174`). A row cannot carry
the charge before the row and UUID exist. Finalization likewise has a shared
bundle rather than an identified target row.

**Consequence.** Crash recovery cannot distinguish an unused prepaid reserve,
an in-progress bundle, and a consumed reserve from authenticated state. An
implementation must either create allocation authority before the declared
intent, store charge truth outside the selected root, silently add unspecified
schema fields, or double-charge a prepaid bundle. Each branch breaks the
ordering, quota, replay, or closed-schema contract, and R12 cannot test the
promised recovery state because no valid encoding exists.

**Required correction.** Add one bounded closed charge-reservation state to the
index-selected projection. It must represent an absent-target allocation,
shared finalization, per-entry source closure, and retirement; bind bundle kind,
deterministic digests, fixed charge, lifecycle owner, and state
`reserved/materializing/consumed`; and define exact generation/CAS transitions.
Specify whether `chargedBytes` includes outstanding reserve, materialized bytes,
or both, and give an equation for `unmaterializedPrechargedClosureBytes` that
cannot double-count the current write. Add maximum-encoding, concurrent charge,
all crash-boundary, replay, and idempotent-consumption tests.

## R6-PLAN-H3 — the 1 GiB quota omits and undercharges retained reservation authority

**Severity:** High. **Confidence:** High.

**Evidence.** R6 defines its logical quota over selected immutable objects
under `.reservation-migration`: predecessor, receipt, lineage, install,
projection history, and retirement v2 (`reservation-search-progress-addendum-
r6.md:168-186`). The list omits the immutable origin, class, and left bodies
that R6 itself calls referenced authority that may never be deleted (`:218-229`).
Those bodies are written outside `.reservation-migration` in the current
storage layout; allocation publishes primary, origin, and class before the
active index (`ModelCatalogTransactionRetention.swift:451-503`). R12 nonetheless
asserts that retained authority never exceeds the 1 GiB quota while repeatedly
allocating, departing, and retiring (`test-spec-r12-reservation-r6-corrections.md:
63-76`).

The fixed first-class charge also cannot be the stated worst case if its ordered
class body is part of the authority bundle. Using R6's maxima and its own
4,096-byte per-object charge rule gives 12,288 bytes for predecessor,
135,168 for receipt, 20,480 for lineage, and 36,864 for class: **204,800 bytes**,
which exceeds the declared 196,608-byte charge. A post-complete allocation that
charges its 16 KiB origin, 32 KiB class, and 16 KiB genesis lineage under the
same rule needs 77,824 bytes, exceeding 65,536. Excluding those files makes the
arithmetic fit only by excluding retained reservation authority from the
lifetime bound.

**Consequence.** The plan can report `chargedBytes <= 1 GiB` while retained
protocol authority exceeds 1 GiB, or it can admit a maximum operation whose
real charge is larger than its prepaid reserve. Near quota or ENOSPC, the last
admitted lifecycle is therefore not guaranteed to close, so R5-PLAN-H2 remains
open despite the storage-fault matrix.

**Required correction.** Define the quota inventory by exact direct path and
artifact version, including origin/class/left and every manifest/root needed by
R6, or explicitly bound excluded retained bytes under a separate reviewed
lifetime quota. Recompute each fixed bundle from maximum canonical sizes,
4,096-byte rounding, and per-object overhead. Include the active index and any
new charge ledger where applicable. Make R12 independently sum every retained
file after each boundary and require physical retained authority plus outstanding
reserve to stay within the declared equations.

## R6-PLAN-H4 — historical v1 retirement compatibility has no complete bounded root

**Severity:** High. **Confidence:** High.

**Evidence.** R6 proposes a 1 MiB content-addressed v1-retirement manifest at
activation, with one UUID/certificate/origin row per historical v1 certificate
(`reservation-search-progress-addendum-r6.md:252-258`). It gives no exact path,
manifest digest field in the active index/projection/install, publication and
crash ordering, or transition from the already content-addressed immutable
completed install. The current v1 layout is a direct `<uuid>.retired` file and
retirement removes the UUID from active membership
(`ModelCatalogTransactionBindings.swift:77-102,158-160`;
`ModelCatalogTransactionArchive.swift:93-100`;
`ModelCatalogTransactionRetention.swift:612-630`). There is no current archive
index from which an exhaustive manifest can be derived without enumeration.

The number of safe historical v1 certificates is not bounded by the 1,024
active-entry cap: retirement removes a row and later allocation can add another
UUID indefinitely. A 1 MiB manifest therefore cannot represent every valid
pre-activation history. R12 creates unspecified plural v1 certificates and
checks changed/missing bytes, but does not cover manifest-at-limit history,
one-row-over activation, enumeration races, or crashes before and after rooting
the manifest (`test-spec-r12-reservation-r6-corrections.md:97-120`).

**Consequence.** A valid existing journal can be impossible to activate, or an
implementation can omit a v1 retirement from the accepted root. If the manifest
is not bound by the selected index/install digest, same-user substitution can
change the accepted historical set. This leaves the compatibility part of
R5-PLAN-H3 incomplete even though new v2 retirements have a coherent lineage.

**Required correction.** Define an exact manifest path, digest-bearing root,
and activation CAS/crash protocol. Provide a bounded exhaustive discovery rule
or a paged content-addressed tree whose root fits the selected projection and
whose capacity covers every previously valid history without narrowing it.
Specify concurrent old-writer fencing while the historical set is captured.
Extend R12 with empty, exact-limit, one-row-over, large paged history,
enumeration collision/race, manifest-root substitution, and real-death cases.

## Disposition of every frozen finding

| Frozen finding | R6 disposition |
|---|---|
| R4-CODE-H1 / architecture H2 | **Closed at plan level.** Sequential probes/detached evidence remain, and R6 ordinary work states constant descriptors plus an RLIMIT/counter matrix. Final implementation evidence remains mandatory. |
| R4-CODE-H2 / R4-SEC-H2 | **Closed at plan level.** R5's global typed allocation gate and three-way generation equality are retained and R11/R12 preserve their hostile cases. |
| R4-CODE-M1 / R4-CODE-M2 / architecture H1 | **Open.** H1 identifies a direct conflict between retained all-body graph validation and R6 row-only non-target preservation. |
| R4-CODE-M3 / R4-SEC-H1 / architecture M2 | **Closed at plan level for active entries.** Same-owner stabilization, rollback rejection, and no retirement with pending/unsettled lineage remain explicit. Historical retirement compatibility remains blocked by H4. |
| R4-SEC-M1 | **Closed at plan level.** Content-addressed install/projection lineage remains, and different-byte substitution is rejected. |
| R4-SEC-M2 | **Closed locally, blocked in the combined protocol.** Predecessor v2 plus the copied pending commitment gives bounded target transition evidence, but H1 must define the governing cross-member invariant. |
| Architecture M1 | **Closed at plan level.** Queued cancellation without custody retains the typed-busy rule and race test. |
| R4-CODE-M4 / architecture H3 | **Open as a gate claim.** R12 adds the missing 1,024-pending, storage-fault, retirement-lineage, and identity matrices, but H1-H4 describe states the current test spec cannot validly instantiate or prove. |
| R5-PLAN-H1 | **Locally corrected.** Target-only predecessor evidence and the 3,383,296-byte/ten-open/four-descriptor bound remove unrelated pending-object fanout. H1 prevents acceptance of the combined governing contract. |
| R5-PLAN-H2 | **Open.** R6 adds quota/preflight/fault concepts, but H2 and H3 show that accounting state and lifetime coverage are incomplete. |
| R5-PLAN-H3 | **Closed for new v2 retirements; open for compatibility.** New v2 lineage, ordering, and corruption tests are sufficient in shape. H4 leaves pre-activation v1 history unrooted/unbounded. |
| R5-PLAN-M1 | **Closed.** R6 and R12 correctly accept byte-equivalent pre-capture replacement and reject post-capture identity change without claiming persisted inode knowledge. |

## Verification and gate decision

Verification was static and adversarial because R6 is a pre-implementation
plan. It included exact hash verification, independent source tracing, quota
arithmetic, maximum pending work, direct-path authority, allocation and
retirement ordering, crash/ENOSPC recovery, descriptor and eight-second bounds,
file identity, backward compatibility, and the complete retained R4/R5/R11
matrix. No test command was treated as evidence for unimplemented R6 behavior.

Final recommendation: **REQUEST CHANGES / FAIL**. Correct R6-PLAN-H1 through
H4, update the paired test specification, freeze new hashes, and obtain a fresh
independent zero-Critical/High/Medium plan gate before implementation.
