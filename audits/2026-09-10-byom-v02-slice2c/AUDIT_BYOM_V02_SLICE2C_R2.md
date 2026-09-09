# Audit R2 — BYOM v0.2 slice 2c (CLI consumption of the SPEC-023 artifact feed)

**Diff reviewed:** `git diff origin/main...HEAD` at `939d7ff7` (R1 fix pass included) over main `6006f313`.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R2 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 1 HIGH / 1 MEDIUM / 3 LOW |
| security-reviewer | 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 1 INFO — **at the bar** |
| architect | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 2 LOW / 1 INFO |

All three lanes re-verified every R1 closure. The remaining findings converge
on one shape — artifact identity consumed without the qualified selection —
and one grammar gap. All resolved in the commit that adds this record:

- **HIGH (code) / MEDIUM ×2 (architect) / LOW (security):** `models
  catalog-economics` ran discovery with the compiled-in matcher before loading
  the selected artifact feed, so under integrity / update-required / stale an
  artifact-only reference could still become `catalog_matched`; the shared
  loader aged only fetched bytes, so an offline binary 14+ days past its baked
  feed's stamp kept a usable feed; discovery's matcher had no freshness
  input; and the matcher minted identity for `candidate` / `blocked` rows.
  Now: `artifactFeedFreshnessWarnings` applies §3.7.6 rules 3–4 to whichever
  artifact bytes were selected, the fallback included (`loadArtifactFeed`);
  `usableArtifactFeed` / `bakedUsableArtifactFeed(now:)` is the one qualified
  offline selection (bound with the three-way signer identity AND fresh) and
  the compiled-in `BYOMCatalogMatcher(now:)` consumes it; `BYOMDiscoveryRunner`
  accepts an injected matcher and `catalog-economics` loads
  `loadRecommendationInputs` FIRST and injects a matcher built from
  `inputs.candidate.selectedBytes` + `inputs.artifactFeed.value`, reporting
  the artifact warnings on stderr (SPEC-044's projection codes are a closed
  v0.1 enum; mapping onto them would misattribute the failure); the matcher
  only mints identity for `listed` / `recommendable` rows (§3.2 ladder) by row
  or by artifact. Tests: `testFallbackBakedFeedIsAgedLikeSelectedBytes` (fresh
  / stale / expired / future fallback), `testOfflineQualifiedSelectionMatchesTheLoaderVerdict`,
  `testDiscoveryEmitsNoArtifactDerivedMatchFromAnUnusableSelection` (an
  artifact-only MLX snapshot loses its match under a nil selection while the
  row-known snapshot keeps it — rule 6), `testCatalogMatcherNeverMatchesCandidateOrBlockedRows`.
- **MEDIUM (code):** RFC3339 grammar differed (Python accepted fractions, Go
  also comma fractions, Swift neither). One grammar in all three artifact-feed
  validators now — seconds precision, `Z` or explicit `±HH:MM`, no fraction —
  the form `generate` stamps; corpus cases "generated_at with fractional
  seconds" and "with a comma fraction" reject in all three; Swift unit test
  pins the grammar.
- **LOW (code, architect):** corpus gains "verified_at is an impossible
  calendar date", "version with surrounding whitespace", and two acceptance
  variants ("artifact notes present", "second verified mlx artifact under
  another repo id"); 41 cases.
- **LOW (code, architect):** runbook now enumerates the transcripts that make
  the live selection, states that `models discover` is offline and uses the
  qualified compiled-in selection, and that `catalog-economics` reports on
  stderr; the stale `bakedArtifactFeedJSON` comment is fixed.
- **INFO (security, architect) — carried:** the corpus asserts verdicts, not
  rejection classes (no wrong-reason verdict was found by any lane);
  `ServedReference` is deliberately advisory-only and slices 3–4 will
  introduce a bound capability context rather than extend it.

Verification: `swift test --filter 'AutotuneArtifactFeedTests|AutotuneCommandTests|BYOMDiscovery|ModelCatalogEconomics|ModelsSubcommand|AutotuneRecommendTests'`
332 tests, 0 failures; `scripts.tests.test_catalog_artifact_feed` 138 OK;
`catalog-release.py verify`; `test-catalog-release.sh` PASS; `go vet` +
`go test ./internal/buyer -run 'SharedConformanceCorpus|CatalogArtifacts'` ok.

R3 runs the code-reviewer and architect lanes over the FULL combined diff;
the security lane met the bar in R2 and is not re-fired.
