# Owner testability addendum r1 — independent Astra gate

**CHANGES REQUIRED. 0 Critical, 0 High, 3 Medium.** This is a design/testability review, not permission to implement the proposed seams or a closure of CODE-M2.

Reviewed addendum SHA-256: `c28d7c2b00f70e1af2380a50f384a56b1d8cc32f54c53022e3b1c74b0396e4e2` (verified from disk). Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Read current owner, benchmarker/engine integration, Stage1 prober/cleanup, candidate runner and conflict/lifecycle code. Scoped source+addendum manifest digest: `8488368f79f15c82f4ffbaa3856a56ca15bfbe50c9abcea6dbdad6950ee5264a`.

## Findings

### OT-M1 — The isolated lifecycle fixture cannot reach the restoration branch

**MEDIUM, high confidence.** Addendum r1 preserves the current isolation predicates before invoking the lifecycle adapter, and promises temporary config/HMAC roots while testing drain/restore/dismiss. Current `ModelCatalogTransactions.swift:497–523` rejects `.foreground` and accepts `.launchdManaged` only when `configPath == AppConfig.defaultConfigPath`; `.none` makes `needsRestore` false. The same default-path equality selects the real operator HMAC file. Therefore a temporary config cannot reach the promised drain/restore branch under the proposed unchanged predicates; using the default path would violate fixture custody isolation.

Required correction: specify a default-preserving, internally injected lifecycle ownership identity (or equivalent narrowly scoped design) that lets tests bind a fixture-managed lifecycle to their explicit config while production still requires the actual default provider identity. Keep HMAC custody selection independently tied to the actual config policy; the fixture lifecycle identity must never select operator HMAC. Test mismatched config/lifecycle identity failing before adapter invocation and the matching isolated identity reaching real owner drain/restore paths. Do not add a public bypass flag or let arbitrary config drain the installed provider.

### OT-M2 — A stub prober cannot prove production probe child teardown

**MEDIUM, high confidence.** The proposal injects a Stage1 prober that returns controlled measured values and records runner creation/termination. In current `AutotuneRecommend.swift`, the benchmarker creates the runner but delegates its start/stop to `Stage1Probing`. Production teardown belongs to `Stage1Iterator.swift:667` through `withCandidateProviderCleanup`; a fixture prober that starts and stops its own child proves its own cleanup, even if a real process is used. The separate parent-death guard test also does not prove owner cancellation/timeout traverses production Stage1 teardown.

Required correction: retain the stub prober for controlled numerical-provenance/engine tests, but explicitly run the actual `Stage1Prober` and `CandidateProviderRunner` for owner cancellation, timeout and child lifecycle tests. Use a harmless fixture executable and existing configurable HTTP session/transport, readiness/timeouts and deterministic sampler; assert process termination before restoration and on cancellation during readiness and streaming. Production defaults must still instantiate the real prober/runner. This needs no fabricated recommendation and must not use operator launchd/config. Distinguish factory invocation from actual child creation and verified exit.

### OT-M3 — Result-commit recovery promise conflicts with current production behavior

**MEDIUM, high confidence.** Addendum r1 requires preserving terminal truth after result commit while allowing only default-preserving seams. Current owner writes/fsyncs its real recommendation result then persists `record.committed = true`. But `ModelCatalogTransactions.swift:303–309` recognizes owner-loss success only for `record.kind == "prepare_model"`; a committed `evaluate_model` whose owner dies before terminal write is permanently appended as failed. `result()` then refuses its already committed result. The promised result-commit crash test necessarily reveals a production behavior correction, not just a seam change.

Required correction: explicitly approve a bounded correction to committed evaluation recovery and its evidence rules in the revised addendum, or present an independently approved contract change (not a silent test expectation weakening). Recovery must validate safe exact transaction-bound committed result evidence and retain ordinary adoption freshness/authority checks; a boolean or mere file existence cannot create an eligible recommendation. Cover crash before result write, after result write but before commit journal, and after commit journal but before terminal write, plus corrupt/missing/swapped result bytes. Genuine noncommitted work stays failed/unavailable; a valid committed result must preserve truthful outcome without rerunning the engine or manufacturing a replacement result.

## Sound parts to retain

The proposed internal dependencies can support the remaining owner matrix without changing authority: production timeout/space defaults, injected HTTP transport, observer-only boundary coordination, cleanup failure injection, real verifier/publisher/journal/result writes, real benchmarker/engine/serializer and original adoption consumer. Returning deliberately different fixture TPS/TTFT from a prober is valid deterministic provenance evidence when the real engine computes eligibility; no eligible output document should be injectable. A downloader spy must cover the resolver used by the benchmarker as well as the transaction downloader. Boundary observers must not call a second journal lock synchronously while the owner holds that same lock; use subprocess coordination or owner-task cancellation appropriately.

This review does not require hardware feeds to add deterministic tests. B1-T10 physical qualification remains independently blocked/unproven. CODE-M2 is not closed by approval of an addendum; the final implementation and fresh tests must still establish its matrix.

## Exact reviewed manifest

```text
c28d7c2b00f70e1af2380a50f384a56b1d8cc32f54c53022e3b1c74b0396e4e2  docs/product-roadmap/build-1/owner-testability-addendum-r1.md
e39be672187ab91fe1331c55a6de7579141f1f7ec945482c5ab6d995cddb1d7e  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
30e760c9caf91eef949ed223c8be8b0a67f21015d291ecd0ddec93883701e514  phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift
b365b5a5f2fd588cf65c24847ff99aa2e0aed597d591186ba39e979f82a64565  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
de1b6478ebe27c078bf0f39ed9333e156834d70308b7514ad3d8d10527fff34e  phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift
b9fc77947f3b3dc5eff4ba7229fc6df424aed9cf257504c46501e14aa5101e31  phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift
```

Manifest digest is SHA-256 of the displayed sorted newline-terminated manifest. No production/source edits or subagents. No test execution was needed to establish these code-grounded design contradictions; this is not runtime validation.
