# Audit R1 — BYOM v0.2 slice 2c (CLI consumption of the SPEC-023 artifact feed)

**Diff reviewed:** `git diff origin/main...HEAD` on `feat/byom-v02-slice2c-cli-artifact-feed`
(`9fd3e1d2`, `227017fb`, `a13463ec`) over main `6006f313` (slices 2a, 2b, 2b-ii landed).
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R1 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 3 HIGH / 4 MEDIUM / 0 LOW |
| security-reviewer | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 2 LOW / 1 INFO |
| architect | 0 CRITICAL / 0 HIGH / 4 MEDIUM / 2 LOW |

All lanes confirmed rule 6 in code (the four artifact warnings are outside
both blocking sets; a nil baked feed yields no fetch and no warnings) and the
identity-only boundary of the discovery matcher. Every finding was resolved in
the commit that adds this record:

- **HIGH (code; security MEDIUM):** the live loader had no production caller —
  every transcript used the compiled-in bytes only, so the authenticated
  selection, signer equality and release binding never ran. `loadRecommendationInputs`
  now loads the artifact feed for the SAME selected candidate release beside
  the three v0.1 feeds and its warnings ride in every merge site (`autotune
  --recommend`, `--recommend-prefetch`, `--consume`, `models` adoption). The
  discovery matcher stays on the compiled-in, release-bound set by design
  (discovery is offline and read-only); the runbook says so.
- **HIGH (code; security MEDIUM; architect MEDIUM):** matching ignored
  `verification_status` and `allowed_runtime_sources`, so a `declared` or
  `blocked` artifact, or an MLX reference reported by an Ollama adapter, could
  yield `catalog_matched`. `ServedReference` now carries both; `catalogKey(for:runtimeSource:)`
  requires `verified` and adapter membership; both call sites pass their adapter.
- **HIGH (code; architect MEDIUM):** the compiled-in path compared the baked
  catalog signer with itself and no release-manifest signer was ever an input.
  `generate` now bakes `bakedArtifactFeedSignerKeyID` from the artifact sidecar
  (the generator's cross-feed equality makes it equal to `release.json`'s
  binding) and `bind` takes `manifestSignerKeyID`: the baked path is a genuine
  three-way identity; the live path enforces the two authenticated signers it
  holds, the manifest binding of served bytes being enforced by `verify`, the
  acceptance signer, the live release gate and the coordinator loader (documented).
- **MEDIUM (code, architect; security LOW):** the multi-line Swift literal was
  not byte-safe. The bake is now `bakedArtifactFeedBase64` of the exact signed
  bytes, decoded at runtime; the Python test bakes hostile bytes (`"""`,
  backslashes, control characters) and round-trips them.
- **MEDIUM (code; security LOW):** `loadSignedStatic` checked policy on loosely
  extracted text before strict decode, so a schema-invalid live document could
  be classified update-required. Strict decode now precedes the policy check
  (§3.5 order: signature → schema → policy/freshness); pinned by
  `testSchemaInvalidLiveFeedIsAnIntegrityFailureNotAnUpdateRequirement`.
- **MEDIUM (code, architect):** `generated_at` was compared as instants in Go
  and Swift but as strings in Python. Go now also requires the raw stamps to be
  equal; Swift carries `generatedAtRaw` and compares it with the candidate's
  raw stamp; corpus case "generated_at spelled as a different RFC3339 form of
  the same instant" → reject in all three languages.
- **MEDIUM (code) / LOW (architect):** rule 5's stale selection now has a
  direct loader test (`testStaleLiveFeedIsSelectedButUnusable`: live bytes
  selected, `value == nil`, stale warning, never blocking).
- **LOW (architect):** `size_bytes` range now agrees: Swift rejects any value
  that does not round-trip through int64; corpus cases "size_bytes beyond
  int64", "size_bytes as a float", "min_ram_gb as a boolean", "model key with a
  double slash" pin the parity (35 cases).
- **INFO (security):** the corpus alone did not prove signer equality, the
  manifest identity, or matcher gating; the new Swift tests above cover the
  manifest combinations (nil / other key / equal), a blocked artifact, adapter
  mismatch, and the production caller.

Verification: `swift test --filter 'AutotuneArtifactFeedTests|AutotuneCommandTests|BYOMDiscovery|AutotuneRecommendTests|ModelsSubcommand'`
(319 tests, 0 failures after the fixture fix), `python3 -m unittest
scripts.tests.test_catalog_artifact_feed` (138 tests OK), `catalog-release.py
verify`, `scripts/test-catalog-release.sh` PASS, `go vet` + `go test
./internal/buyer` OK.

R2 runs all three lanes over the FULL combined diff.
