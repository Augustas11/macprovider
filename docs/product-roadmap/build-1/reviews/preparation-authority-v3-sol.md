# Build 1 reservation/preparation authority v3 formal adversarial review

Date: 2026-09-12

Reviewer lane: independent Sol formal authority/feasibility gate

Verdict: **BLOCK**

Finding count: **0 Critical, 3 High, 3 Medium, 0 Low**

The acceptance gate requires zero Critical, High, and Medium findings. Revision
v3 of the authority and the pinned v7 plan/test corpus do not meet that gate.
The correction closes most findings from the first two reviews, but the combined
authority still contains one destructive-cleanup contradiction, two financial
truth/binding contradictions, and three implementability gaps.

## Reviewed immutable inputs

- Base: `origin/main` =
  `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Pinned plan worktree revision:
  `ba5f8b303b19c9664c1fe81e3bd452948d4c7a13`.
- `reservation-rebaseline-plan-v7.md` SHA-256:
  `033d57a69f0c754051625d1c628fcf9a5f8e9f89ae07ba05e76a8a02d1bb841a`.
- `reservation-rebaseline-test-spec-v7.md` SHA-256:
  `2c404fb012831440b89a1004bbc278f827c0c82885f845c8fe114a97e0950d43`.
- Authority revision:
  `fccb813cfa02fba5bc7aec71ee23bccb4619429b`.
- Cumulative authority diff:
  `f7e584499828b3d16036382848b5caa1a897cdf9...fccb813cfa02fba5bc7aec71ee23bccb4619429b`.

The authority history is linear from the pinned base. The landed BYOM Slice 5
commit `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` and Slice 6 commit
`c4401f1791d593d37d68eba91af94219b26d278f` are ancestors of the reviewed
authority revision.

## Findings

### B1-AUTH-V3-H1 — High — The v7 cleanup protocol contradicts the final continuous-lock authority

**Evidence.** SPEC-044-R010 requires the cleanup worker to take `cancel.lock`
immediately before the final marker check and hold it without interruption
through the final-to-tombstone rename, both parent durability barriers, durable
and readback-validated `tombstoned`, and only then release it
(`specs/SPEC-044-malibu-model-catalog-economics.md:559-566`). Recovery uses the
same operation/cleanup-then-cancel order and holds all three locks while
mutating recovery state (`:578-608`). Staging cleanup repeats the continuous
hold (`:610-620`). R012 requires proof of that exact continuous interval
(`:778-783`).

The pinned v7 plan calls a different sequence “exact”: it releases
`cancel.lock` after the marker check, renames and syncs the parent while the
lock is absent, then reacquires the lock and may restore if a marker appeared
(`reservation-rebaseline-plan-v7.md:273-284`). T10.3 requires cancel/crash
injection at that release/reacquire handoff and specifically requires a marker
to be written after the objects-parent barrier but before the worker's attempted
phase update (`reservation-rebaseline-test-spec-v7.md:248`). T10.5 copies the
same handoff into staging cleanup (`:256`). That live-worker race is
unconstructible under the final authority because the cancel process cannot
acquire `cancel.lock` in the stated interval.

**Consequence.** No implementation can satisfy the exact combined corpus.
Following the SPEC fails mandatory v7 tests; following the plan/tests violates
the authority and reopens cancellation around an irreversible deletion path.
The inherited v2 High finding remains open and cannot be downgraded.

**Required correction.** Revise the plan and test specification to the
continuous-lock sequence. Remove live-worker marker-window vectors inside the
protected interval. Retain the constructible post-crash race: cancellation
wins by acquiring `cancel.lock` before recovery and recording the marker, or
recovery wins by acquiring the ordered locks first and durably committing
`tombstoned`. Recompute the plan/test hashes and repeat the formal gate.

### B1-AUTH-V3-H2 — High — The required “Earning now” verdict violates the authority's financial-truth rule

**Evidence.** SPEC-001 requires an exact provider-facing verdict of
**“Earning now”** whenever `provider_guidance.earning_path_class` is
`settlement_capable` (`specs/SPEC-001-phase3-binary.md:3229-3247`). The v7 plan
retains the landed Slice 6 state labels, meanings, and earning-verdict copy as
exact input and requires Malibu to render the bound verdict before preparation
or economics copy (`reservation-rebaseline-plan-v7.md:33,37-50`). Yet
SPEC-047 defines `settlement_capable` only as permission to participate in
positive settlement for request attempts that later satisfy route-time and
receipt-verification predicates
(`specs/SPEC-047-network-model-admission.md:86-97`). SPEC-044 also permits a
`settlement_capable` row whose runtime is `needs_preparation`, so the artifact
need not be ready or serving (`specs/SPEC-044-malibu-model-catalog-economics.md:401-409`).
Finally, SPEC-044-R004 requires rates rather than income, says actual rewards
depend on demand, uptime, accepted requests, routing, settlement, and other
conditions, and prohibits copy such as “earns” or other implied income absent a
later verified forecast contract (`:644`).

**Consequence.** The exact required verdict can tell a provider that income is
currently occurring when the model is unprepared, receives no requests, or has
no qualifying settled receipt. This is a money-facing false claim and an
internal normative contradiction.

**Required correction.** Replace the unconditional verdict with operator-owned
conditional eligibility copy, for example **“Eligible to earn on qualifying
settled requests”**, and reconcile SPEC-001, SPEC-044, SPEC-046/SPEC-047, the
Slice 6 copy handoff, plan, tests, and localization/accessibility fixtures. If
“Earning now” is retained, define and bind a separate live evidence predicate
that proves current qualifying settled activity before rendering it.

### B1-AUTH-V3-H3 — High — Catalog-only trusted economics has no admissible identity binding

**Evidence.** SPEC-044 permits `candidate_id`, `provider_guidance`, and
`guidance_binding` all to be null only when no matching SPEC-046/SPEC-047
candidate or local source exists. It then says the same catalog-only row remains
eligible for trusted catalog-rate display when “independent admission” and
signed-feed evidence satisfy R002/R003
(`specs/SPEC-044-malibu-model-catalog-economics.md:137-146`). The v7 plan and
T16 repeat that allowance
(`reservation-rebaseline-plan-v7.md:37-39`;
`reservation-rebaseline-test-spec-v7.md:345-349`). But SPEC-047 admission is
closed and per-provider/per-candidate, and every state event is bound to a
candidate (`specs/SPEC-047-network-model-admission.md:86-99`). With the entire
candidate/binding group null, SPEC-044 defines no identity, event, digest, or
join by which a coordinator admission decision can authorize economics for the
catalog-only row.

**Consequence.** A conforming implementation cannot prove the stated positive
case. An implementation that invents a model-key or display-name join can show
trusted money data using admission evidence from a different candidate. An
implementation that always blocks is safe but fails the mandatory “allow”
acceptance vector. This is a financial trust-boundary and test-oracle defect.

**Required correction.** Either prohibit trusted economics whenever the
candidate/guidance/binding group is null, or define a separate closed
catalog-level pricing authorization whose identity and signed evidence do not
claim SPEC-047 candidate admission. Do not reuse a per-candidate admission
state without a candidate binding. Update R002/R003, the plan matrix, and T16
with positive and cross-candidate negative cases.

### B1-AUTH-V3-M1 — Medium — ACL creation authority is internally contradictory

**Evidence.** SPEC-044 says atomic creation strips inherited ACLs from an
“unopened temporary namespace entry” before publication, then requires ACL and
identity verification from an opened descriptor
(`specs/SPEC-044-malibu-model-catalog-economics.md:330-344`). The v7 plan and
T08 instead require clearing the inherited ACL through an already-open
descriptor before any sensitive bytes are written
(`reservation-rebaseline-plan-v7.md:177-185`;
`reservation-rebaseline-test-spec-v7.md:154-160`). The object cannot be both
unopened and modified through its open descriptor, and the SPEC does not state
whether sensitive bytes may exist before inherited access is removed.

**Consequence.** Implementations and acceptance tests can choose different
creation orders. A literal path-based interpretation can expose private bytes
through an inherited named-user ACL before the descriptor-bound validation
required by the plan.

**Required correction.** Say “already-open, unpublished temporary entry.”
Require owner-only creation, descriptor-bound ACL clear and empty-ACL
verification before the first sensitive write, and descriptor revalidation
before publication or use. Preserve fail-closed removal of only the newly
created empty object. This keeps inherited v2 M5 open until the wording and
oracle agree.

### B1-AUTH-V3-M2 — Medium — A “bounded” cancel-lock wait has no deadline or timeout outcome

**Evidence.** SPEC-001 describes cancellation as a short-lived second CLI
process that writes exactly one acknowledgement. SPEC-044 calls the lock and
call bounded and says cancellation waits when worker or recovery holds
`cancel.lock` (`specs/SPEC-044-malibu-model-catalog-economics.md:528,594-607`).
The worker may hold that lock through rename, `fsync`, `F_FULLFSYNC`, phase-file
write/full-sync, and readback (`:559-564,610-616`). The only numeric cancellation
profile explicitly excludes tombstoning and declines a general durability
latency bound (`:626-640`). The v7 test suite checks busy/free and deadlock races
but supplies no lock-acquisition deadline or deterministic timeout result
(`reservation-rebaseline-test-spec-v7.md:268`).

**Consequence.** A slow or wedged durability operation can block the supposedly
short-lived cancellation subprocess and its sole acknowledgement indefinitely.
Repeated app cancellation attempts can accumulate subprocesses and resources
while still satisfying the written tests.

**Required correction.** Define a monotonic cancel-lock acquisition deadline
and a deterministic bounded result when it expires, including exit status,
acknowledgement behavior, and the rule that timeout cannot mutate marker or
phase state. Test injected slow/stuck sync, one waiter, repeated cancellation,
and eventual worker/recovery release.

### B1-AUTH-V3-M3 — Medium — “Deterministic” ranking has no total stable tie-break

**Evidence.** SPEC-044-R005 gives ordered preference classes and calls the
result deterministic, but defines no final key for rows tied on all named
criteria (`specs/SPEC-044-malibu-model-catalog-economics.md:646-650`). T15
permutes input/feed order and requires “the authority's stable tie-break,” which
the authority does not define
(`reservation-rebaseline-test-spec-v7.md:332`). The landed app ultimately uses
`displayID.localizedStandardCompare` after category, payout, and demand
(`phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:2885-2898`),
which is locale-sensitive and is not a total identity order when display IDs
compare equal.

**Consequence.** Tests must invent an oracle, and equal rows can reorder across
locale, input order, or sorting implementation. That undermines stable action
placement and the claimed deterministic fixtures.

**Required correction.** Freeze a total ordered tuple using canonical wire
values, with a final unique stable identity such as candidate ID or model key
and an explicit null/case/byte-order rule. Keep locale-aware display sorting
out of the authoritative tie-break. Add equal-display-name, null-field,
duplicate-rate/demand, locale, and permuted-input vectors.

## v2 finding disposition

| v2 finding | Disposition in this gate |
|---|---|
| V2-H1 incomplete v1 advertisement | **Closed.** SPEC-001/SPEC-044 and v7 plan/T15 require one exclusive complete capability/token pair and cover partial, dual, conflicting, and manifest/status mismatch cases. The separate `model_catalog_economics.v1` output-schema declaration in the landed manifest is not a v1/v2 selection token. |
| V2-H2 coordinator no-event `not_offered` | **Closed.** The binding now permits null event only for authoritative coordinator `not_offered`, binds the exact response, and T16 covers no-event and event-backed cases. |
| V2-H3 cleanup cancellation/recovery | **Open as B1-AUTH-V3-H1 (High).** The SPEC correction is coherent, but v7 retained the rejected release/reacquire protocol and impossible live marker race. |
| V2-H4 root identity | **Closed.** The complete identity digest and every reopening lifecycle record bind the saved locator, descriptor identity, schema/version, and digest; plan/tests cover config drift, replacement, remount, and reuse. |
| V2-M1 catalog-only representation | **Closed for representation.** Exact all-null behavior and no actions are defined. The new positive trusted-economics allowance has a distinct High binding defect, B1-AUTH-V3-H3. |
| V2-M2 orphan event correlation | **Closed.** Cleanup targets and durable state carry immutable non-null `event_model_key`; T10.6 runs orphan success/cancel/recovery through the built boundary. |
| V2-M3 projection ordering | **Closed.** App-owned refresh generations precede process launch and T14.1 covers inverted completion, restart, timeout, and action overlap. |
| V2-M4 JSONL/backpressure | **Closed.** Authority and T14.1 specify bounded incremental decoding, partial-line rejection, bounded stderr/queues, continued drain, and sustained-rate proof. |
| V2-M5 ACL policy | **Open as B1-AUTH-V3-M1 (Medium).** Scope and rejection policy are present, but creation order contradicts plan/test. |

No v2 High or Medium finding has been downgraded. Each is either closed by
specific replacement authority and acceptance vectors or retained at its prior
severity.

## v1 finding disposition

| v1 finding | Disposition in this gate |
|---|---|
| H1 guidance/candidate correlation | **Closed.** Candidate-associated rows carry the exact owner guidance and source binding with freshness and mismatch failure. Catalog-only rows are separately represented; their trusted-economics positive case is the fresh H3 above. |
| H2 deterministic v1/v2 selection | **Closed.** Exclusive complete pairs and every partial/dual/conflict negative are frozen. |
| M1 coordinator `not_offered` | **Closed.** Both authoritative no-event and event-backed forms are specified and tested. |
| M2 verified-artifact prerequisite | **Closed.** `verification_status: verified` is required at projection and dispatch, with negative statuses covered. |
| M3 cancellation acknowledgement outcomes | **Closed.** Exact echo/nullability, durable predicates, and total precedence are defined and table-tested. |
| M4 cleanup commit point | **Open as B1-AUTH-V3-H1 (High).** Durable `tombstoned` is now a coherent authority boundary, but v7 contradicts its continuous lock. |
| M5 reclaimable-byte definition | **Closed.** Descriptor-relative logical accounting and APFS-truthful copy are defined and tested separately from physical capacity. |
| M6 orphan cleanup reachability | **Closed.** Bounded cleanup targets and immutable event correlation are defined and exercised. |
| M7 governance mismatch | **Closed.** SPEC-001-R003, authority consumers, conformance mappings, versions, and indexes agree; validators pass. |
| M8 built CLI to production Malibu proof | **Closed prospectively.** T14.1/T15 require the built CLI through the production adapter. Execution remains a future implementation qualification. |
| M9 budget/precedence tests | **Closed prospectively.** Exact rounding, source precedence, invalid overrides, overflow, and free-space boundary cases are required. |
| M10 legacy accounting block | **Closed prospectively.** Both projected and direct preparation plus cleanup fail closed while serving remains untouched. |
| M11 localized sizes | **Closed prospectively.** Exact decimal-GB boundaries, locales, equality, and non-understatement are required. |
| M12 undefined two-second completion | **Closed.** The authority defines a qualified measurement profile and explicitly excludes tombstone durability from the two-second claim. B1-AUTH-V3-M2 is the separate undefined lock-wait bound. |
| M13 event-error precedence | **Closed prospectively.** Multi-fault precedence and terminal/exit/side-effect assertions are required. |
| I1 structural validation limits | **Retained as information.** Green structural checks do not establish semantic closure. |

## Cross-cutting challenge disposition

- **Feasibility and test proof:** blocked by H1 and M1-M3. The remaining
  reservation, bounded-state, budget, durability, and direct-dispatch cases are
  implementable at plan level.
- **Trust, economics, and UX truth:** blocked by H2 and H3. Locally motivated
  Prepare copy itself correctly avoids rate/demand motivation and says that
  preparation does not enable earnings.
- **Filesystem, root, and ACL:** root locator/authentication, no-follow
  traversal, identity reuse, and logical accounting are closed; ACL creation
  remains M1.
- **Cleanup, cancellation, locks, and recovery:** durable phase ownership and
  cancel-process mutation limits are defined; the plan/SPEC conflict is H1 and
  the missing lock-wait bound is M2.
- **Process adapter, JSONL, and backpressure:** constant-space framing, bounded
  stderr/delivery, drain behavior, malformed lines, child exit, and production
  adapter integration are adequately required for future proof.
- **Version compatibility:** the exact exclusive v1/v2 pair matrix and
  fail-closed fallback are consistent. Extra non-generation schema declarations
  do not violate pair selection.
- **Migration and rollback:** v3 does not import legacy state; rollback
  preserves both legacy and v3 bytes/recovery state; re-upgrade validates in
  place. No new blocking inconsistency was found.
- **Resources and privacy:** storage/count/path/line/queue caps and redacted
  observability are specified. The cancellation subprocess resource gap is M2.
  Paths, usernames, credentials, feed bodies, prompts, completions, and raw
  errors remain excluded from public/log surfaces.

## Pending implementation and release qualifications

The reviewed repository still contains the landed v1 implementation rather
than the future v2 preparation/cleanup implementation. That is expected at this
planning gate and is not a plan defect. The following remain pending evidence,
not additional findings:

- first implementation commit ancestry from the eventual approved plan/test
  revision and its T18 digest check;
- execution of future v2 built-CLI/Malibu, fault-injection, race, capacity,
  localization, accessibility, and recovery suites;
- final signed/notarized app and tarball byte identity, updater evidence, real
  Apple Silicon/MLX usability, ordinary reboot and externally controlled abrupt
  power durability;
- first listed-tier release evidence, the pending BYOM journey conformance, and
  Slice 7's real served and correctly settled request.

## Fresh verification evidence

The following read-only checks ran against the pinned authority worktree unless
another worktree is named:

```text
git rev-parse HEAD
=> fccb813cfa02fba5bc7aec71ee23bccb4619429b

git rev-parse origin/main
=> f7e584499828b3d16036382848b5caa1a897cdf9

shasum -a 256 reservation-rebaseline-plan-v7.md \
  reservation-rebaseline-test-spec-v7.md
=> 033d57a69f0c754051625d1c628fcf9a5f8e9f89ae07ba05e76a8a02d1bb841a
=> 2c404fb012831440b89a1004bbc278f827c0c82885f845c8fe114a97e0950d43

git diff --check \
  f7e584499828b3d16036382848b5caa1a897cdf9...fccb813cfa02fba5bc7aec71ee23bccb4619429b
=> exit 0

python3 scripts/gen_spec_index.py --check
=> canonical specs: 47; ok: spec index is up to date

python3 scripts/gen_spec_index.py --lint
=> exit 0

python3 scripts/check_spec_governance.py \
  --base-ref f7e584499828b3d16036382848b5caa1a897cdf9
=> SPEC governance validation passed

python3 -m json.tool specs/AUTHORITY.json
python3 -m json.tool specs/CONFORMANCE.json
=> both exit 0

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_spec_governance scripts.tests.test_spec_pr_declaration
=> Ran 61 tests in 95.598s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> Executed 8 tests, 0 failures

cd phase4-coordinator && go test ./internal/ws -run \
  'TestModelAdmissionStatusForPreBYOMProviderReturnsNotOffered|TestModelAdmissionSubmissionsDisabledRejectsSubmitAndPreservesReadback' \
  -count=1
=> ok github.com/augstar/macprovider-coordinator/internal/ws
```

SwiftPM rewrote `phase3-binary/Package.resolved` during the Swift test; that
generated change was restored before this review artifact was staged. The
structural and current-code test passes do not resolve the semantic conflicts
above.

## Gate result

**BLOCK.** Correct all three High and three Medium findings, reconcile and
commit a new plan/test revision with new byte digests, and run another
independent cumulative authority gate. Slice 6B remains unauthorized.
