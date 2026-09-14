# Build 1 catalog read completeness — independent Sol plan review r2

Date: 2026-09-10. Reviewer: independent native GPT-5.6 Sol adversarial plan lane.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, branch
`codex/product-build-1`.

**Verdict: APPROVED FOR IMPLEMENTATION at the scoped plan gate — 0 Critical,
0 High, 0 Medium, 0 Low.** The exact r2 proposal closes all three Medium findings
from the rejected r1 review. This approval covers the plan only. The four
preliminary CLI findings remain runtime-open until the approved corrections are
implemented and every additive CR/CC requirement passes against the final source
manifest. Final combined code, security and architecture audits at zero
Critical/High/Medium remain mandatory.

## Scope and method

Reviewed `catalog-read-completeness-addendum-r2.md`, exact SHA-256
`bfd90e81137d22404212bf3c97d44b98b2b168a4b618a58de9c83278bd7e9ced`,
against the immutable rejected r1 artifact, its independent Sol review, the
approved lifecycle r2 contract and test-spec-r4. Independently traced the current
production event encoder and limits, verify preflight, projection construction,
admission fetch/validation, signed static selection, transaction reconciliation,
success binding, recommendation-pointer publication, descriptor-relative atomic
write and cleanup inventory/action paths. The cited current source hashes still
match the rejected r1 review's source manifest, so the three corrections were
assessed against the same demonstrated defects rather than a moving runtime
implementation.

No tests, services, network operations or runtime/spec/plan edits were performed.
Only this independent review artifact was added.

## Severity summary

| Severity | Open findings |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |

## CR-COMP-M1 — resolved: exact fully framed output sizing

**Prior severity:** Medium. **Disposition:** Resolved at plan level.
**Confidence:** High.

The current implementation proves the r1 defect: `ModelCatalogReadOutput.preflight`
encodes only a mutated projection and compares that byte count to the reserved
ceiling (`ModelCatalogReadCommand.swift:153-174`), while the actual completed
event repeats `target_model_id` and `model_key` outside the projection and adds
request, sequence, byte-count, kind, error and schema fields plus a newline
(`ModelCatalogRead.swift:97-120,145-162`). Candidate validation fixes revision
and artifact-hash widths but does not impose the same finite bound on candidate
keys or model IDs (`AutotuneRecommend.swift:997-1032`). A fixed 2 KiB allowance
therefore cannot substitute for encoding those variable outer fields.

R2 sections 5 and 6 close this gap. Preflight must construct the actual
prospective `model_catalog_read_event.v1` completed line through the production
event encoder and newline framing. It binds the exact request UUID and exact
selected outer target/key, uses maximum applicable completed sequence and byte
widths, includes null error and the complete sizing projection, and counts the
terminating newline. The 2 KiB reserve is explicitly additional to that measured
line, with overflow-safe arithmetic. Final publication independently re-encodes
the actual event and enforces both the raw 1 MiB line and existing 8 MiB total
stdout limits.

This is a real upper-bound procedure for the stable state visible before hashing,
not a guessed row or envelope allowance. R2 correctly avoids claiming a universal
finite maximum for signed fields that current validators do not individually
bound. CC-06 forces the previously missed long/escaped outer target/key case and
zero artifact bytes on deterministic overflow. CC-07 requires production-encoder
tests one byte below, exactly at and one byte above both the reserved preflight
ceiling and raw line limit, including repeated identifiers, maximum applicable
numeric widths and newline. CC-09 separately covers post-preflight growth and
requires final fail-closed behavior without a second hash or stale-template
publication. The correction is implementable by exposing/reusing the existing
event construction/encoding path; it requires no wire change or new parser limit.

## CR-COMP-M2 — resolved: both suppressed index paths and durable pointer truth

**Prior severity:** Medium. **Disposition:** Resolved at plan level.
**Confidence:** High.

The current reconciliation path suppresses `indexCompletedEvaluation` failure
after recovered committed success and again after a newly committed successful
terminal (`ModelCatalogTransactions.swift:500-507,557-575`). The indexing helper
reads and validates active primary, result, provenance/index and an existing
pointer before a descriptor-relative atomic pointer write
(`ModelCatalogTransactionRetention.swift:599-660`). The underlying write fsyncs
the temporary file, renames it and fsyncs the directory
(`ModelCatalogTransactionStorage.swift:188-219`), so failures before publication,
after rename and after durable publication have materially different durable
truth even though every current owned read must fail incomplete.

R2 section 3 expressly covers both suppression sites and forbids either from
returning a recommendation-absent projection. Its failure taxonomy is exhaustive
for the observed helper: active primary/index/result/provenance and previous-
pointer reads; missing bytes; closed decode, semantic and binding failures;
pointer-directory metadata, safe-open and creation; source validation/change and
budget expiry before write; atomic write, rename and durability; post-write
readback/closed validation; and expiry or injected failure after the exact pointer
became durable but before acknowledgement.

The required publication outcome preserves the important recovery distinction:
the helper must report whether no pointer was durably published or the exact
pointer may/did become durable without usable acknowledgement. Both outcomes fail
the current owned read and cannot become nil recommendation,
`measured_recommendation_required` or false empty recovery. A durable exact
pointer is neither deleted nor rolled back; a later request may use it only after
ordinary complete validation under that later request's original budget. This
adds no pointer trust, cache or mutation authority. CC-04 injects every listed
class at each suppressed call site, checks all request/phase/incoming-helper
deadlines, and proves the durable-pointer retry behavior. CC-05 supplies the
positive semantic absence/live-owner/valid-pointer controls, preventing a blanket
"all errors are absence" implementation.

The correction is feasible with the existing descriptor-relative storage model:
the publication helper can carry an explicit pre-publication versus
may-or-did-publish outcome while preserving the original error, then perform the
required readback/validation before acknowledgement. An fsync or injected
post-publication ambiguity need not be guessed into success; it remains failure
for this read and discoverable durable state for a later bounded validation.

## CR-COMP-M3 — resolved: additive CR-01–CR-13 plus CC-01–CC-10 gate

**Prior severity:** Medium. **Disposition:** Resolved at plan level.
**Confidence:** High.

R2 sections 6 and 7 state without substitution language that CC-01–CC-10 are
mandatory additions to every lifecycle CR-01–CR-13 requirement at exact lifecycle
r2 SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`.
Every one of the 23 IDs must have passing evidence against the same final landing
diff and source manifest. The report schema requires exact command, exit status,
selected/executed/skipped counts, sanitized log and artifact hashes, tested
commit/tree, source-manifest digest and assertion. Zero-selected, skipped,
interrupted, stale-manifest and historical-only rows expressly fail.

The forward lifecycle table covers all CR-01 through CR-13 and the reverse table
covers all CC-01 through CC-10. CR-01, CR-03, CR-07, CR-08, CR-09, CR-11 and
CR-12 are named as directly impacted fresh reruns after the last completeness
edit. CR-10's targeted/full suites and three independent audit lanes must also be
fresh over the complete landing diff. CR-02, CR-04, CR-05, CR-06 and CR-13 remain
mandatory against that same final manifest. CC-10 removes r1's open-ended
"relevant suite" substitution. The mapping also keeps test-spec-r4 B1-T01–B1-T14
mandatory and preserves B1-T10 as separate physical, signed hardware evidence.
No lifecycle compatibility, process-ownership, trust or release qualification
case can be dropped by satisfying the narrower completeness matrix.

## Trust, economics, recovery and feasibility assessment

**Trust and economics.** The present `ModelCatalogTransactionAuthority.matches`
compares only model identity plus candidate/artifact digests and signer
(`ModelCatalogTransactions.swift:14-53`), while each signed selection also carries
selected bytes, warnings, fallback state and signer identity
(`AutotuneRecommend.swift:1533-1539,1664-1754`). R2 requires all four selected
candidate/artifact/rate/demand byte strings, signer identities, effective versions
and trust/fallback classes to be captured before hashing and re-fetched after it.
It also names authorization-relevant warning changes, including fallback cases
that reuse the same baked bytes. Changed or expired authority fails without a
second hash. Actual accepted coordinator status must pass the existing strict
64 KiB response path and be included in sizing; the preflight cannot synthesize
trusted admission or economic permission. These requirements strengthen current
authority comparison without minting a new tier, readiness fact, route or
settlement predicate.

**Recovery.** Current complete inventory still skips an active primary whose
bytes are missing (`ModelCatalogTransactionRetention.swift:541-561`), and action
construction can run recommendation reconciliation after the inventory
(`ModelCatalogReadCommand.swift:88-100`; `ModelCatalogTransactions.swift:1215-1267`).
R2 requires every active index entry to be decidable, pre-reconciles every signed
primary target that can enter the projection, captures cleanup before optional
reservations, then performs a final complete capture and action-evidence witness
validation after the last action-side mutation. Any new obligation is reserved
through the existing exact UUID/generation/evidence API and recaptured; no old/new
row merge or rollback is permitted. Compact metadata/digest witnesses and no bulk
decode under the global lock keep the design compatible with the existing
bounded owner-fence model.

**Feasibility and honest limits.** R2 does not promise that 1,024 maximum-size
primaries fit ten seconds or that every valid projection fits one line. It
requires a measured high-count positive case, exact encoded sizes and wall time,
and an explicit unavailable outcome when the finite request or transport limit
cannot be met. It forbids shrinking fixtures, omitting recovery/economics,
lengthening deadlines or using overflow-only evidence to manufacture acceptance.
The one-byte encoder boundaries are constructible with finite accepted string
fixtures, while raw-line tests may exercise the production encoder independently
of the preflight rejection path. Shared budgets preserve the minimum of request,
phase and helper deadlines through transitive reads and writes rather than
renewing the existing eight-second helper default. These are demanding but
concrete and testable requirements.

No plan-level trust escalation, economic authorization leak, recovery erasure,
unbounded retry, hidden cache, dependency addition or infeasible success promise
was found.

## Gate disposition

The exact r2 proposal passes the zero-Critical/High/Medium plan gate and is
approved for implementation within its stated ownership and scope. The rejected
r1 artifact remains immutable. Approval does not waive the normative SPEC-001/
SPEC-044 amendments, any CR/CC/B1 evidence, physical B1-T10 qualification or the
final combined audit gate.

## Exact reviewed-artifact and source SHA-256 manifest

```text
bfd90e81137d22404212bf3c97d44b98b2b168a4b618a58de9c83278bd7e9ced  docs/product-roadmap/build-1/catalog-read-completeness-addendum-r2.md
b7a2ce242d20e14e76443bfc90b3125169dc4a39706003159c1f2d9fd5fb8694  docs/product-roadmap/build-1/catalog-read-completeness-addendum-r1.md
6e6028e0bb168f67c201570af857e8c035116622aae879c6c47c86e22c03f33f  docs/product-roadmap/build-1/reviews/catalog-read-completeness-r1-sol.md
e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954  docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r2.md
20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be  docs/product-roadmap/build-1/test-spec-r4.md
fb0ffa38641044059113efffd6f546739db37436a79c0d3b54832bfa8c0edb70  docs/product-roadmap/build-1/reviews/catalog-read-cli-preliminary-r1-astra.md
f2e39f62223ed1c35760366c8b92ebb70fecbe400162ac64dcff799a8d7dfdf5  phase3-binary/Sources/macprovider-cli/ModelCatalogReadCommand.swift
661f47f41e57c01b72c4c8d516283af3ad46466c2aa140b026cde387ab7007c6  phase3-binary/Sources/macprovider-cli/ModelCatalogRead.swift
8140d9ee9f6d76b9784a1d92da73653b8c6a5c573ad40794c99d23d10886665f  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
cfe7d52d9be3219b8f64e3da346d855d36ca6d983dfdcbafc7ced1affb2f2287  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
3fdf995460882e8752016aa0679fcdb7668e484d5433b14ec6e74dcbe53d52bc  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift
e79db53d8e7dd6d3bbe2bcc0554a05a33f13e5a22ad732a24b9b731a6a861f53  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
6d12d94c1d7bd514bed598670b5bd0c1e438d5496b6173f4684fde91481cb6ff  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift
b6804e760a6ad1693eff0234e4a80ac82be3d250441627532446b07b1cee5c91  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
f39668509c4df5577e9641710d63ae410b237370fc33c9e65a4f60b2567843c1  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
f4019fa681a312ea9eb8aebb4df7dabbfdeaedf94f1fa321fe7ca28473e85caa  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
03c2810bc61c833dfbf96930c255db3f6f37c41d1be3386e8000e7069af835cc  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
c2c42457baca745f21c59c73ad7e2ada70055c9a5a2b407d89ec879b0c65eba4  phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift
```
