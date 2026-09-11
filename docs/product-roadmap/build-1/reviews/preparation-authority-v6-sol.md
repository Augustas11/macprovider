# Build 1 preparation authority v6 independent adversarial review

**Gate result: BLOCK**

**Finding counts:** 0 Critical, 2 High, 2 Medium.

This review independently inspected the exact v10 plan and test specification,
the complete cumulative authority diff, current implementation and test
surfaces, and every prior formal finding named by the gate. The authority's
new provider-copy corrections are sound and the structural checks plus current
v1 tests are green. The reviewed corpus still contains two incompatible public
behavior oracles, a stale normative version reference, and an incomplete
destructive-action acceptance proof. None can be deferred to implementation.

## Reviewed immutable inputs

- Repository base: `origin/main` =
  `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Planning worktree revision:
  `250d8619b1a4c117e3584a5aebbb19379299fbac`.
- `reservation-rebaseline-plan-v10.md` SHA-256:
  `da3841ac6fe153f0809cf5325102ce49e2e0475c6ffe2150a4d2fa34e1ad01e3`.
- `reservation-rebaseline-test-spec-v10.md` SHA-256, computed directly from
  the committed file:
  `c783b21171292c228d0a0f6048eb16bfb2240a9608fe7491dc19916aaa2f95fd`.
  The task prompt supplied a 63-character transcription missing one `a`; the
  review lead confirmed the directly computed 64-character digest before this
  review continued.
- Authority worktree revision:
  `a73d6020d34acacc3cd32399d93306b02bddedba`.
- Cumulative authority diff:
  `f7e584499828b3d16036382848b5caa1a897cdf9...a73d6020d34acacc3cd32399d93306b02bddedba`.
- Prior formal review artifact:
  `docs/product-roadmap/build-1/reviews/preparation-authority-v5-sol.md`
  at `02faf9a2bc47189e83894826183a12a76719a45d`, SHA-256
  `7566693203c38f8684268c9b3665384cfce5639f90cf6a1ec8582f52e86659dd`.

Both supplied worktrees were clean at initial inspection. The authority
revision has the stated base as merge base, is authored by the named operator,
and landed BYOM Slice 5 `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a`
and Slice 6 `c4401f1791d593d37d68eba91af94219b26d278f` are ancestors.
A filtered SwiftPM test rewrote `phase3-binary/Package.resolved`; that generated
change was restored before this artifact was written.

## Findings

### B1-AUTH-V6-H1 — High — Malformed capability advertisements have incompatible fallback-warning oracles

**Evidence.** The v10 compatibility matrix requires capability-only,
token-only, dual-generation, mixed/conflicting/unknown values, and
manifest/status disagreement to use the existing fallback with an approved
unavailable warning (`reservation-rebaseline-plan-v10.md:73-86`). T15 likewise
requires `unavailable-warning fallback` for capability-only, token-only,
unknown/mixed/contradictory advertisements and for partial, dual, stale, or
generation-disagreeing surfaces
(`reservation-rebaseline-test-spec-v10.md:315-325`).

SPEC-044-R001 does require all those malformed advertisements to take the
no-call legacy fallback (`specs/SPEC-044-malibu-model-catalog-economics.md:94`).
R008 then states that when neither complete pair exists, including a partial or
dual-generation advertisement, Malibu uses the static current-model card with
**no error indicator**. It reserves the distinct `model catalog unavailable`
warning and retry affordance for a negotiated complete pair whose request
fails, times out, or returns a malformed envelope
(`specs/SPEC-044-malibu-model-catalog-economics.md:749`). The v10 plan/test's
unavailable warning is an indicator of unavailability in exactly the cases for
which the normative owner requires none.

**Consequence.** One Malibu implementation cannot pass the exact v10 warning
assertions and conform to R008's silent malformed-advertisement fallback.
Choosing the warning misrepresents capability negotiation as a catalog request
failure; omitting it fails the written acceptance oracle. The conflict also
prevents reliable localization, accessibility, and production-adapter fixtures.

**Required correction.** Select the exact operator-owned visible behavior for
each class and make SPEC-001, SPEC-044-R001/R008, the plan, and T15 byte-for-byte
consistent. Preserve separate cases for no supported capability, malformed or
stale advertisement, manifest/status disagreement, and a successfully
negotiated request that later fails. Freeze the exact warning code/copy/retry
behavior, including whether each malformed class is silent, then test every
class independently without permitting a read or mutation.

### B1-AUTH-V6-H2 — High — Exit-3 pre-worker failures cannot satisfy the required terminal-event contract

**Evidence.** SPEC-001-R003 assigns exit `3` when the referenced action is stale,
unavailable, or conflicts **before the worker starts**
(`specs/SPEC-001-phase3-binary.md:3346-3353`). SPEC-044 says only the attached
worker emits events and requires every event to match the durable reservation's
immutable non-null `event_model_key`
(`specs/SPEC-044-malibu-model-catalog-economics.md:457-474`).

T14 nevertheless requires `stale_transaction` and `operation_conflict` to emit
terminal `failed` with exit `3`, while also requiring respectively `no worker
state` and `no second worker` (`reservation-rebaseline-test-spec-v10.md:281-302`).
T14 explicitly says the corrected authority must reconcile pre-worker
event/exit ambiguity, but the candidate authority retains the ambiguity. It
does not define a durable failure reservation, the point at which the run
process becomes the attached worker, or a legal event-model-key source when
failure precedes worker state.

**Consequence.** A conforming implementation either emits the required failed
event without the durable identity authority that every event must bind, or
returns exit `3` without the terminal event required by T14. This affects stale
dispatch and concurrency recovery at the shipping process boundary, so the app
cannot have one exact reducer oracle for a valid run invocation.

**Required correction.** Define one constructive lifecycle for every
syntactically valid `--run`: the exact point the initiating process becomes the
attached worker, which minimal durable reservation/failure record exists before
any event, how its immutable `event_model_key` is obtained from the validated
projected action, and how stale/unavailable/conflict failures emit exactly one
terminal `failed` event before exit `3`. Reword the side-effect boundary to
forbid a live/second attempt, network, staging, or model mutation while allowing
only the specified minimal failure record. Align SPEC-001, SPEC-044, T01, T02,
T14, crash recovery, terminal compaction, and production-adapter tests. Do not
allow an unbound event or an invocation with no deterministic terminal result.

### B1-AUTH-V6-M1 — Medium — Current normative references still select superseded SPEC-044 v0.2.4

**Evidence.** The candidate SPEC-044 header and embedded metadata declare
version `0.2.5` (`specs/SPEC-044-malibu-model-catalog-economics.md:1-10`), whose
operator correction supplies provider copy needed by v10. SPEC-001-R003 still
says SPEC-044 **v0.2.4** owns the projection, event, cancellation, preparation,
action, and storage contracts (`specs/SPEC-001-phase3-binary.md:3383-3386`).
SPEC-044's current open-gap row directs implementation of the approved v0.2.4
authority and its evidence section says current implementation predates the
v0.2.4 Build 1 authority (`specs/SPEC-044-malibu-model-catalog-economics.md:
1011-1022`). T18 requires SPEC versions, indexes, ownership/copy, and source
digests to agree (`reservation-rebaseline-test-spec-v10.md:372-381`).

**Consequence.** An implementer or governance check can cite the superseded
v0.2.4 contract and omit the v0.2.5 provider-copy corrections while appearing
to follow the current normative cross-reference. That defeats the version
traceability T18 is meant to prove.

**Required correction.** Update all forward-current ownership, implementation,
and evidence references to SPEC-044 v0.2.5 and add a contract-lock assertion for
the cross-spec version. Retain v0.2.4 only where it is explicitly historical,
such as its changelog entry. Regenerate/check indexes and rerun governance and
the exact-digest gate.

### B1-AUTH-V6-M2 — Medium — T09.6 does not independently prove both cleanup action copies bind to the enclosing target

**Evidence.** The candidate authority requires the two nested action objects to
be JCS-byte-identical and separately requires **each** action digest and size to
equal the enclosing target. Its release-test oracle explicitly requires
one-field mutations of row-side digest/size, target-side digest/size, and every
other field in **each nested action copy**
(`specs/SPEC-044-malibu-model-catalog-economics.md:281-291,851-865`).

T09.6 now covers enclosing digest/size changes and cross-target movement, which
closes much of v5 M3, but it still enumerates only singular `the nested action`
digest, size, canonical bytes, and every other field
(`reservation-rebaseline-test-spec-v10.md:206-208`). It does not say which of
`row.cleanup_published` or `cleanup_targets[i].cleanup` is changed, nor require
a fixture that changes both copies identically while leaving the enclosing
target unchanged. A decoder that checks JCS equality and validates only one
copy against the target can reject every singular mismatch without proving the
authority's independent two-copy binding.

**Consequence.** The acceptance suite can pass an implementation whose
destructive cleanup authority is bound through only one projection copy. A
future refactor or dispatch path that consumes the unchecked copy could accept
a target digest or byte count not authorized by its enclosing cleanup target.

**Required correction.** Expand T09.6 to name and mutate
`row.cleanup_published` and `cleanup_targets[i].cleanup` separately for digest,
size, transaction kind, transaction ID, and every remaining closed action
field. Add equal two-copy digest and size mutations that preserve JCS equality
but disagree with the enclosing target, so the independent enclosing binding is
the only rejection reason. Preserve the existing enclosing-target,
cross-target, pre-confirmation/no-mutation, protected, outside-root, and legacy
sentinels.

## v5 finding disposition

| v5 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V5-H1 conflicting exact `local_only` copy | **Closed.** Plan v10, T01/T16, SPEC-001, SPEC-044, SPEC-046, the Slice 6 handoff, and the contract lock use the same admission-only sentence and retain independent readiness/runtime proof. |
| B1-AUTH-V5-M1 catalog-only section conflict | **Closed.** The exact sentinel is admitted only in R008 `Blocked`; v10 positively asserts that placement and rejects `Network catalog`, `Current`, `Ready`, and `Needs preparation` one field at a time. |
| B1-AUTH-V5-M2 false local-default offer history | **Closed.** The corpus now distinguishes exact local-default unknown/unqueried state from exact coordinator no-active-offer readback, rejects `never offered`, and covers source swaps/localization/accessibility. |
| B1-AUTH-V5-M3 cleanup target proof | **Partially closed; remains B1-AUTH-V6-M2.** Enclosing digest/size and cross-target cases were added, but the v10 test does not independently prove both nested copies' target bindings as required by the candidate authority. |

No v5 finding was downgraded or discarded to reach a passing result.

## v4 finding disposition

| v4 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V4-H1 incompatible ranking oracles | **Closed.** R005, plan v10, and T01/T15/T16 use the same sole tuple, directions, null order, nontrusted applicability, tagged canonical identity, and duplicate predicate. Current localized display-name sorting remains explicitly pending implementation. |
| B1-AUTH-V4-M1 incomplete catalog-only sentinel | **Closed.** Authority and tests freeze every null/false/source/state/economics/action field, cross-candidate isolation, and forbidden placements. |
| B1-AUTH-V4-M2 false `local_only` readiness copy | **Closed.** The exact source copy is admission-only and every provider surface requires independent readiness/runtime evidence. |
| B1-AUTH-V4-M3 impossible cleanup byte comparison | **Partially closed; remains B1-AUTH-V6-M2.** Action-to-action JCS comparison and enclosing binding are coherent; the test proof is still incomplete per copy. |
| B1-AUTH-V4-M4 12-versus-13 state count | **Closed.** Authority, handoff, plan, test, and contract lock enumerate exactly 12 and reject a thirteenth. |

## v3 finding disposition

| v3 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V3-H1 cleanup continuous-lock contradiction | **Closed.** Worker/recovery retains `cancel.lock` from the final marker check through rename, both parent barriers, durable `tombstoned`, and readback; only cancellation-first versus recovery-first after crash remains constructible. |
| B1-AUTH-V3-H2 false `Earning now` verdict | **Closed.** All owner surfaces retain **Eligible to earn on qualifying settled requests** and prohibit a current-income meaning. |
| B1-AUTH-V3-H3 catalog-only trusted economics | **Closed.** The exact catalog sentinel has unavailable economics, no rate/demand/candidate authority, and no action. |
| B1-AUTH-V3-M1 contradictory ACL creation | **Closed.** The already-open unpublished owner-only temp is ACL-cleared and verified before its first sensitive byte, then descriptor-revalidated. |
| B1-AUTH-V3-M2 unbounded cancel-lock wait | **Closed.** A separate monotonic 2.000-second deadline yields exact null-attempt/no-mutation/exit-0 `busy` with fixed resources. |
| B1-AUTH-V3-M3 missing total ranking | **Closed.** The R005 tuple is complete and total. |

## Earlier finding regression check

| Earlier findings | Disposition in this gate |
|---|---|
| B1-AUTH-V2-H1 exclusive v1/v2 advertisement | **Closed for exclusive negotiation and no-call behavior.** Complete pair exclusivity and partial/dual/mixed/disagreement no-call cases remain. B1-AUTH-V6-H1 is a new contradiction about the visible fallback warning. |
| B1-AUTH-V2-H2 coordinator no-event `not_offered` | **Closed.** Exact response digest, nullable-event exception, event-backed case, and source-aware provider meaning remain. |
| B1-AUTH-V2-H3 cleanup cancellation/recovery | **Closed.** Marker-only cancel authority, ordered locks, reversible intent, and durable `tombstoned` commit remain. |
| B1-AUTH-V2-H4 root identity | **Closed.** Nonce/path/device/inode/version digest and saved lifecycle locators remain mandatory and fault-tested. |
| B1-AUTH-V2-M1 catalog-only representation | **Closed.** Exact all-null/no-action representation and section isolation remain. |
| B1-AUTH-V2-M2 orphan cleanup correlation | **Closed.** Immutable receipt-bound `event_model_key` and bounded target reachability remain. |
| B1-AUTH-V2-M3 refresh ordering | **Closed.** App-owned prelaunch generation and action-worker isolation remain. |
| B1-AUTH-V2-M4 JSONL/backpressure | **Closed.** Partial-line/stdout/stderr/queue/task/backpressure caps remain constant-space. |
| B1-AUTH-V2-M5 ACL policy | **Closed.** Empty extended-ACL enforcement and mutation races remain explicit. |
| B1-AUTH-H1/H2 and M1-M13 from v1 | **Closed or prospectively gated as previously recorded.** Guidance/version selection, verified artifacts, bounded selection/transfer, root/durability, budgets, error precedence, built boundary, legacy protection, cancellation, adoption, and qualification gates remain. H2 exposes a newly detected lifecycle inconsistency inside the corrected event/exit authority; it does not reopen unrelated v1 controls. |

## Cross-cutting adversarial assessment

- **Feasibility and architecture:** the same-EUID v3 namespace, initiating
  process, bounded reservation/history, transfer, publish, cancellation,
  recovery, inventory, cleanup, and adoption handoff remain feasible at plan
  level. H2 blocks a deterministic run lifecycle before worker start.
- **Trust and economics:** candidate/source/digest/freshness binding,
  verified-primary-artifact gating, catalog-only trust isolation, and strict
  preparation-versus-admission/settlement separation remain fail closed. No
  provider assertion, prepared artifact, model name, or signature alone grants
  paid admission or pricing.
- **UX truthfulness:** conditional settlement eligibility, source-aware
  `not_offered`, and admission-only `local_only` semantics are now coherent.
  H1 still makes the compatibility fallback's visible warning untruthful or
  nonconformant under one of the reviewed oracles.
- **Failure recovery and security:** descriptor-relative traversal, root
  authentication, ACL clearing, bounded unique-temp recovery, continuous
  cancel locking, reversible tombstone recovery, keep sets, and legacy
  exclusion remain coherent. M2 must complete the destructive target proof.
- **Compatibility, migration, and rollback:** v1/v2 negotiation is fail closed;
  v3 state is isolated and preserved across rollback; abandoned R21-R27 state
  is not imported. H1 and M1 must be resolved before this compatibility claim
  has one current, traceable acceptance contract.
- **Observability and privacy:** bounded redacted event/ack/refresh/transport/
  transfer/recovery/inventory/accounting/deletion codes and counters remain
  specified. Paths, credentials, feed bodies, prompts, completions, and raw
  errors remain excluded. H2 currently prevents one exact observable result for
  pre-worker failures.
- **Hardware, release, and economics qualification:** the documents correctly
  leave real MLX, APFS stable-media/power recovery, incumbent continuity,
  signed discovery/admission, settlement and positive credit, listed-tier
  evidence, signing/notarization, app/tarball byte identity, and updater proof
  pending. Those are named future gates, not findings in this plan review.

## Current implementation boundary

The inspected implementation still serves v1 catalog economics:
`ModelCatalogEconomics.swift:246` constructs
`model_catalog_economics.v1`; `ModelsSubcommand.swift:405` documents that
schema; Malibu advertises `model_catalog_economics_v1` and strictly decodes v1
at `ModelManagement.swift:30,548`; and the final row tie-break still uses
`displayID.localizedStandardCompare` at `ModelManagement.swift:2897`. The v2
preparation/storage/cleanup implementation and named future test targets do not
exist at the reviewed revision. That is expected at this plan gate and is not a
finding; current v1 tests cannot be cited as v2 acceptance evidence.

## Pending implementation and qualification gates

After these findings are corrected and a fresh plan gate passes:

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
git rev-parse HEAD
=> a73d6020d34acacc3cd32399d93306b02bddedba

git merge-base HEAD f7e584499828b3d16036382848b5caa1a897cdf9
=> f7e584499828b3d16036382848b5caa1a897cdf9

git merge-base --is-ancestor 6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a HEAD
git merge-base --is-ancestor c4401f1791d593d37d68eba91af94219b26d278f HEAD
=> both exit 0

shasum -a 256 reservation-rebaseline-plan-v10.md \
  reservation-rebaseline-test-spec-v10.md
=> da3841ac6fe153f0809cf5325102ce49e2e0475c6ffe2150a4d2fa34e1ad01e3
=> c783b21171292c228d0a0f6048eb16bfb2240a9608fe7491dc19916aaa2f95fd

shasum -a 256 preparation-authority-v5-sol.md
=> 7566693203c38f8684268c9b3665384cfce5639f90cf6a1ec8582f52e86659dd

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
=> Ran 72 tests in 87.648s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> 8 XCTest tests, 0 failures

cd phase4-coordinator && go test ./internal/ws -run \
  'TestModelAdmission(StatusForPreBYOMProviderReturnsNotOffered|OfferSubmitAndStatusStayNonEarning|StatusGuidanceForRejectedAndDemotion)$' -count=1
=> ok, 1.194s
```

Swift Testing separately reported zero selected Swift-Testing-framework tests
after the eight XCTest cases; that zero-test line is not counted as passing
evidence. The green checks validate current governance structure, contract-lock
assertions, and v1 behavior; they do not resolve the contradictory or missing
v2 acceptance oracles above.

## Gate result

**BLOCK: 0 Critical, 2 High, 2 Medium.** Reconcile malformed-advertisement
fallback presentation, define a constructible pre-worker failure event
lifecycle, update current cross-spec references to SPEC-044 v0.2.5, and add the
missing per-copy cleanup binding proofs. Commit revised authority/plan/test
bytes, recompute their exact digests, and repeat the independent cumulative
gate. Slice 6B implementation must not begin from the reviewed corpus.
