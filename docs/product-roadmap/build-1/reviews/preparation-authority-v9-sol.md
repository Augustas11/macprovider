# Build 1 preparation authority v9 independent adversarial review

**Gate result: BLOCK**

**Finding counts:** 0 Critical, 1 High, 0 Medium.

This review independently inspected the exact v14 plan and test specification,
the complete cumulative authority diff only through the supplied candidate
revision, the shipped v1 implementation and tests, and every earlier formal
finding named by the gate. The v14 ownership table now agrees with the
normative exhaustive lock graph, closing the only v8 finding. A newly exposed
compatibility contradiction leaves the shipped v1 advertisement outside the
plan's “exact pair only” grammar. The contract does not say whether the existing
schema-discriminator token is a permitted companion or how either upgrade order
must handle it. That ambiguity can disable the supported old-CLI journey or
break the current app, so implementation remains blocked.

## Reviewed immutable inputs

- Repository base: `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Planning worktree:
  `/Users/augstar/.codex/worktrees/macprovider/build1-reservation-rebaseline`.
- Planning revision: `2e98f5ce8af6b054e8f45f92dac7569b9ab00c68`.
- `reservation-rebaseline-plan-v14.md` SHA-256:
  `b8a6e66a42f7076b73b1ad2fdebb09062387fbd38dfe192df1419362139bfd72`.
- `reservation-rebaseline-test-spec-v14.md` SHA-256:
  `f176b652b7448e295bda75e9d04c6e9f87a620cfe8a17bc2e007760c5716f9b3`.
- Authority worktree:
  `/Users/augstar/.codex/worktrees/macprovider/build1-preparation-authority`.
- Authority candidate revision:
  `d4f5eeb0dec4120811ac76afccdfc70a72e3483d`.
- Cumulative authority diff reviewed:
  `f7e584499828b3d16036382848b5caa1a897cdf9...d4f5eeb0dec4120811ac76afccdfc70a72e3483d`.
- Prior review commit:
  `ccf5545e3f041f0641d03c60ababf8e93ba103e6`.
- Prior review artifact SHA-256:
  `fa55aed02c6d91558b3ef9e10fdbec931b059f1ce2a7d4dadd38de986a69a77c`.

The authority worktree's initial `HEAD` was the supplied prior-review commit,
which follows the authority candidate. This review treated that artifact only
as prior evidence and inspected authority bytes only through the candidate.
Both supplied worktrees were clean at initial inspection. The supplied base is
an ancestor of the candidate, and BYOM Slice 5
`6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` and Slice 6
`c4401f1791d593d37d68eba91af94219b26d278f` are candidate ancestors.

## Finding

### B1-AUTH-V9-H1 — High — The exclusive-pair grammar does not cover the shipped v1 schema-discriminator token

**Evidence.** SPEC-044-R001 says v1 is advertised only by the complete pair
`model_catalog_economics_v1` and `models catalog-economics.v1`, says the exact
pair must appear in both the manifest and fresh local status, and classifies an
otherwise complete pair plus an unknown value as a silent no-call fallback
(`specs/SPEC-044-malibu-model-catalog-economics.md:94`). SPEC-001-R003 likewise
says a v1 CLI advertises only the v1 pair
(`specs/SPEC-001-phase3-binary.md:3328-3336`). The v14 plan's compatibility
matrix repeats “exact v1 capability plus exact v1 command-schema token only”
and rejects unknown advertisement
(`reservation-rebaseline-plan-v14.md:75-89`); T01 and T15 freeze the same
selection rule.

The checked-in v1 manifest does not contain only those two values. Its v1 tier
requires local-status capability `model_catalog_economics_v1` and two command
schemas: `models catalog-economics.v1` **and**
`model_catalog_economics.v1`
(`phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json:16-20`).
The current CLI advertises all three strings in its flat status capability set
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:238-249`). Current
Malibu requires every manifest category by applying `isSuperset` against that
one flat peer set
(`phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:64-78`).
SPEC-044 later identifies `model_catalog_economics.v1` as the JSON envelope
schema discriminator but never reconciles why it is also a shipped, required
command-schema advertisement (`SPEC-044:1332`).

The v14 plan and tests therefore do not define whether the third shipped token
is a permitted same-generation companion, an unknown value that invalidates
negotiation, or a value to remove. They also do not delimit the namespace in
which “unknown” is fatal; the real flat status set necessarily contains many
unrelated capability and schema strings.

**Consequence.** A literal v14 implementation can reject the current v1 CLI as
unknown and fail the claimed “new Malibu with old v1-only CLI requests v1”
journey. Removing `model_catalog_economics.v1` to make the CLI advertise the
stated exact pair can make the current Malibu reject the new CLI because the
checked-in manifest requires that token. Since the public read spelling carries
no version selector, this is an upgrade-order compatibility boundary rather
than cosmetic terminology. The accepted plan can lead two conforming
implementers to incompatible wire behavior and can silently remove the model
catalog during a staged app/CLI rollout.

**Required correction.** Define a closed advertisement grammar separately for
the manifest categories and the flat local-status set. State explicitly whether
`model_catalog_economics.v1` and its v2 counterpart are required or permitted
schema-discriminator companions that do not participate in generation
selection, or specify an explicit backward-compatible migration that removes
them. Scope “unknown” to named generation-selection namespaces so unrelated
shipped capabilities cannot invalidate the tier. Freeze byte-level fixtures and
upgrade-order results for at least: current manifest plus current three-value v1
status; new Malibu with the current v1 CLI; current Malibu with a new v2 CLI;
the new v2 advertisement including any schema companion; partial, mixed, dual,
and cross-surface disagreement cases. Reconcile SPEC-001, SPEC-044, the v14
plan, T01/T15/T18, the checked-in manifest/status fixtures, and the contract-lock
tests, recompute plan/test digests, and rerun the cumulative gate.

## v8 finding disposition

| v8 finding | Disposition in this gate |
|---|---|
| B1-AUTH-V8-M1 ownership table forbids required lock custody | **Closed.** The v14 ownership table gives the failure-only worker one bounded `failure.lock` → `cancel.lock` pair for pending/history creation, compaction, and eviction, and gives direct cancel the same bounded pair for its cancel-visible snapshot and marker decision (`reservation-rebaseline-plan-v14.md:124-136`). The constructive graph and authority require the same direction and bounded custody. T01/T03/T12/T14 exercise it, and T18 rejects single-lock or inverted regressions. Neither owner gains operation, cleanup, adoption, socket, runtime, or incumbent authority. |

No v8 finding was downgraded or discarded. B1-AUTH-V9-H1 is a distinct
compatibility defect exposed by comparing the proposed exact grammar with the
actual shipped manifest and status bytes.

## v7 through v3 finding dispositions

| Earlier finding | Disposition in this gate |
|---|---|
| B1-AUTH-V7-H1 recovery lock-order contradiction | **Closed.** SPEC-044 and v14 define one exhaustive acyclic graph with exact acquisition, retention, phase, and reverse-release rules for all twelve named paths. Cleanup and failure custody do not overlap. |
| B1-AUTH-V7-H2 cancellation outside failed-history serialization | **Closed.** Failed-dispatch pending/history creation, compaction, deterministic eviction, recovery, and direct cancel-visible reads share the ordered `failure` → `cancel` suffix; durable terminal evidence wins cancellation precedence. |
| B1-AUTH-V7-M1 unbounded failure-lock wait | **Closed.** Failure-only dispatch and direct cancel share an exact two-second `CLOCK_MONOTONIC_RAW` pair-acquisition deadline, release partial custody/resources, and make no fairness or starvation-free claim. |
| B1-AUTH-V6-H1 malformed-advertisement fallback contradiction | **Closed for the previously identified warning split.** Negotiation-negative cases are silent static-card results; only post-negotiation request failure yields `projection_unavailable` and retry. B1-AUTH-V9-H1 separately blocks the set membership grammar used to decide whether negotiation succeeded. |
| B1-AUTH-V6-H2 pre-worker terminal lifecycle | **Closed.** Immutable identity validation precedes attempt allocation; semantic rejection uses durable failed-dispatch state and one terminal event, while pair-acquisition timeout is a no-event/no-state exit-5 path. |
| B1-AUTH-V6-M1 stale authority-version references | **Closed.** Forward-current authority, governance, handoff, plan, and tests select SPEC-044 v0.2.7; earlier versions are historical. |
| B1-AUTH-V6-M2 incomplete per-copy cleanup proof | **Closed.** T09.6/T16 cover both action copies, all other closed fields, enclosing digest/size binding, equal-copy defects, and cross-target substitution. |
| B1-AUTH-V5-H1 conflicting `local_only` copy | **Closed.** Current authority and test corpus use admission-only copy and require independent readiness evidence. |
| B1-AUTH-V5-M1 catalog-only section conflict | **Closed.** The exact unavailable sentinel is valid only in `Blocked`; one-fault placement alternatives reject. |
| B1-AUTH-V5-M2 false local-default offer history | **Closed.** Local unknown/unqueried coordinator state and authoritative coordinator no-offer readback have distinct source-aware meanings. |
| B1-AUTH-V5-M3 cleanup target proof | **Closed.** Both action copies bind the enclosing target independently before confirmation or mutation. |
| B1-AUTH-V4-H1 incompatible row-order oracles | **Closed.** R005 is the sole locale-independent total tuple with explicit null directions, exact numeric comparisons, and tagged length-prefixed identity. |
| B1-AUTH-V4-M1 incomplete catalog-only sentinel | **Closed.** The full null/false source/state/economics/action sentinel and one-field deviations remain explicit. |
| B1-AUTH-V4-M2 false `local_only` readiness copy | **Closed.** Copy describes admission only. |
| B1-AUTH-V4-M3 impossible cleanup comparison | **Closed.** JCS compares nested action copies and each independently binds the enclosing digest/size. |
| B1-AUTH-V4-M4 admission cardinality mismatch | **Closed.** Every current owner surface freezes the same twelve states and rejects a thirteenth. |
| B1-AUTH-V3-H1 cleanup continuous-lock contradiction | **Closed.** Cleanup retains cancellation custody from the final marker check through rename, barriers, durable tombstone, and readback; crash race outcomes are total. |
| B1-AUTH-V3-H2 false `Earning now` verdict | **Closed.** Exact copy is conditional eligibility for qualifying settled requests and forbids traffic, current-income, receipt, or guaranteed-demand meaning. |
| B1-AUTH-V3-H3 catalog-only trusted economics | **Closed.** Catalog-only rows carry the nontrusted sentinel, null money/demand, no candidate binding, and no action. |
| B1-AUTH-V3-M1 contradictory ACL creation | **Closed.** Sensitive files begin as open unpublished owner-only temps; inherited ACLs are stripped and verified empty before sensitive bytes, with descriptor revalidation. |
| B1-AUTH-V3-M2 unbounded cancel wait | **Closed.** Direct cancel has one total two-second ordered-pair deadline and a no-read/no-mutation `busy` result. |
| B1-AUTH-V3-M3 missing total ranking | **Closed.** R005 and property tests specify a stable total order independent of locale and permutation. |

## v2 and v1 finding dispositions

| Earlier finding | Disposition in this gate |
|---|---|
| B1-AUTH-V2-H1 exclusive v1/v2 advertisement | **Reopened as B1-AUTH-V9-H1.** Generation exclusivity, partial/dual/mixed rejection, and silent fallback remain intended, but the grammar does not account for the shipped same-generation schema-discriminator token or flat-set namespace. This is not closed until the current three-value fixture and both upgrade orders are normative and tested. |
| B1-AUTH-V2-H2 coordinator no-event `not_offered` | **Closed.** Response-byte digest, candidate/source/state/guidance/time binding, nullable-event exception, and event-backed case are distinct. |
| B1-AUTH-V2-H3 cleanup cancellation/recovery | **Closed.** Direct cancel remains marker-only; operation-owning cleanup recovery implements reversible intent and durable tombstone commit. |
| B1-AUTH-V2-H4 root identity | **Closed.** Secret nonce, canonical path, device, inode, schema/version, and digest bind every reopen with drift/copy/remount/reuse negatives. |
| B1-AUTH-V2-M1 catalog-only representation | **Closed.** All-null catalog-only and all-non-null candidate identity groups are representable and exclusive. |
| B1-AUTH-V2-M2 orphan cleanup correlation | **Closed.** Immutable receipt-bound `event_model_key` preserves event correlation for catalog-orphaned targets. |
| B1-AUTH-V2-M3 refresh ordering | **Closed.** App-owned prelaunch generations reject older completions across restart/timeout without disrupting attached workers. |
| B1-AUTH-V2-M4 JSONL/backpressure | **Closed.** All transport and UI queues, partial lines, outputs, terminal reservation, and producer backpressure have fixed caps. |
| B1-AUTH-V2-M5 ACL policy | **Closed.** Empty extended ACL and descriptor-race requirements are normative and tested. |
| B1-AUTH-V1-H1 authoritative earning disclosure correlation | **Closed.** The v2 admission object binds source/state/event or exact no-event evidence, observation time, response digest, candidate, and guidance; earning copy additionally requires independently settlement-capable admission. |
| B1-AUTH-V1-H2 deterministic v1/v2 selection | **Reopened as B1-AUTH-V9-H1.** The plan now selects by exclusive generation pair rather than caller inference, but it omits the shipped same-generation schema-discriminator token and therefore does not deterministically cover the actual v1 wire set. |
| B1-AUTH-V1-M1 legal `coordinator:not_offered` | **Closed.** The exact twelve-state matrix includes it and distinguishes response-bound no-event evidence from event-backed evidence and from local-default unknown state. |
| B1-AUTH-V1-M2 verified-artifact prerequisite | **Closed.** Positive local eligibility requires `verification_status: verified` plus current independently bound artifact/root evidence; preparation assertions cannot grant paid admission or economics. |
| B1-AUTH-V1-M3 undefined cancel acknowledgements | **Closed.** The acknowledgement has six closed outcomes, exact precedence/nullability, bounded bytes, request echo, exit behavior, and marker semantics. |
| B1-AUTH-V1-M4 cleanup commit/recovery | **Closed.** Continuous lock custody, reversible intent, durable/readback tombstone commit, and cancel-first/recovery-first behavior define the commit point and crash outcomes. |
| B1-AUTH-V1-M5 reclaimable-byte accounting | **Closed.** Logical bytes, APFS caveat copy, managed-v3 versus protected-legacy totals, overflow, and filesystem-enumeration rules are normative. |
| B1-AUTH-V1-M6 cleanup reachability | **Closed.** Each reclaimable published identity has a bounded immutable cleanup target/action; eviction and pagination preserve deterministic reachability. |
| B1-AUTH-V1-M7 governance disagreement | **Closed.** SPEC-001/SPEC-044, AUTHORITY, CONFORMANCE, generated indexes, handoff, and contract-lock fixtures select the forward-current authority; fresh governance checks pass. |
| B1-AUTH-V1-M8 production CLI-to-Malibu boundary | **Closed prospectively.** T14 requires the built production adapter, process transport, manifest/status negotiation, event/cancel decoding, refresh generation, and UI behavior; implementation evidence remains pending. |
| B1-AUTH-V1-M9 managed-budget precedence | **Closed.** Configuration/default derivation, byte arithmetic, cap/overflow behavior, and exact enforcement precedence have explicit fixtures. |
| B1-AUTH-V1-M10 unavailable legacy accounting | **Closed.** Unknown or unsafe legacy totals block preparation rather than being treated as zero; preservation and rollback cases are explicit. |
| B1-AUTH-V1-M11 localized size calculations | **Closed.** The CLI owns exact byte values while Malibu localizes display only; locale matrices and raw-value invariants prohibit UI recomputation. |
| B1-AUTH-V1-M12 undefined two-second completion | **Closed.** The two-second claim is now scoped to the total monotonic lock-pair acquisition episode, with release and typed failure behavior; no scheduler fairness or whole-operation completion claim remains. |
| B1-AUTH-V1-M13 event-error precedence | **Closed.** Closed error/warning enums, single terminal outcome, total precedence, mutation limits, and one-fault tests are explicit. |
| B1-AUTH-V1-I1 structural validation limitation | **Retained.** Passing structural/governance checks is recorded only as mechanical evidence; this review does not treat it as semantic closure or acceptance proof. |

No earlier Critical, High, or Medium finding was weakened or omitted merely to
reach a lower count.

## Cross-cutting adversarial assessment

- **Feasibility, ownership, and contention:** the storage state machine, bounded
  resources, twelve-path lock graph, deadlines, worker/cancel split, and
  cancellation/recovery rules are implementable and internally consistent in
  v14. Lock acquisition is bounded without making an unsupported fairness claim.
- **Trust and economics:** signed source/digest/freshness correlation,
  verified-primary-artifact gating, catalog-only isolation, admission/economics
  separation, and conditional settlement copy fail closed. Provider or
  preparation assertions never become pricing or settlement authority.
- **UX truthfulness:** source-aware no-offer copy, admission-only `local_only`,
  conditional earning eligibility, typed contention/cancel results, and
  projection refresh avoid claims of current demand, traffic, income, or paid
  readiness. The compatibility ambiguity can wrongly hide the feature and is
  therefore user-visible despite a silent fallback.
- **Failure recovery and security:** authenticated roots, descriptor-relative
  traversal, owner-only/ACL-empty publication, bounded temp files,
  copy-before-delete history, reversible cleanup, and exact marker ownership
  cover the challenged crash and race boundaries.
- **Compatibility, migration, and rollback:** v3 state and configured legacy
  data remain isolated and preserved; abandoned R21-R27 state is not imported.
  The shipped v1 advertisement and both app/CLI upgrade orders remain the one
  blocking contract gap.
- **Observability and privacy:** bounded redacted events, acknowledgements,
  recovery phases, counters, refresh decisions, and truncation metadata exclude
  credentials, feed bodies/URLs, prompts, completions, provider identity, and
  raw errors.
- **Hardware, release, and product qualification:** real MLX/APFS behavior,
  abrupt-power recovery, incumbent continuity, signed discovery/admission,
  settled positive credit, first-listed-tier proof, final signing/notarization,
  app/tarball byte identity, and previous-stable updater proof remain future
  evidence gates. Observation or preparation alone does not satisfy them.

## Current implementation boundary

The inspected code remains on the shipped v1 catalog-economics path.
`ModelCatalogEconomics.swift` emits `model_catalog_economics.v1`;
`ModelsSubcommand.swift` exposes the v1 read form; `HTTPServer.swift` advertises
the three v1-related strings described in B1-AUTH-V9-H1; and Malibu's
`ModelManagement.swift` decodes v1. There is no v2 worker/cancel implementation,
`failed_dispatch`, `failure.lock`, or v3 preparation engine in the reviewed
candidate. That is expected at this pre-implementation gate and is not a
finding. Existing v1 tests and deterministic fixtures do not satisfy future v2,
physical-hardware, signed-release, admission, or settlement acceptance.

## Pending gates after correction

After B1-AUTH-V9-H1 is corrected and a fresh exact-input plan review passes:

- the approved authority and plan must be strict ancestors of implementation;
- T01-T20 plus targeted and broad Swift/Xcode, Go, distribution, governance,
  and secret-scan checks must pass on the final implementation;
- independent code, security, and architecture full-diff reviews must each
  reach zero Critical, High, and Medium findings;
- physical Apple Silicon/APFS must prove actual MLX preparation/adoption,
  cancellation, custom-root recovery, and incumbent continuity;
- signed/notarized app and tarball assets, embedded CLI byte identity,
  first-listed-tier evidence, and previous-stable updater behavior remain
  release gates; and
- signed discovery/admission plus an actually routed, receipted, correctly
  settled request with positive provider credit remain Build 1 product
  qualification gates.

No plan review, historical result, fixture-only run, prepared artifact, or
provider assertion counts as those pending proofs.

## Fresh verification evidence

All authority checks below ran against the supplied candidate corpus; the
worktree's later review commit was excluded from the authority diff.

```text
git diff --check f7e584499828b3d16036382848b5caa1a897cdf9..d4f5eeb0dec4120811ac76afccdfc70a72e3483d
=> exit 0

git diff --check f7e584499828b3d16036382848b5caa1a897cdf9..2e98f5ce8af6b054e8f45f92dac7569b9ab00c68
=> exit 0

python3 scripts/gen_spec_index.py --check
python3 scripts/gen_spec_index.py --lint
python3 scripts/check_spec_governance.py
=> all exit 0; 47 canonical specs; index current; governance passed

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_byom_contract_lock
=> Ran 15 tests; OK

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_spec_governance \
  scripts.tests.test_spec_pr_declaration \
  scripts.tests.test_byom_contract_lock
=> Ran 76 tests in 76.276s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> XCTest: Executed 8 tests, 0 failures
=> Swift Testing separately reported 0 selected tests and is not counted

cd phase4-coordinator && go test ./internal/ws \
  -run 'TestModelAdmission(StatusForPreBYOMProviderReturnsNotOffered|OfferSubmitAndStatusStayNonEarning|StatusGuidanceForRejectedAndDemotion)$' \
  -count=1
=> ok; 0.962s
```

The filtered Swift run rewrote `phase3-binary/Package.resolved`; it was restored
before this artifact was written. These green checks show that the current
authority corpus and existing implementation tests are mechanically healthy.
They do not resolve B1-AUTH-V9-H1 or prove the unimplemented/hardware/release/
production acceptance paths.

**Final verdict: BLOCK — 0 Critical, 1 High, 0 Medium.**
