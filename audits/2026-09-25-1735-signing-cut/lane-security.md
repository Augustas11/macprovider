# Audit: #1735 signing cut (catalog artifact-hash correction), branch catalog/1735-hash-correction

Repository: /Users/augstar/macprovider-1735-sign (git worktree). Review the FULL diff `git diff origin/main...HEAD` (one commit). Read-only: do NOT edit any file.

Context:
- Issue #1735: 8 signed catalog rows carry a `model_sha256` that no correct download of the pinned HF revision can produce. PR #1739 (merged) added `scripts/catalog-hash-sweep.py` and recorded `audits/2026-09-24-1735-catalog-hash-sweep/sweep.json` + an unsigned source patch.
- This commit is the signing cut (#1735 step 2): applies that patch to `autotune-artifacts-source.json`, sets `model_sha256` of the same 8 rows in `autotune-candidates.json` (notes updated), restamps to release `published-2026-09-25-artifact-hash-correction-v1`, re-signs Tier-2 (`tier2-catalog.json`, new catalog_id, issued 2026-09-25, expires 2026-12-25, key `tier2-coordinator-key:707a860299e6a37f`), and regenerates+re-signs static feeds via `scripts/resign-autotune-static.sh` (v4 key) which also rewrites release.json, release-ledger.json (append), tier2-identity-binding.json, AutotuneCatalog.generated.swift.
- Test changes: release id bumps; hermetic harness release dates moved 2026-09-24->26 and 09-25->27 (must stay newer than the committed release); gemma hash in tier2-llama-conflict-template.json testdata; expected ledger history.
- docs/releases/coordinator-release-train.md: rows for #1738, #1741 (previously missing) and this cut, reserving v1.8.194. Ships via a Pearl runtime cut, not the content lane (content-lane evidence (e) is NO_GO for re-hashed buyer-serving rows; see docs/runbooks/catalog-release-decision-tree.md).
- Verified locally: `python3 scripts/catalog-release.py verify` OK; `bash scripts/test-catalog-release.sh` PASS; test_catalog_artifact_feed + test_catalog_content_gate 222 OK; go test ./internal/buyer ./internal/autotune OK; deploy_catalog_* dist tests OK.

Independently check that every new hash equals `recomputed_sha256` in sweep.json for the matching row, that no MATCH row changed, that Tier-2 entries equal the candidate rows (model_id + sha256 + min_ram_gb), and that no other semantic field (pricing, runtime_status, min_ram, bench_gate, revisions, rate card rows) changed.

Output: findings as CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line and concrete failure scenario. End with a line `VERDICT: C=<n> H=<n> M=<n> L=<n>`.

## Lane: SECURITY REVIEW
Trust chain: signatures verify against trusted keys, signer ids unchanged, no key material committed, Tier-2 binding / buyer strict-pin identity cannot be widened, hash provenance is from an auditable source (sweep.json) not operator assertion, no downgrade/rollback path opened in ledger or rejected releases.
