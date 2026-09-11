# Build 1 preparation authority v4 independent adversarial review

**Gate result: BLOCK**

**Finding counts:** 0 Critical, 1 High, 4 Medium.

This review independently inspected the exact v8 plan and test specification,
the complete cumulative authority diff, the current implementation surfaces,
and the previous formal findings. Structural validation is green, but the
reviewed corpus does not yet give an implementer one coherent set of normative
and acceptance-test oracles.

## Reviewed immutable inputs

- Repository base: `origin/main` =
  `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Planning worktree revision:
  `5eb809c505d6f4f3dde22128d968dfd2db4cec84`.
- `reservation-rebaseline-plan-v8.md` SHA-256:
  `e99886d69bf52720d2455ca0327d7914d9d619ec42f6efd8219be07d6d47f896`.
- `reservation-rebaseline-test-spec-v8.md` SHA-256:
  `95c2281fa4e1cf31d3bf51e051537780f38cfe50d822e14661f3f1bb71901ba3`.
- Authority worktree revision:
  `037a39349cae2302fa793042b9e461df719f946f`.
- Cumulative authority diff:
  `f7e584499828b3d16036382848b5caa1a897cdf9...037a39349cae2302fa793042b9e461df719f946f`.
- Prior formal review artifact:
  `docs/product-roadmap/build-1/reviews/preparation-authority-v3-sol.md`
  at `25e12533fb4a2a21e955c48f3be72e582bf369b5`.

Both supplied worktrees were clean at initial inspection, the base is the
authority branch's merge base, and landed BYOM Slice 5 commit `6f271245` and
Slice 6 commit `c4401f17` are ancestors of the authority revision. SwiftPM
rewrote `phase3-binary/Package.resolved` during a filtered test; that generated
change was restored before this artifact was written.

## Findings

### B1-AUTH-V4-H1 — High — Plan/test and SPEC-044 prescribe incompatible exact row orders and identities

**Evidence.** The v8 plan rejects duplicate exact `model_key` values and sorts
by a custom `bucket_rank`; applies payout only in bucket 1; applies
`recommendation_rank`, demand rank, demand weight, supply-deficit score, and
ready-provider count only in bucket 2; then compares `display_model_id`, nullable
`candidate_id`, and finally `model_key`
(`reservation-rebaseline-plan-v8.md:55-65`). T15 requires that exact tuple and
duplicate-`model_key` rejection
(`reservation-rebaseline-test-spec-v8.md:337-339`).

The reviewed authority instead freezes R008 section rank; then payout, demand
rank, **supply-deficit before demand weight**, ready-provider count, and a final
tagged canonical identity. It defines that identity as (`candidate`,
`candidate_id`) when a candidate exists and (`catalog`, `model_key`) otherwise,
rejects duplicate canonical identity, and expressly forbids display names from
participating (`specs/SPEC-044-malibu-model-catalog-economics.md:683-712`).
Thus two candidate rows may legally share a model key while having distinct
candidate identities under the SPEC, but the plan/test reject them. Conversely,
the plan requires display identity and recommendation-rank comparisons that the
authority does not authorize. The current app sorter is a third behavior: it
ends with `displayID.localizedStandardCompare`
(`phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:2885-2898`).

**Consequence.** No implementation can satisfy both exact oracles. Following
the plan/test violates SPEC-044; following SPEC-044 fails mandatory v8 tests.
Candidate rows can also be rejected or reordered differently across the two
contracts, changing visible actions and recommendations.

**Required correction.** Freeze one exact tuple, field applicability rule,
null order, numeric representation, final unique canonical identity, and
duplicate predicate in SPEC-044, the plan, and T01/T15/T16. Either revise the
plan/test to the operator-owned R005 tuple or intentionally amend R005, but do
not describe both as exact. Recompute plan/test digests and repeat this gate.

### B1-AUTH-V4-M1 — Medium — Catalog-only acceptance permits states forbidden by the authority

**Evidence.** SPEC-044 requires a catalog-only row to use exactly
`economics_state: unavailable`, `rate_source: none`, and the conservative
`local_default:not_offered` admission sentinel with null event/time and both
authorization booleans false
(`specs/SPEC-044-malibu-model-catalog-economics.md:137-157`). The v8 plan only
requires an economics state that is never `trusted` and null money/demand
(`reservation-rebaseline-plan-v8.md:37`). T01 says “always nontrusted,” T16
accepts any `economics_state` other than `trusted`, and T18 again describes the
case only as nontrusted/null-money/no-action
(`reservation-rebaseline-test-spec-v8.md:47,356,372-378`). No positive oracle
requires the exact economics state, rate source, admission source/state,
nullability, or false booleans.

**Consequence.** An implementation can pass the written acceptance suite while
emitting `fallback`, `stale`, or `blocked`, borrowing the wrong source semantics,
or constructing a non-authoritative admission shape. That changes provider
warnings and undermines the intended identity/economics isolation even though
money remains hidden.

**Required correction.** Make the plan and T01/T16 require the exact
`unavailable`/`none`/`local_default:not_offered` sentinel and every required
null/false value. Add one-fault negatives for each alternative economics state,
rate source, admission source/state, event/time, and authorization boolean.

### B1-AUTH-V4-M2 — Medium — The retained `local_only` copy makes a readiness claim the owner spec does not support

**Evidence.** The plan says the Slice 6 labels and meanings remain exact inputs
(`reservation-rebaseline-plan-v8.md:33`) and explicitly drives
`local_default:local_only` through preparation
(`reservation-rebaseline-plan-v8.md:43-53`; test specification `:358`). The
retained handoff maps `local_only` to **“Installed and usable on this Mac; not
offered to the network.”**
(`audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md:39-43`).
SPEC-046 defines `local_only` much more broadly: identity, readiness, fit,
adapter safety, or policy may be insufficient, and the provider may need to fix
a local blocker or evaluate before becoming offerable
(`specs/SPEC-046-provider-byom-discovery.md:95-103`). The v8 matrix also permits
the same row to have `runtime_state: needs_preparation` and show **Prepare
locally** (`reservation-rebaseline-plan-v8.md:41-50`).

**Consequence.** Malibu can truthfully receive a `local_only` candidate that
needs weights/runtime or is unreachable, yet tell the provider it is installed
and usable. The row can simultaneously claim usability and ask to prepare the
model, violating the Build 1 truthful-readiness goal.

**Required correction.** Replace the `local_only` state meaning with
admission-only language consistent with SPEC-046, leaving readiness to the
independently bound readiness/runtime fields. Add fixtures for each reason that
can produce `local_only`, including `needs_weights`, `needs_runtime`,
`requires_preparation`, unreachable, fit failure, adapter rejection, and policy
block, and reject installed/usable copy unless separate evidence proves it.

### B1-AUTH-V4-M3 — Medium — The cleanup “byte-identical” oracle compares different schema shapes

**Evidence.** A v2 row contains a `cleanup_published` action using the closed v2
action shape (`specs/SPEC-044-malibu-model-catalog-economics.md:200-214`). A
top-level `cleanup_targets` element contains identity/display/revision/artifact/
release/model-key/root/receipt/size/keep-set fields **and** its nested `cleanup`
action (`:261-276`). The next sentence nevertheless requires a row cleanup
action to be a “byte-identical projection” of the corresponding top-level entry
(`:276-279`). The plan and T09.6 repeat that the row action is identical or
byte-identical to the target entry
(`reservation-rebaseline-plan-v8.md:266-269`;
`reservation-rebaseline-test-spec-v8.md:204-206`). An action object cannot be
byte-identical to the larger target object that contains it.

**Consequence.** A literal test is impossible to pass; a nonliteral test must
invent which fields or serialization are compared. That ambiguity sits on the
identity binding for destructive published cleanup.

**Required correction.** State that `row.cleanup_published` is byte-identical
to `cleanup_targets[i].cleanup` under one named canonical byte encoding, then
separately require the action digest and estimated bytes to equal the enclosing
target fields. Update T09.6 with positive and digest/size/transaction/action
one-fault negatives.

### B1-AUTH-V4-M4 — Medium — The closed admission-state corpus is simultaneously specified as 12 and 13 values

**Evidence.** SPEC-046-R003 enumerates exactly 12 admission states
(`specs/SPEC-046-provider-byom-discovery.md:82`). The Slice 6 handoff says all
13 values remain unchanged, but its own table lists 12
(`audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md:21,39-52`).
SPEC-001 repeats “13 machine admission states”
(`specs/SPEC-001-phase3-binary.md:3255-3256`). T16 correctly generates both
sources over all 12 states
(`reservation-rebaseline-test-spec-v8.md:343-352`).

**Consequence.** The supposedly closed inventory has no single cardinality.
Implementers and contract-lock tests can either invent a thirteenth value or
contradict the normative prose while accepting the actual closed enum.

**Required correction.** Correct SPEC-001 and the handoff to 12, or add and
fully define the missing thirteenth state across SPEC-046/047, source legality,
guidance, copy, transitions, and T16. The current evidence supports correcting
the count to 12.

## v3 finding disposition

| v3 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V3-H1 cleanup continuous-lock contradiction | **Closed.** Authority, v8 plan, and T03/T10/T12 now keep `cancel.lock` continuously from the final marker check through rename, both parent barriers, durable/readback-validated `tombstoned`, and only retain the constructible cancellation-first versus recovery-first post-crash race. |
| B1-AUTH-V3-H2 false “Earning now” verdict | **Closed.** SPEC-001/044/046/047, the Slice 6 handoff, plan, contract lock, localization requirements, and tests now use **Eligible to earn on qualifying settled requests** and prohibit current-income implications. |
| B1-AUTH-V3-H3 catalog-only trusted economics | **Closed in authority.** SPEC-044 now prohibits trusted economics and candidate authority for the all-null row. The separate acceptance-proof gap is B1-AUTH-V4-M1; this does not reopen the prior positive trusted-economics design. |
| B1-AUTH-V3-M1 contradictory ACL creation | **Closed.** Authority, plan, and tests now require an already-open unpublished owner-only temp, empty-ACL proof before the first sensitive byte, fail-closed removal of only the new empty object, and same-descriptor revalidation. |
| B1-AUTH-V3-M2 unbounded cancel-lock wait | **Closed.** The exact six-outcome acknowledgement includes null-attempt/no-mutation `busy` after a 2.000-second monotonic deadline, exit 0, fixed resources, and repeated-attempt tests. |
| B1-AUTH-V3-M3 missing total ranking | **Not closed; escalated to B1-AUTH-V4-H1.** Both sides now define exact total orders, but the definitions conflict. This is more severe than the prior omission because implementation cannot satisfy the combined corpus. |

No v3 finding was downgraded or removed to reach a passing result.

## Earlier finding disposition and regression check

| Earlier findings | Disposition in this gate |
|---|---|
| B1-AUTH-V2-H1 exclusive v1/v2 advertisement | **Closed.** Complete mutually exclusive capability/token pairs and partial/dual/disagreement negatives remain in R001 and T01/T15. |
| B1-AUTH-V2-H2 coordinator no-event `not_offered` | **Closed.** Exact response-digest binding, nullable event only for authoritative no-event `not_offered`, and event-backed negatives remain. |
| B1-AUTH-V2-H3 cleanup cancellation/recovery | **Closed.** Marker-only cancel authority, worker/recovery phase ownership, reversible precommit intent, and durable `tombstoned` commit remain; the v3 continuous-lock correction is coherent. |
| B1-AUTH-V2-H4 root identity | **Closed.** Nonce/path/device/inode/version digest and saved lifecycle locators remain required and fault-tested. |
| B1-AUTH-V2-M1 catalog-only representation | **Closed for representation.** The all-null/no-action boundary remains. B1-AUTH-V4-M1 requires exact behavioral proof of the new sentinel. |
| B1-AUTH-V2-M2 orphan cleanup correlation | **Closed.** Required immutable receipt-bound `event_model_key` and bounded target reachability remain. |
| B1-AUTH-V2-M3 refresh ordering | **Closed.** App-owned prelaunch generation remains ahead of CLI-session ordering and tests cover inversions/restarts/timeouts. |
| B1-AUTH-V2-M4 JSONL/backpressure | **Closed.** Constant-space framing, stderr and delivery bounds, terminal preservation, and discard-drain behavior remain. |
| B1-AUTH-V2-M5 ACL policy | **Closed.** The v3 repair resolved creation order without weakening descriptor-bound enforcement. |
| B1-AUTH-H1/H2 and M1-M13 from v1 | **Closed or prospectively gated as previously recorded.** Guidance binding; version selection; both `not_offered` sources; verified-artifact gating; cancellation predicates; cleanup commit/correlation/accounting; governance; built-boundary proof; budget/legacy/size/timing/error precedence all remain present. B1-AUTH-V4-H1 supersedes the ranking portion, B1-AUTH-V4-M2 corrects a newly observed retained-copy inconsistency, and B1-AUTH-V4-M3 corrects a newly observed cleanup comparison oracle. |
| Original v1 H1/H2, M1-M13, I1 | **No regression found beyond the named v4 findings.** Structural validation still does not establish semantic closure (I1). Future built-boundary, hardware, release, and settlement evidence remains explicitly pending rather than claimed. |

## Cross-cutting adversarial assessment

- **Feasibility:** the private v3 namespace, bounded reservation/history,
  same-EUID worker, transfer/accounting limits, publication, cancellation, and
  recovery design are implementable at plan level after the exact-oracle
  corrections above. H1 and M3 currently make literal implementation
  conformance impossible.
- **Trust and economics:** candidate/source/freshness binding, verified artifact
  status, catalog-only trust isolation, and preparation-versus-admission
  separation are appropriately fail-closed. M1 must make the exact sentinel
  observable in tests.
- **UX truthfulness:** conditional settlement eligibility and local preparation
  copy are materially improved. M2 still creates a direct false readiness claim.
- **Failure recovery and security:** root authentication, descriptor-relative
  traversal, ACL clearing, bounded temp recovery, continuous cancel locking,
  intent/tombstone phases, exact keep sets, and no legacy deletion are coherent
  at plan level. M3 must remove ambiguity from destructive cleanup binding.
- **Compatibility, migration, and rollback:** v1/v2 selection is fail-closed;
  v3 state is isolated and not imported into the legacy store; rollback preserves
  both stores without GC; re-upgrade validates and resumes recovery.
- **Observability and privacy:** bounded redacted codes/counters cover worker,
  cancellation, refresh, transfer, recovery, inventory, accounting, and deletion
  phases. Paths, credentials, feed bodies, prompts, completions, and raw errors
  remain excluded.
- **Hardware and release truth:** the plan correctly reserves real MLX, APFS
  stable-media/power recovery, incumbent serving, signed journeys, correctly
  settled credit, listed-tier, notarization, app/tarball byte identity, and
  updater proof for later qualification. It does not treat fixture evidence as
  those results.

## Pending implementation and qualification gates

The repository still contains the landed v1 catalog-economics implementation,
not the future v2 preparation/storage/cleanup implementation. That is expected
at this preimplementation gate and is not a finding. After the corpus is
corrected and approved, the following evidence remains pending:

- the first implementation commit must descend from the finally approved
  authority and exact plan/test revision;
- all targeted and broad Slice 6B/6C tests, built CLI through production Malibu,
  and independent code/security/architecture full-diff audits must pass;
- physical Apple Silicon execution must prove real MLX preparation/adoption,
  APFS/custom-root/reboot/abrupt-power recovery, and incumbent continuity;
- final signed/notarized assets, app/tarball CLI byte identity, updater behavior,
  and first listed-tier evidence remain release gates;
- accepted signed discovery and admission journeys plus an actual routed,
  receipted, correctly settled request and positive provider credit remain Build
  1 qualification gates. Preparation, local assertions, fixtures, and this
  authority review do not satisfy them.

## Fresh verification evidence

The following checks ran against the exact authority revision unless stated
otherwise:

```text
git rev-parse HEAD
=> 037a39349cae2302fa793042b9e461df719f946f

git rev-parse origin/main
git merge-base HEAD origin/main
=> f7e584499828b3d16036382848b5caa1a897cdf9 (both)

shasum -a 256 reservation-rebaseline-plan-v8.md \
  reservation-rebaseline-test-spec-v8.md
=> e99886d69bf52720d2455ca0327d7914d9d619ec42f6efd8219be07d6d47f896
=> 95c2281fa4e1cf31d3bf51e051537780f38cfe50d822e14661f3f1bb71901ba3

git diff --check f7e584499828b3d16036382848b5caa1a897cdf9..HEAD
=> exit 0

python3 -m json.tool specs/AUTHORITY.json
python3 -m json.tool specs/CONFORMANCE.json
=> both exit 0

python3 scripts/gen_spec_index.py --check
=> canonical specs: 47; index up to date

python3 scripts/gen_spec_index.py --lint
=> exit 0

python3 scripts/check_spec_governance.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_spec_governance \
  scripts.tests.test_spec_pr_declaration \
  scripts.tests.test_byom_contract_lock
=> governance passed; Ran 67 tests in 84.095s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> Executed 8 XCTest tests, 0 failures

cd phase4-coordinator && go test ./internal/ws -run \
  'TestModelAdmission(StatusForPreBYOMProviderReturnsNotOffered|OfferSubmitAndStatusStayNonEarning|StatusGuidanceForRejectedAndDemotion)$' -count=1
=> ok github.com/augstar/macprovider-coordinator/internal/ws 0.947s
```

An earlier coordinator command selected zero tests and is deliberately excluded
as passing evidence. The structural and current-code test passes do not resolve
the semantic conflicts above.

## Gate result

**BLOCK: 0 Critical, 1 High, 4 Medium.** Correct B1-AUTH-V4-H1 and M1-M4,
commit a new internally consistent authority/plan/test revision, recompute exact
digests, and repeat the independent cumulative gate. Slice 6B implementation
must not begin from the reviewed corpus.
