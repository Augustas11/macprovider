# Build 1 reservation search progress R16/R22 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: exact R16 plan and R22 test specification, inspected independently
against the failed R15 gate, the governing R10/R11 and current SPEC-001
contracts, current Swift reservation/artifact source, and `origin/main`. No
source or test implementation was authorized or changed by this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 6 High, 0 Medium, 0 Low.**

R16 fixes three important R15 defects in architectural direction: a selected
root is promoted only after its carrier exists, the terminal abort receipt no
longer attests a future pending clear, and A3-or-later cancellation preserves
the inherited forward-only economic boundary. It also correctly moves large
artifact byte publication out of the short reservation invocation.

The implementation gate nevertheless remains closed. The first selected
carrier-directory intent has no field in the exact selector/bootstrap schema;
the supposedly durable lease identity has no digest definition; and the
standalone codec still leaves required unions, null matrices, discriminators,
and record types undefined. More fundamentally, committed source/merge/tree/
verification progress has no selected root in the selector and the capacity
table does not pay for the checkpoint/activation publications that would make
it authoritative. The artifact shortcut also contradicts the current
normative requirement that adoption fully verify current integrity, and its GC
rule has an unpinned validation-to-selection race plus no durable post-terminal
custody rule.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r16.md` | `ca385468c1f8cc4646c227a9a7b06b49d85726695372462c9e03ec1f4f9ab346` |
| `test-spec-r22-reservation-r16-corrections.md` | `9331d8d3b069c3625abcbcbb12e2a20d4f028c06c416cab3a5dd6819fac79747` |
| Failed R15 review | `f0843c6b3c651779e34214b8d822784503ae78083516016203218a7fe30a17c2` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`, matching the plan. The
working reservation implementation is still the R4 implementation identified
by R16; the relevant source digests are:

| Current source | SHA-256 |
|---|---|
| `ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `ModelCatalogTransactionStorage.swift` | `33cf08501a9d0e8509e8433d1cde7537bf9f660b814da0bf26fa1287a104916e` |
| `ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |

Repository search confirms that current Swift source/tests contain no
`model_catalog_selector.v7`, `budgetLease.v4`, `rootPromotion.v1`,
`adoption_ticket.v1`, or `terminal-abort-successor`. Existing tests remain
baseline evidence and cannot approve R16.

The advertised arithmetic itself was independently reproduced:

```text
9,937 * 453,215,218,612 + 18,309 = 4,503,599,627,365,753
9,937 * 453,215,218,613 + 18,309 = 4,503,599,627,375,690
2^52                                 = 4,503,599,627,370,496
1,046 * 453,215,218,612 + 1,928 = 474,063,118,670,080
9,937 * 1,024 + 18,309             = 10,193,797
1,046 * 1,024 + 1,928              = 1,073,032
```

Those calculations match R16/R22. Finding H4 shows why they still price an
incomplete authority graph.

## Critical (0)

None.

## High (6)

### R16-PLAN-H1 — generation zero cannot encode the selected carrier-directory intent

**Severity:** High. **Confidence:** High.

**Evidence.** Generation zero is required to contain
`bootstrapState.phase="carrier-directory-intent"` and an exact
`directoryIntent.v1`; that selected intent is the sole authority for the first
post-fence `mkdirat` (`R16:120-135`). The exact `bootstrapState.v2` key set is
later frozen as only `phase,sourceRowCount,sourceWitnessSHA256,unitLimit,
unitsConsumed,unitsReleased,carrierLimit,carriersConsumed,byteLimit,
bytesConsumed,bytesReleased,nextBudgetRowOrdinal,activationDirectoryIdentity,
carrierDirectoryIdentity,bootstrapScaffoldChargeBytes,
bootstrapDirectoryChargeBytes` (`R16:333-339`). It has no `directoryIntent`
field. The selector has no separate bootstrap-intent field, and generation
zero cannot use the ordinary `pendingTransaction.v2` without a lease,
transaction UUID, edge intent, and other fields that R16 says bootstrap does
not yet have (`R16:272-301`). R16 also does not enumerate the legal
`bootstrapState.phase` values or the generation-zero/revision-one null matrix.

R22 requires an independent encoder to freeze generation zero and to prove the
exact selected intent before directory creation (`R22:20-47`). No byte-valid
object satisfying both exact schemas exists.

**Consequence.** The carrier directory must either be created without selected
authority, placed under an invented field, or encoded as an ordinary pending
transaction that violates the frozen bootstrap. Crash recovery cannot
distinguish an authorized empty candidate from unrelated filesystem content.
This reopens R15 H1 at the first post-format mutation.

**Required correction.** Add one exact, closed representation for the selected
directory intent. Freeze its location, schema discriminator, phase enum, null
rules, generation-zero bytes, revision-one bytes, and the rule that removes or
retains the intent after identity adoption. Define carrier-limit unused
accounting as well: `bootstrapState.v2` currently has no released-carrier field
despite requiring zero unused bootstrap authority. R22 must independently
encode these states and kill at every format/selector/mkdir/fsync boundary.

### R16-PLAN-H2 — the stable no-expiry lease identity and close binding have no digest contract

**Severity:** High. **Confidence:** High.

**Evidence.** R16 defines the digest of `leaseAuthorization.v2`
(`R16:152-167`) and embeds mutable counters in `budgetLease.v4`
(`R16:169-175`). It then requires the budget entry to store the same
`openLeaseDigest`, receipts to store `budgetLeaseDigest`, and all 64 target
edges plus reserve/close retries to retain the same durable lease identity
(`R16:177-190,341-350,401-402`). The digest registry says lease digests use
their “separately stated domains” (`R16:368-382`), but no digest preimage or
domain for `budgetLease.v4` is stated. It is therefore unclear whether the
stable identity is the authorization digest, a digest of the initial lease, or
a digest of each mutable selected lease state. The last choice necessarily
changes whenever counters/state change; the first two require an independently
named state digest if receipts are to prove the selected counters.

`controlAuthorization.v2.targetBudgetEntrySHA256` similarly has no explicit
rule binding the final promoted budget root, closing lease state, released
counters, and last close outcome. R22 asks an independent encoder to freeze all
of this and to resume the same identity across 64 edges (`R22:49-70`), but the
normative bytes are absent.

**Consequence.** Implementations can disagree on which digest opens/closes the
budget entry and whether a replayed carrier consumed the same selected lease
state. A stale process can appear to hold the same authorization while
presenting different counters, or a correct 64-edge recovery can be rejected
because its full lease digest changed. R15 H2 is improved but not closed.

**Required correction.** Name and domain-separate two concepts explicitly: a
stable lease authorization/identity digest and, if required, a digest of each
selected mutable lease state. Freeze which value appears in every budget
entry, receipt, pending selector, continuation, and close record. Define the
exact final-entry simulation and promoted-root equality checked by
`targetBudgetEntrySHA256`. Add independent 63/64/65 vectors that mutate every
counter and prove stale-state substitution fails while the stable identity
does not change.

### R16-PLAN-H3 — the claimed standalone codec remains incomplete and internally inconsistent

**Severity:** High. **Confidence:** High.

**Evidence.** R16 calls section 6 a standalone codec and requires unknown,
missing, duplicate, and illegal-null fields to reject (`R16:234-246`). It does
not publish the null/type/reference matrix needed to do that. Examples include:

* selector fields such as `selectedActivationReference`,
  `selectedCheckpointReference`, every tree root, `lastReceiptReference`,
  `carrierAuditState`, and the empty-root case have no frozen reference type or
  legal-null state (`R16:272-301`);
* `targetDescriptor.v4` says “exactly the named coordinates” are non-null but
  never maps the eight descriptor kinds to their required/null fields
  (`R16:316-325`);
* `sourceBinding`, `targetBinding`, `activeIntentReference`,
  `completedCompensationSteps`, `operationInputReferences`, and multiple work-
  root suffix references lack closed sub-schemas and null/bound rules
  (`R16:303-367,384-408`);
* `carrierRecordReference.v2` uses `carrierLengthBytes`, while the exact
  `carrierReference.v2` used for the same complete carrier uses
  `payloadLengthBytes`; no conversion/equality rule defines the promotion input
  (`R16:194-216,257-270`);
* the blanket `*SHA256` content/transcript rule has no closed exception table
  for raw selected digests such as prior index, migration source, format fence,
  preparation seal/receipt, record references, and artifact catalog identity
  (`R16:368-382`).

The materialization graph also names `binding-publish`, but the record registry
contains no binding record schema (`R16:384-408,490-515`). R22 asks a test-only
encoder sharing no production helpers to freeze every literal and every null/
reference cross-product (`R22:88-113`). It would have to invent these bytes.

**Consequence.** Two conforming implementations can encode different selector,
intent, binding, receipt, and promoted-root graphs while each claims R16. Some
malformed cross-version graphs cannot be distinguished from valid ones. This
leaves the trust and compatibility defect in R15 H4 open.

**Required correction.** Publish a genuinely closed registry: exact schema
discriminator and key set for every embedded/record object; scalar widths and
bounds; all enums; every reference union; every per-state/per-kind null matrix;
every digest domain and exception; and the exact equality/promotion mapping
between carrier and carrier-record references. Add the missing binding record
or remove its transition. R22 must generate vectors from those literals alone,
without consulting R14/R15 prose or production types.

### R16-PLAN-H4 — intermediate work has no selected authority path, so the capacity table omits required publications

**Severity:** High. **Confidence:** High.

**Evidence.** The selector directly selects storage, path, lifecycle, and
budget roots, but has no `sequenceRegistryRootReference` or `workRootReference`
(`R16:272-284`). Those roots exist only inside `activation_record.v3` and
`checkpoint_record.v3` (`R16:403-404`). Therefore a committed source capture,
merge, tree-build, or verification mutation becomes authoritative only if its
successor selector also selects a new checkpoint/activation record that names
the new sequence/work root.

The transition table counts source, merge, tree, and verification logical
mutations without any checkpoint or activation publication. Only the end of
the materialization list names `activation-record` and `checkpoint-record`
(`R16:482-515`). The fixed-state cross-products likewise list state names but
do not give an ordered carrier graph that roots each new work value
(`R16:521-539`). R16 then derives 3,306 ordinary units per row, 6,612 control
units, and the carrier formulas from those incomplete counts
(`R16:541-565`). R22 repeats the author's counts while asking an independent
semantic generator to require every needed phase/root publication
(`R22:115-148`); those requirements cannot both pass.

**Consequence.** An implementation that stays within the advertised limits
can publish carriers whose progress roots are not selected authority. An
implementation that adds the checkpoint/activation records needed for recovery
can exceed the frozen unit, carrier, byte, and revision limits. Crashes between
work publication and a later checkpoint have no specified old/pending/new
authority. R15 H5 and the capacity proof remain open.

**Required correction.** Choose one authority model. Either add current
sequence/work roots to the selector with exact successor rules, or include the
checkpoint/activation publication that selects every intermediate mutation.
Expand every source/capture/merge/tree/verification/retry transition into its
literal pending selector, target carrier(s), receipt, promoted root, checkpoint/
activation, successor, reserve, close, and terminal steps. Recompute all unit,
control, carrier, byte, and selector-revision bounds from that graph, then make
R22 derive rather than restate the resulting counts.

### R16-PLAN-H5 — preverified ticket adoption violates the governing fresh-integrity contract

**Severity:** High. **Confidence:** High.

**Evidence.** Current SPEC-001 is explicit: a publication seal is historical
evidence only, root-inode checks cannot detect later descendant writes, and
“Fresh discovery readiness, evaluation and adoption MUST still fully verify
current artifact integrity” (`SPEC-001:4324`). Current source states the same
boundary: `ModelCatalogArtifactSeal` is evidence of past verification and is
never a substitute for adoption verification
(`ModelCatalogArtifactSeal.swift:5-16`). Its placement observation proves only
the root directory placement, not unchanged descendants
(`ModelCatalogArtifactSeal.swift:60-84`).

R16 deliberately makes reservation adoption read no artifact payload. It
checks a historical preparation receipt, ticket/seal digests, and root
metadata, then selects the adoption record (`R16:628-663`). The proposed later
MLX check revalidates seal/file identities, not full current content, and occurs
after adoption has already been selected. R22 goes further and requires proof
that adoption performs no payload open/read/hash while treating the ticket as
the adoption integrity input (`R22:177-200`). No SPEC update is proposed, and a
historical seal cannot be promoted into the current-integrity claim that the
normative owner contract expressly withholds.

**Consequence.** An artifact modified after preparation can receive selected
adoption evidence without the required current full verification. Later
metadata checking may block one serving attempt, but it cannot retroactively
make the adoption valid and does not prove content against the signed digest.
This weakens the trusted-artifact boundary in Build 1 and could be composed
incorrectly with readiness/admission code.

**Required correction.** Preserve the short reservation bound without
weakening freshness: perform an adoption-specific full content verification in
the long-running owner path, then hand the exact freshly verified object to the
short selector through a frozen custody protocol that prevents descendant
mutation/replacement between verification and selection. Define the fresh
receipt, descriptor/identity custody, cancellation point, and serving handoff
normatively. If the owner contract itself must change, update and gate SPEC-001
before implementing; do not silently redefine “adoption.” R22 must corrupt
content after preparation and at every verification/handoff boundary and prove
rejection before selected adoption.

### R16-PLAN-H6 — artifact custody is unpinned across validation, selection, and terminal use

**Severity:** High. **Confidence:** High.

**Evidence.** R16 validates the ticket/seal/root before selecting the pending
adoption intent (`R16:653-668`). It says GC must not remove an artifact while a
ticket is selected by pending work, but permits inactive-artifact GC under the
existing store policy and says nothing about coordination before pending
selection or after terminal selection clears pending (`R16:665-671`). The
current `DurableModelArtifactStore.gcInactive` API receives only a caller-
provided `keeping` set and recursively removes any other durable directory;
there is no journal/selector lease coupling in this API
(`DurableModelArtifactStore.swift:211-250`).

Thus GC can validate its keep set, while adoption validates the artifact, then
delete or rename the artifact before the pending selector is durable. After
successful terminal selection, `pendingTransaction` becomes null, so the only
explicit R16 prohibition also ends even though the selected catalog path still
depends on the artifact. R22 injects cancellation and death around adoption
records but has no GC race, active-custody lifetime, or selected-artifact
deletion case (`R22:194-200`).

**Consequence.** A selected pending or completed adoption can point at a
missing artifact, or GC can delete the incumbent during the validation-to-CAS
window. Recovery then protects instead of completing a path R16 declares
legal, and a successful catalog binding can lose its model after pending is
cleared.

**Required correction.** Define one durable pin/lease protocol shared by
adoption and GC. It must cover the interval before fresh verification begins,
the validation-to-pending CAS, every crash/retry, terminal catalog selection,
serving, replacement, and explicit later release. Freeze lock order, selected
pin authority, path/identity checks, and GC behavior for stale/corrupt pins;
never rely on an in-memory keep set assembled before the selector check. Add
adoption-versus-GC races at every selector/filesystem boundary and prove that
active artifacts remain retained until an authorized replacement/release is
durable.

## Medium (0)

None. Each identified defect affects selected filesystem authority, budget
authorization, codec interoperability, crash-recoverable progress, normative
artifact integrity, or durable artifact custody and is therefore High.

## Low (0)

None.

## Disposition of the eight R15 findings

| Failed R15 finding | R16/R22 disposition |
|---|---|
| H1 bootstrap parent cycle | **Partially resolved, still open.** The unselected activation scaffold removes the parent cycle, but H1 shows that the selected child-directory intent is not present in the exact generation-zero schema. |
| H2 lease expires before close | **Partially resolved, still open.** Removing revision expiry makes 64 edges directionally reachable, but H2 shows that the stable lease identity and mutable-state binding are undefined. |
| H3 local selected root | **Resolved in architecture direction.** Receipt-local root plus post-carrier promotion is acyclic. Final approval still depends on H3's missing closed reference/equality codecs. |
| H4 contradictory codecs/taxonomy | **Open.** R14 external run/page formats are rejected, but H3 identifies enough missing schemas, unions, null rules, and digest rules that an independent encoder still cannot implement R16 alone. |
| H5 phase work absent from limits | **Open.** Materialization phases were added, but H4 shows that source/merge/tree/verification work is not selected without uncounted checkpoint/activation publications. |
| H6 receipt claims future clear | **Resolved in architecture direction.** The final receipt lists slots 0–6 and the explicit terminal successor selects receipt/A8/null-pending atomically. Codec completion and crash vectors remain required. |
| H7 post-A3 refund | **Resolved.** A1/A2 alone may abort/refund; A3+ finishes forward with the full admitted charge or protects, and `cancelled_after_commit` is truthful. |
| H8 unbounded artifact publication | **Partially resolved, still open.** Reservation no longer publishes GiB artifact bytes and the physical proof is correctly mandatory, but H5/H6 show that historical-ticket adoption violates current integrity and lacks safe GC/custody composition. |

## Required next gate

Do not implement R16/R22. Produce a new exact plan/test revision that closes
H1–H6 without lowering the eight-second/four-FD bounds, weakening current
integrity, dropping any legal crash/cancellation/concurrency path, or changing
A3+ economics. The next independent GPT-5.6 Sol gate must inspect the complete
replacement and report zero Critical, High, and Medium findings before source
or test implementation begins.
