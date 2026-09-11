# Build 1 preparation authority v5 independent adversarial review

**Gate result: BLOCK**

**Finding counts:** 0 Critical, 1 High, 3 Medium.

This review independently inspected the exact v9 plan and test specification,
the complete cumulative authority diff, current implementation and test
surfaces, and the prior formal findings. The structural checks and current v1
tests are green. The reviewed corpus still gives an implementer incompatible
exact provider-copy and section-placement oracles, and its destructive-cleanup
test plan does not yet prove every binding required by the authority.

## Reviewed immutable inputs

- Repository base: `origin/main` =
  `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Planning worktree revision:
  `01a9908d9d7e0bd8ade698c27b14f069fe35eb38`.
- `reservation-rebaseline-plan-v9.md` SHA-256:
  `217db6fbabc76433004ee835cfb8846099d0855132cf141e2c91a3e051d8a90d`.
- `reservation-rebaseline-test-spec-v9.md` SHA-256, computed directly from
  the committed file:
  `245d1fd3652a5e445b525c2567517cc51e80b8e4437a91ce5e375784268d92c2`.
  The duplicated digest in the initial review prompt was transcription noise
  and was not used as authority.
- Authority worktree revision:
  `4196d6d9850632386130b6d658325632e4d80b38`.
- Cumulative authority diff:
  `f7e584499828b3d16036382848b5caa1a897cdf9...4196d6d9850632386130b6d658325632e4d80b38`.
- Prior formal review artifact:
  `docs/product-roadmap/build-1/reviews/preparation-authority-v4-sol.md`
  at `4164d0aad26c317ac7c6c1767ec2269d02bb9b43`, SHA-256
  `f16e4a6f87aa64a26dc8758735123128c8e2d8adcdb6e636671575944990d670`.

Both supplied worktrees were clean at initial inspection. The authority
revision has the stated base as merge base, and landed BYOM Slice 5
`6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` and Slice 6
`c4401f1791d593d37d68eba91af94219b26d278f` are ancestors. A filtered SwiftPM
test rewrote `phase3-binary/Package.resolved`; that generated change was
restored before this artifact was written.

## Findings

### B1-AUTH-V5-H1 — High — The plan/test and operator copy artifact require different exact `local_only` meanings

**Evidence.** The v9 plan says the corrected `local_only` meaning is exactly
**“Local inventory only; not offered to the network. Readiness and usability
are shown separately.”** and says the Slice 6 meanings remain exact inputs
except for that correction
(`reservation-rebaseline-plan-v9.md:33`). T01 and T16 require that same exact
sentence (`reservation-rebaseline-test-spec-v9.md:57,362`).

The reviewed operator-owned Slice 6 artifact instead says its strings are the
English source values and must not be reworded, and now defines the exact row
meaning as **“Retained as local inventory only; this admission state does not
claim the model is prepared, installed, ready, reachable, or usable.”**
(`audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md:35-42,69`).
The new contract-lock test pins that latter wording
(`scripts/tests/test_byom_contract_lock.py:39-48`). SPEC-001 and SPEC-046
normatively require admission-only semantics but do not select the v9 sentence
over the operator artifact's sentence
(`specs/SPEC-001-phase3-binary.md:3261-3265`;
`specs/SPEC-046-provider-byom-discovery.md:99`).

**Consequence.** One implementation cannot pass the exact v9 acceptance test
and ship the exact operator-owned source copy. Choosing either string violates
one reviewed oracle. Localization and accessibility fixtures would be generated
from an unresolved English source, so this is an implementation-blocking
contract conflict rather than a cosmetic difference.

**Required correction.** Select one exact English source string under the
operator-owned authority and make the Slice 6 artifact, SPEC references, v9
plan, T01, T16, and contract-lock test byte-for-byte consistent. Retain all
negative readiness semantics and the independently evidenced readiness/runtime
rule. Recompute the committed plan/test digests and repeat this gate.

### B1-AUTH-V5-M1 — Medium — T16 puts an unavailable catalog-only row in a section forbidden by R008

**Evidence.** SPEC-044-R008 requires a row whose economics are not `trusted` to
appear in `Needs preparation` only when local preparation is its sole blocker,
and otherwise in `Blocked` or an equivalent warning subsection; it must not be
placed in `Network catalog` from stale, fallback, blocked, or unavailable
economics (`specs/SPEC-044-malibu-model-catalog-economics.md:745`). A
catalog-only row has exact `economics_state: unavailable`, no candidate, and
every action unavailable (`:137-157`).

T16 nevertheless requires the same row to survive the production view
“only as a nontrusted Network catalog discovery row”
(`reservation-rebaseline-test-spec-v9.md:360`). `Network catalog` is a named,
capitalized R008 section and participates in the exact R005 section-rank tuple
(`reservation-rebaseline-plan-v9.md:57-68`; SPEC-044 `:693-725`).

**Consequence.** Following T16 places a nontrusted/no-action row in the wrong
section and changes the first component of the authoritative total order.
Following R008 fails the written T16 acceptance oracle. It also risks making an
unavailable sentinel look like current network catalog authority.

**Required correction.** Replace T16's section oracle with `Blocked` or the one
explicitly named equivalent warning subsection selected by R008. If product
intent is to create a separate non-economic discovery section, amend R008 and
the R005 section-rank tuple under owner authority before implementation. Add a
positive section assertion plus one-fault negatives that try `Network catalog`,
`Current`, `Ready`, and `Needs preparation` without the required evidence.

### B1-AUTH-V5-M2 — Medium — Exact `local_default:not_offered` copy asserts history the source cannot know

**Evidence.** SPEC-046 says `local_default:not_offered` means coordinator state
is unavailable or has not been queried, while `coordinator:not_offered` is
authoritative readback; callers must inspect the source
(`specs/SPEC-046-provider-byom-discovery.md:101-105`). Current CLI code follows
that distinction with source-specific guidance keys:
`byom.local.not_offered_coordinator_state_unavailable` for local default
(`phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4382-4397`) and
`byom.admission.not_offered` for coordinator output
(`phase4-coordinator/internal/ws/model_admission.go:2484-2513`).

The operator Slice 6 copy table defines only a `local_default` row and states
**“Discovered but never offered to the network.”**
(`SLICE6_STATE_SURFACE_AND_COPY.md:42`). The v9 plan preserves the handoff's
exact state meanings, drives both source variants through preparation, and
requires the bound state disclosure (`reservation-rebaseline-plan-v9.md:33,
47,53`). T16 exercises the two source variants and transition but does not
freeze truthful source-specific English meanings or reject the “never offered”
assertion (`reservation-rebaseline-test-spec-v9.md:358,362`).

**Consequence.** When coordinator state is unavailable, the UI can claim the
provider never offered a candidate even if a prior offer exists. The exact
operator table also leaves coordinator-backed `not_offered` without a distinct
source row while the plan requires both sources. This breaks truthful readiness
and admission presentation on the supported transition path.

**Required correction.** Define exact source-aware meanings for both
`local_default:not_offered` and `coordinator:not_offered`. The local-default
copy must state that coordinator state is unavailable/not yet queried and must
not assert offer history. The coordinator copy may state that authoritative
readback reports no active offer. Update the operator artifact, plan, T16,
localizations/accessibility fixtures, and negative semantic assertions.

### B1-AUTH-V5-M3 — Medium — T09.6 omits the enclosing-target and cross-target one-fault cleanup proofs

**Evidence.** The corrected authority requires JCS equality between
`row.cleanup_published` and `cleanup_targets[i].cleanup`, then independently
requires both action digests and sizes to equal the enclosing target. Its
release tests explicitly require one-fault changes to the **enclosing or
action** digest, **enclosing or action** size, every other action field, and an
otherwise-valid action attached to a different target
(`specs/SPEC-044-malibu-model-catalog-economics.md:277-289,833-839`).

T09.6 positively asserts nested-action equality and enclosing digest/size
binding, but its enumerated one-fault set changes only the nested action digest,
estimated bytes, transaction fields, availability/nullability/reason/other
action fields, or canonical action bytes. It does not independently mutate the
enclosing target digest, enclosing target size, or attach an otherwise-valid
action to a different target
(`reservation-rebaseline-test-spec-v9.md:206-208`). Generic statements in T01
and T18 require the binding but do not supply those missing proving negatives.

**Consequence.** An implementation can pass the specified destructive-action
negative suite while comparing two identical nested actions and failing to
bind them to the enclosing deletion target. A target-record substitution or
wrong-target attachment can therefore escape the acceptance proof even though
the authority forbids it.

**Required correction.** Extend T09.6 with distinct one-fault fixtures for the
enclosing target digest, enclosing target estimated bytes, each action-side
digest/size, and a valid action moved to another target. Each must fail before
confirmation, reservation, rename, or deletion, with outside/protected/legacy
sentinels unchanged. Preserve RFC 8785 action-to-nested-action comparison; do
not compare an action to the enclosing target object.

## v4 finding disposition

| v4 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V4-H1 incompatible ranking oracles | **Closed.** SPEC-044-R005, the v9 plan, and T01/T15/T16 use the same sole tuple, exact directions/null order, nontrusted field applicability, tagged canonical identity, and duplicate-canonical-identity predicate. Current localized display-name sorting remains explicitly pending implementation. |
| B1-AUTH-V4-M1 incomplete catalog-only sentinel proof | **Closed for the sentinel.** Authority and T01/T16 now require every exact null/false/source/state/economics/action field and reject one-fault deviations. B1-AUTH-V5-M1 is a separate section-placement contradiction after the row validates. |
| B1-AUTH-V4-M2 false `local_only` readiness copy | **Not closed in the combined corpus; escalated to B1-AUTH-V5-H1.** Both proposed strings are admission-only, but exact source-copy authority conflicts with the exact v9 test oracle. |
| B1-AUTH-V4-M3 impossible cleanup byte comparison | **Partially corrected; remains blocked as B1-AUTH-V5-M3.** Action-to-nested-action RFC 8785 comparison and enclosing binding are now coherent, but T09.6 omits required enclosing/cross-target negative proofs. |
| B1-AUTH-V4-M4 12-versus-13 state count | **Closed.** SPEC-001, SPEC-046, the handoff, plan, contract lock, and T01/T16 consistently enumerate 12 and reject a thirteenth. |

No v4 finding was downgraded or discarded to reach a passing result.

## v3 finding disposition

| v3 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V3-H1 cleanup continuous-lock contradiction | **Closed.** Worker/recovery retains `cancel.lock` from the final marker check through rename, both parent barriers, durable `tombstoned`, and readback; only cancellation-first versus recovery-first after crash remains constructible. |
| B1-AUTH-V3-H2 false `Earning now` verdict | **Closed.** SPEC-001/044/046/047, handoff, plan, and tests retain the conditional **Eligible to earn on qualifying settled requests** verdict and forbid current-income meaning. |
| B1-AUTH-V3-H3 catalog-only trusted economics | **Closed.** The exact catalog sentinel has unavailable economics, no rate/demand/candidate authority, and no action. |
| B1-AUTH-V3-M1 contradictory ACL creation | **Closed.** The already-open unpublished owner-only temp is ACL-cleared and verified before its first sensitive byte, then descriptor-revalidated. |
| B1-AUTH-V3-M2 unbounded cancel-lock wait | **Closed.** The separate monotonic 2.000-second deadline leads to exact null-attempt/no-mutation/exit-0 `busy` with fixed resources. |
| B1-AUTH-V3-M3 missing total ranking | **Closed.** The v9 and R005 tuple is complete and total. |

## Earlier finding regression check

| Earlier findings | Disposition in this gate |
|---|---|
| B1-AUTH-V2-H1 exclusive v1/v2 advertisement | **Closed.** Exclusive complete cross-surface pairs and no-call partial/dual/mixed/disagreement cases remain in authority and T01/T15. |
| B1-AUTH-V2-H2 coordinator no-event `not_offered` | **Closed for wire binding.** The exact response digest and nullable-event exception remain. B1-AUTH-V5-M2 concerns the source-aware provider meaning, not event authority. |
| B1-AUTH-V2-H3 cleanup cancellation/recovery | **Closed.** Marker-only cancel authority, ordered worker/recovery locks, reversible intent, and durable `tombstoned` commit remain. |
| B1-AUTH-V2-H4 root identity | **Closed.** Nonce/path/device/inode/version digest and saved lifecycle locators remain mandatory and fault-tested. |
| B1-AUTH-V2-M1 catalog-only representation | **Closed.** Exact all-null/no-action representation remains. |
| B1-AUTH-V2-M2 orphan cleanup correlation | **Closed.** Immutable receipt-bound `event_model_key` and bounded target reachability remain. |
| B1-AUTH-V2-M3 refresh ordering | **Closed.** App-owned prelaunch generation and action-worker isolation remain. |
| B1-AUTH-V2-M4 JSONL/backpressure | **Closed.** Partial-line/stdout/stderr/queue/task/backpressure caps remain constant-space. |
| B1-AUTH-V2-M5 ACL policy | **Closed.** Empty extended-ACL enforcement and mutation races remain explicit. |
| B1-AUTH-H1/H2 and M1-M13 from v1 | **Closed or prospectively gated as previously recorded.** Guidance/version selection, verified artifact, bounded selection/transfer, root/durability, budgets, error precedence, built-boundary, legacy protection, cancellation, adoption, and qualification gates remain. The new findings above do not weaken those prior corrections. |

## Cross-cutting adversarial assessment

- **Feasibility and architecture:** the same-EUID private v3 namespace,
  initiating-process worker, bounded reservation/history, transfer, publish,
  cancellation, recovery, inventory, cleanup, and adoption handoff remain
  implementable at plan level. H1 and M1 currently prevent one implementation
  from satisfying the combined exact UI oracles.
- **Trust and economics:** candidate/source/digest/freshness binding,
  verified-primary-artifact gating, catalog-only trust isolation, and strict
  preparation-versus-admission/settlement separation remain fail closed. No
  provider assertion, prepared artifact, model name, or signature alone grants
  paid admission or pricing.
- **UX truthfulness:** conditional settlement eligibility and admission-only
  `local_only` semantics are sound in intent. H1 leaves the actual source string
  unresolved; M2 still allows a false offer-history statement; M1 places an
  unavailable row under an incompatible section oracle.
- **Failure recovery and security:** descriptor-relative traversal, root
  authentication, ACL clearing, bounded unique-temp recovery, continuous cancel
  locking, reversible intent/tombstone recovery, keep sets, and legacy exclusion
  are coherent at plan level. M3 must complete proof of destructive target
  binding.
- **Compatibility, migration, and rollback:** v1/v2 negotiation remains
  fail closed; v3 state is isolated and preserved across rollback; no legacy or
  abandoned R21-R27 state is imported.
- **Observability and privacy:** bounded redacted event/ack/refresh/transport/
  transfer/recovery/inventory/accounting/deletion codes and counters remain
  specified. Paths, credentials, feed bodies, prompts, completions, and raw
  errors remain excluded.
- **Hardware, release, and economics qualification:** the documents correctly
  leave real MLX, APFS stable-media/power recovery, incumbent continuity, signed
  discovery/admission, settlement and positive credit, listed-tier evidence,
  signing/notarization, app/tarball byte identity, and updater proof pending.
  Current unit and deterministic-fixture passes are not those results.

## Current implementation boundary

The inspected implementation still serves v1 catalog economics:
`ModelsSubcommand.swift` describes and emits `model_catalog_economics.v1`,
`ModelCatalogEconomics.swift` constructs the v1 wire object, Malibu decodes v1,
and its existing final row tie-break remains
`displayID.localizedStandardCompare` (`ModelManagement.swift:2897`). The
future v2 preparation/storage/cleanup implementation and its named test targets
do not exist at this reviewed revision. That is expected at this plan gate and
is not itself a finding; it prevents current v1 tests from being cited as v2
acceptance evidence.

## Pending implementation and qualification gates

After the findings are corrected and a fresh plan gate passes:

- the finally approved owner authority must land and be a strict ancestor of
  the first 6B implementation commit;
- every targeted and broad 6B/6C test plus the built CLI through production
  Malibu adapter must pass on the complete implementation diff;
- independent code, security, and architecture full-diff audits must each
  reach zero Critical, High, and Medium;
- physical Apple Silicon must prove actual MLX preparation/adoption, incumbent
  continuity, custom-root/APFS stable-media behavior, reboot, and abrupt-power
  recovery;
- final signed/notarized assets, app/tarball CLI byte identity, previous-stable
  updater behavior, and first-listed-tier evidence remain release gates; and
- accepted signed discovery/admission journeys plus an actual routed,
  receipted, correctly settled request and positive provider credit remain the
  Build 1 qualification gate.

No plan review, historical report, deterministic fixture, prepared artifact,
or provider assertion satisfies those pending gates.

## Fresh verification evidence

The following checks ran against the exact authority revision unless stated
otherwise:

```text
git rev-parse HEAD
=> 4196d6d9850632386130b6d658325632e4d80b38

git rev-parse origin/main
git merge-base HEAD origin/main
=> f7e584499828b3d16036382848b5caa1a897cdf9 (both)

git merge-base --is-ancestor 6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a HEAD
git merge-base --is-ancestor c4401f1791d593d37d68eba91af94219b26d278f HEAD
=> both exit 0

shasum -a 256 reservation-rebaseline-plan-v9.md \
  reservation-rebaseline-test-spec-v9.md
=> 217db6fbabc76433004ee835cfb8846099d0855132cf141e2c91a3e051d8a90d
=> 245d1fd3652a5e445b525c2567517cc51e80b8e4437a91ce5e375784268d92c2

git diff --check f7e584499828b3d16036382848b5caa1a897cdf9..HEAD
=> exit 0

python3 scripts/gen_spec_index.py --check
python3 scripts/gen_spec_index.py --lint
python3 scripts/check_spec_governance.py
=> all exit 0; 47 canonical specs; index current

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_spec_governance \
  scripts.tests.test_spec_pr_declaration \
  scripts.tests.test_byom_contract_lock
=> Ran 71 tests in 85.226s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> 8 XCTest tests, 0 failures

cd phase4-coordinator && go test ./internal/ws -run \
  'TestModelAdmission(StatusForPreBYOMProviderReturnsNotOffered|OfferSubmitAndStatusStayNonEarning|StatusGuidanceForRejectedAndDemotion)$' -count=1
=> ok, 1.221s
```

Swift Testing separately reported zero selected Swift-Testing-framework tests
after the eight XCTest cases; that zero-test line is not counted as passing
evidence.

## Gate result

**BLOCK: 0 Critical, 1 High, 3 Medium.** Reconcile the exact `local_only`
source copy, fix catalog-only section placement, define truthful source-aware
`not_offered` meanings, and add the missing enclosing/cross-target cleanup
negatives. Commit revised authority/plan/test bytes, recompute their exact
digests, and repeat the independent cumulative gate. Slice 6B implementation
must not begin from the reviewed corpus.
