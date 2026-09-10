# Independent review — BYOM v0.2 slice 2c (CLI consumption of the SPEC-023 artifact feed)

After four anchored codex rounds (R1–R4) the loop stopped, per the repo's
audit discipline, and three cold-context reviewers (code-reviewer,
security-reviewer, architect; each given only the branch, the governing SPEC
sections, and the existing test commands — no fix narrative, no prior audit
records) reviewed the COMPLETE diff `git diff origin/main...HEAD` at `e858d59f`.

## Verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 1 HIGH / 5 MEDIUM / 3 LOW / 3 INFO |
| security-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 3 LOW / 4 INFO |
| architect | 0 CRITICAL / 2 HIGH / 6 MEDIUM / 2 LOW / 2 INFO |

The independent lanes found what the anchored loop could not see from inside
its own framing: two contracts OUTSIDE the diff that the diff violates, and
one trap the anchored lanes had accepted as pre-existing. Everything below is
resolved in the commit that adds this record unless marked carried.

## Findings and resolutions

- **HIGH (code): Malibu rejects the new root warnings.** The app decodes
  `autotune_recommend.v1` against a closed `knownRootWarnings` allow-list, so
  the first artifact-bound release — whose ordinary pre-coordinator-config
  state is `catalog_artifact_feed_fallback_used` — would make Malibu reject
  every recommendation document (§3.7.6 rule 6 inverted). The four codes are
  now in `knownRootWarnings` and deliberately absent from
  `adoptionBlockingWarnings`; `testRecommendationValidationKeepsAnyRootWarningAdvisoryOnly`
  covers them.
- **HIGH (architect): `catalog_matched` minted from a served-reference
  string.** SPEC-047 §R001 (v0.1.3) says a match against a `served_model_ref`,
  display name, or runtime-reported label is NOT a catalog match, and SPEC-023
  §3.7.4 forbids a tag without its digest as identity; the matcher resolved a
  GGUF `library_tag` or an MLX `repo_id` by name. `ServedReference` is replaced
  by `ArtifactIdentity` (artifact id, hash + algorithm, runtime format,
  primary flag, full `source_ref`) and the artifact leg matches only together
  with the IMMUTABLE half of the source reference as the adapter observed it:
  the HuggingFace `revision` (the MLX cache adapter now reports its snapshot
  revisions — directory names, not a locally computed hash) or the GGUF
  layer `digest` (no adapter reports one yet, so no GGUF artifact matches
  until slice 3). For a catalog key the usable feed covers, a repo id, row
  key, or tag alone mints no identity (closure pass: the name-level row leg
  no longer pre-empts the artifact leg); a key the feed does not cover keeps
  the v0.1 name-level row match with `catalog_match_unverified` (rule 6).
  Tests: revision-required, wrong-revision, digest-required, wrong-digest,
  covered-key-by-name.
- **MEDIUM (security) / MEDIUM (code) / HIGH (architect): baked-bytes
  force-unwrap.** The shared loader's `(try? decode(bakedBytes))!` would trap
  every recommend / consume / preflight transcript on a compiled-in artifact
  feed the Swift decoder rejects — a rule-6 inversion latent until activation.
  `loadArtifactFeed` now decodes the snapshot first and yields
  `catalog_artifact_feed_integrity_failure` with no usable value (and no
  fetch); `testUndecodableCompiledInSnapshotIsAnIntegrityFailureNotATrap`;
  `testCompiledInArtifactFeedDecodesAndQualifiesWhenPresent` is the activation
  gate (a no-op while the bake is nil).
- **MEDIUM (code, architect): SPEC-023 §6 output contract.** §6 did not list
  the four v0.10.0 codes and its blanket "any integrity/update-required warning
  blocks a paid recommendation" contradicted §3.7.6 rule 6 — the sentence a
  Malibu implementer would have read. SPEC-023 v0.10.2 amends §6 (bundled in
  this PR per the SPEC+IMPL rule); CONFORMANCE version follows.
- **MEDIUM (code, architect) / LOW (security): ICU `$` accepts a trailing line
  terminator.** Swift's anchored patterns accepted `hash`, `artifact_id`,
  `repo_id`, `revision`, model keys, and `verified_at` with a trailing `\n`
  that Go and Python reject — and two hashes differing only by a newline would
  defeat global uniqueness. `matches` now requires the match to span the whole
  value; three corpus cases and `testGrammarsRejectATrailingLineTerminator`
  pin it.
- **MEDIUM (architect): no type distinguishes a qualified feed from a decoded
  one.** `QualifiedArtifactFeed` (fileprivate initializer; produced only by
  `usableArtifactFeed` and `loadArtifactFeed`, which now share one `qualify`
  step) is what `BYOMCatalogMatcher` and `loadRecommendationInputs` carry; it
  records the digest of the exact selected bytes, the authenticated signer,
  and the release id — the provenance SPEC-047-R003 requires — so slices 3–4
  add a hash lookup rather than rewrite the matcher.
- **MEDIUM (architect): matching authority differed between commands.**
  `catalog-economics` matched against the fetched candidate catalog while
  `discover` / `evaluate` / `offer` used the compiled-in one. One authority
  now: every command resolves BYOM identity against the compiled-in release
  through the offline qualified selection (SPEC-046: discovery is offline);
  the live selection governs recommendation and is reported on stderr. The
  runner's matcher injection is removed.
- **MEDIUM (architect): every caller paid for the artifact fetch.** The
  recommendation-freshness checker and the `serve` preflight consume only the
  three v0.1 feeds; `loadRecommendationInputs(includeArtifactFeed: false)`
  skips the fetch there.
- **MEDIUM (code): the bake-signer branch was untested.** The hermetic
  activation test now asserts the generated Swift carries the exact published
  bytes (base64) and the sidecar's `key_id`.
- **MEDIUM (code) / INFO (security): corpus gaps.** Eight cases added
  (verified GGUF allowing `openai_compatible_loopback`, `verified_at` with a
  time of day, non-null `verified_at` on a `declared` artifact, repeated
  adapter, empty `artifacts`, three trailing-newline values); every harness
  asserts `len(cases) == case_count` so no runner can silently skip cases (55).
- **LOW (security): candidate-row ambiguity by dictionary order.** The row leg
  now applies the same rule as the artifact leg (one key or nothing);
  `testAmbiguousCandidateRowIdentityMintsNoCatalogIdentity`.
- **LOW (security, architect): the live path's `release.json` signer leg.**
  Documented in code only. SPEC-023 v0.10.2 §3.7.2 now scopes the
  `release.json` equality to generation and to consumers that hold the
  manifest; a fetching CLI enforces the two authenticated signers plus, for
  its compiled-in snapshot, the baked manifest-bound signer. The runbook no
  longer credits the coordinator loader with a manifest check.
- **LOW (code): stale sidecar at `generate` time.** Runbook states that a bare
  `generate` bakes the sidecar on disk at that moment and the shippable bake
  is the re-run inside `resign-autotune-static.sh`; `verify` fails drift.
- **Carried, documented in the PR body:** (LOW, code) the v0.1 loader's
  schema-before-policy order changes which of two blocking codes is emitted
  for a schema-invalid AND policy-incompatible v0.1 feed (gating unchanged);
  (LOW, code / INFO, architect, security) the `listed`/`recommendable` row
  gate is a wire-visible discovery change with zero fleet impact today (all
  ten committed rows are `recommendable`); (INFO, security) `catalog_matched`
  remains a local advisory name-level match on the v0.1 row leg with
  `catalog_match_unverified`, and SPEC-047 must keep resolving by verified
  hash; (INFO, code) only the `mlx_cache` and `ollama_loopback` adapters
  consult the matcher (pre-existing v0.1 shape); (INFO, architect) the three
  harnesses assert the same case count but not a shared schema version.

## Closure verification (three fresh cold-context lanes, at `63e7757d`)

| Lane | Verdict (open or new only) |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 2 INFO |
| security-reviewer | 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 4 INFO — **at the bar** |
| architect | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW / 3 INFO |

All three lanes verified every finding above as closed (the architect: one
partially, see the first item). Resolved in the commit that adds this section:

- **MEDIUM (architect):** the name-level row leg pre-empted the artifact leg,
  so every primary artifact was still matched on its repo id alone. Now a
  catalog key the usable feed covers is decided by the artifact leg alone
  (revision / digest required); a key the feed does not cover — every key
  when no usable feed exists — keeps the v0.1 name-level row match (rule 6).
  The record and runbook wording above were corrected accordingly.
- **MEDIUM (code):** MLX snapshot revisions were collected from an unsorted
  first 20 entries. Revisions are now collected over every entry (a name
  test, no I/O) and the bounded directory enumerator sorts its result; the
  discovery test adds 25 older snapshot directories ahead of the artifact's.
- **MEDIUM (architect):** §3.7.6 class 2 and the §3.7.7 R004 signer sentence
  restated the unscoped `release.json` rule; both now carry the §3.7.2
  scoping and cross-reference it (v0.10.2, no further bump; `last-locked`
  advanced to 2026-09-10).
- **LOW (security):** an artifact-feed-only warning flipped every candidate's
  `explanation.warning_state` to `advisory`; the artifact classes are now
  subtracted before that v0.1 verdict (`artifactFeedWarnings`), pinned by
  `testArtifactFeedWarningsLeaveTheCandidateWarningStateUntouched`.
- **LOW (code):** `models adopt-recommendation` skips the artifact fetch
  (`includeArtifactFeed: false`); its inert union is dropped.
- **INFO (code, security):** `generated_at` now goes through the hardened
  whole-string helper; corpus case "generated_at with a trailing newline" (56).
- **INFO (security):** `ArtifactFeed.artifactIdentities()` is fileprivate;
  identities are obtainable only from a `QualifiedArtifactFeed`.
- **INFO (security):** the `manifestSignerKeyID` doc comment now states that
  the manifest leg is enforced at generation and re-asserted here.
- **INFO (architect):** the `catalog-economics` comment no longer says the
  live selection "governs" recommendation.
- **Carried, in the PR body:** (INFO, code) `ArtifactFeed.Model.primary`
  force-unwraps an invariant `decode` guarantees but the type does not;
  (INFO, security) the MLX artifact leg is gated on the observed snapshot
  directory name, not a locally computed hash — the coordinator resolves by
  verified hash; (INFO, architect) three validators reject duplicate adapters
  and whitespace-only `quantization`, which §3.7.3 does not name.
