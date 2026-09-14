# Build 1 reservation search progress R9 — independent plan gate (Sol)

Date: 2026-09-11. Reviewer: independent GPT-5.6 Sol plan-gate lane.

Verdict: **FAIL / NOT APPROVED FOR IMPLEMENTATION**. Architectural status:
**BLOCK**. Findings: **0 Critical, 5 High, 1 Medium, 0 Low**.

R9 correctly removes cross-invocation kernel/process authority, corrects the
three-internal-page abort cascades, adds selected empty-directory intent states,
and gives concrete macOS pathname-resolution and work-object formats. The exact
1 GiB multiplications in R9/R15 are arithmetically correct. The combined R4–R9
contract is still not implementable: no selected pre-genesis object can own the
activation/checkpoint CAS; checkpoint bootstrap and mutable digest rules
contradict one another; partial merge/build work is not durably rooted; the
persisted identities cannot detect required in-place changes; allocation body
crash suffixes and directory charging remain open; and R15 mistakes the
393,216-byte reservation envelope for a reachable actual encoded charge.

## Frozen inputs and source inspected

The requested hashes were independently recomputed and matched:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r9.md` | `d8b48f6ebed050a3c5745dd30a3d5e8cb40621cf879e4b148e985c3f4b503c93` |
| `test-spec-r15-reservation-r9-corrections.md` | `f32b391f8dca8e5b68a85964eda76172b8d8de45f7d0825f9a011b8d5dae7ada` |
| Failed R8 review | `4c853a5322c050350bcf000cc29a0e2f95c72f633f35beb9e7b2f4e592c05bf3` |

The governing R4–R8 addenda, R11–R14 test specifications, current transaction
store/evidence/retention/reservation-migration sources, current command/app
process topology, and maximum-shape measurement evidence were inspected. No
source or test was edited.

## Critical (0)

None.

## High (5)

### R9-PLAN-H1 — the durable activation has no selected pre-genesis authority or complete CAS

**Severity:** High. **Confidence:** High.

R9 says a selected projection owns one activation object, and that the active
index and projection bind its UUID, generation, state, checkpoint, and aggregate
root (`reservation-search-progress-addendum-r9.md:53-86`). It defines neither a
direct path nor a selector/publication order for that activation object. Section
7.1 lists work, checkpoint-slot, and selector paths but no activation-object path
(`:361-376`). R9 also expressly replaces R8 section 5.3, so R8's only concrete
activation-lock path is no longer governing (`:21-32`; R8 `:290-325`).

The proposed binding is incompatible with retained R7 authority. R7 says the
only transition from the pre-R7 graph is `genesis-v2`, which first publishes the
v2 projection and v5 index, and its inductive transition table is exhaustive
(`reservation-search-progress-addendum-r7.md:62-124`). R9 instead requires
multiple pre-genesis activation/checkpoint CAS generations in that same
index/projection, without amending their closed schemas or transition table.
Current source confirms the shipped authority is still one v2–v4 active-index
file with none of these fields (`ModelCatalogTransactionRetention.swift:6-30,
191-221`). A detached activation file cannot be authority; rewriting the future
v2 projection before genesis violates the retained base-case rule.

**Consequence.** A new CLI/app process cannot determine which activation object
is selected after a crash, and compatible writers cannot reliably consult the
claimed logical fence. The no-held-resource direction is sound, but R8-PLAN-H1
is not closed without a durable selection protocol.

**Required correction.** Define the exact activation-lock path and safe
open/create rules; define the activation object's direct path, selector, closed
pre-genesis schema, and write/fsync/rename/directory-fsync/CAS order; and amend
the governing format/index/projection schemas and exhaustive transition table.
Freeze old/candidate/new bytes for every crash boundary and prove that one
selected pre-genesis record survives process exit without making genesis occur
early.

### R9-PLAN-H2 — checkpoint bootstrap, digest mutability, and partial-work authority conflict

**Severity:** High. **Confidence:** High.

Activation generation zero is selected before capture, all not-yet-produced SHA
fields are null, and no non-null digest may ever be replaced
(`reservation-search-progress-addendum-r9.md:76-81`). Yet every checkpoint
publication must CAS a new `checkpointSHA256` into that activation (`:500-511`),
and row/verification work roots necessarily advance over several generations.
The initial checkpoint also requires both path-receipt digests non-null
(`:477-498`), although generation-zero activation precedes the initial complete
name/path capture (`:174-181`). No legal first invocation satisfies all three
rules.

The durable graph is also incomplete during multi-group work. R9 defines a
`workKind: runs` work root, but neither activation nor checkpoint has a
`runWorkRootSHA256`; `sortedRunSHA256` is the terminal result. After one of
several merge groups is selected, the checkpoint cursors do not name the set of
completed merge manifests needed by the next invocation. Building has the same
ambiguity between an advancing tree work root and the terminal tree root. The
generic statement that ordered objects are named does not specify which
checkpoint field selects each intermediate work root (`:398-444,464-498,
520-529`). R15 nevertheless requires more than 32 runs, multiple passes, retry
byte identity, and recovery of only the missing suffix (`test-spec-r15-...
:120-152`).

**Consequence.** Implementations must either replace forbidden non-null digests,
trust unselected partial output, rescan/rederive prior groups, or invent fields
and bootstrap states. R8-PLAN-H4 remains open.

**Required correction.** Separate immutable terminal result fields from mutable
selected-progress pointers. Define a legal activation/checkpoint generation-zero
pair, every joint generation relation, and exact phase transition/nullability
rules. Add selected current run/tree/verification work-root digests (or an
equivalent complete rooted frontier) that name every prior output required by
the next bounded invocation. Freeze independent bytes and crash recovery for
each intermediate merge group, pass, tree level, and verification block.

### R9-PLAN-H3 — the portable identities cannot enforce the retained no-mutation boundary

**Severity:** High. **Confidence:** High.

R9 retains strict post-capture identity (`reservation-search-progress-addendum-
r9.md:34-43`). The inherited rule requires stable size and metadata and rejects
same-inode in-place mutation through final CAS
(`reservation-search-progress-addendum-r6.md:260-275`). R9's selected name entry
omits byte length, modification/change times, and body digest, while its row
identity omits both modification/change times (`reservation-search-progress-
addendum-r9.md:176-197,378-396`). Thus a same-inode certificate change after
name selection but before row open cannot be distinguished from the selected
source. R15 explicitly requires that before-open change to fail
(`test-spec-r15-...:112-118`).

There is a second uncovered interval after terminal row verification. The final
CAS rechecks only pathname components and the transaction-root time tuple
(`reservation-search-progress-addendum-r9.md:205-216`). An in-place same-length
write changes the file's timestamps/bytes, not its parent directory identity or
necessarily the transaction-root tuple. It can therefore occur after the final
body read and before genesis without changing the namespace digest, which hashes
only name/type/device/inode (`:148-167`). Current production evidence includes
size, mtime, and ctime precisely to reject that class
(`ModelCatalogTransactionEvidence.swift:35-92`).

**Consequence.** Genesis can select a tree whose rooted body bytes no longer
occupy the direct authoritative paths, and R15's in-place-mutation oracle is not
implementable.

**Required correction.** Persist the full required file witness from name
capture onward, including size and modification/change times, and define the
final bounded validation that closes the interval from the last body read to
genesis. The test must mutate same-inode bytes before row open, during read,
after verification, and immediately before CAS. If the chosen final witness
walk cannot meet eight seconds, the plan must change rather than weaken the
identity claim.

### R9-PLAN-H4 — allocation materialization still has unclassified durable body suffixes

**Severity:** High. **Confidence:** High.

R9 closes the empty-directory boundary through A3/A4, but not the following
immutable writes. A4 requires an exact empty directory and may create primary;
A5 requires the selected phase's exact ordered prefix
(`reservation-search-progress-addendum-r9.md:233-258`). The body must be durable
before the phase CAS. Death after primary fsync but before the A5-primary CAS
leaves selected A4 with a nonempty directory, which R9 classifies as protected
rather than a recoverable suffix. The same gap repeats after origin, class, and
lineage durability before their phase CAS. R15 injects death around immutable
creates/fsyncs and retains the prior real-death matrix, but supplies no expected
selected state for these bytes (`test-spec-r15-...:39-65,162-190,250-274`).

R9 also never assigns the 4,096-byte directory charge to an exact A3/A4 CAS or
states the corresponding `materializedChargeBytes`/reserved/slack delta, although
the selected capacity equations must hold at every state (`reservation-search-
progress-addendum-r8.md:130-143`; R9 `:220-260,341-352`).

**Consequence.** A real crash can wedge forward-only allocation and leave two
implementations with different charged/materialized counters. The prior empty-
directory finding is only partly closed.

**Required correction.** For directory, primary, origin, class, and lineage,
define each selected pre-write intent, permitted absent/equal durable candidate,
post-durability CAS, and exact charge delta. Alternatively define a single
selected phase that explicitly admits only the next byte-identical unselected
object. R15 must assert disk inventory and all four capacity counters immediately
before and after each create/fsync/CAS/death boundary.

### R9-PLAN-H5 — R15 treats a conservative abort envelope as a reachable actual charge

**Severity:** High. **Confidence:** High.

The three-page cascade and envelope arithmetic are correct:
`20,480 + 4,096 + 2*69,632 + 3*69,632 + 20,480 = 393,216`. The 1 GiB products
and remainders in R9/R15 also recompute exactly. But R9 requires
`retainedAbortChargeBytes` to be the sum of actual `F(canonicalLength)` values
(`reservation-search-progress-addendum-r9.md:296-303`). The inherited page
contract says the maximum internal page encodes below 55 KiB and forbids padding
(`reservation-search-progress-addendum-r8.md:252-267`); receipts and leaves also
have closed, generally smaller canonical encodings. Therefore a legal object
need not, and for the stated internal maximum cannot, have `F(length)=69,632`.

R15 nevertheless requires the cascade to *retain exactly* 393,216 at “maximum
canonical lengths,” freezes 2,730 “maximum-charge” actual aborts, and exercises
an all-maximum-abort history (`test-spec-r15-...:192-239`). That confuses the safe
per-object envelope reservation with reachable actual retained bytes.

**Consequence.** A correct actual-length implementation fails the mandated exact
fixture, while padding or charging the unused envelope violates canonical bytes
and R9's refund rule. The capacity test oracle is impossible as written.

**Required correction.** Keep 393,216 as the conservative admission ceiling.
Independently encode the true maximum-field receipt/leaves/nodes/root, freeze
their reachable lengths and actual retained sum, and use that value for exact
refund and all-maximum history fixtures. If fixed envelope charging is intended,
replace the actual-length rule explicitly and recompute all equations and tests.

## Medium (1)

### R9-PLAN-M1 — two exact path fields still lack canonical value definitions

**Severity:** Medium. **Confidence:** High.

The content-addressed path receipt includes `capturedAt` but gives no type,
timestamp grammar, or nullability (`reservation-search-progress-addendum-r9.md:
123-141`). R15 requires an independent exact canonical encoder for that schema
(`test-spec-r15-...:16-37`), so expected bytes cannot be derived. Separately,
section 3's path digest accepts an absolute path, while the allocation admission
defines its directory digest from the relative direct path
`.reservation-migration/lineage/<uuid>` “using the path digest domain”
(`reservation-search-progress-addendum-r9.md:118-121,220-231`). Those inputs are
not byte-equivalent and no base/join rule chooses one.

**Required correction.** Define `capturedAt` with the inherited exact timestamp
grammar or remove it from content-addressed authority. Define one canonical
absolute or root-relative materialization path encoding, including its domain,
length, normalization, join rule, and independent digest vectors.

## Low (0)

None.

## Disposition of the R8 findings

| R8 finding | R9 disposition |
|---|---|
| R8-PLAN-H1, held cross-call activation session | **Direction corrected; still open.** No FD, lock, directory stream, key, or deadline survives a call, and macOS `openat`/`O_NOFOLLOW`/`flock`/directory-fsync primitives are already exercised in current source. R9-PLAN-H1/H2 leave the durable selector/CAS and restart authority incomplete. |
| R8-PLAN-H2, missing third abort page | **Structural arithmetic closed.** Both legal cascades have three internal pages and the 393,216 envelope is correct. R9-PLAN-H5 leaves the exact actual-charge test oracle wrong. |
| R8-PLAN-H3, empty directory outside A0–A6 | **Partly closed.** A3/A4 now classify absent/empty directory states. R9-PLAN-H4 leaves subsequent durable body-before-CAS states and exact directory accounting open. |
| R8-PLAN-H4, undefined work/checkpoint/path authority | **Open.** R9 adds useful codecs and component receipts, but R9-PLAN-H1/H2/H3/M1 prevent a complete authoritative transcript and pathname/body CAS. |
| Earlier cascade/quota bounds | **Verified in part.** The five envelope sums and `1,846`, `37,449`, and `2,730` quotient/remainder arithmetic are correct; reachable actual abort maxima must be separated from envelopes. |
| Eight-second/FD feasibility and tests | **Correctly retained as implementation gates.** R15 measures the maximum namespace scan under eight seconds and FD 256 without retaining cursors. The current maximum-shape evidence shows why cross-call durable progress is necessary, but no existing run proves the new R9 behavior. |

## Verification and gate decision

Verification was static and adversarial because R9 is a pre-implementation
proposal that authorizes no source or test change. It covered the exact input
hashes, all R8 findings, governing R4–R8 authority, current Swift process/storage
topology, macOS descriptor and durability mechanisms, activation and checkpoint
generation order, root/path/body identity, allocation crash states, B+tree
cascade shapes, actual versus envelope charging, quota products, eight-second/FD
bounds, and R15's independent-oracle and real-death coverage.

Final recommendation: **REQUEST CHANGES / FAIL**. Correct R9-PLAN-H1 through H5
and M1, update R15's exact fixtures, freeze new hashes, and obtain a fresh
independent zero-Critical/High/Medium plan gate before implementation.
