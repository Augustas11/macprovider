# Independent GPT-5.6 Sol review — Build 1 c944 reconciliation plan r3

Date: 2026-09-10  
Reviewer: independent GPT-5.6 Sol plan-verification lane  
Verdict: **FAIL — conflict resolution and implementation remain blocked**  
Finding count: **0 Critical, 1 High, 2 Medium, 0 Low, 3 Info**

## Reviewed inputs

- Historical Build 1 base: `914f7cafcdbcfc1805a10f4f34167218341d5587`
- Freshly fetched target `origin/main`:
  `c9445561e4fe00a073926ff2ab0fdb0536d00e37`
- Reconciliation plan r1, verified SHA-256:
  `353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`
- Reconciliation plan r2, verified SHA-256:
  `d3093609329f0177318913544fc6d0b351a26d1104b9c8cf43f176e0ff9db44a`
- Reconciliation plan r3, verified SHA-256:
  `1455757afbcbd2b9ce09f1698281fb67b893f0e5d80adaebe5016c79e5d7742f`
- Compatibility test specification r5, verified SHA-256:
  `75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
- Correction test specification r6, verified SHA-256:
  `69cded9a4aa91c68abccb9bd740f6a78e5c965d571401a8559946cbb9036ffec`
- Owner/schema correction test specification r7, verified SHA-256:
  `179672cd03554a12eb18393ba520bf560e27f1d6c1f27c84653e10d5c83533d6`
- Prior failed GPT-5.6 Sol review, verified SHA-256:
  `7a2ba41961a03c565b0f66b789966021f39e290886c1b9555617e5958e4a4544`

The supplied r6 and r7 digest identities are correct, although their actual
filenames are `test-spec-r6-c944-corrections.md` and
`test-spec-r7-c944-owner-schema-corrections.md`, rather than the supplied
`*-compatibility.md` aliases. This review used the digest-identified files.

This review inspected the complete r1+r2+r3 and r5+r6+r7 bundles, the target
c944 tree, the dirty Build 1 tree at the historical base, the current owner and
SQLite transaction implementations, and the normative SPEC-010/SPEC-047
settlement boundary. It is a pre-implementation plan gate, so implementation
tests were not run. No GPT-5.5 reviewer output was used as evidence.

## Gate result

The required zero-Critical/High/Medium gate is not met. R3 closes the precise
owner-list, SQLite-first ordering, and 24-field enumeration defects reported as
H2-R, H5, and H4-R. The complete revised bundle still lacks the authoritative
SPEC-047 schema amendment required before this money-path format can be
implemented, and r7 leaves two concrete bypasses in its proof obligations:
numeric JSON nulls and the existing direct positive-preparer setter.

## Findings

### H6 — The new money-path envelope has no authoritative SPEC-047 amendment

**Severity:** High  
**Disposition:** New gate finding.

**Evidence:** R3 defines a new closed route-snapshot contract: discriminator
`macprovider.artifact_admission.v2`, exactly 24 required fields, non-null/type
rules, and an RFC8785 digest preimage
(`origin-main-c944-reconciliation-addendum-r3.md:77-116`). Target c944 states
that the artifact route extension is owned by SPEC-047 and normatively requires
the six artifact fields for feed-derived settlement
(`c9445561:specs/SPEC-047-network-model-admission.md:117`). C944's implementation
accordingly serializes those exact six legacy fields
(`c9445561:phase4-coordinator/internal/billing/route_snapshot.go:79-88,148-155`).

The complete plan never instructs an amendment of that owner contract to define
the discriminator, the additional 18 fields, their exact types/presence rules,
or the historical classifier. R1 says to preserve c944's six-field contract,
lists SPEC-047 as an overlap path, and later asks only to reconcile governance
indexes (`origin-main-c944-reconciliation-addendum-r1.md:18-36,101-138`). Its
verification runs governance tooling but does not make the missing normative
definition exist (`r1:145-165`). The frozen Build 1 SPEC edit demonstrates the
collision: it is also version `0.1.4`, but still names only the six-field
`candidate_catalog_sha256` form and describes all-six-or-none behavior
(`specs/SPEC-047-network-model-admission.md:3,192-225`). Target c944 is already
SPEC-047 v0.1.4 with different non-primary-member semantics. R3 does not resolve
the version collision or define the combined successor requirement.

**Consequence:** Implementing r3 as written would put a new signed pricing,
session, expiry, and settlement schema into executable code without its
authoritative owner spec. Reviewers and future decoders would have two
incompatible definitions of the same SPEC-047-owned extension, and governance
index success could still coexist with an undefined money-path wire/storage
contract. A later spec reconciliation could change names or semantics after
rows have already been persisted and digested.

**Required correction:** Before source reconciliation, add an explicit plan
step to amend SPEC-047 at a new conflict-free version. The requirement must name
the discriminator and all 24 fields, their JSON types and non-null/all-or-none
rules, allowed algorithms/units and numeric bounds, cross-field signer/release/
model/session relationships, full canonical preimage, exact c944 legacy
classifier/spelling, and no-rewrite migration behavior. Reconcile SPEC-047's
v0.1.4 collision from the c944 version rather than replaying the historical-base
file wholesale; then update SPEC README/AUTHORITY/CONFORMANCE mappings as the
repository tooling requires. Add an r7 assertion that the final normative
requirement and conformance mapping name the implemented schema and tests.

### M4 — R7 does not prove rejection of numeric JSON nulls

**Severity:** Medium  
**Disposition:** New gate finding.

**Evidence:** R3 requires every one of the 24 fields to be present and non-null,
while explicitly retaining valid zero numeric rates (`r3:103-108`). R7 tests
every field missing individually, but asks for only a generic `JSON null` and
generic wrong-type case (`test-spec-r7-c944-owner-schema-corrections.md:73-84`).
Those obligations are not equivalent. Go `encoding/json` defines that JSON
`null` unmarshaled into a non-pointer scalar has no effect and produces no
error. The current integration surface uses scalar `int64` fields for billing
snapshot ID, rates, share, multiplier, and expiries
(`phase4-coordinator/internal/billing/artifact_admission.go:25-39`) and directly
unmarshals stored route JSON into the embedded evidence object
(`phase4-coordinator/internal/billing/settlement_receipts.go:845-872`). Its
validation permits zero prompt/cache/completion rates
(`artifact_admission.go:42-58`). A representative string-null test can pass
while `"admission_prompt_rate_per_mtok":null` decodes as zero and survives as a
valid rate.

**Consequence:** The test suite can report that the non-null schema is enforced
while persisted route JSON with null economic authority is accepted and
canonicalized as numeric zero. This collapses a malformed money-path input into
a legitimate zero-price authority and defeats the closed-envelope claim.

**Required correction:** Table-drive raw JSON substitution of `null` for each
of the 24 required fields, not one representative. Explicitly include all eight
integer fields, especially each of the three zero-valid rates, share, and
multiplier. Assert rejection before struct materialization, canonicalization,
digest acceptance, or settlement. Exercise wrong types per JSON type class and
use a presence/null-aware strict decoder so a scalar zero cannot hide null.

### M5 — The superseding publication matrix omits the existing positive-preparer setter

**Severity:** Medium  
**Disposition:** New test-proof gap adjacent to the closed H2-R owner defect.

**Evidence:** The Build 1 tree has an exported
`SetModelAdmissionAuthority(resolve, preparer)` method. It increments the WS
authority generation and installs a positive preparer without any WS
catalog/index generation parameter or combined-publication capability
(`phase4-coordinator/internal/ws/model_admission_authority.go:37-50`). Production
and numerous tests call it directly, including coordinator startup
(`phase4-coordinator/cmd/coordinator/main.go:993`; repository call-site search).
R2 requires every positive publication to route through the orchestrator and
says direct setters cannot install a positive preparer (`r2:65-74`). R3 retains
that closed requirement and calls for inventorying every direct WS setter and
positive test seam (`r3:3-12,22-45`).

R7 says it supersedes r6 owner-contention coverage, then labels its list as each
concrete publication surface. The list names both catalog setters, the new
combined publisher, callback, boot/reload callers, and test publishers, but not
`SetModelAdmissionAuthority` itself (`r7:3-10,12-32`). Testing callers after
they are migrated does not prove that the still-callable direct setter cannot
install a preparer that lacks the combined catalog/index generation.

**Consequence:** An implementation can satisfy the enumerated r7 matrix while
leaving the current direct setter capable of bypassing the new catalog/index
publication capability. A later internal caller or surviving test seam can
install positive authority over an independently mutable WS member index, which
reopens the coherence risk that H2-R was meant to close.

**Required correction:** Add `SetModelAdmissionAuthority` to the r7 publication
matrix explicitly. Require the implementation to remove/private-scope it or
make positive installation require an unforgeable combined-publication result
containing the expected WS catalog/index generation and pointers. Direct calls
without that capability must invalidate/remain non-paid. Table-test the direct
method, every production caller, and every positive test seam under concurrent
catalog/index replacement.

## Prior-finding disposition

| Prior finding | Result | Evidence |
|---|---|---|
| H2-R WS catalog/index owner | **Closed in the plan; companion proof incomplete as M5** | R3 adds `autotuneCatalogMu`, the exact catalog/index generation and pointers, fail-closed split setters, combined publication, session refresh, and final comparison (`r3:14-45`). R7 pauses that real owner and covers split/combined catalog publication (`r7:12-32`). The omitted direct positive-preparer setter is a separate concrete test gap. |
| H5 SQLite-first ordering | **Closed** | R3 explicitly acquires memory serialization or reserved connection plus successful `BEGIN IMMEDIATE` before any authority pin, then uses bounded Phase-B try-locks and rollback/release rules (`r3:47-75`). R7 preserves the external-BEGIN regression, adds memory serialization, cancellation/deadline, each Phase-B owner, failures, rollback, and deadlock bounds (`r7:34-61`). |
| H4-R complete canonical v2 shape | **Closed at plan enumeration; normative/test gaps remain as H6 and M4** | R3 enumerates the discriminator and all 24 fields, validation groups, canonical coverage, legacy classifier, and rejection classes (`r3:77-116`). R7 golden-tests the full shape and immutable settlement/replay (`r7:63-90`). |

## Confirmed scope and safety points

### I1 — Live authority and immutable historical settlement remain separated

**Severity:** Info

R2 continues to reject stale prepared generations before a new dispatch while
settling an already-routed attempt only from its immutable route/billing
snapshots and receipt tuple. R7 preserves restart/replay and forbids current
feed/index/keyring consultation. No regression was found in this plan boundary.

### I2 — Pricing identity, recovery, and observability remain bounded

**Severity:** Info

The pair-resolved model key remains the sole signed/effective rate lookup key;
the recovery flow retains its named ref, verified bundle, private manifests, and
fresh hidden worktree; observability retains bounded reason codes, exact event
counts, and local-path/private-material redaction. The reviewed addenda do not
weaken those prior closures.

### I3 — SQLite Phase-A release wording should be kept implementation-specific

**Severity:** Info

R3 correctly requires COMMIT or ROLLBACK before releasing Phase-B owners. SQLite
releases its write serialization as part of COMMIT/ROLLBACK, whereas the memory
store can release its serialization mutex after the Phase-B callbacks. The
phrase “then release Phase-A serialization” should be interpreted as releasing
the remaining connection/owner handle, not as moving COMMIT after Phase-B
unlock. R7's transaction-failure and no-deadlock assertions preserve the safe
order; implementation notes should avoid claiming that a SQLite write lock
survives COMMIT.

## Required disposition

Revise the plan and test bundle to close H6, M4, and M5 without weakening the
already closed lifecycle, retry, pricing, recovery, observability, H2-R owner,
H5 SQLite-first, or H4-R field-enumeration requirements. The next review must
inspect the complete r1+r2+revised-r3 and r5+r6+revised-r7 bundles at their new
hashes. Conflict resolution and implementation remain blocked until a fresh
independent GPT-5.6 Sol review reports zero Critical, High, and Medium findings.
