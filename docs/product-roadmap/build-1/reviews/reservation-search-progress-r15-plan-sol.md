# Build 1 reservation search progress R15/R21 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: exact R15 plan and R21 test specification, inspected independently
against the failed R14 gate, the governing R4–R13 addenda, current Swift
reservation source, and `origin/main`. No source or test implementation was
authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 8 High, 0 Medium, 0 Low.**

R15 removes the R14 multi-edge digest cycle and the incomplete MMR design, and
it materially improves the carrier boundary, direct historical audit claim,
budget-entry state, object taxonomy, and ordinal separation. The implementation
gate nevertheless remains closed. The first selector still depends on creating
its own parent directory, a 64-edge operation necessarily outlives its selected
lease, and a selected ordinary root can retain a context-only local reference.
The retained R14 codec registry also contradicts R15's carrier-only taxonomy.
The transition budgets omit required phase publications, the eight-step abandon
queue cannot attest or perform its final step as specified, and its economic
result directly conflicts with the inherited A3–A8 rule. Finally, the only
publication protocol for a prepared model artifact is an unchunked operation of
unbounded supported length, while the mandatory eight-second proof never
exercises that case.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r15.md` | `11f2ad881314e1067bd1f43040667cd37c34753bdaa596a42a8ae1348d0c21e6` |
| `test-spec-r21-reservation-r15-corrections.md` | `ad3db16a3d7bb8392487e0bbc17851c13506c0b554ed96268a3d12007f239771` |
| Failed R14 review | `795b6ef4d59181fba0c7e0d4064710a0a38bb948a59b78b52cd990c2332b0c78` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`, matching the plan. The current
implementation is still the frozen R4 implementation:

| Current source | SHA-256 |
|---|---|
| `ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `ModelCatalogTransactionStorage.swift` | `33cf08501a9d0e8509e8433d1cde7537bf9f660b814da0bf26fa1287a104916e` |
| `ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |

That source still carries array-valued active and reservation-progress entries
(`ModelCatalogTransactionRetention.swift:6-30` and
`ModelCatalogTransactionReservationMigration.swift:65-78`), caps the current
active index at 1,024 entries (`ModelCatalogTransactionRetention.swift:109-112,
191-198`), enumerates the legacy directory during bootstrap
(`ModelCatalogTransactionRetention.swift:146-160`), and uses sorted-key
`JSONEncoder` rather than RFC 8785 JCS
(`ModelCatalogTransactionRetention.swift:114-125`). No selector v6, carrier,
authenticated budget tree, embedded lease, continuation, or compensation queue
exists. Existing source and tests are therefore baseline evidence only; they do
not approve R15.

The following advertised arithmetic was independently reproduced:

```text
units(Rmax)        = 9,367*439,804,651,110 + 18,323
                   = 4,119,650,166,965,693
carrierCount(Rmax) = 986*439,804,651,110 + 1,928
                   = 433,647,385,996,388
max carrier bytes  = 433,647,385,996,388 * 1,064,960
                   = 461,817,120,190,713,364,480
```

These calculations are internally correct. Findings H2, H5, and H8 show why
they do not yet prove a reachable, deadline-safe protocol.

## Critical (0)

None.

## High (8)

### R15-PLAN-H1 — the selected bootstrap requires the selector to authorize creation of its own parent directory

**Severity:** High. **Confidence:** High.

**Evidence.** R15 retains nonconflicting R4–R13 bootstrap requirements
(`R15:14-21`). The inherited direct selector path is
`.reservation-migration/retirement/v1/activation/<activationUUID>/active.json`
(`R10:71-85,119-124`). R15 then says the first v6 selector is created before
any ordinary R15 object and that its first pending state authorizes creation of
the activation and carrier directories (`R15:403-443`). It expressly makes
activation-directory creation a selector-only target (`R15:432-436`) and
forbids creation of any target before pending-only selector authority
(`R15:691-701`). The selector cannot exist at its governed path until the
`<activationUUID>` directory already exists.

The inherited R10 bootstrap avoided this cycle by creating and fsyncing the
activation directory under the journal lock before writing the generation-zero
selector, then selecting it through the format fence (`R10:134-153`). R15 does
not say that this precreated directory is merely adopted and authenticated; it
counts its creation as a later selected target. R21 kills bootstrap after pages,
receipts, carriers, selectors, and directory fsyncs (`R21:171-184`), but has no
non-circular byte state from which to generate the first pending selector.

**Consequence.** An implementation must either create the selector parent
without the authority R15 requires, write the selector somewhere other than the
format-fence path, or silently retain R10's preselection creation while charging
and receipting a creation that already happened. The first v6 authority and its
crash recovery cannot be implemented as written.

**Required correction.** Freeze one acyclic bootstrap. If the parent is
precreated under the existing journal-lock/format-fence protocol, name its exact
unselected status, identity capture, later adoption rule, charge, and every
old/candidate/new crash outcome; do not call its later step creation. If another
selector path is intended, update the direct path, format fence, lock order, and
old-binary rejection contract together. R21 must begin from the actual current
R4 on-disk graph and prove death at every directory, lock, selector, and format
fence boundary.

### R15-PLAN-H2 — the selected lease expires before the mandatory 64-edge operation can close

**Severity:** High. **Confidence:** High.

**Evidence.** Lease authorization expires at exactly the base selector revision
plus 64 and cannot be extended (`R15:350-369`). R15 separately requires two and
64 consecutive edges and makes every edge use a pending-intent selector CAS and
a later between-edge successor selector before the next intent
(`R15:281-301,671-678`). Thus each carrier edge needs at least one successor
revision, and under the stated separate pending CAS it needs two selector
revisions. Sixty-four target edges therefore reach the expiry boundary even
under the most favorable one-revision interpretation, before the required
budget-close selector mutations; under the literal two-CAS protocol they consume
at least 128 revisions before close.

R21 constructs the 64-edge sequence (`R21:30-38`) and rejects expiry extension
(`R21:163-169`), but never requires the same lease to remain valid through the
64th edge and its control-authorized close. Those requirements cannot both pass.

**Consequence.** A conforming long operation must expire while selected work is
still pending. Recovery must then extend/reissue authority, consume after expiry,
or protect a protocol path that R15 declares legal. Any of those choices breaks
the selected lease identity or the claimed 64-edge reachability.

**Required correction.** Derive the lease horizon from the exact maximum count
of every selector revision in reserve, target continuations, compensation, and
close, including crash replay without renewal. Either lower the legal edge count
and all dependent transition ceilings, or choose a frozen horizon that covers
the entire legal operation and prove first-expired rejection. Add 63/64-edge
commit and abandon vectors at the exact revision boundary.

### R15-PLAN-H3 — a selected ordinary root may contain a context-only local reference

**Severity:** High. **Confidence:** High.

**Evidence.** A `localRecordReference.v1` contains only slot/record coordinates
and record bytes metadata; it has no carrier ordinal or digest and is legal only
inside the same carrier (`R15:158-177`). Yet every root reference permits its
`topPageReference` to be local or carrier (`R15:178-182`). The final carrier's
receipt is required to contain a non-null target root and all receipt target
references are local (`R15:256-277`). The successor selector then selects the
new ordinary roots, but R15 never defines a canonical conversion of the final
root's local top-page reference into a complete carrier reference after the
carrier digest and identity exist (`R15:281-300,638-650`).

R21 freezes local references in the carrier and requires ordinary root authority
to switch only at the final selector (`R21:98-121`), but it does not require the
selector's persisted root to contain a carrier-addressable top reference or
freeze the conversion bytes.

**Consequence.** If the selector stores the receipt's local root literally, a
reader outside that carrier cannot locate or authenticate its top page. If an
implementation silently rewrites it as a carrier reference, the selected root
bytes and digest differ from the receipt's target root and independent encoders
have no normative conversion rule. Current lookup authority is therefore not
byte-exact.

**Required correction.** Separate the in-carrier local target root from the
successor selector's external selected root. Define a deterministic post-carrier
rebasing function that substitutes the exact final carrier reference without
changing any child/page digest, bind both representations in the receipt, and
freeze one- and two-carrier vectors. Reject every selector root with a local top
reference.

### R15-PLAN-H4 — the retained R14 codecs contradict R15's common record envelope and carrier-only object taxonomy

**Severity:** High. **Confidence:** High.

**Evidence.** R15 says every record body begins with exactly
`schema,activationUUID,transactionUUID,edgeOrdinal,slotOrdinal,recordOrdinal`
(`R15:158-163`). It then retains R14 section 8 field lists after only a limited
substitution list (`R15:626-634`). R14's common work/control envelope is instead
`schema,recordOrdinal,transactionIntentID,edgeOrdinal,activationUUID`, with no
slot ordinal and with the removed multi-edge transaction-intent identity
(`R14:521-534`). R15 never maps `transactionIntentID` to the one-edge intent
digest or reconciles the two exact envelopes.

The physical taxonomy also says run manifests and every tree page are catalog
records in carriers and expressly forbids external run/tree objects
(`R15:540-567`). But the sequence-reference registry retained from R14 still
represents capture/input/output runs and current-level tree pages using
`runSHA256`/`pageSHA256`, `storageOrdinal`, and external immutable identity
(`R14:544-559`; retained by `R15:587-592,626-634`). R15 changes only the row-block
role and the run-manifest record; it does not replace those external sequence
reference schemas with carrier record references.

R21 asks an independent encoder to freeze all retained R14 work/sequence/page
schemas and simultaneously reject an external run manifest/tree page
(`R21:11-28,191-208`). No encoder can satisfy both exact registries.

**Consequence.** Independent implementations can disagree on record identity,
intent binding, slot addressing, and whether a run/page consumes external
storage/path authority. A byte-valid graph under one retained table is forbidden
by the other. This leaves the H4/H5 trust boundary from R14 open.

**Required correction.** Publish a standalone R15 codec registry with no
textual substitutions. Every record must have one exact common envelope, every
sequence entry must name one physical carrier class, and run/tree references
must use exact carrier record references. Enumerate every schema/version/field,
reference union, null rule, digest preimage, and min/max bound in the R15
document; R21 must freeze those literals without consulting contradictory R14
bytes.

### R15-PLAN-H5 — the closed transition tables omit required phase publications and therefore do not prove the budgets

**Severity:** High. **Confidence:** High.

**Evidence.** Target classes never mix: external publication, tree mutation,
and record publication are separate carrier edges (`R15:46-62`). The descriptor
registry has an explicit phase-transition class and the edge registry has a
`phase-commit` edge (`R15:184-232`). The materialization table nevertheless
counts A3 as only directory publish, storage index, and path index; each A5 body
likewise receives only those three operations. Its six closing operations name
only lifecycle reserve/bind, binding publication, and phases A6/A7/A8
(`R15:454-482`). There is no phase publication for the required A3→A4 durable
transition or for any of the ordered A5 durable suffixes.

The inherited normative state machine requires selected `directory_intent` to
advance to selected `directory_durable`, and every body intent to advance to its
ordered durable suffix before the next body (`R10:488-541`). R15 itself relies
on the A4 transfer and each A5 receipt suffix (`R15:703-717,789-795`). Because a
tree edge cannot also publish a checkpoint/activation record, those phase
advances require additional named edges or a newly defined selector-only
exception. Neither appears in the row limit `19N`, control limit `38N`, or
carrier bound `6N` (`R15:445-524`).

The fixed table compounds the problem by using numeric cross-products such as
“source state 0–15” and “crash suffix 0–15” without mapping those rows to the
literal selector/activation/checkpoint phase matrix (`R15:488-511`). R21
recomputes the author's named table (`R21:123-169`) but has no complete production
edge graph from which to discover the missing publications independently.

**Consequence.** A correct implementation can exhaust selected category/control
authority before completing an inherited legal path, while an implementation
that skips durable phase evidence can fit the advertised bound. The formulas are
arithmetically correct for an incomplete registry and therefore do not resolve
R14 H3.

**Required correction.** Expand each source, merge, tree, verification,
materialization, retry, and fixed transition into its literal ordered carrier
edges, including every checkpoint/activation phase record, reserve and close
continuation, and selector-only mutation. Derive target units, control units,
carriers, bytes, and revision use from that graph. R21 must generate the graph
from independent state-machine rules and prove every legal A3/A4/A5 suffix plus
the first over-limit transition.

### R15-PLAN-H6 — the eight-step abandon receipt attests a future step and the final pending clear has no legal publication

**Severity:** High. **Confidence:** High.

**Evidence.** The compensation queue has exactly eight ordered steps, ending in
`publish-abandon-receipt` and then `clear-pending`; every applicable step is its
own one-edge intent (`R15:751-767`). The `abandon_receipt.v2` emitted by step
seven must already list exactly all eight completed steps (`R15:798-816`). It
therefore attests `clear-pending` before that step has happened.

The final step is also unencodable. R15 lists only three selector-only
exceptions: intent selection, audit-cursor advancement, and the two bootstrap
directory receipts (`R15:64-68`). Every carrier successor must first select a
between state with a non-null pending transaction and no intent
(`R15:671-678`). Consequently a receipt-bearing `clear-pending` edge can reach
only a between state, while a following selector-only clear would be a fourth
forbidden exception. R21 demands the exact eight-step queue and injects death at
pending clear (`R21:210-235`), but no normative byte state exists for that
transition.

**Consequence.** Cancellation cannot reach the required stable null-pending
selector without either forging future completion in the immutable receipt,
silently adding an unauthorized selector-only CAS, or clearing pending in a
carrier successor that violates the between-state rule. Crash replay and the
claimed bounded compensation proof are not implementable.

**Required correction.** Redesign the last two steps so the immutable receipt
contains only work already selected and the selector that clears pending is an
explicitly authorized atomic successor. Freeze whether the final receipt and
clear happen in one selector commit or in two commits with an exact fourth
selector-only exception. Give each pre/post state, compensation cursor, receipt
reference, revision, budget charge, and crash outcome literal bytes. Add death
immediately before and after the receipt carrier and final clear CAS.

### R15-PLAN-H7 — the abandon economics directly weaken the inherited A3–A8 no-refund boundary

**Severity:** High. **Confidence:** High.

**Evidence.** R15 declares inherited A3–A8 reserve/refund arithmetic governing
and unchanged (`R15:14-21,789-796`). The inherited contract says A3 or later
permanently forces forward completion; abort/refund is legal only at A1 or A2
(`R10:505-541`). R15 instead says a path that is reserved, materialized, or bound
may move to retained-abandoned, a lifecycle reservation before A6 may return to
available, and abandonment before the A6 receipt releases the exact 581,632 or
696,320 reserve (`R15:769-795`). R21 explicitly expects that pre-A6 release
(`R21:210-235`).

Retaining the selected object's exact charge does not reconcile this conflict:
the inherited contract deliberately transfers the unmaterialized remainder to
spent slack on forward completion and forbids economic abort after directory
intent. R15 creates a new economic terminal after selected A3/A4/A5 work.

**Consequence.** A caller can obtain a refund path after the governed boundary
where prior revisions required completion, changing capacity and settlement
accounting under the claim that economics are unchanged. This is an economic
authority change and can also make historical A3–A8 receipts disagree with the
new lifecycle/budget state.

**Required correction.** Preserve the inherited economic boundary exactly, or
open and govern an explicit normative economics change outside this corrective
storage plan. Under the current scope, A3 and later cancellation must retain the
full admitted economic charge and finish the exact forward success path or
protect; only A1/A2 may take the inherited abort/refund route. Replace R21's
pre-A6 release expectation with byte-exact A1/A2 refund and A3–A6 forward-only
vectors for both provenance classes.

### R15-PLAN-H8 — prepared-artifact publication has no bounded implementation or acceptance proof under the eight-second contract

**Severity:** High. **Confidence:** High.

**Evidence.** An external edge publishes exactly one whole immutable object and
has no continuation (`R15:46-62`). The taxonomy permits a
`prepared-model-artifact` of an opaque signed safe-integer length bounded only by
host `off_t` (`R15:540-561`). Its publication/recovery protocol requires the
candidate to progress through file fsync, containing-directory fsync, complete
identity recapture, and exact-candidate validation before receipt selection
(`R15:689-717`). R15 nevertheless keeps an eight-second limit for every
invocation and says a host must preflight time capacity before v6 publication
(`R15:78-102`). No chunked external-object format, already-hashed adoption
contract, bounded per-call cursor, or safe interruption point exists for an
artifact that is many GiB.

R21's performance matrix measures 1,024 primary rows, synthetic height-eight
trees, and maximum carrier ordinals, but no real prepared artifact at the
supported maximum or even the Build 1 model size (`R21:265-287`). The crash
matrix asks to write external temporaries (`R21:73-96`), again without a bounded
large-object continuation. A throughput preflight cannot prove that a later
fsync or full validation always completes inside the deadline, and labelling a
host unsupported does not establish a usable physical-Mac preparation journey.

**Consequence.** The central prepared artifact can time out after durable bytes
but before selected receipt state, with no legal bounded continuation. Smaller
1 MiB migration blocks and synthetic carrier tests could pass while the actual
Build 1 artifact path remains unusable, so the acceptance suite would not prove
the product claim.

**Required correction.** Define one bounded path: either adopt a separately
prepared immutable artifact through a frozen prior hash/identity authority that
requires no full-content reread in the reservation invocation, or add an
authenticated chunk/progress protocol whose every call obeys the existing
deadline and cancellation rules. Freeze large-object crash/replacement rules,
quota/Wpeak accounting, and the exact point at which content integrity becomes
selected. R21 must exercise the actual supported prepared-artifact path and
record bytes processed, fsync duration, FD peak, cancellation, and recovery; a
small external fixture cannot prove this claim.

## Medium (0)

None. The identified defects affect authority, reachability, economic behavior,
or mandatory physical feasibility and are therefore High rather than Medium.

## Low (0)

None.

## Disposition of the R14 findings

| Prior finding | Disposition in R15/R21 |
|---|---|
| R14-H1 — cross-edge digest cycle | **Resolved in architecture direction.** One selected edge intent at a time removes the future-root fixed point. H3 requires a byte-exact local-to-carrier root promotion before the selected graph is complete. |
| R14-H2 — budget authorization/lease state | **Partially resolved, still open.** The prior selected control headroom and single embedded lease remove recursive self-reservation, but H2 makes the lease lifetime insufficient for a declared legal operation and H5 leaves the charged edge registry incomplete. |
| R14-H3 — asserted ceilings | **Open.** The arithmetic matches its tables, but H5 identifies required phase edges absent from those tables; H2 also omits the actual selector-revision horizon. |
| R14-H4 — contradictory taxonomy | **Open.** The physical table is improved, but H4 shows retained external run/tree references contradict the new carrier-only taxonomy. |
| R14-H5 — missing literal codecs/unions | **Open.** H3 and H4 require implementers to invent selected-root rebasing and reconcile incompatible common envelopes/reference schemas. |
| R14-H6 — partial crash oracle | **Open.** Ordinary selector/carrier/external tables are improved. H1 leaves first bootstrap/format-fence publication circular, H6 leaves final clear unencodable, and H8 has no bounded large-object recovery. |
| R14-H7 — contradictory abandon state | **Open.** Declared enums are now coherent, but H6 makes the queue's terminal receipt/clear impossible and H7 changes inherited economics. |
| R14-M1 — incomplete MMR work bound | **Resolved.** Removing MMR and stating direct carrier/page/hash bounds yields a testable current-lookup claim. H8 is a separate external-object deadline failure. |
| R14-M2 — ordinal ambiguity | **Resolved.** Protocol-history, carrier, and filename/JCS boundaries are now explicitly separated and R21 requires distinct outcomes. |

## Trust, UX, and scope assessment

R15 correctly keeps reservation evidence separate from paid admission, model
identity, pricing, settlement, enforcement, and activation (`R15:838-861`; 
`R21:282-287`). It also states the historical-audit limitation truthfully: an
unvisited superseded carrier is not claimed verified (`R15:70-76,743-749`). No
additional trust-tier or economics authority is justified by this plan.

The scope remains a very large replacement of a working 1,024-entry R4 store.
The source has none of the proposed formats, so passing old tests would provide
no incremental confidence. After the plan gate closes, implementation should be
split into reviewable, unreachable codec/storage slices behind the still-old
selected format, with one final compatibility cutover only after every literal
vector and crash oracle passes. Calling all eight implementation stages one
“unshippable compatibility slice” (`R15:826-836`) must not be used to avoid the
repository's bounded-diff review requirement.

## Approval decision

The implementation gate remains closed. R15/R21 has **8 High findings** and
therefore does not meet the required zero Critical/High/Medium threshold. No
finding was downgraded, no acceptance criterion was weakened, and no source or
test implementation is authorized by this review.
