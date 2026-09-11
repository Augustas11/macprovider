# Build 1 preparation authority v8 independent adversarial review

**Gate result: BLOCK**

**Finding counts:** 0 Critical, 0 High, 1 Medium.

This review independently inspected the exact v13 plan and test specification,
the complete cumulative authority diff, the current implementation and test
surfaces, and every prior formal finding named by the gate. The v8 authority
closes the v7 lock-order, cancel-visible-history, and acquisition-bound defects.
The plan's ownership table still forbids the failure-only worker from taking the
lock that the normative lifecycle requires and assigns the cancel process only
the second lock of its required ordered pair. That contradiction must be removed
before the plan can govern slice 6B implementation.

## Reviewed immutable inputs

- Repository base: `origin/main` =
  `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Planning worktree revision:
  `77108941704e95a3b916233d93e9064aae7ca9d0`.
- `reservation-rebaseline-plan-v13.md` SHA-256:
  `88b2db5ebfd9c449bed355ebd9157d5dbabefba0dc0dc2c372e1fd6c9aa4defa`.
- `reservation-rebaseline-test-spec-v13.md` SHA-256:
  `035115c0627ee35a39f0960b4675d1fb18037c4e1730f1842bd0e72190cec5fc`.
- Authority worktree revision:
  `d4f5eeb0dec4120811ac76afccdfc70a72e3483d`.
- Cumulative authority diff:
  `f7e584499828b3d16036382848b5caa1a897cdf9...d4f5eeb0dec4120811ac76afccdfc70a72e3483d`.
- Prior formal review artifact:
  `docs/product-roadmap/build-1/reviews/preparation-authority-v7-sol.md`
  at `767f20b399b41baf658ef043decb785a482684af`, SHA-256
  `e1872075dc033046c46f6582c25f070537ba8e2d482a1e6ce1c36bfe7d2db858`.

`git fetch --prune origin` confirmed that `origin/main` remains the supplied
base. Both supplied worktrees were clean at initial inspection. The authority
revision has the stated base as merge base, and landed BYOM Slice 5
`6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` and Slice 6
`c4401f1791d593d37d68eba91af94219b26d278f` are ancestors. A filtered SwiftPM
test rewrote `phase3-binary/Package.resolved`; that generated change was
restored before this review artifact was written.

## Finding

### B1-AUTH-V8-M1 — Medium — The ownership table forbids the lock custody required by the exhaustive graph

**Evidence.** The v13 ownership table says the failure-only worker owns
`failure.lock` and lists `cancel` among the locks it **must not own**
(`reservation-rebaseline-plan-v13.md:124-131`). The same table describes the
cancel process as owning only a "Brief cancel lock". The normative lifecycle
requires the opposite assignments: failure-only creation, compaction, and
eviction take `failure.lock` then `cancel.lock`, and direct cancel also takes
`failure.lock` then `cancel.lock`
(`specs/SPEC-044-malibu-model-catalog-economics.md:522-533`). The v13
constructive lifecycle, cancellation protocol, exhaustive twelve-path graph,
and T03/T12/T14 tests correctly repeat those ordered pairs
(`reservation-rebaseline-plan-v13.md:223-235,243-269`;
`reservation-rebaseline-test-spec-v13.md:93-118,281-302,308-318`).

**Consequence.** File ownership and mutation boundaries are implementation
instructions, not narrative decoration. A slice owner following the table can
implement failure-only history under `failure.lock` alone or direct cancellation
under `cancel.lock` alone, recreating the torn cancel-visible transition that
B1-AUTH-V7-H2 identified. A slice owner following the later graph instead
violates the table's explicit prohibition. The current acceptance tests cannot
make both instructions true, so the plan has not yet reached a single
code-reviewable ownership contract even though the operator SPEC itself is
coherent.

**Required correction.** Revise the ownership table so the failure-only worker
owns bounded `failure.lock`-then-`cancel.lock` custody for its exact pending/
history transition and the direct cancel process owns bounded
`failure.lock`-then-`cancel.lock` custody for its predicate and exact marker.
Keep `operation.lock`, cleanup/adoption/socket/runtime authority, live work, and
incumbent mutation outside the failure-only worker; keep history/recovery/
cleanup/artifact/model/runtime mutation outside direct cancel. Add an exact
T18 consistency assertion or equivalent plan-gate check so the ownership table
cannot regress independently from SPEC-044's graph. Recompute the committed
plan/test digests and rerun this cumulative gate.

## v7 finding disposition

| v7 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V7-H1 contradictory recovery lock order | **Closed.** SPEC-044 v0.2.7 and the v13 plan now define one exhaustive acyclic graph covering twelve operational paths: projection publication; initial valid-run view; operation-conflict reporting; pre-active creation; live non-cleanup commit; next failure-writer compaction; normal terminal/non-cleanup recovery; direct cancel; live marker polling; cleanup mutation; cleanup terminal compaction; and adoption. Every multi-lock path has an exact acquisition, retention, phase boundary, and reverse release rule. Cleanup and failure custody never overlap. |
| B1-AUTH-V7-H2 cancellation outside failed-history serialization | **Closed.** Failed-dispatch pending/history creation, compaction, deterministic eviction, recovery, and direct cancel-visible reads now share the `failure.lock`-then-`cancel.lock` suffix. Replacement history is durable and readback-valid before pending unlink; crash duplicates deduplicate by immutable identity; cancel linearizes under the same pair and returns exact `terminal` for a matching durable failed dispatch. T03/T12/T14 inject reads at every persistence boundary. |
| B1-AUTH-V7-M1 unbounded/fairness-free failure-lock wait | **Closed.** Failure-only dispatch and direct cancel use one total `CLOCK_MONOTONIC_RAW` two-second pair-acquisition deadline, while a successful nonblocking operation acquisition starts a separate bounded subordinate-lock episode. Partial custody and fixed resources are released on timeout. The authority and tests expressly make no scheduler-fairness or starvation-free claim and test per-episode bounded fail-closed behavior under sustained arrivals. |

No v7 finding was downgraded or discarded to obtain these dispositions.
B1-AUTH-V8-M1 is a new contradiction in the planning ownership boundary, not a
renaming of a v7 finding.

## v6 finding disposition

| v6 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V6-H1 malformed-advertisement fallback contradiction | **Closed.** R001, SPEC-001-R003, the plan, and T01/T14/T15 reserve the exact unavailable warning/retry for failure after a valid exclusive complete pair; every negotiation-negative class is a silent static-card result with no read/run/cancel call. |
| B1-AUTH-V6-H2 pre-worker terminal lifecycle | **Closed.** Immutable action identity validation precedes attempt allocation and semantic work. A semantic rejection durably publishes one bounded non-live pending record before one sequence-1 terminal event and exit 3; pair-acquisition timeout is the distinct pre-attachment stderr/no-event/exit-5 path. Crash recovery never fabricates stdout or work. |
| B1-AUTH-V6-M1 stale v0.2.4 references | **Closed.** All forward-current owner, index, conformance, handoff, contract-lock, plan, and test references select SPEC-044 v0.2.7. Earlier versions occur in explicit changelog/review history. |
| B1-AUTH-V6-M2 incomplete per-copy cleanup proof | **Closed.** T09.6/T16 separately mutate both action copies, every other closed field, equal-two-copy digest/size values against the unchanged enclosing target, and cross-target substitutions. |

## v5 finding disposition

| v5 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V5-H1 conflicting exact `local_only` copy | **Closed.** Current authority, handoff, plan, and tests use the same admission-only sentence and require independent readiness/runtime evidence before positive usability copy. |
| B1-AUTH-V5-M1 catalog-only section conflict | **Closed.** The exact unavailable sentinel is valid only in R008 `Blocked`; `Network catalog`, `Current`, `Ready`, and `Needs preparation` are explicit one-fault rejections without their independent evidence. |
| B1-AUTH-V5-M2 false local-default offer history | **Closed.** Local-default unknown/unqueried coordinator state and coordinator authoritative no-active-offer readback have different exact English meanings and localization/accessibility/source-swap negatives. |
| B1-AUTH-V5-M3 cleanup target proof | **Closed.** Enclosing-target, per-action-copy, equal-two-copy, every-field, and cross-target fixtures are explicit before confirmation or mutation. |

## v4 finding disposition

| v4 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V4-H1 incompatible row-order oracles | **Closed.** R005 is the sole exact locale-independent tuple; plan and tests use its explicit null directions, exact numeric comparisons, tagged length-prefixed canonical identity, and duplicate-canonical-identity predicate. |
| B1-AUTH-V4-M1 incomplete catalog-only sentinel | **Closed.** The exact null/false source/state/economics/action sentinel and every one-field deviation remain fail closed. |
| B1-AUTH-V4-M2 false `local_only` readiness copy | **Closed.** The exact copy speaks only to admission and blocker fixtures require separate readiness evidence. |
| B1-AUTH-V4-M3 impossible cleanup comparison | **Closed.** JCS compares nested action to nested action, and each copy independently binds the enclosing digest and size. |
| B1-AUTH-V4-M4 inconsistent admission cardinality | **Closed.** Every current owner surface enumerates the same closed 12-state set and rejects a thirteenth value. |

## v3 finding disposition

| v3 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V3-H1 cleanup continuous-lock contradiction | **Closed.** Cleanup worker/recovery retains `cancel.lock` from final marker check through same-parent rename, both required barriers, durable `tombstoned`, and readback. Post-crash cancel-first/recovery-first is explicitly total. |
| B1-AUTH-V3-H2 false `Earning now` verdict | **Closed.** Provider surfaces use exact conditional qualifying-settlement eligibility and prohibit current-income, traffic, receipt, or guaranteed-demand meaning. |
| B1-AUTH-V3-H3 catalog-only trusted economics | **Closed.** Catalog-only rows have the exact nontrusted sentinel, null money/demand, no candidate binding, and no action. |
| B1-AUTH-V3-M1 contradictory ACL creation | **Closed.** New sensitive objects are already-open, unpublished, owner-only temps; ACL inheritance is stripped and verified empty before the first sensitive byte, followed by descriptor revalidation. |
| B1-AUTH-V3-M2 unbounded cancel wait | **Closed.** Direct cancel has the exact total two-second ordered-pair deadline and a valid null-attempt/no-read/no-mutation `busy` result with fixed resources. |
| B1-AUTH-V3-M3 missing total ranking | **Closed.** R005 defines a total stable order and the property/permutation/locale tests are explicit. |

## earlier finding regression check

| Earlier findings | Disposition in this gate |
|---|---|
| B1-AUTH-V2-H1 exclusive v1/v2 advertisement | **Closed.** Each generation requires its exclusive complete capability/token pair in both fresh surfaces; partial, dual, mixed, unknown, stale, and disagreement cases make no catalog-economics call. |
| B1-AUTH-V2-H2 coordinator no-event `not_offered` | **Closed.** Exact response-byte digest, candidate/source/state/guidance/time binding, nullable-event exception, and event-backed case remain distinct. |
| B1-AUTH-V2-H3 cleanup cancellation/recovery | **Closed.** Direct cancel has marker-only authority; operation-owning cleanup recovery implements reversible intent and durable `tombstoned` commit under continuous ordered custody. |
| B1-AUTH-V2-H4 root identity | **Closed.** Secret nonce, canonical path, device, inode, schema/version, and digest are bound and persisted in every reopening record with drift/copy/remount/reuse negatives. |
| B1-AUTH-V2-M1 catalog-only representation | **Closed.** All-null catalog-only and all-non-null candidate groups are both representable and mutually exclusive. |
| B1-AUTH-V2-M2 orphan cleanup correlation | **Closed.** Receipt-bound immutable `event_model_key` makes catalog-orphaned targets runnable and event-correlated. |
| B1-AUTH-V2-M3 refresh ordering | **Closed.** App-owned prelaunch generations reject older completions across restart/timeout without disturbing attached workers. |
| B1-AUTH-V2-M4 JSONL/backpressure | **Closed.** Partial-line, stdout, stderr, decoded queue, scheduled MainActor work, terminal reservation, and producer backpressure all have fixed caps. |
| B1-AUTH-V2-M5 ACL policy | **Closed.** Empty extended ACLs and descriptor mutation races have normative creation and rejection rules. |
| B1-AUTH-H1/H2 and M1-M13 from v1 | **Closed or prospectively gated as previously required.** Guidance correlation, verified-artifact eligibility, cleanup/accounting, budget and formatting, cancellation, error precedence, production-adapter coverage, legacy protection, adoption, and qualification evidence remain mapped to exact tests. B1-AUTH-V8-M1 is the only current gate blocker. |

No earlier Critical, High, or Medium finding was weakened or removed from the
acceptance corpus.

## Cross-cutting adversarial assessment

- **Feasibility and architecture:** the operator SPEC's lock graph is acyclic
  and implementable with fixed descriptors and bounded nonblocking retry. Root,
  transfer, publication, reversible cleanup, accounting, and independent
  adoption remain feasible at plan level. The ownership-table contradiction is
  the remaining plan integration defect.
- **Trust and economics:** candidate/source/digest/freshness correlation,
  current signed verified-primary-artifact gating, catalog-only isolation,
  preparation/admission separation, and conditional settlement copy remain fail
  closed. Preparation cannot mint identity, pricing, admission, settlement, or
  credit.
- **UX truthfulness:** local/coordinator `not_offered`, admission-only
  `local_only`, qualifying-settlement eligibility, silent negotiation fallback,
  typed contention retry, cancellation acknowledgements, and post-action refresh
  are explicit and avoid current-income or readiness overclaims.
- **Failure recovery and security:** descriptor-relative traversal,
  authenticated roots, ACL-empty creation, bounded temps, publish-once objects,
  copy-before-delete terminal history, and reversible cleanup are coherent in
  the authority. The plan table must assign the required pair custody to the
  same owners before implementation delegation.
- **Compatibility, migration, and rollback:** v1/v2 negotiation is fail closed;
  v3 state and configured legacy data remain isolated and preserved across
  rollback/re-upgrade; abandoned R21-R27 state is not imported.
- **Observability and privacy:** bounded redacted records, events, acknowledgments,
  refresh decisions, counters, recovery phases, and truncation metadata exclude
  credentials, feed bodies/URLs, prompts, completions, provider identity, and raw
  errors. Lock contention has exact non-secret typed outcomes.
- **Hardware, release, and economics qualification:** real MLX, APFS stable-media
  and abrupt-power behavior, incumbent continuity, signed discovery/admission,
  correctly settled positive credit, first-listed-tier evidence, final signing/
  notarization, app/tarball byte identity, and previous-stable updater proof are
  named future gates, not current passes.

## Current implementation boundary

The inspected implementation remains on the v1 catalog-economics surface:
`phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift` emits
`model_catalog_economics.v1`; `ModelsSubcommand.swift` exposes only the v1 read
form; `HTTPServer.swift` advertises v1 values; Malibu's
`ModelManagement.swift` advertises and decodes v1 and still uses
`localizedStandardCompare` as the final display-name tie-break. There is no
`failed_dispatch`, `failure.lock`, `dispatch_state_busy`, v3 preparation engine,
or v2 run/cancel implementation in the reviewed implementation tree. That is
expected at this pre-implementation plan gate and is not a finding. Existing v1
tests are supporting evidence only and do not satisfy future v2 acceptance.

## Pending implementation and qualification gates

After B1-AUTH-V8-M1 is corrected and a fresh exact-byte gate passes:

- the finalized owner authority must be a strict ancestor of the first slice 6B
  implementation commit;
- T01-T20 and the targeted/broad Swift, Xcode, distribution, Go, governance,
  secret-scan, and full-diff audit lanes must pass on the implementation;
- code, security, and architecture full-diff reviews must each reach zero
  Critical, High, and Medium;
- physical Apple Silicon/APFS must prove real preparation/adoption, incumbent
  continuity, custom-root and stable-media recovery behavior;
- final signed/notarized assets, app/tarball CLI byte identity, first-listed-tier
  evidence, and previous-stable updater behavior remain release gates; and
- accepted signed discovery/admission journeys plus an actual routed, receipted,
  correctly settled request and positive provider credit remain the Build 1
  product qualification gate.

No plan review, historical result, deterministic fixture, prepared artifact, or
provider assertion satisfies those pending gates.

## Fresh verification evidence

The following checks ran against the exact authority revision unless stated
otherwise:

```text
git fetch --prune origin
git rev-parse origin/main
=> f7e584499828b3d16036382848b5caa1a897cdf9

git rev-parse HEAD
=> d4f5eeb0dec4120811ac76afccdfc70a72e3483d

git merge-base HEAD f7e584499828b3d16036382848b5caa1a897cdf9
=> f7e584499828b3d16036382848b5caa1a897cdf9

git merge-base --is-ancestor 6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a HEAD
git merge-base --is-ancestor c4401f1791d593d37d68eba91af94219b26d278f HEAD
=> both exit 0

shasum -a 256 reservation-rebaseline-plan-v13.md \
  reservation-rebaseline-test-spec-v13.md
=> 88b2db5ebfd9c449bed355ebd9157d5dbabefba0dc0dc2c372e1fd6c9aa4defa
=> 035115c0627ee35a39f0960b4675d1fb18037c4e1730f1842bd0e72190cec5fc

shasum -a 256 preparation-authority-v7-sol.md
=> e1872075dc033046c46f6582c25f070537ba8e2d482a1e6ce1c36bfe7d2db858

git diff --check f7e584499828b3d16036382848b5caa1a897cdf9..HEAD
=> exit 0

python3 scripts/gen_spec_index.py --check
python3 scripts/gen_spec_index.py --lint
python3 scripts/check_spec_governance.py
=> all exit 0; 47 canonical specs; index current; governance passed

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_spec_governance \
  scripts.tests.test_spec_pr_declaration \
  scripts.tests.test_byom_contract_lock
=> Ran 76 tests in 86.634s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> 8 XCTest tests, 0 failures

cd phase4-coordinator && go test ./internal/ws -run \
  'TestModelAdmission(StatusForPreBYOMProviderReturnsNotOffered|OfferSubmitAndStatusStayNonEarning|StatusGuidanceForRejectedAndDemotion)$' -count=1
=> ok, 1.008s
```

Swift Testing separately reported zero selected Swift-Testing-framework tests
after the eight XCTest cases; that line is not counted as passing evidence. The
green checks validate governance structure, contract-lock strings, and current
v1 behavior. They do not implement or prove the planned v2 runtime.

## Gate result

**BLOCK: 0 Critical, 0 High, 1 Medium.** Correct the plan's failure-only and
direct-cancel ownership rows so they match the exact ordered pair already
required by SPEC-044, the exhaustive graph, and T03/T12/T14. Commit the revised
plan/test bytes, recompute their digests, and repeat the independent cumulative
gate. Slice 6B implementation must not begin from the reviewed corpus.
