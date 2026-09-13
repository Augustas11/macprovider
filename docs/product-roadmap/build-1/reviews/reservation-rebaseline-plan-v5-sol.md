# Build 1 preparation-reservation rebaseline plan v5 independent review (Sol)

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol adversarial plan gate

Verdict: **PASS — APPROVED AS CONDITIONAL PLANNING INPUT**

Architectural status: **CLEAR**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Informational | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. V5
passes the plan gate. This verdict approves the reviewed plan and test design;
it does not unlock slice 6B. The operator-owned SPEC-001/SPEC-044 amendment in
Dependency Gate 5 must still land, strictly predate implementation, and pass
the separate combined plan-plus-authority review required by T18.

## Frozen review inputs

- Exact reviewed commit:
  `79d63fac764881f8e17d4ef8fb0cee66a9399b2d`.
- Exact base:
  `f7e584499828b3d16036382848b5caa1a897cdf9` (`origin/main`).
- Reproduced plan SHA-256:
  `b20f502684856cf13e5f94e59a7fca9f64a7dd9981809e7d10a7e83934d67354`.
- Reproduced test-spec SHA-256:
  `d08f71feba48887a4dae446cb95b4cf874f93e0e53a5c7356dfbf8a8fe80c811`.
- `origin/main` is an ancestor of the reviewed commit. The product baseline
  `c4401f1791d593d37d68eba91af94219b26d278f` is an ancestor of the exact base.
- Reproduced operator-handoff SHA-256 values are
  `5a8b35734b733692c12620986443f050a5ebc09bf21ce94207cb65207d84fcaf`
  for the activation UX handoff and
  `572dea4865b578db09ba662967ec7370818b1e692e34727351137b1ae24b259d`
  for the state/copy handoff.
- All v1-v4 Sol review artifacts, the complete V5 plan and test specification,
  current SPEC-001 and SPEC-044, AUTHORITY, CONFORMANCE, the operator handoffs,
  catalog-economics projection code, legacy durable store, and existing
  adoption wire/handler were inspected.
- The reviewed branch changes only Build 1 planning, test, and review documents
  relative to the exact base. `git diff --check origin/main...HEAD` passed
  before this artifact was written.

## V4 finding closure

### B1-V4-M1 — bounded overflow detection does not infer exact cardinality

**Severity: None — closed.**

**Evidence:** V5 reads at most 257 object-directory entries solely to establish
the predicate `count > 256`; it expressly forbids claiming that the 257th
observed entry is the last entry. Every detected overflow disables preparation
and all published cleanup without truncation, guessing, rename, or deletion
(`reservation-rebaseline-plan-v5.md:210-223`). T09.3 and T09.5 require the
same bounded result for seeded 257, 258, and 10,000-entry directories and prove
that no exact-257 claim or mutation occurs
(`reservation-rebaseline-test-spec-v5.md:150-171`).

**Consequence:** The implementation can distinguish every admissible count
from overflow after observing the first 257 names. It does not need EOF after
entry 257 and cannot derive deletion authority from an unproved cardinality.

**Required correction:** None.

### B1-V4-M2 — no unapproved overflow-recovery product surface remains

**Severity: None — closed.**

**Evidence:** V5 removes the exceptional one-object overflow recovery. An
overfull namespace is a fail-closed corruption state requiring out-of-band
operator diagnosis, and production must not expose it as recoverable
(`reservation-rebaseline-plan-v5.md:223`). Ordinary provider-confirmed cleanup
remains limited to an inventory-classified reclaimable v3 identity under the
intent/tombstone state machine (`reservation-rebaseline-plan-v5.md:225-236`).
The future operator amendment still must authorize the general versioned
`cleanup_published_artifact` action, projection, accounting, and budget contract
before implementation (`reservation-rebaseline-plan-v5.md:94-101`;
`reservation-rebaseline-test-spec-v5.md:261-273`).

**Consequence:** No implementation choice can accidentally invent eligibility,
confirmation, selection, result, or error semantics for overflow recovery.
Ordinary cleanup remains fully inside the explicit operator authority gate.

**Required correction:** None.

### B1-V4-M3 — T18 names the exact V5 inputs

**Severity: None — closed.**

**Evidence:** The test specification identifies itself as the acceptance spec
for `reservation-rebaseline-plan-v5.md`, and T18 item 6 requires fresh review
of "this exact v5 plan and test specification plus the landed SPEC diff" at
zero Critical/High/Medium
(`reservation-rebaseline-test-spec-v5.md:1-5,261-273`).

**Consequence:** Governance evidence cannot satisfy the implementation gate by
reviewing an obsolete blocked revision.

**Required correction:** None.

## B1-V3-M1 final correction audit

| Required boundary | V5 disposition |
|---|---|
| 255 valid objects plus one distinct publication | **Closed.** A new identity is admitted at count 255 and may create object 256 under the retained common lock (`reservation-rebaseline-plan-v5.md:202-208`; T09.5). |
| 256 valid objects plus exact existing identity | **Closed.** Exact receipt/hash identity remains idempotent with no network, staging, new receipt, or count change (`reservation-rebaseline-plan-v5.md:204`; T09.5/T10.1). |
| 256 valid objects plus new distinct identity | **Closed.** Admission fails before network or staging and the target/count check repeats immediately before exclusive rename (`reservation-rebaseline-plan-v5.md:204-208`; T09.5/T10.0). |
| Publication versus cleanup | **Closed.** Both operations use the common operation/cleanup lock; T10.0 requires linearizable schedules and an ending count no greater than 256 (`reservation-rebaseline-test-spec-v5.md:173-181`). |
| External same-UID mutation before the final check | **Closed at the stated trust boundary.** The final inventory/target recheck refuses rename, records the unpublished tree, and never creates object 257 (`reservation-rebaseline-plan-v5.md:206`; T10.0). |
| Seeded 257, 258, or large overflow | **Closed fail-safe.** At most 257 names are consumed; the result is only bounded overflow, and preparation, cleanup, rename, and deletion are disabled (`reservation-rebaseline-plan-v5.md:223`; T09.3/T09.5). |

The object ceiling is now an admission invariant rather than merely a decoder
limit. Ordinary product operations cannot self-wedge the store, exact
idempotence remains usable at the ceiling, cooperative cleanup is serialized,
and externally corrupted inventories receive one bounded non-mutating result.

## Earlier-finding regression audit

### V2 findings

| Finding | V5 disposition |
|---|---|
| B1-V2-H1 — conforming prepare-before-offer authority | **Closed conditionally.** The exhaustive source/state/economics matrix, exact local copy, hard R002/R003 operator gate, ancestry proof, and T16/T18 coverage remain. Current authority is not misrepresented as sufficient. |
| B1-V2-M1 — deletion intent ordering and recovery | **Closed.** Durable intent precedes rename, `tombstoned` follows the objects-parent barrier, every final/tombstone/phase combination has an exact rule, and T10 injects every boundary. |
| B1-V2-M2 — unique temps and root bootstrap | **Closed.** UUID-bound validated temps, atomic complete `root.identity`, bounded reconciliation, hostile-object refusal, and T01/T04/T08 crash cases remain. |
| B1-V2-M3 — enforceable URLSession bounds | **Closed.** Only accepted application bytes and staged bytes are capped. Delegate, transport, and server counts remain observational in the plan and T06/T09/T21. |
| B1-V2-M4 — v3 namespace and configured legacy | **Closed.** V3 enumeration and mutation stay inside `.macprovider-prepared-v3`; configured legacy is protected/accounted; unconfigured legacy is unmanaged; mixed-root upgrade/rollback remains tested. |
| B1-V2-M5 — cancellation event/marker ownership | **Closed.** Worker-only event sequencing, the separate capped acknowledgement, terminal sweep under `cancel.lock`, and prior-attempt marker removal remain explicit and race-tested. |

### V1 findings

| Finding | V5 disposition |
|---|---|
| B1-V1-H1 — public authority contradiction | **Closed conditionally.** The required public grammar/schema/copy changes are operator-owned and pre-6B; no transaction-status schema, `models transactions` family, public crash/late-cancel state, or new control frame is introduced. |
| B1-V1-H2 — custom-root authority | **Closed.** Canonical path, device/inode/root identity, saved-root recovery, cross-process configuration changes, separate volumes, and independent serving verification remain in plan/T04/T05/T08/T13. |
| B1-V1-H3 — durable publication ordering | **Closed.** File/tree barriers, exclusive rename, destination-parent `fsync` and `F_FULLFSYNC`, terminal ordering, separate-filesystem recovery, and real APFS abrupt-power evidence remain mandatory. |
| B1-V1-M1 — deterministic bounded selection | **Closed.** Exact 64/256 limits, authority order, unchanged-ID retention, active pinning, eight fairness slots, starvation bounds, overflow refusal, and serialized dispatch remain in plan/T02/T03. |
| B1-V1-M2 — bounded published storage and recovery | **Closed.** Count admission, byte budget, bounded inventory, provider-confirmed ordinary cleanup, intent-first recovery, v3 isolation, legacy protection, and fail-closed external overflow now compose without an ordinary self-wedge. |
| B1-V1-M3 — bounded transfer cancellation | **Closed.** The serial production delegate, 250 ms watchdog, bounded work-loop polling, heartbeat/deadline rules, direct descriptor writes, late-callback exclusion, and accepted/staged caps remain in plan/T06/T09/T21. |

## Conditional authority-gate assessment

The conditional plan structure remains sound. Dependency Gates 4-6 accurately
state that current SPEC-044 v0.1.1 does not authorize locally motivated
pre-offer preparation, a cancellation acknowledgement, or published-artifact
cleanup/accounting. Gate 5 requires one @Augustas11-owned SPEC-001/SPEC-044
amendment to freeze the complete matrix and copy, run/cancel grammar, event
codes, worker sequencing, bounded acknowledgement, and ordinary published
cleanup/accounting contract. T18 requires strict ancestry and a fresh combined
review before the first 6B implementation commit.

Current repository evidence agrees with the stated dependency: SPEC-044-R002
still closes the v1 action set at `cleanup_staging`, R003 disables
money-motivated preparation without trusted economics, and the current Swift
projection emits unavailable preparation and only `cleanup_staging`. AUTHORITY
assigns SPEC-001 and SPEC-044 ownership to @Augustas11. CONFORMANCE keeps
SPEC-044 pending reconciliation/not deployed, SPEC-023-R006 pending, and the
signed discovery and network-admission journeys pending. V5 claims none of
those gates have passed.

## Informational observations

### B1-V5-I1 — adoption remains on the existing control frame

The plan retains `prepareModelAdoptionRequest` and treats requester path/hash as
claims. The serving process must independently reload signed authority, resolve
its configured v3 root, and verify the bound receipt/hash before acceptance
(`reservation-rebaseline-plan-v5.md:17,69-71,242-262`; T13). Current
`ModelAdoptionAuthorityWire` supplies the comparison fields, so no new control
frame is required.

### B1-V5-I2 — final Build 1 acceptance remains truthful

Preparation remains distinct from configuration, serving adoption, admission,
routing, economics, settlement, and positive credit. T21-T24 retain signed
physical-Mac/APFS evidence, accepted discovery and admission journeys, first
listed-tier release, signed/notarized assets, app/tarball CLI byte identity, and
prior-stable updater proof. The plan gate cannot substitute for those outcomes.

## Required disposition

No plan/test correction is required. Preserve the exact reviewed V5 inputs and
hashes. Slice 6B remains blocked until the complete operator authority amendment
lands, is a strict ancestor of implementation, and the exact V5 documents plus
the landed SPEC diff pass the T18 zero-Critical/High/Medium review. Any later
change to overflow behavior, admission limits, cleanup authority, or another
reviewed contract requires new hashes and a fresh full adversarial review.
