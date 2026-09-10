# Audit R3 — BYOM v0.2 slice 2c (CLI consumption of the SPEC-023 artifact feed)

**Diff reviewed:** `git diff origin/main...HEAD` at `7ba8578f` (R1 + R2 fix passes included) over main `6006f313`.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes. The
security lane met the bar in R2 and was not re-fired.

## R3 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 1 INFO |
| architect | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 2 INFO |

Both lanes re-verified every R1 and R2 closure. The two MEDIUMs are new,
narrow, and resolved in the commit that adds this record:

- **MEDIUM (code):** `min_ram_gb` had no common numeric domain — the generator's
  global int64 parsing limit rejected a huge integer that Go (float64) and
  Swift (`doubleValue`) accepted, so a secondary artifact could split the
  verdict. One domain now, (0, 1 048 576] (1 PiB), enforced explicitly in all
  three validators; corpus cases "min_ram_gb above the shared bound",
  "min_ram_gb beyond int64 on a secondary artifact" (reject) and "min_ram_gb
  at the shared bound on a secondary artifact" (accept).
- **MEDIUM (architect):** a served reference is a lossy projection of
  content-addressed identity (repo id without revision, library tag without
  digest); two verified artifacts of different `listed`/`recommendable` keys
  could share one normalized reference at different revisions and the matcher
  took the first by sort order. `catalogKey(for:runtimeSource:)` now collects
  every matching reference and mints a catalog identity only when exactly one
  model key answers; pinned by `testAmbiguousServedReferenceMintsNoCatalogIdentity`.
- **INFO (both):** the trimmed-version corpus case rejected in Python for the
  release-equality reason rather than a trimming rule. The artifact-feed
  header (`version`, `release_id`, `policy_version`) now has an explicit
  non-empty-trimmed check in Python (Go and Swift already had it); corpus
  gains "policy_version with surrounding whitespace". 45 cases.
- **LOW (architect):** duplicate-key rejection had no raw-byte artifact test
  (the corpus works on object models). `testDuplicateObjectKeyInRawBytesIsRejectedBeforeDeserialization`
  pins it on raw bytes (top level and nested) in Swift, which is the consumer
  that added a scanner in this slice; Python's `strict_json` and Go's
  `decodeStrictJSON` are shared with the v0.1 feeds and covered there.
- **LOW (code) — carried:** the `models catalog-economics` qualified-selection
  wiring has helper-level coverage (loader, qualification, matcher, injected
  runner) but no command-level test executing the production success path;
  that needs injectable static inputs on the subcommand and is documented in
  the PR body.
- **INFO (architect) — carried:** `ServedReference` is deliberately
  advisory-only; slices 3–4 introduce a bound-artifact context with the six
  SPEC-023 binding fields rather than extending it.

Verification: `swift test --filter 'AutotuneArtifactFeedTests|AutotuneCommandTests|BYOMDiscovery|ModelCatalogEconomics|ModelsSubcommand|AutotuneRecommendTests'`
334 tests, 0 failures; `scripts.tests.test_catalog_artifact_feed` 138 OK;
`catalog-release.py verify`; `test-catalog-release.sh` PASS; `go vet` +
`go test ./internal/buyer -run 'SharedConformanceCorpus|CatalogArtifacts'` ok.

R4 (final anchored round) runs the code-reviewer and architect lanes over the
FULL combined diff.
