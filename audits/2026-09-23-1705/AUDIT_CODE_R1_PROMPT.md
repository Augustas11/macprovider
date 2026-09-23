# Audit — #1705 catalog row-continuity admission + CLI envelope refresh (round R1)

Method constraint (read first): this is a first-party software-correctness / proof
review. Do NOT author or construct malformed payloads or exploit inputs. Evaluate by
reading source and running EXISTING/NEW tests in the repo; describe any gap abstractly
(field + condition) in prose. Do not edit any file in the worktree.

Worktree: /Users/augstar/macprovider-1705 (branch fix/1705-catalog-row-continuity).
The complete fix under review is `git -C /Users/augstar/macprovider-1705 diff origin/main`
(committed + uncommitted working tree) PLUS the untracked file
`phase4-coordinator/cmd/coordinator/autotune_row_continuity_test.go`. Review the FULL
combined diff, and read surrounding code outside the diff where contracts meet it.

Context:
- Issue: `GH_TOKEN=$(gh auth token -u Augustas11) gh issue view 1705 --repo Augustas11/macprovider`.
- Governing contract: specs/SPEC-023-installer-autotune-recommend.md §3.6.1
  (SPEC-023-R010, v0.14.3 additions) and AC-CAT-22; SPEC-010-R004/R007 for identity
  binding. CONFORMANCE entry SPEC-023-R010.
- Coordinator: `.row-continuity-target` (<=8 `releases/<id>` lines) is loaded through the
  keyring-verified previous-candidate loader, tombstones dropped, marked
  `Catalog.RowContinuityOnly`; `catalogAdmissionWithCatalog` returns mode
  `row_continuity` for such documents and requires equal row identity +
  PolicyEquivalent; `admittedCandidateCatalogSHA256` excludes row_continuity so
  artifact-derived identity fails closed.
- CLI: `CoordinatorClient` catalog envelope becomes replaceable; on
  `catalog_incompatible` or an ack advertising a different current sha, a rate-limited
  refresher re-runs the signed live fetch and stages a new envelope for the next hello
  only when the served row's model_sha256 is unchanged. Malibu/CLI status copy for plain
  `catalog_incompatible` no longer says "install new software".

Useful commands:
- `cd phase4-coordinator && go test ./internal/ws -run 'RowContinuity|CatalogAdmission|Previous' -count=1`
- `cd phase4-coordinator && go test ./cmd/coordinator -run 'RowContinuity|Restamp|PreviousAutotune' -count=1`
- `cd phase3-binary && swift build --build-tests && swift test --skip-build --filter "CoordinatorClientTests.test(CatalogIncompatibleRefresh|HelloAckOn)|ServeCommandTests.testCatalogEnvelopeRefresh|StatusCommandTests.testPlainCatalogIncompatible"`
  (if swift build modifies phase3-binary/Package.resolved, restore it with
  `git checkout origin/main -- phase3-binary/Package.resolved`).

Output format: a findings list, each with severity CRITICAL/HIGH/MEDIUM/LOW/INFO,
file:line, the defect, a concrete failure scenario, and a suggested fix. Only report a
finding as C/H/M if you can point to the code path that produces the failure. End with
exactly one line: `VERDICT: C=<n> H=<n> M=<n> L=<n>`.

## Lane: CODE REVIEW
Focus: logic correctness and completeness vs AC-CAT-22 positive and negative matrix;
every consumer of `CatalogAdmissionMode` (grep the whole phase4-coordinator tree, stats,
admin, poolsnapshot, providerevents, routing, settlement, scripts/malibu_fleet_ledger.py)
treats `row_continuity` correctly; SIGHUP reload path; compatible-map key collisions in
`buildCompatibleCatalogSet` (version vs sha keys between previous-target, restamp and
row-continuity entries); Swift actor/concurrency correctness of the envelope swap
(pending adoption, rate limit, detached task, reconnect loop backoff reset); test
adequacy (would each test fail if the fix were reverted?).
