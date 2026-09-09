# Audit — BYOM v0.2 slice 2a: catalog artifact-feed generator, class rate expansion, ledger v3 (#1453; SPEC-023 v0.10.0 R004/R005)

METHOD CONSTRAINT: first-party software-correctness review of release tooling on the money path (rate card, catalog identity). Do NOT author adversarial payloads. Evaluate by reading source and running the EXISTING tests (`python3 scripts/catalog-release.py verify`, `bash scripts/test-catalog-release.sh`, the new unittest modules, `python3 scripts/check_spec_governance.py`). Describe gaps abstractly (field + condition).

Review the COMPLETE diff `git diff origin/main...HEAD` on branch `feat/byom-v02-slice2a-artifact-feed-generator`. Every file. Cross-check against SPEC-023 v0.10.0 §3.2, §3.3.1, §3.5, §3.7.1–§3.7.8, AC-CAT-1..12/16/18/19, §15; SPEC-047-R003 (0.1.3); SPEC-005 §5.5; and the real generator/verify/sign scripts.

## What the change does
1. Operator-authored artifact source → generator produces the published `autotune-artifacts.json` (§3.7.3 closed shape, release-bound), enforcing the tuple matrix, global hash uniqueness, `artifact_id` grammar + cross-release rebinding check, GGUF digest equality, primary-artifact consistency with candidate rows, `rate_class` on every recommendable key. Seeded with the 10 current rows' primary MLX artifacts.
2. `rate-card-source.json` (never published) with explicit rows + `classes` + release globals; generator expands to the published `rate-card.json` and coordinator fallback rows; first expansion byte-identical (AC-CAT-10).
3. Ledger v3 rows for artifact-bound releases; `release.json` gains the feed; release.json feed-set checks widened to 5; compatibility-set `catalog.files` map UNCHANGED (Stage A). Signer equality enforced at generation; feed added to the sign/verify flow.
4. No release cut: the committed release (4 feeds) still verifies; artifact-feed generation exercised hermetically in a temp release with a throwaway key.

## Invariants to verify (challenge them)
- Candidate-catalog bytes, `release.json`, `release-ledger.json`, and `dist/static/*` are unchanged in this diff; `catalog-release.py verify` on the committed release passes unchanged.
- Stage A: nothing adds the artifact feed to `components.catalog.files`; the exact nine-name set is asserted by a test; the deployed updater (`CompatibilitySetManifest.swift`) is untouched.
- Money path: the expanded rate-card `rows` and coordinator fallback rows are byte-identical to today's (prove via the test, not prose); precedence explicit-row > class; class rows carry only the three credit fields; globals equal coordinator globals; a recommendable key without a resolvable rate row fails generation, never falls to `default`; the published rate-card `version` projection (§3.3) still holds.
- Artifact feed: closed schema at every level; every illegal tuple rejected; duplicate `(algorithm, hash)` under two keys rejected; `artifact_id` grammar; rebinding across releases rejected with the previous feed as a named input (and the first-release case defined); GGUF `source_ref.digest` equality; `candidate` rows may be `declared`, `listed`/`recommendable` primaries must be `verified` and equal the candidate row; signer key id equality with the candidate feed.
- Ledger v3: exact row shape, canonical ordering, uniqueness, v1/v2 untouched, downgrade fails closed; `intake_decision_sha256` null only when no add/promote.
- No operator secret, key material, or private path in the diff; throwaway test keys are generated at test time, not committed.
- Test adequacy: each AC-CAT case named above maps to a real test that would fail if the check were removed.

## Lanes to report (this pass is: {{LANE}})
CRITICAL / HIGH / MEDIUM / LOW / INFO; merge bar 0 C / 0 H / 0 M.
- code-reviewer: generator correctness, schema closure, byte-identity proof, test adequacy, verify-path parity.
- security-reviewer: catalog identity/settlement binding integrity, rate mis-declaration, artifact substitution, signer/key handling, secret hygiene.
- architect: SPEC-023 §3.7/§3.3.1 fidelity, Stage A discipline, source-vs-published separation, single source of truth for enums/bounds, whether the first artifact-bound release cut is cleanly separated from this change.

End with `VERDICT: <N> CRITICAL / <N> HIGH / <N> MEDIUM / <N> LOW / <N> INFO`. Cite file:line. Do not invent issues to fill a lane.
