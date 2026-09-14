# Build 1 reservation search progress R8 — independent plan gate (Sol)

Date: 2026-09-11. Reviewer: independent GPT-5.6 Sol plan-gate lane.

Verdict: **FAIL / NOT APPROVED FOR IMPLEMENTATION**. Architectural status:
**BLOCK**. Findings: **0 Critical, 4 High, 0 Medium, 0 Low**.

R8 resolves the naming contradiction between one-time activation and ordinary
inductive retirement-root replacement, separates the illegal shared-admission
maximum fixtures, and introduces rooted terminal allocation-abort evidence. The
combined R4–R8 contract is still not implementable. The activation session has
no legal owner across its required multi-call lifetime and holds the global
journal lock across bulk work; the abort-tree maximum omits a third internal
page at a legal cascading split; an empty materialization directory creates a
state outside A0–A6; and the v1 work/checkpoint transcript remains incomplete
and lacks the pathname-identity CAS required by its own tests.

## Frozen inputs and source inspected

The requested hashes were independently recomputed and matched:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r8.md` | `45514011e40023e57c2a9cd96c01e3d79f40b5578c76469c2c1f0d2d93946789` |
| `test-spec-r14-reservation-r8-corrections.md` | `8db9e33879ac17cc5373ceee0788a5249633541736d095a79d4f93c03fbb4422` |
| Failed R7 review | `8f1db48647e8b9ad497e964866a9e765e19f729181f699e5b8111dedbda8381f` |

The governing R4–R7 plans matched `3bb911a0...`, `051eb952...`,
`b26a480d...`, and `fa1a9178...`; R11–R13 matched `96a51cb4...`,
`61f2dc00...`, and `cdbb44bf...`; and the failed R5/R6 reviews matched
`7b1e71fd...` and `e985c269...`. The three frozen R4 audits and current command
and app process surfaces were inspected.

The six governing source files remain byte-identical to the R4 implementation
manifest: bindings `60abe294...`, evidence `b49c13fa...`, migration
`5bc526e3...`, reservation migration `c8505d5d...`, retention `0a6b4873...`,
and transactions `65cbb0e9...`. The three frozen tests also remain
`a0c700eb...`, `bf45cf3a...`, and `009611a1...`. No implementation or test was
edited.

## Critical (0)

None.

## High (4)

### R8-PLAN-H1 — the held activation session cannot cross the required bounded calls

**Severity:** High. **Confidence:** High.

**Evidence.** R8 retains every correction not expressly replaced
(`reservation-search-progress-addendum-r8.md:19-44`) and retains an eight-second
deadline for each activation slice without helper renewal (`:52-56`). The
inherited cutover discipline says no lock or descriptor set survives a call and
bulk evidence capture occurs outside the journal lock
(`reservation-search-progress-addendum-r4.md:365-375`); R5 likewise permits a
maximum migration to advance over several calls without renewing the caller's
deadline (`reservation-search-progress-addendum-r5.md:388-404`). R8 instead
requires the activation process to hold the journal lock, directory FD, `DIR *`,
activation-lock FD, and in-memory HMAC key continuously until genesis selection
(`reservation-search-progress-addendum-r8.md:290-310,352-373`). R14 makes the
conflict executable by requiring progress across separate slices in the same
live process (`test-spec-r14-reservation-r8-corrections.md:201-214`).

The frozen product has no cross-invocation activation-session owner. A catalog
operation is an `AsyncParsableCommand` invocation
(`phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:437-503`) with one
eight-second `ModelTransactionWorkBudget`
(`phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift:5-27`).
The app launches a new `Process`, waits for it to exit, and returns that result
(`phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:1358-1423`).
R8 neither adds nor specifies a persistent session service, request protocol,
or lawful deadline boundary.

**Consequence.** A history that needs more than one slice has no conforming
execution. Exiting the call loses the FDs, lock, and key and forces entry-zero
restart. Keeping the command alive cannot obtain a fresh per-call deadline
without the forbidden renewal. Holding the global journal lock through
enumeration, merge, build, and two-pass verification also contradicts the
inherited outside-lock bulk rule and can block heartbeat/control for the entire
unbounded activation rather than one bounded final CAS. R6-PLAN-H4 and the R4
resource/availability findings therefore remain open.

**Required correction.** Define an executable activation owner and request
lifetime that exists in the shipped process topology, including how a new
eight-second caller slice attaches without renewing an old call, how
cancellation and owner death release every FD/lock, and how heartbeat/control
remain bounded. Keep bulk enumeration/build work outside the global journal
lock; use the compatible-writer exclusion fence for the session and acquire the
journal lock only for bounded recapture/selection CAS steps. R14 must exercise
the real CLI/app entrypoints across slice return, cancellation, process death,
and concurrent control, not only an in-process fixture object.

### R8-PLAN-H2 — the abort-tree maximum omits a legal third internal page

**Severity:** High. **Confidence:** High.

**Evidence.** R8 permits an allocation-abort tree of height three but says its
worst insertion creates at most two leaves, two internal pages, one root
envelope, one receipt, and one directory, totaling 323,584 bytes
(`reservation-search-progress-addendum-r8.md:435-442`). Its insertion algorithm
splits a 65-row leaf into 32/33, splits a 257-child internal page into 128/129,
and creates a new top page when the top splits (`:375-388`). A legal insertion
that grows height two to height three therefore materializes two leaf pages, two
replacement level-one pages, **and one new level-two top page** before the root
envelope: three internal pages, not two. Sequential insertion reaches 257 leaves
at 8,225 rows (`65 + 255 * 32`), well below R8's admitted 37,449 abort-row bound.
The same three-page shape recurs when a non-top level-one page splits under an
existing level-two top.

Using R8's own charges, the legal maximum is:

```text
receipt 20,480 + UUID directory 4,096 + two leaves 139,264
+ three internal pages 208,896 + root envelope 20,480
= 393,216 bytes
```

R14 freezes the incorrect two-node/323,584-byte value as exact
(`test-spec-r14-reservation-r8-corrections.md:225-244`) and never requires the
height-growth cascade.

**Consequence.** At that legal split, a conforming implementation must either
omit a retained authority page, exceed the asserted retained-abort charge,
silently charge after admission, or violate the capacity equation. The
581,632-byte mutually exclusive admission can cover the corrected shape, but
R8's `retainedAbortChargeBytes`, refund, `Wpeak`, and exact quota fixtures are
wrong. R7-PLAN-H2 and R6-PLAN-H3 remain open.

**Required correction.** Recompute every abort successor shape by old height and
leaf/internal overflow, including height-two-to-three growth and a level-one
split below an existing top. Set the maximum retained abort charge to at least
393,216 bytes under the frozen maxima, derive the exact actual charge before A4,
and use that value consistently in refund and peak-space arithmetic. Extend R14
with independently encoded cascading-split fixtures and disk inventory after
each of the three internal-page writes.

### R8-PLAN-H3 — an empty allocation directory is outside the closed A0–A6 machine

**Severity:** High. **Confidence:** High.

**Evidence.** R8 defines A2 as an allocating row with every allocation body and
per-UUID directory absent, while A3 requires a nonempty valid body prefix
(`reservation-search-progress-addendum-r8.md:159-169`). It then says one empty
per-UUID directory makes abort illegal and forces forward A3 completion
(`:171-177`). The durable state immediately after creating that directory and
before writing the initial primary is therefore neither A2 nor A3, although R8
calls A0–A6 the only legal states. R14 explicitly creates the empty directory,
requires abort rejection, and says to preserve A2/A3 for completion
(`test-spec-r14-reservation-r8-corrections.md:131-139`); it also injects storage
faults and real death at directory boundaries (`:289-302`).

**Consequence.** After real death at the directory-create boundary, recovery has
no authoritative state classification or exact permitted suffix. Treating the
row as A2 contradicts A2's all-directory absence; treating it as A3 contradicts
A3's required nonempty body prefix. Implementations can diverge between
protected wedge, directory removal, abort/refund, or forward completion, so the
claimed closed abort/refund protocol and R7-PLAN-H3 closure are false.

**Required correction.** Add a closed materializing state/fact for the exact
expected directory prefix with zero complete bodies, or redefine A3 explicitly
to include that state. Bind the directory path/identity and its materialized
charge, forbid refund from it if that is the intended boundary, and specify the
only idempotent forward suffix. Reject wrong/extra/unsafe directories without
deleting evidence. R14 must kill the real writer immediately after each
directory creation and prove the exact state, counters, and recovery result.

### R8-PLAN-H4 — v1 work/checkpoint bytes and root-path change detection remain undefined

**Severity:** High. **Confidence:** High.

**Evidence.** R8 defines final tree pages and roots, but the bulk builder writes
canonical content-addressed work blocks and orders merge runs by
`(firstUUID, creationOrdinal)` without defining a work-block/run schema, direct
path, maximum, canonical byte layout, creation-ordinal assignment, or the
`workRootSHA256` chain (`reservation-search-progress-addendum-r8.md:269-288`).
The checkpoint lists fields and broad phases, but does not define the legal
phase-transition table, which fields are applicable/null in each phase, how
merge outputs bind prior runs, or the write/fsync/rename/directory-fsync order
that makes a slot selectable (`:320-365`). R14 nevertheless requires an
independent byte-identical work-root chain and rejects an unfsynced selected
slot (`test-spec-r14-reservation-r8-corrections.md:182-199`); those expected
bytes and validity decisions cannot be derived from R8.

The stable-directory rule compares repeated `fstat` values only on the already
opened directory FD (`reservation-search-progress-addendum-r8.md:301-318`). If
the transaction-root pathname is renamed and replaced, that FD and all its
witness fields remain unchanged. R14 explicitly requires this attack to fail on
a witness/path CAS (`test-spec-r14-reservation-r8-corrections.md:174-180`), but
R8 defines no final re-resolution of the pathname, parent-directory evidence,
or identity comparison binding the selected index to the held directory.

**Consequence.** Two implementations can produce different checkpoint/work
bytes or accept different crash suffixes while claiming the same final tree.
After a root-path replacement, one implementation can select genesis in a
detached old directory while another can combine old-FD enumeration with a new
path's journal. The two-pass transcript does not resolve this namespace change.
R7-PLAN-H4 remains open, and R14-05 is not an implementable oracle.

**Required correction.** Specify closed work-block, run-manifest, merge-output,
work-root, selector, and slot encodings with direct paths and size bounds; define
creation ordinals, every phase invariant/nullability rule, digest chaining, and
the exact durable publication order. At final selection, re-open the configured
transaction root through a stable parent FD and require its no-follow identity
to equal the held enumeration FD, with the parent/path evidence bound into the
checkpoint and genesis CAS. Add independent bytes for every phase and real-death
boundary plus root rename/replacement before and after final recapture.

## Medium (0)

None.

## Low (0)

None.

## Disposition of frozen findings

| Frozen finding | R8 disposition |
|---|---|
| R4 global allocation gate, generation equality, exact origin, primary-first departure, pending stabilization, rollback, queued cancel, and prior-binary fence | **Retained at plan level; implementation evidence remains required.** R14 carries the relevant hostile cases. |
| R4 owner/FD/eight-second availability and qualification findings | **Open.** R8-PLAN-H1 introduces an unowned multi-slice live session and holds the global journal lock through bulk work. |
| R4/R6 global graph versus ordinary target-local validation; R7-PLAN-H1 | **Closed at plan level.** Genesis and named phase transitions are global; ordinary retirement is an inductive path update. |
| R5-PLAN-H1 | **Closed at plan level.** Ordinary paths remain target-local and projection-rooted. |
| R5-PLAN-H2 / R6-PLAN-H3 / R7-PLAN-H2 | **Open.** Retirement-v2 charging is corrected, but R8-PLAN-H2 leaves one legal abort-tree page uncharged and freezes the wrong exact maximum. |
| R5-PLAN-H3 | **Closed in authority shape, pending implementation.** V2 retirement remains rooted and binds dynamic departure lineage. |
| R5-PLAN-M1 | **Closed.** Byte-equivalent pre-capture identity and strict post-capture identity remain coherent. |
| R6-PLAN-H2 / R7-PLAN-H3 | **Open.** Rooted abort evidence is a sound direction, but R8-PLAN-H3 leaves a production crash state outside the only legal state machine. |
| R6-PLAN-H4 / R7-PLAN-H4 | **Open.** R8 fixes page packing and post-death cursor reuse, but R8-PLAN-H1/H4 leave session execution, work/checkpoint authority, and root-path stability incomplete. |
| R7-PLAN-M1 | **Closed.** R8 and R14 use five separate legal maximum fixtures and reject simultaneous shared admissions. |
| Earlier missing-test-evidence findings | **Open as an implementation gate.** R14 is broad, but its impossible/incorrect cases above cannot prove the current plan; the frozen R4 implementation still contains none of the R8 formats. |

## Verification and gate decision

Verification was static and adversarial because R8 is a pre-implementation
proposal and expressly authorizes no source or test change. It covered exact
input/source hashes, every governing R4–R8 plan and R11–R14 test specification,
the failed R4–R7 audits, frozen command/app process lifetime, transition
authority, allocation abort/refund idempotency, deterministic tree growth,
retained page/root quota arithmetic, checkpoint/change detection, shared
admission exclusivity, direct-read/body/descriptor bounds, storage faults, and
real-death ordering. No existing test command was treated as evidence for
unimplemented R8 behavior.

Final recommendation: **REQUEST CHANGES / FAIL**. Correct R8-PLAN-H1 through H4,
update the paired test specification and exact capacity fixtures, freeze new
hashes, and obtain a fresh independent zero-Critical/High/Medium plan gate before
any source or test implementation.
