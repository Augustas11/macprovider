# Build 1 preparation authority v1 independent adversarial review

Date: 2026-09-11

Reviewer: independent Codex `gpt-5.6-sol` adversarial gate

Verdict: **BLOCK**
Finding counts: **Critical 0 · High 2 · Medium 13 · Low 0 · Info 1**

The required zero-Critical/High/Medium gate is not met. Authority candidate
`c42eea1ccfe637f0bfe3fa9939c18b26bd657434` must not authorize slice 6B
implementation. The amendment does not completely or consistently close
Dependency Gate 5 / T18 from the approved v5 plan and test specification.

## Exact review inputs

- Repository worktree:
  `/Users/augstar/.codex/worktrees/macprovider/build1-preparation-authority`
- Base revision: `origin/main` at
  `f7e584499828b3d16036382848b5caa1a897cdf9`
- Authority candidate revision:
  `c42eea1ccfe637f0bfe3fa9939c18b26bd657434`
- Candidate parent:
  `f7e584499828b3d16036382848b5caa1a897cdf9`
- Approved plan:
  `/Users/augstar/.codex/worktrees/macprovider/build1-reservation-rebaseline/docs/product-roadmap/build-1/reservation-rebaseline-plan-v5.md`
- Approved plan SHA-256:
  `b20f502684856cf13e5f94e59a7fca9f64a7dd9981809e7d10a7e83934d67354`
- Approved test specification:
  `/Users/augstar/.codex/worktrees/macprovider/build1-reservation-rebaseline/docs/product-roadmap/build-1/reservation-rebaseline-test-spec-v5.md`
- Approved test specification SHA-256:
  `d08f71feba48887a4dae446cb95b4cf874f93e0e53a5c7356dfbf8a8fe80c811`

The reviewed `origin/main...c42eea1c` diff contains one commit and four files:

| File | Insertions | Deletions |
|---|---:|---:|
| `specs/CONFORMANCE.json` | 6 | 6 |
| `specs/README.md` | 2 | 2 |
| `specs/SPEC-001-phase3-binary.md` | 63 | 1 |
| `specs/SPEC-044-malibu-model-catalog-economics.md` | 245 | 12 |
| **Total** | **316** | **21** |

The review inspected the full diff, the current CLI and Malibu v1 projection
implementations/tests, SPEC-023 artifact authority, SPEC-046/047 admission and
guidance authority, governance manifests/process, the approved v5 plan and test
specification, and the landed Slice 6 state/copy handoff. It did not inspect
`d-inference` or access operator secrets.

## Findings

### B1-AUTH-H1 — v2 cannot carry or correlate the authoritative earning disclosure

**Severity: High**

**Evidence.** SPEC-044 requires locally motivated rows to preserve the
candidate's authoritative admission and earning disclosures and the matrix
repeats that obligation (`specs/SPEC-044-malibu-model-catalog-economics.md:94,
193-221`). The closed v1 row inherited by v2 contains admission state/source and
economics fields, but it contains neither `candidate_id` nor
`provider_guidance`; v2 adds only `artifact_identity_digest`,
`cleanup_published`, and top-level storage (`:96,100-145`). Current code confirms
that absence (`phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift:120-185`).
SPEC-001 requires the provider verdict to come from
`provider_guidance.earning_path_class` and expressly forbids Malibu from
re-deriving it from admission state or model names
(`specs/SPEC-001-phase3-binary.md:3214-3240`). SPEC-046/047 own that guidance,
and the landed Slice 6 handoff makes the wire value authoritative.

**Consequence.** Malibu cannot prove which SPEC-046/047 candidate supplied the
guidance for a preparation row. An implementation must invent a heuristic join,
derive the verdict from admission/economics, or omit required truth-first copy.
Each choice violates an owner contract or leaves B1-V2-H1 unreachable.

**Required correction.** Add a closed, required v2 `provider_guidance` object
and an exact candidate/source correlation binding, reusing the owner-spec enum
and fields verbatim. Define freshness and mismatch failure, require Malibu to
render this guidance first, and add strict-decoder and all-matrix-branch tests.
Alternatively, freeze a complete versioned composition protocol with an exact
join key, freshness binding, and fail-closed mismatch behavior.

### B1-AUTH-H2 — the unchanged read command has no deterministic v1/v2 selection mechanism

**Severity: High**

**Evidence.** SPEC-044 calls v2 a breaking extension, says a v2 CLI must not
send v2 to a client that did not negotiate the exact capability/token, and
promises v1 or legacy fallback (`specs/SPEC-044-malibu-model-catalog-economics.md:94,
102-109,299-304`). SPEC-001 defines the same public read form used by v1 and says
that form writes one v2 object, without a version selector or any caller
capability input (`specs/SPEC-001-phase3-binary.md:3261-3284`). Current Malibu
chooses whether to launch the subprocess from peer capability evidence, but the
invocation transmits no selected schema to the CLI and its production decoder
accepts only v1
(`phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:64-78,
479-555,1693-1698,1845-1860`).

**Consequence.** If an upgraded CLI advertises both generations, old Malibu can
invoke the unchanged command because it recognizes v1 and receive a strict-
incompatible v2 document. Advertising only v2 would avoid that case, but the
authority does not freeze mutual exclusion or the full version matrix. T15
therefore cannot derive a single correct cross-version result from authority.

**Required correction.** Freeze one exact version-selection mechanism. Within
the approved public grammar, one viable rule is that a v2-serving CLI advertises
only v2 capability/token and a v1-serving CLI advertises only v1. Otherwise
define an exact authenticated/private negotiated-version input and validation.
Add old-Malibu/new-CLI and new-Malibu/old-CLI production-boundary tests.

### B1-AUTH-M1 — the claimed exhaustive matrix omits legal `coordinator:not_offered`

**Severity: Medium**

**Evidence.** SPEC-044 allows `source: coordinator` with SPEC-047 coordinator
states (`specs/SPEC-044-malibu-model-catalog-economics.md:96`). SPEC-046 says
the same `not_offered` state legally appears with either source and callers must
read the source; a coordinator readback with no active offer must use
`coordinator:not_offered` (`specs/SPEC-046-provider-byom-discovery.md:86-96`).
SPEC-047 includes coordinator-backed `not_offered` in its closed state machine
(`specs/SPEC-047-network-model-admission.md:86-90`). The new matrix omits it
from the coordinator non-priced rows and sends every omitted combination to the
unavailable catch-all
(`specs/SPEC-044-malibu-model-catalog-economics.md:193-203`). The approved plan
contains the same omission while claiming every legal combination is covered
(`reservation-rebaseline-plan-v5.md:37-47`).

**Consequence.** A fresh authoritative readback can change a valid pre-offer
row from local-default `not_offered` to coordinator `not_offered` and silently
remove local preparation. The advertised pre-offer journey is not reliably
reachable, and the matrix is not exhaustive.

**Required correction.** Add coordinator `not_offered` to the non-trusted local
preparation branch and to the trusted-invalid branch, with the same exact local
copy, or normatively prohibit that pair and reconcile SPEC-046/047. T16 must
exercise both sources and the transition between them.

### B1-AUTH-M2 — artifact eligibility drops the approved `verified` prerequisite

**Severity: Medium**

**Evidence.** The approved plan requires a primary **verified**
`mlx_safetensors` artifact (`reservation-rebaseline-plan-v5.md:33-35`). The
amendment requires only that the signed primary artifact binding be current
(`specs/SPEC-044-malibu-model-catalog-economics.md:197-202`). A valid signed
artifact-feed entry may still be `declared`; SPEC-023 distinguishes a current
signed binding from operator verification and prohibits declared or blocked
artifacts from being downloaded or prepared as catalog artifacts
(`specs/SPEC-023-installer-autotune-recommend.md:403-416,748-776`).

**Consequence.** The authority permits an implementation to expose Prepare for
an operator-recorded but unverified artifact while still satisfying the words
"signed" and "current." That weakens the exact trust prerequisite approved by
the plan.

**Required correction.** Require the bound primary artifact's
`verification_status` to equal `verified`, reject `declared` and `blocked`
before action projection and dispatch, and add T05/T16 vectors for every
verification status and feed-drift boundary.

### B1-AUTH-M3 — four cancellation acknowledgement outcomes are undefined

**Severity: Medium**

**Evidence.** The acknowledgement lists five outcomes and attempt-ID nullability
rules, but defines only `recorded`
(`specs/SPEC-044-malibu-model-catalog-economics.md:249-257`). It does not require
the returned `transaction_id` to echo the requested ID or define the durable
predicates and precedence for `already_recorded`, `terminal`, `not_active`, and
`stale`. T03 expects particular results across active, terminal, absent, and
stale-marker races, while T14 requires all five outcomes
(`reservation-rebaseline-test-spec-v5.md:74-91,232-236`). Gate 5 requires exact
outcomes and marker-race semantics (`reservation-rebaseline-plan-v5.md:100`).

**Consequence.** Independent implementations can return different valid-looking
acknowledgements for the same state, and acceptance tests must invent policy.

**Required correction.** Define exact durable-state predicates, request/echo
matching, attempt-ID semantics, and a total first-match precedence for all five
outcomes under concurrent active/terminal/marker states.

### B1-AUTH-M4 — cleanup cancellation and recovery have no defined commit point

**Severity: Medium**

**Evidence.** The cancellation rule distinguishes only winning before
publication from losing after durable publication
(`specs/SPEC-044-malibu-model-catalog-economics.md:259-271`). Cleanup performs no
publication. The amendment nevertheless mandates progress, cancellation, and
terminal events for both cleanup kinds while authorizing destructive rename and
deletion (`:111-129,283-297`). The approved plan defines an
intent -> tombstoned -> removed recovery sequence, but the candidate authority
does not map cancellation outcomes onto those boundaries
(`reservation-rebaseline-plan-v5.md:225-240`).

**Consequence.** Implementations can disagree whether cancellation after intent,
rename, or unlink returns `cancelled`, `succeeded`, or `failed`. A worker could
report cancellation after destructive mutation or strand a tombstone while
remaining textually conformant.

**Required correction.** Freeze cleanup-specific commit points and the worker
outcome at every destructive/recovery boundary. For published cleanup, a
pre-commit cancellation must preserve or restore the final object; after the
durable tombstone commit point, recovery must complete deterministically and
must not report `cancelled`. Define staging cleanup separately and add cancel,
crash, and retry races at every phase.

### B1-AUTH-M5 — "exact reclaimable bytes" has no filesystem accounting definition

**Severity: Medium**

**Evidence.** The amendment uses exact byte values for cleanup confirmation,
managed totals, budget admission, and free-space checks
(`specs/SPEC-044-malibu-model-catalog-economics.md:118-190`) but does not define
logical length versus allocated blocks, APFS clone/compression semantics,
directory/receipt/metadata inclusion, hard links, sparse files, or checked
descriptor-relative traversal. The copy promises to "recover" the projected
amount (`:118-123`).

**Consequence.** Two implementations can disagree on eligibility and budget
while both claim conformance. On APFS, deleting data of a given logical size may
not recover the same physical capacity, so the confirmation can overpromise.

**Required correction.** Define one checked, descriptor-relative accounting
algorithm and exact inclusion rules for managed and configured-legacy trees.
Keep logical prepared-data size distinct from filesystem free-space recovery.
Unless physical allocation recovery is actually measured, change the cleanup
copy so it does not promise that the displayed amount will be recovered.

### B1-AUTH-M6 — reclaimable artifacts are not guaranteed a reachable cleanup action

**Severity: Medium**

**Evidence.** `cleanup_published` is attached only to a catalog-economics row,
while storage exposes only aggregate managed/reclaimable totals
(`specs/SPEC-044-malibu-model-catalog-economics.md:111-156,283-289`). No clause
requires every eligible verified v3 object to receive a row/action or defines a
cleanup target list. Automatic garbage collection is prohibited (`:128-129`).

**Consequence.** A verified object whose model/release disappears from the
current signed catalog can remain counted and reclaimable but have no action.
Enough such objects can consume all 256 slots permanently, leaving provider-
controlled cleanup unable to recover the budget.

**Required correction.** Define a bounded authoritative projection of every
cleanup-eligible verified identity through cleanup-only rows or a closed
top-level target array. Include stable display identity, binding digest, exact
measured bytes, keep-set status, deterministic ordering/caps, and behavior when
the object has no current catalog row.

### B1-AUTH-M7 — governance surfaces disagree with the new contract

**Severity: Medium**

**Evidence.** The governance process requires every new normative `MUST` and
`MUST NOT` to have a stable requirement ID and CONFORMANCE mapping
(`specs/PROCESS.md:60-72,79-84`). New normative SPEC-001 §6.14b has no
requirement ID, and CONFORMANCE has only unrelated SPEC-001-R001/R002 entries
(`specs/SPEC-001-phase3-binary.md:3259-3307`;
`specs/CONFORMANCE.json:1459-1506`). SPEC-001 expressly consumes SPEC-044's
projection/event/ack/action/accounting contract, but AUTHORITY still lists no
consumer for `malibu-model-economics-ux` (`specs/AUTHORITY.json:667-673`). The
amended R005 requires a valid locally motivated row to remain visible
(`specs/SPEC-044-malibu-model-catalog-economics.md:277-279`), while its
CONFORMANCE mapping still cites `testCatalogEconomicsHidesLocalDefaultBYOMRowsForThisRelease`
and calls hiding the release decision (`specs/CONFORMANCE.json:6859-6878`). T18
requires AUTHORITY, versions, indexes, CONFORMANCE, and the handoff to agree.

**Consequence.** The invocation contract is untraceable, the authority consumer
graph is stale, and mapped evidence asserts the opposite visibility behavior.
Structural validators pass because they do not infer Markdown semantics.

**Required correction.** Assign §6.14b a stable SPEC-001 requirement ID and
pending CONFORMANCE entry, register the correct SPEC-044 domain consumer(s), and
update R005 mappings/rationale so the old hide test is explicitly a gap and the
future visible-local-preparation proof is named.

### B1-AUTH-M8 — no production CLI-to-Malibu wire-boundary test is required

**Severity: Medium**

**Evidence.** The test specification assigns CLI schema generation and Malibu
behavior to separate suites and says only to "cross-test" version combinations
(`reservation-rebaseline-test-spec-v5.md:16-30,238-240`). It never requires
bytes from the built CLI to pass through the production Malibu process adapter
and decoder. Current Malibu tests use `FakeModelCLI` and hand-authored JSON
(`phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift:489-505,
1816-1861`).

**Consequence.** CLI and Malibu suites can pass independently with incompatible
v2 field names, nullability, capability tokens, JSONL chunking, stderr, or exit
handling.

**Required correction.** Require an integration test that launches the built
CLI and feeds exact stdout/stderr/exit status through the production Malibu
adapter and decoder. Cover reads, terminal run outcomes, all cancel
acknowledgements, partial/chunked JSONL, v1 fallback, and malformed v2 negatives.

### B1-AUTH-M9 — managed-budget derivation and configuration precedence lack exact tests

**Severity: Medium**

**Evidence.** SPEC-044 defines
`min(1 TiB, floor(70% of volume capacity))`, checked arithmetic, positive
override validation, environment-over-YAML precedence, a 1 TiB ceiling, and the
exact free-space formula
(`specs/SPEC-044-malibu-model-catalog-economics.md:179-190`). T09 tests near
boundaries and exact/one-over publication but does not enumerate formula
rounding, source, precedence, invalid configuration, or exact free-space
thresholds (`reservation-rebaseline-test-spec-v5.md:150-171`).

**Consequence.** A wrong default, rounding direction, precedence, or unchecked
calculation can pass while admitting too much storage or rejecting valid work.

**Required correction.** Add injected-volume cases below/at/above the 1 TiB
crossover, non-divisible 70% capacities, zero/negative/non-integer/>1 TiB
overrides, YAML-only/environment-only/both precedence, budget-source assertions,
checked overflow, and free space one byte below/at/above the exact formula.

### B1-AUTH-M10 — unavailable legacy accounting is not tested as a preparation block

**Severity: Medium**

**Evidence.** SPEC-044 requires unavailable configured-legacy accounting to
disable both preparation and published cleanup
(`specs/SPEC-044-malibu-model-catalog-economics.md:158-177`). T09.3 says only
that malformed configured legacy blocks "cleanup/accounting" while incumbent
serving continues (`reservation-rebaseline-test-spec-v5.md:150-163`).

**Consequence.** An implementation can project or dispatch preparation while
its existing legacy budget charge is unknown and still satisfy the stated test.

**Required correction.** Assert that projected Prepare is unavailable, direct
stale dispatch refuses before network/staging, published cleanup is unavailable,
all affected accounting fields have exact required nullability, and incumbent
serving remains unchanged.

### B1-AUTH-M11 — exact localized size calculations are not proven

**Severity: Medium**

**Evidence.** Cleanup `estimated_bytes` must equal exact reclaimable bytes, and
preparation size must round upward to 0.1 decimal GB with localized digits,
separator, and unit (`specs/SPEC-044-malibu-model-catalog-economics.md:118-123,
205-217`). T16 checks literal copy plus generic localization expansion, without
numeric boundary vectors or action-byte equality
(`reservation-rebaseline-test-spec-v5.md:242-255`).

**Consequence.** A confirmation can understate download or cleanup data while
all named copy tests pass.

**Required correction.** Add boundary/property cases for 1 byte,
99,999,999 bytes, exact 100,000,000-byte multiples, each boundary plus one, and
large values through 1 TiB; cover multiple locales including non-Latin digits;
assert cleanup equality and that displayed preparation size never understates.

### B1-AUTH-M12 — T06 imposes an undefined two-second completion requirement

**Severity: Medium**

**Evidence.** T06.1 requires "supported-profile completion within 2 seconds"
(`reservation-rebaseline-test-spec-v5.md:112-114`). The plan and authority
define 250 ms marker observation/watchdog behavior, heartbeat, and overall action
timeouts, but neither defines a two-second terminal completion bound or a
"supported profile" (`reservation-rebaseline-plan-v5.md:186-196`;
`specs/SPEC-044-malibu-model-catalog-economics.md:259-263`).

**Consequence.** The test can reject a conforming worker that observes
cancellation promptly but needs longer for durable cleanup, or pressure an
implementation to emit a premature terminal event.

**Required correction.** Either define the profile, clock start/end, scheduler
tolerance, cleanup state, and terminal bound in authority, or constrain T06 to
the approved 250 ms observation/`task.cancel()` requirement plus heartbeat and
action-timeout behavior.

### B1-AUTH-M13 — closed event-error precedence is not tested

**Severity: Medium**

**Evidence.** The amendment freezes both a closed error-code set and a
first-applicable precedence for concurrent failures
(`specs/SPEC-044-malibu-model-catalog-economics.md:223-247`). T14 says only to
test "approved codes" and does not require simultaneous-error cases
(`reservation-rebaseline-test-spec-v5.md:232-236`).

**Consequence.** Nondeterministic or lower-priority error selection can ship
while all single-fault tests pass, weakening stable UI behavior and diagnostics.

**Required correction.** Add table-driven multi-fault cases across every
adjacent precedence class and assert the exact emitted code, terminal state,
exit status, and unchanged side-effect boundary.

### B1-AUTH-I1 — structural validation succeeds but does not prove semantic closure

**Severity: Info**

The candidate has the correct base and operator authorship, the supplied plan
and test hashes match, the two prerequisite commits are ancestors of the base,
and structural checks are green. `scripts/check_spec_governance.py` explicitly
does not infer normative meaning from Markdown, so those results do not resolve
the findings above.

## Verification evidence

Fresh checks performed in the authority worktree:

| Check | Result |
|---|---|
| `git rev-parse origin/main` | `f7e584499828b3d16036382848b5caa1a897cdf9` |
| `git rev-parse c42eea1c^` | exact base revision |
| `git rev-list --count origin/main..c42eea1c` | `1` |
| prerequisite ancestry for `6f271245` and `c4401f17` | pass |
| `git merge-base --is-ancestor origin/main c42eea1c` | pass |
| `sha256sum` of approved plan/test specification | both exact expected digests |
| `python3 scripts/check_spec_governance.py --base-ref origin/main` | pass, exit 0 |
| `python3 scripts/gen_spec_index.py --check` | pass, 47 canonical specs |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_spec_governance scripts.tests.test_spec_pr_declaration` | pass, 61 tests |
| `cd phase3-binary && swift test --filter ModelCatalogEconomicsTests` | pass, 8 tests |
| `git diff --check origin/main...c42eea1c` | pass |

The structural passes establish file integrity, ancestry, manifest syntax, and
existing governance-test behavior. They do not establish semantic completeness,
compatibility, reachability, or adequacy of the future acceptance tests. The
two High and thirteen Medium findings therefore block Dependency Gate 5/T18.
