# Build 1 preparation-reservation rebaseline plan v4 independent review (Sol)

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol adversarial plan gate

Verdict: **BLOCK — NOT APPROVED FOR IMPLEMENTATION**

Architectural status: **BLOCK**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 0 |
| Informational | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. V4
therefore fails the plan gate. The ordinary-publication portion of B1-V3-M1 is
materially corrected: the plan admits the 256th distinct identity, preserves
idempotence at 256, refuses a new 257th identity before transfer/staging, retains
the common operation/cleanup lock through publication, and rechecks inventory
immediately before rename. The newly added exceptional 257-object recovery path
cannot yet prove its own exact-cardinality precondition, is not explicitly
covered by the required operator authority patch, and the mandatory governance
test still names v3 rather than the reviewed v4 plan.

## Frozen review inputs

- Exact reviewed commit:
  `3f4f641ca8439110acb77bdb7f68fc47f673153d`.
- Exact base:
  `f7e584499828b3d16036382848b5caa1a897cdf9` (`origin/main`).
- Reproduced plan SHA-256:
  `a6d25c3a33676935ea7c04ea5af821812b65b523bdd412ce7a0b8c71f9e715d6`.
- Reproduced test-spec SHA-256:
  `e7b61d25005117d51fb4d48ad0d6f532a7749281ddcf44c669904be849746516`.
- `origin/main` is an ancestor of the reviewed commit. The earlier product
  baseline `c4401f1791d593d37d68eba91af94219b26d278f` is an ancestor of the exact
  base; the intervening merge changes SPEC-005/SPEC-006 and coordinator/gateway
  surfaces, not SPEC-001, SPEC-044, the provider Swift surfaces, or the handoffs
  reviewed here.
- Reproduced operator-copy and handoff SHA-256 values are
  `572dea4865b578db09ba662967ec7370818b1e692e34727351137b1ae24b259d`
  and
  `5a8b35734b733692c12620986443f050a5ebc09bf21ce94207cb65207d84fcaf`.
- All v1-v3 Sol review artifacts, V4 plan/test documents, current SPEC-001 and
  SPEC-044, AUTHORITY, CONFORMANCE, catalog-economics projection/tests, legacy
  durable store/tests, adoption wire/handler/tests, and both operator handoffs
  were inspected. Current SPEC-044 remains v0.1.1 and its relevant conformance
  rows remain pending.
- The reviewed branch changes only Build 1 planning, test, and review documents
  relative to the exact base. `git diff --check` passed before this artifact was
  written.

## Findings

### B1-V4-M1 — a 257-entry inspection cap cannot prove that the directory has exactly 257 entries

**Severity: Medium**

**Evidence**

- Normal inventory is capped at 256 exact receipts
  (`reservation-rebaseline-plan-v4.md:210-223`). The exceptional recovery mode
  then says it "may inspect exactly 257 directory entries," permits recovery
  when there are exactly 257, and requires more than 257 to fail closed
  (`reservation-rebaseline-plan-v4.md:223`).
- After observing 257 valid entries, an enumerator cannot distinguish end of
  directory from a 258th entry without attempting one more bounded observation.
  A cap that stops after entry 257 therefore cannot prove the exact-cardinality
  predicate on which deletion authority depends.
- T09.3 and T09.5 require exactly 257 valid entries to expose recovery while
  more-than-257 remains fail closed, but they repeat the result rather than
  defining the necessary 258th-entry sentinel observation
  (`reservation-rebaseline-test-spec-v4.md:150-171`).

**Consequence**

A conforming implementation must either treat a full 257-entry read as
truncated and keep the promised exactly-257 recovery unavailable, or assume EOF
and authorize a deletion from a directory that may contain 258 or more entries.
The latter can leave the store overfull after a supposedly restorative action;
the former recreates the operator-only manual recovery wedge that B1-V3-M1
required V4 to close.

**Required correction**

Define a bounded enumeration that observes at most 258 names: accept the
exceptional path only after 257 valid entries followed by proven EOF, and fail
closed immediately when a 258th name is observed. Validation and deletion must
remain limited to the exact 257-entry case. Add explicit 256, exactly-257,
258, and much-larger directory tests, including unstable/reordered enumeration
and the common-lock recheck immediately before intent.

### B1-V4-M2 — the exceptional overflow-recovery action can escape the operator authority gate

**Severity: Medium**

**Evidence**

- Current SPEC-044-R002 closes the v1 action set at `switch`, `prepare`,
  `evaluate`, `adopt_recommendation`, and `cleanup_staging`; it has no published
  cleanup or overflow-recovery contract
  (`specs/SPEC-044-malibu-model-catalog-economics.md:90`). Current projection
  code likewise emits only `cleanup_staging`, and preparation remains unavailable
  (`phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift:420-480`).
- V4 introduces a special product-visible state: exactly 257 valid objects
  expose only a provider-confirmed one-object recovery path through an
  operator-approved cleanup action, while other overflow shapes expose none
  (`reservation-rebaseline-plan-v4.md:223`;
  `reservation-rebaseline-test-spec-v4.md:150-171`).
- Dependency Gate 5 requires a general versioned
  `cleanup_published_artifact` projection/action/accounting contract, but does
  not require the authority patch to freeze the exceptional overflow state,
  recovery eligibility, exact selected-identity semantics, confirmation/result,
  or fail-closed distinction from malformed and greater-than-257 states
  (`reservation-rebaseline-plan-v4.md:94-102`). T18 repeats only the general
  published-cleanup action/projection requirement
  (`reservation-rebaseline-test-spec-v4.md:261-273`).

**Consequence**

The required SPEC patch can satisfy the literal pre-6B gate by authorizing
ordinary published cleanup while leaving the only recovery from exactly 257
objects unspecified. An implementation must then invent provider-visible
action availability and recovery semantics, suppress the action and preserve
the wedge, or overload ordinary inventory behavior despite the closed-schema
contract.

**Required correction**

Add the exactly-257 recovery behavior explicitly to Dependency Gate 5 and T18.
The operator-owned SPEC-001/SPEC-044 amendment must freeze how the overfull state
is represented, when `cleanup_published_artifact` is available, how one exact
reclaimable identity is selected and confirmed, its bounded result/error
semantics, and the fail-closed behavior for invalid, protected, no-reclaimable,
258th-entry, and larger cases. Review that landed authority together with the
corrected V4 documents before 6B.

### B1-V4-M3 — the mandatory governance test still requires review of v3 instead of v4

**Severity: Medium**

**Evidence**

- The test specification declares itself the acceptance specification for V4
  (`reservation-rebaseline-test-spec-v4.md:1-5`).
- T18 nevertheless requires a fresh independent review of **v3** plus the
  landed SPEC diff (`reservation-rebaseline-test-spec-v4.md:261-273`). V3 is the
  revision whose independent review reported B1-V3-M1 and blocked
  implementation (`reviews/reservation-rebaseline-plan-v3-sol.md:7-25,53-100`).
- Copied revision labels remain elsewhere: the V4 plan says it supersedes v2,
  and its disposition table labels the current section column `v3 section`
  (`reservation-rebaseline-plan-v4.md:5-7,321-333`). These are secondary signs;
  the blocking issue is the executable T18 gate naming the wrong input.

**Consequence**

T18 cannot prove that the plan used for implementation is the plan that passed
the combined plan-plus-authority review. Read literally, it either requires an
obsolete blocked plan to pass or permits evidence attached to the wrong
revision, defeating the exact-input governance gate.

**Required correction**

Change T18 to require a fresh independent review of the exact V4 plan and test
specification, their recorded hashes, and the landed SPEC diff at zero
Critical/High/Medium. Correct the copied V2/V3 revision labels so the operative
document and its disposition mapping are unambiguous.

## B1-V3-M1 correction audit

| Required boundary | V4 result |
|---|---|
| 255 valid objects + one distinct publish | **Closed for normal publication.** A new identity is admitted at count 255 and may create object 256 (`reservation-rebaseline-plan-v4.md:202-208`; T09.5). |
| 256 valid objects + exact existing identity | **Closed.** Exact receipt/hash identity remains idempotent with no network, staging, receipt, or count change (`reservation-rebaseline-plan-v4.md:204`; `reservation-rebaseline-test-spec-v4.md:169-181`). |
| 256 valid objects + new distinct identity | **Closed.** Refused before network/staging and rechecked before exclusive rename (`reservation-rebaseline-plan-v4.md:204-208`; T09.5/T10.0). |
| Publication versus cleanup | **Closed for cooperative product processes.** Both use the same retained operation/cleanup lock, and T10.0 requires linearizable schedules with at most 256 objects (`reservation-rebaseline-plan-v4.md:204-206`; `reservation-rebaseline-test-spec-v4.md:173-181`). |
| External same-UID mutation between early admission and publication | **Closed at the specified boundary.** The pre-rename inventory/target recheck refuses publication and preserves recorded unpublished state; T10.0 injects the mutation before that recheck. Same-EUID actors remain inside the plan's stated trust boundary (`reservation-rebaseline-plan-v4.md:92,204-208`; `reservation-rebaseline-test-spec-v4.md:175-177`). |
| Externally seeded exactly 257 | **Still blocked by B1-V4-M1/M2.** The intended one-object recovery is bounded in scope and retains keep-set plus tombstone durability, but exact cardinality and public authority are incomplete. |

The lock is sufficiently identifiable for the count-race contract: the private
root defines only `operation.lock` and `cancel.lock`; publication retains the
common operation/cleanup lock and cleanup uses that same lock. The worker owns
the operation lock, while the cancel process owns only the cancel lock
(`reservation-rebaseline-plan-v4.md:81-92,131-150,171-184,202-208`). No new
finding is raised for cooperative lock serialization.

## Prior-finding dispositions

### V2 findings

| Finding | V4 disposition |
|---|---|
| B1-V2-H1 — conforming prepare-before-offer authority | **Closed conditionally.** The complete matrix, exact local copy, and hard operator-owned R002/R003 gate remain. B1-V4-M2 is narrower and concerns only the new exceptional overflow action. |
| B1-V2-M1 — deletion intent ordering and recovery | **Closed.** Durable intent precedes rename, phase follows the objects-parent barrier, and T10 freezes every final/tombstone combination. |
| B1-V2-M2 — unique temps and root bootstrap | **Closed.** Unique validated temps, atomic root identity, bounded reconciliation, and crash injection remain mandatory. |
| B1-V2-M3 — enforceable URLSession bounds | **Closed.** Only application-accepted and staged bytes are normative; server, transport, and delegate counts remain observational. |
| B1-V2-M4 — v3 namespace and configured legacy | **Closed except for the separately reported overflow recovery defects.** Legacy remains outside v3 enumeration/import/delete and configured legacy is protected/accounted. |
| B1-V2-M5 — cancellation event/marker ownership | **Closed.** Worker-only events, bounded cancel acknowledgement, cancel-lock terminal sweep, and new-attempt cleanup remain explicit. |

### V1 findings

| Finding | V4 disposition |
|---|---|
| B1-V1-H1 — public authority contradiction | **Closed conditionally.** No invented status/control frame remains; the exact operator patch and strict ancestry gate precede implementation. |
| B1-V1-H2 — root authority | **Closed.** Canonical path, device/inode/identity binding, saved-root recovery, and independent serving verification remain. |
| B1-V1-H3 — durable publication ordering | **Closed.** Tree and destination-parent full-sync barriers precede durable terminal success and event emission; APFS abrupt-power evidence remains required. |
| B1-V1-M1 — deterministic bounded selection | **Closed.** Exact 64/256 limits, authority order, retention, active pinning, fairness, starvation, overflow refusal, and serialized dispatch remain tested. |
| B1-V1-M2 — bounded published storage/recovery | **Reopened only through B1-V4-M1/M2.** Normal count admission, budget, legacy protection, and intent-first cleanup are sound; the exceptional recovery is incomplete. |
| B1-V1-M3 — bounded cancellation during transfer | **Closed.** Serial delegate, watchdog, direct descriptor writes, late-callback exclusion, and accepted/staged caps remain. |

## Informational observations

### B1-V4-I1 — the current authority dependency remains accurately active

Current SPEC-044 v0.1.1 does not authorize local pre-offer preparation,
cancellation acknowledgement, or published cleanup. Current projection code
keeps local catalog preparation unavailable, current AUTHORITY assigns
SPEC-044 to @Augustas11, and CONFORMANCE keeps SPEC-023-R006, SPEC-044,
discovery, and admission/settlement evidence pending. V4 does not falsely claim
those dependencies have landed.

### B1-V4-I2 — adoption and final Build 1 acceptance did not regress

The plan retains the existing adoption frame while requiring the serving
process to reload signed feeds and independently derive and verify its configured
v3 root, receipt, and hash. It also keeps preparation separate from admission,
routing, settlement, positive credit, first-listed-tier release, signed assets,
notarization, updater proof, and real Apple Silicon/APFS evidence. T21-T24 remain
the final acceptance boundary.

## Required disposition

Repair the exact-cardinality overflow algorithm, add that exceptional recovery
surface to the operator authority gate, and make T18 review the exact V4 inputs.
Preserve the corrected normal count admission and every prior authority, root,
durability, selection, storage, URLSession, legacy, cancellation, adoption, and
final-acceptance gate. Reproduce hashes and run a fresh independent adversarial
review. PASS remains available only at 0 Critical, 0 High, and 0 Medium.
