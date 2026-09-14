# Independent adversarial Build 1 plan gate — revision 3

Verdict: **APPROVED FOR IMPLEMENTATION**. Open findings: **0 Critical, 0 High, 0 Medium, 1 Low**. No Build 1 outcome was removed or reduced to obtain approval.

This approval covers the exact plan/test pair below at the stated base and explicit pinned prerequisite. It is plan approval, not implementation, physical acceptance, release qualification or production authorization.

## Reviewed identity and method

- Base: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`.
- Explicit unmerged prerequisite: PR #1468, `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`.
- `plan-r3.md` SHA-256: `8d990d4236ef7e20c1003a62468df7a1e1b0771b9e1979278d1292aa73a05c1f`.
- `test-spec-r3.md` SHA-256: `66efa0e20b45f4d3c32edd2803605ea16a50ea633c1d787f5ae10048759d706d`.

Both digests were independently checked. The reviewer read the full r3 pair, compared it with r2, and inspected the newly selected real benchmark path in `AutotuneRecommend.swift:3948` onward. Prior independent inspection of the base, prerequisite through `git show`, repository `AGENTS.md`/`CLAUDE.md`, admission, billing, storage, discovery, app projection and normative requirements remains applicable. Only this review file was written. Earlier reviews were preserved. No tests or physical acceptance journey were run by this reviewer, and no secrets, clean-room source or production services were inspected or modified.

## Prior finding dispositions

| Finding | Disposition | Evidence |
|---|---|---|
| r1 H1: activation/admission bootstrap cycle | Closed at plan level | The plan requires owner-spec amendments before runtime changes for confirmed non-economic local activation, with economics suppressed, authenticated identity/configuration safeguards retained, and paid admission still decided independently after activation. Legacy clients retain conservative behavior. B1-T11 starts without a target session, admission record or saved recommendation. |
| r1 H1 / r2 H1-R2: recommendation producer cannot produce promised measurements | Closed at plan level | Step 3 now explicitly implements `models recommend-prepared TARGET --json`, mandates a complete prepared-artifact map, uses the real runner and recommendation engine, and excludes installed-only catalog estimates. The existing `benchmarks` function validates an exact prepared path/hash through `verifiedExistingArtifact` before `runnerFactory`, and assigns measured `medianTPS` / `p95TTFTMS` from the probe to `CandidateBenchmark`. Thus the chosen implementation seam exists. B1-T14 requires runner invocation, deliberately different catalog/runner values, no downloader calls, missing/corrupt-artifact rejection, complete recommendation consumption and cancellation/timeout/memory-pressure recovery. |
| r1 M1: durable publication disconnected from discovery/readiness/offers | Closed at plan level | The durable inventory contract assigns discovery/projection/command integration, shared root resolution, path-independent identity, verified durable preference, conflict handling, stable IDs across restart and cache removal, and read-only failure behavior. B1-T12 verifies the empty-HF-cache journey and duplicate/corrupt/conflicting inputs. |
| Operator custody isolation | Addressed at plan level | The harness contract explicitly isolates identity, config, HMAC, namespace, credential and model stores, requires inspection/override before command execution, and prevents connecting the installed provider to test services. B1-T13 rejects operator-default stores and nonlocal targets. |

These closures validate the revised design and evidence requirements. They do not assert the corresponding code already exists or has passed tests.

## L1 — Correct the adoption-owner citation

**Severity: Low.** The plan's introductory statement “Existing SPEC-011/043 adoption boundaries” incorrectly names SPEC-043, whose title and scope are Trusted Pool Creator Onboarding MVP. `SPEC-001` §6.14a's command taxonomy explicitly assigns `models adopt-recommendation` to SPEC-001 plus BUILD_SPEC_953 BS953-R015; signed recommendation inputs remain under SPEC-023 and warm swap under SPEC-011. Correct this citation in the next plan revision and use those actual owner contracts during normative implementation. The substantive plan already requires applicable adoption-owner amendments and preserves the existing adoption checks and protocol, so this citation error does not change the approved runtime scope or reopen the bootstrap finding. SPEC-043 must not be treated as adoption authority or amended on that premise. Any new exact plan digest should be rebound to this review after verifying the citation-only diff.

## Full-plan adversarial assessment

**Feasibility and prerequisites.** The plan distinguishes the open pinned feed prerequisite, missing production promotion, new transaction and discovery work, new measured producer, and existing adoption foundations. The prepared-only benchmark seam is executable in the existing codebase when integrated as specified; the plan no longer assumes the background estimate path performs inference. Mandatory map/filter/identity validation must prevent optional-map fallback into downloader code. This is expressly tested by B1-T14.

**Trust and economics.** The sequence preserves authenticated primary-artifact identity and freshness; it does not make preparation, local activation, benchmark output or provider assertions into pricing or settlement authority. Coordinator decisions require current session/model/hash/algorithm agreement, signed effective rates, independent Tier2 material, successful bounded probe, receipt prerequisites, sanction/lease/generation checks and enforcement mode. Default-fallback pricing is rejected for new admission. The six artifact provenance fields enter immutable admission/route evidence; candidate catalog digest is not confused with Tier2 `CatalogBodyDigest`. Old snapshots keep their existing digest interpretation. B1-T07–T09 cover failed predicates, concurrent transitions and accounting/receipt negatives.

**UX, cancellation and recovery.** The complete journey retains confirmed preparation, known/unknown-size disclosure, progress/deadline behavior, CLI-owned cancellation, publication commit-point truth, too-late cancellation disclosure, fresh-projection reconciliation, cleanup recovery, conservative legacy capability behavior, prepared-only adoption and incumbent preservation. The new real measurement step is explicitly a confirmed long-running evaluation with cancellation, child termination and provider-lifecycle restoration. Transaction, filesystem, stale-authority, crash and app-event negatives remain in B1-T02–T06 and B1-T14.

**Normative consistency.** Preparation, pre-admission evaluation/activation and updated nontrusted-action validation must follow the named owner-spec amendments before runtime implementation. This is an explicit dependency of the approved plan. No new trust tier or stronger compute claim is authorized. Discovery remains read-only; admission and money-path specifications retain their authority.

**Proof quality.** B1-T11 proves composition without preseeded positive admission or a hand-constructed eligible recommendation. B1-T14 distinguishes actual runner measurements from catalog estimates. Deterministic runner tests are labeled fixtures; they cannot prove physical inference. The suite requires actual selected test counts and fresh results, followed by surface gates and full cumulative code/security/architecture reviews including the prerequisite and migrations. No Critical/High/Medium plan issue remains from this inspection.

## Completion boundaries retained

Physical B1-T10 remains mandatory: actual supported MLX weights on the specified Mac, authenticated exact artifact/runtime context, isolated coordinator/gateway/PostgreSQL, independently qualified reference material, real buyer inference, persisted receipt verification and expected settled accounting. Missing qualified feed/reference material leaves physical acceptance blocked even if fixture tests pass. The prerequisite's nil baked feed is not evidence of usable signed distribution. Fixture keys cannot substitute for operator trust, and no operator-secret changes are authorized.

The separate locked release-toolchain requirement cannot be satisfied by local Xcode evidence from another version. Release/publication and production activation remain outside the stated operational scope. Subsequent implementation audits and physical evidence must be completed before claiming Build 1 complete; this plan approval does not waive either gate.
