# Owner testability addendum r2 — independent Astra gate

**PASS — 0 Critical, 0 High, 0 Medium.** The three r1 testability findings are resolved by the revised design. This authorizes the described bounded seams and committed-evaluation recovery correction, not a claim that CODE-M2 or physical acceptance is complete.

Exact reviewed addendum SHA-256: `5141587df7e9749947830649f579653d463fdd6fbe4940fa460baee1c9dd8bad` (verified from disk). Base `914f7cafcdbcfc1805a10f4f34167218341d5587`. Reviewed against current owner, actual Stage1Prober/cleanup, CandidateProviderRunner/readiness, benchmarker/engine integration, adoption parser and lifecycle/conflict code.

## Findings disposition

| r1 finding | Disposition and evidence |
| --- | --- |
| OT-M1: isolated lifecycle unreachable | CLOSED at design level. The paired internal managed-context config and HMAC paths provide a fixture-owned identity that can satisfy the same managed-lifecycle equality check. Production commands provide no overrides and retain actual operator defaults; fixtures supply both paths under their isolated root with a precreated private secret. An unrelated config and foreground conflict still fail before lifecycle invocation. No CLI/environment bypass or injected authority is introduced. |
| OT-M2: stub cleanup proves only itself | CLOSED at design level. The r2-specific section explicitly uses the actual Stage1Prober and CandidateProviderRunner with a compiled harmless loopback provider. Real readiness/stream cancellation and timeout traverse `withCandidateProviderCleanup` and the production runner stop path. PID exit/port closure precede lifecycle restore. Existing synthetic Stage1 result tests are calculation-only, not lifecycle acceptance. The r2 real-prober requirement supersedes the r1 introductory stub-prober description for producer and lifecycle proof. |
| OT-M3: committed evaluation loses truth | CLOSED at design level. The r2 section explicitly authorizes the needed production correction. Result SHA-256 is stored in the same committed journal update; recovery requires secure exact bytes, full document validation and recorded target/catalog/revision/artifact bindings. Missing legacy binding, uncommitted result, partial/missing/corrupt/substituted result fail closed. Historical outcome is preserved separately from current adoption eligibility. No recommendation/engine output injection is allowed. |

## Implementation and verification interpretation

The design is feasible with existing control surfaces and narrow internal defaults. Implement these details consistently with its stated contracts:

- The owner currently hardcodes probe port 19191. To satisfy the explicit no-operator-ports requirement, give the fixture an internally selected unused loopback port (production remains 19191), shared by owner, prober, child and fake lifecycle checks. Assert actual child listener ownership as the existing runner requires; a fabricated `/v1/models` HTTP 200 alone is insufficient. This is test isolation, not a public runtime option.
- `ModelsAdoptRecommendationCommand.parseRecommendation` currently enforces age against `Date()`. Historical committed-result recovery must validate structure/bindings at the captured completion context or otherwise separate historical structural validation from current action freshness. It must not turn a valid old committed outcome into failure simply because seven days elapsed. Retain the existing current-time validation for projection/adoption. Test a valid aged committed result that remains historically succeeded while adoption is unavailable.
- Persist and compare the exact serialized result digest, rather than a reencoded approximation. Cover cross-transaction, cross-target/revision/hash/catalog substitutions, result write before committed journal, committed journal before terminal event, missing/corrupt results and legacy committed records without a digest. Reconciliation does not rerun the benchmarker/engine or create a replacement result.
- Real fixture throughput and TTFT must feed the unmodified engine and full result serializer; compare to sufficiently different signed catalog thresholds without brittle millisecond-equality assertions. The measured result must actually be eligible under the fixture catalog, then pass the ordinary adoption consumer with test-owned state.
- The no-download spy must reach the exact artifact resolver used by the real benchmarker, not only the preparation downloader. Existing byte verification and complete prefetched-map validation stay enabled.
- A boundary observer running while the owner holds the journal lock must not synchronously acquire that same lock through a second operation. Coordinate process exit/task cancellation without turning the test into a lock deadlock or changing persistence ordering.

These are concrete applications of the revised isolation, real-prober, and historical-truth requirements, not extra authority exceptions. Production defaults remain real; no seam accepts trusted metadata, eligibility, artifact verification, publication or terminal/result output from the caller. No new package dependency is needed.

## Remaining acceptance

CODE-M2 remains open until the actual owner matrix, real producer/adoption composition, crash/recovery and broader affected suites run successfully on the final source. This design gate is not runtime proof. The original full CLI bootstrap/service matrix remains required; approving these seams does not waive any separate test. Physical B1-T10 remains independently blocked/unproven; fixture model timing is not MLX evidence.

INFO: the r2 filename and section are correct, but its first heading still says r1. This is editorial and does not change the reviewed bytes or approval.

## Exact scoped snapshot

Manifest digest: `d0292fda9dbd28280e55f2ca438fdf718e8b462557eca1e39861de140fa8eb76`. SHA-256 over the sorted newline-terminated manifest below.

```text
5141587df7e9749947830649f579653d463fdd6fbe4940fa460baee1c9dd8bad  docs/product-roadmap/build-1/owner-testability-addendum-r2.md
e39be672187ab91fe1331c55a6de7579141f1f7ec945482c5ab6d995cddb1d7e  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
30e760c9caf91eef949ed223c8be8b0a67f21015d291ecd0ddec93883701e514  phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift
b365b5a5f2fd588cf65c24847ff99aa2e0aed597d591186ba39e979f82a64565  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
8fb190b38dfda46a03315fe64a4404e60a8cb07c3d6568de3124850b2d55ccc5  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
de1b6478ebe27c078bf0f39ed9333e156834d70308b7514ad3d8d10527fff34e  phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift
b9fc77947f3b3dc5eff4ba7229fc6df424aed9cf257504c46501e14aa5101e31  phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift
```

No source/runtime edits, subagents, secrets or external services were used. This was a code-grounded testability design review; no new tests were executed.
