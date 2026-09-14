# Build 1 reservation search progress R4 — implementation checkpoint

Status: source frozen; targeted verification passed; independent code,
security, and architecture audits in progress. This is not Build 1 acceptance.

Governing plan SHA-256:
`3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21`.
Current-source compatibility approval SHA-256:
`d19a8bc39fecb61ad58e073fcbc147bb45e792a977d18b6972780a7e0c1a32e9`.

## Frozen source manifest

| File | SHA-256 |
|---|---|
| `ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `ModelCatalogTransactionMigration.swift` | `5bc526e395b048c9d1c41cede30d7430321da83395d2a9a02590e35ecfa4b4df` |
| `ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |
| `ModelCatalogTransactionReservationMigrationTests.swift` | `a0c700eb26cce0938d6dcf973f2dea1eacd8194de2a368ad1fb2270611aa2c35` |
| `ModelCatalogTransactionRetentionTests.swift` | `bf45cf3a914b377d61ecd10b9013467784acf4a9f234fee01e1f5ebd0c7d55cb` |
| `ModelCatalogTransactionsTests.swift` | `009611a1f01fb26dc695ae588abb7e401d1b4cf93c90d6e3fa21249bf6144121` |

Source paths are under `phase3-binary/Sources/macprovider-cli/`; test paths are
under `phase3-binary/Tests/macprovider-cliTests/`.

## Fresh verification

- `swift test --filter ModelCatalogTransactionReservationMigrationTests`:
  4/4 passed, zero failures, 1.693 seconds.
- `swift test --filter ModelCatalogTransactionRetentionTests`:
  44/44 passed, zero failures, 338.254 seconds.
- The contained 1,024-entry migration/retirement case passed 1/1 in 205.953
  seconds: classification completed in 20 bounded calls, then retirement removed
  628 and 396 entries with two index decodes per call.
- `swift test --filter ModelCatalogTransactionsTests`:
  31/31 passed, zero failures, 201.743 seconds.

Total source-current targeted evidence: 79 tests, zero failures. Earlier red
runs remain historical failures: the first broad run exposed pre-v4 fixtures;
the next exposed redundant per-UUID source/progress decoding; the next exposed a
test that directly fabricated a started primary without mandatory R4 exclusion
publication. Each was corrected and its complete affected selection rerun.

## Open verification

Package-wide Swift, post-c944 compatibility, Xcode, and final combined-diff
checks remain pending. Physical MLX, signed release/feed, deployed settlement,
enforcement, and economic activation are not qualified by this checkpoint.
