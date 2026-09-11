# Build 1 preparation authority v7 independent adversarial review

**Gate result: BLOCK**

**Finding counts:** 0 Critical, 2 High, 1 Medium.

This review independently inspected the exact v12 plan and test specification,
the complete cumulative authority diff, current implementation and test
surfaces, and every prior formal finding named by the gate. The v12 corpus
closes the previous fallback, failed-dispatch identity, version, and two-copy
cleanup findings. Its new failed-dispatch lifecycle still has incompatible lock
oracles for recovery and cancellation, and it claims starvation freedom without
a constructive scheduling rule. Those defects must be resolved before the
authority can govern implementation.

## Reviewed immutable inputs

- Repository base: `origin/main` =
  `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Planning worktree revision:
  `04d8eeca49f300f3906e595cd3e302b8332a4051`.
- `reservation-rebaseline-plan-v12.md` SHA-256:
  `6957c36e6104f8d4d04c9d2f429a86207083ca7e4ff53302cb45b717691ed418`.
- `reservation-rebaseline-test-spec-v12.md` SHA-256:
  `68fd90bbbeb1bf21cae866c0155ffa5ffff4a08dcbfd617882abf4df737f23ed`.
- Authority worktree revision:
  `d12e9428df0f0bd26df720da7cd9b9fbbc820ec0`.
- Cumulative authority diff:
  `f7e584499828b3d16036382848b5caa1a897cdf9...d12e9428df0f0bd26df720da7cd9b9fbbc820ec0`.
- Prior formal review artifact:
  `docs/product-roadmap/build-1/reviews/preparation-authority-v6-sol.md`
  at `ebcf395670623ab9bf69dd1f6cffbb51d55be99c`, SHA-256
  `db9ccb076380e8bb8e1e77fcf307d0be12e9ef295c85b3aba0b47ceab2c63b60`.

`git fetch --prune origin` confirmed that `origin/main` remains the supplied
base. Both supplied worktrees were clean at initial inspection. The authority
revision has the stated base as merge base, and landed BYOM Slice 5
`6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` and Slice 6
`c4401f1791d593d37d68eba91af94219b26d278f` are ancestors. A filtered SwiftPM
test rewrote `phase3-binary/Package.resolved`; that generated change was
restored before this review artifact was written.

## Findings

### B1-AUTH-V7-H1 — High — The failed-dispatch recovery lock order contradicts the plan's exhaustive lock oracle

**Evidence.** The normative authority requires a normal or startup recovery
compactor to take `operation.lock` and then `failure.lock`
(`specs/SPEC-044-malibu-model-catalog-economics.md:568-574`). The v12 plan
repeats that requirement for failed-dispatch recovery
(`reservation-rebaseline-plan-v12.md:227-235`). The same plan later states that
all recovery mutation belongs to an operation-owning recovery worker, that
non-cleanup recovery takes `cancel.lock` next, and that the **only** nested
orders are `operation.lock -> cancel.lock` and
`operation.lock -> cleanup lock -> cancel.lock`
(`reservation-rebaseline-plan-v12.md:252`). T12 asks the implementation to
prove fixed lock orders while naming operation-before-failure as merely one of
several “applicable” orders, without reconciling the exhaustive two-order
statement (`reservation-rebaseline-test-spec-v12.md:280-282`).

The authority also requires ordinary terminal compaction to participate in two
partial orders: conflict-visible terminal compaction takes
`operation.lock -> failure.lock` (`SPEC-044:513-517`), while terminal commit,
marker sweep, and operation release take `operation.lock -> cancel.lock`
(`SPEC-044:650-670`). It never freezes whether a path touching both shared
histories takes failure-before-cancel, cancel-before-failure, releases one
before the other, or uses a generation protocol. T12 races terminal compaction,
failed-dispatch compaction, projection rewrite, cancellation, and recovery, but
does not supply the missing total order.

**Consequence.** One implementation cannot satisfy the plan's “only nested
orders” statement and the required startup-recovery
`operation.lock -> failure.lock` path. Independently chosen failure/cancel lock
orders can deadlock or expose different terminal/conflict views. The test suite
has no single normative lock trace to assert, so passing schedules would not
prove the claimed recovery and no-deadlock contract.

**Required correction.** Publish one exhaustive lock graph for projection
writers, pre-active workers, live workers, normal terminal compaction,
failed-dispatch creation/compaction, startup recovery, cancellation, adoption,
and both cleanup paths. State the exact acquisition, retention, and release
order whenever a path touches more than one lock. Remove the contradictory
“only” list or extend it consistently. Add lock-trace tests for every path and
all pairwise overlaps, including ordinary terminal compaction against
failed-dispatch recovery and cancel reads. No test may infer an unspecified
failure-versus-cancel order.

### B1-AUTH-V7-H2 — High — Cancellation reads shared terminal history outside the lock that mutates failed-dispatch history

**Evidence.** Pending failed-dispatch records and ordinary terminal history
share one 256-record/262,144-byte history budget, and failure workers create,
compact, and evict that state under `failure.lock` alone
(`specs/SPEC-044-malibu-model-catalog-economics.md:563-574`; plan v12:229-235).
The cancel process instead takes only `cancel.lock`, then validates active,
terminal-history, projected-transaction, and marker records
(`SPEC-044:626-648`). SPEC-044 claims concurrent terminal compaction cannot
change the cancel result because the worker holds `cancel.lock`
(`SPEC-044:650-654`), but a failure-only worker is expressly forbidden from
taking `cancel.lock` and may compact its terminal record under `failure.lock`
alone (`SPEC-044:533-535,568-574`).

The plan preserves the same split: a direct cancel reads durable
terminal/reservation/history evidence under `cancel.lock` only
(`reservation-rebaseline-plan-v12.md:243-250`), while failed-dispatch mutation
uses `failure.lock` only (plan v12:229-235). T03 requires a matching
failed-dispatch cancellation to return only `terminal` with its exact attempt
ID **without taking `failure.lock`**
(`reservation-rebaseline-test-spec-v12.md:93-110`). No immutable snapshot
generation, read-retry rule, or copy-before-delete ordering makes a multi-file
read linearizable across those two lock domains.

**Consequence.** Cancellation can observe a torn failed-dispatch
pending-to-history transition or eviction and classify an already committed
terminal attempt as `stale`, `not_active`, or malformed instead of the required
`terminal`. Atomic replacement of each individual file is insufficient when
the reader validates several files without the writer's lock. The authority's
claim that concurrent compaction cannot change the result is false for the new
failure-only path, and T03's exact terminal oracle is not implementable from
the specified synchronization.

**Required correction.** Choose one constructive serialization protocol for
all state used by the cancel predicate. Either include failed-dispatch terminal
creation/compaction/eviction in the cancel-visible lock order, let cancel obtain
a compatible bounded snapshot lock, or define and prove an immutable
generation/read-retry protocol that cannot observe a gap. Preserve the
two-second cancel bound and avoid a failure/cancel deadlock. Freeze durable
copy/rename/delete ordering and add injected reads between every pending,
history, eviction, and parent-barrier step. Prove a terminal failed-dispatch
that exists at the chosen linearization point always returns `terminal` with
the exact attempt ID and never creates a marker.

### B1-AUTH-V7-M1 — Medium — `failure.lock` has no fairness or acquisition bound capable of proving the no-starvation claim

**Evidence.** Every immutable-identity-valid invocation blocks while acquiring
`failure.lock`, and failed reporters hold it through semantic checks, history
compaction/eviction, atomic pending persistence, full sync, and readback before
stdout (`SPEC-044:500-560`). Each reporter later reacquires it for compaction
(`SPEC-044:557-574`). A successful dispatcher holds `operation.lock` while it
waits to reacquire `failure.lock` before creating `active.json`
(`SPEC-044:526-531`). The authority gives `cancel.lock` an exact two-second
deadline and resource bound, but supplies no acquisition bound, FIFO/priority
rule, waiter cap, admission rule, or retry outcome for `failure.lock`.

T02 launches 1,000 reporters and requires that neither the incumbent nor any
challenger starve (`reservation-rebaseline-test-spec-v12.md:85-91`); T14 again
claims that blocked stdout, conflict reporters, and the incumbent cannot starve
(`reservation-rebaseline-test-spec-v12.md:292-296`). A finite favorable
scheduler run cannot prove starvation freedom for continuous arrivals when the
contract defines no fairness mechanism. A successful dispatcher can retain
`operation.lock` while an unbounded succession of reporters repeatedly wins
`failure.lock`, extending conflict for every later invocation and delaying the
incumbent's terminal compaction.

**Consequence.** The implementation can pass bounded stress runs yet wedge a
valid dispatch or terminal transition under ordinary retry storms. This also
undermines the test claim that conflict reporting does not delay the incumbent
and makes the resource/availability behavior implementation-dependent.

**Required correction.** Freeze a bounded and testable `failure.lock`
admission policy: waiter/process cap, fair queue or explicit priority for the
operation owner, monotonic wait bound and typed fail-closed outcome, plus exact
resource cleanup. Ensure that policy composes with the final lock graph and
does not turn a failure-only reporter into a live attempt. Test sustained
arrivals, a pre-active operation owner, terminal compaction, crashes, timeout
boundaries, and recovery, using a deterministic scheduler/clock oracle rather
than treating 1,000 favorable completions as a proof of starvation freedom.

## v6 finding disposition

| v6 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V6-H1 malformed-advertisement fallback contradiction | **Closed.** SPEC-001, SPEC-044-R001/R008, plan v12, and T01/T14/T15/T18 now select silent static-card/no-warning/no-retry/no-call behavior for every negotiation-negative class and reserve exact `model catalog unavailable`/`projection_unavailable` plus retry for failure after a valid exclusive complete pair. |
| B1-AUTH-V6-H2 pre-worker terminal lifecycle | **Partially closed.** Immutable identity, fresh attempt, closed pending record, one sequence-1 terminal, exit 3, lock-free stdout, and crash intervals are constructive. B1-AUTH-V7-H1/H2 show that the lifecycle's recovery and cancel-visible shared-state locking is still internally inconsistent. |
| B1-AUTH-V6-M1 stale v0.2.4 references | **Closed.** Forward-current owner, implementation, evidence, CONFORMANCE, index, plan, test, handoff, and contract-lock references select SPEC-044 v0.2.6. Earlier versions occur only in explicit changelog/history or unrelated specs. |
| B1-AUTH-V6-M2 incomplete per-copy cleanup proof | **Closed.** Authority and T09.6 separately mutate both copies and add equal-two-copy digest/size mutations against an unchanged enclosing target, preserving JCS equality while proving independent target binding. |

No v6 finding was downgraded or discarded to reach a passing result.

## v5 finding disposition

| v5 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V5-H1 conflicting exact `local_only` copy | **Closed.** All current owner surfaces use the same admission-only sentence and require separate readiness/runtime evidence. |
| B1-AUTH-V5-M1 catalog-only section conflict | **Closed.** The exact unavailable sentinel is allowed only in R008 `Blocked`; the other four sections are distinct rejection cases. |
| B1-AUTH-V5-M2 false local-default offer history | **Closed.** Local-default unknown/unqueried state and coordinator authoritative no-active-offer readback have distinct exact source meanings with localization/accessibility negatives. |
| B1-AUTH-V5-M3 cleanup target proof | **Closed.** Enclosing, per-action-copy, equal-two-copy, every-field, and cross-target fixtures are now explicit. |

## v4 finding disposition

| v4 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V4-H1 incompatible ranking oracles | **Closed.** R005, plan, and tests use one complete locale-independent tuple with explicit null directions and final canonical identity. |
| B1-AUTH-V4-M1 incomplete catalog-only sentinel | **Closed.** Every null/false/source/state/economics/action field, placement, and cross-candidate negative remains frozen. |
| B1-AUTH-V4-M2 false `local_only` readiness copy | **Closed.** Copy is admission-only and positive readiness requires independent evidence. |
| B1-AUTH-V4-M3 impossible cleanup comparison | **Closed.** JCS compares the two nested action objects, while each digest/size binds independently to the enclosing target. |
| B1-AUTH-V4-M4 12-versus-13 state count | **Closed.** Authority, handoff, plan, test, and contract lock enumerate exactly 12. |

## v3 finding disposition

| v3 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V3-H1 cleanup continuous-lock contradiction | **Closed.** Cleanup worker/recovery retains `cancel.lock` from final marker check through rename, both parent barriers, durable `tombstoned`, and readback. |
| B1-AUTH-V3-H2 false `Earning now` verdict | **Closed.** Every owner surface uses exact conditional qualifying-settlement eligibility and prohibits current-income meaning. |
| B1-AUTH-V3-H3 catalog-only trusted economics | **Closed.** The catalog-only sentinel has null money/demand, unavailable economics, and no action. |
| B1-AUTH-V3-M1 contradictory ACL creation | **Closed.** New sensitive objects are already-open unpublished owner-only temps, ACL-cleared before sensitive bytes, then descriptor-revalidated. |
| B1-AUTH-V3-M2 unbounded cancel-lock wait | **Closed.** Cancel has the exact monotonic 2.000-second deadline and valid null-attempt/no-mutation `busy`. This does not close B1-AUTH-V7-M1 for the separate failure lock. |
| B1-AUTH-V3-M3 missing total ranking | **Closed.** The R005 tuple is complete and total. |

## Earlier finding regression check

| Earlier findings | Disposition in this gate |
|---|---|
| B1-AUTH-V2-H1 exclusive v1/v2 advertisement | **Closed.** Complete pair exclusivity, agreement, partial/dual/mixed/unknown/stale no-call cases, and negotiated-request failure presentation are exact. |
| B1-AUTH-V2-H2 coordinator no-event `not_offered` | **Closed.** The exact response digest, nullable-event exception, event-backed case, and source-aware meaning remain. |
| B1-AUTH-V2-H3 cleanup cancellation/recovery | **Closed.** Marker-only cancel authority, ordered cleanup recovery, reversible intent, and durable `tombstoned` commit remain. |
| B1-AUTH-V2-H4 root identity | **Closed.** Nonce/path/device/inode/version digest and saved lifecycle locators remain mandatory and fault-tested. |
| B1-AUTH-V2-M1 catalog-only representation | **Closed.** Exact all-null/no-action representation and section isolation remain. |
| B1-AUTH-V2-M2 orphan cleanup correlation | **Closed.** Receipt-bound immutable `event_model_key` and bounded target reachability remain. |
| B1-AUTH-V2-M3 refresh ordering | **Closed.** App-owned prelaunch generation and action-worker isolation remain. |
| B1-AUTH-V2-M4 JSONL/backpressure | **Closed.** Partial-line/stdout/stderr/queue/task/backpressure caps remain constant-space. |
| B1-AUTH-V2-M5 ACL policy | **Closed.** Empty extended-ACL enforcement and mutation races remain explicit. |
| B1-AUTH-H1/H2 and M1-M13 from v1 | **Closed or prospectively gated as previously recorded.** Guidance, verified-artifact eligibility, root/durability, budgets, error precedence, production-adapter coverage, legacy protection, cancellation, adoption, and qualification gates remain. The v7 findings concern the newly introduced failed-dispatch concurrency protocol. |

## Cross-cutting adversarial assessment

- **Feasibility and architecture:** the root, namespace, bounded transfer,
  publication, reversible cleanup, accounting, and adoption design remains
  feasible at plan level. The failed-dispatch feature lacks one executable
  global lock graph and cancel-visible state protocol.
- **Trust and economics:** signed candidate/source/digest/freshness binding,
  verified-primary-artifact gating, catalog-only isolation, conditional earning
  copy, and preparation-versus-admission/settlement separation remain fail
  closed. B1-AUTH-V7-H1 must ensure projection invalidation linearizes with
  dispatch rather than allowing an implementation-specific stale action window.
- **UX truthfulness:** negotiation fallback, local/coordinator `not_offered`,
  admission-only `local_only`, and qualifying-settlement copy are coherent.
  B1-AUTH-V7-H2 can still make a direct cancellation response falsely report a
  committed failed dispatch as nonterminal or malformed.
- **Failure recovery and security:** descriptor-relative traversal,
  authenticated roots, ACL clearing, bounded unique temps, cleanup locks, and
  reversible tombstones remain coherent. The new failed-dispatch history cannot
  yet be read and recovered under one noncontradictory synchronization contract.
- **Compatibility, migration, and rollback:** v1/v2 negotiation is fail closed;
  v3 state is isolated and preserved across rollback; abandoned R21-R27 state
  remains excluded. Current v0.2.6 version traceability is exact.
- **Observability and privacy:** bounded redacted event/ack/refresh/transport/
  transfer/recovery/inventory/accounting/deletion data remains specified. The
  new record excludes credentials, feed bodies, prompts, completions, and raw
  errors. A lock-contention outcome for `failure.lock` is not yet defined.
- **Hardware, release, and economics qualification:** real MLX, APFS
  stable-media/power recovery, incumbent continuity, signed discovery/admission,
  settlement and positive credit, listed-tier evidence, signing/notarization,
  app/tarball byte identity, and updater proof remain named future gates rather
  than passing claims.

## Current implementation boundary

The inspected implementation still serves v1 catalog economics:
`phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift` builds the
v1 envelope; `ModelsSubcommand.swift` exposes only the v1 read command; Malibu
advertises and decodes `model_catalog_economics_v1`; and
`ModelManagement.swift` still uses `localizedStandardCompare` as its final row
tie-break. No `failed_dispatch` or `failure.lock` implementation exists outside
the proposed authority/test corpus. This is expected at a plan gate and is not
a finding. Current v1 tests cannot be cited as v2 acceptance evidence.

## Pending implementation and qualification gates

After the findings above are corrected and a fresh plan gate passes:

- the finally approved owner authority must be a strict ancestor of the first
  6B implementation commit;
- every targeted and broad 6B/6C test plus the built CLI through the production
  Malibu adapter must pass over the complete implementation diff;
- independent code, security, and architecture audits of the full diff must
  each reach zero Critical, High, and Medium;
- physical Apple Silicon must prove actual MLX preparation/adoption, incumbent
  continuity, custom-root/APFS stable-media behavior, reboot, and abrupt-power
  recovery;
- final signed/notarized assets, app/tarball CLI byte identity,
  previous-stable updater behavior, and first-listed-tier evidence remain
  release gates; and
- accepted signed discovery/admission journeys plus an actual routed,
  receipted, correctly settled request and positive provider credit remain the
  Build 1 qualification gate.

No plan review, historical report, deterministic fixture, prepared artifact,
or provider assertion satisfies those pending gates.

## Fresh verification evidence

The following checks ran against the exact authority revision unless stated
otherwise:

```text
git fetch --prune origin
git rev-parse origin/main
=> f7e584499828b3d16036382848b5caa1a897cdf9

git rev-parse HEAD
=> d12e9428df0f0bd26df720da7cd9b9fbbc820ec0

git merge-base HEAD f7e584499828b3d16036382848b5caa1a897cdf9
=> f7e584499828b3d16036382848b5caa1a897cdf9

git merge-base --is-ancestor 6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a HEAD
git merge-base --is-ancestor c4401f1791d593d37d68eba91af94219b26d278f HEAD
=> both exit 0

shasum -a 256 reservation-rebaseline-plan-v12.md \
  reservation-rebaseline-test-spec-v12.md
=> 6957c36e6104f8d4d04c9d2f429a86207083ca7e4ff53302cb45b717691ed418
=> 68fd90bbbeb1bf21cae866c0155ffa5ffff4a08dcbfd617882abf4df737f23ed

shasum -a 256 preparation-authority-v6-sol.md
=> db9ccb076380e8bb8e1e77fcf307d0be12e9ef295c85b3aba0b47ceab2c63b60

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
=> Ran 75 tests in 85.807s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> 8 XCTest tests, 0 failures

cd phase4-coordinator && go test ./internal/ws -run \
  'TestModelAdmission(StatusForPreBYOMProviderReturnsNotOffered|OfferSubmitAndStatusStayNonEarning|StatusGuidanceForRejectedAndDemotion)$' -count=1
=> ok, 0.849s
```

Swift Testing separately reported zero selected Swift-Testing-framework tests
after the eight XCTest cases; that zero-test line is not counted as passing
evidence. The green checks validate current governance structure,
contract-lock strings, and v1 behavior. They do not resolve the contradictory
or missing v2 concurrency oracles above.

## Gate result

**BLOCK: 0 Critical, 2 High, 1 Medium.** Reconcile the exhaustive lock graph,
serialize cancel-visible failed-dispatch terminal state, and define a bounded
fairness policy for `failure.lock`. Commit revised authority/plan/test bytes,
recompute their exact digests, and repeat the independent cumulative gate.
Slice 6B implementation must not begin from the reviewed corpus.
