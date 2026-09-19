# Audit — OpenRouter listed intake (`published-2026-09-19-openrouter-listed-v1`)

**Branch:** `catalog/openrouter-listed-nine` · **Release:** `published-2026-09-19-openrouter-listed-v1`

## Codex lanes

`omc ask codex` for code-reviewer, security-reviewer, and architect all failed with Codex usage limit (retry after 23:38 local). No lane produced a findings report.

## Local checks that did run

- `python3 scripts/catalog-release.py verify` — pass on this release.
- `bash scripts/test-catalog-release.sh` — pass.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_catalog_artifact_feed` — pass.
- `bash scripts/test-autotune-gate-matrix.sh` — pass.
- `go test ./internal/buyer -run 'TestAutotune|TestLiveVerified|TestCatalog'` — pass.
- Swift catalog filters: 343 tests, 0 failures.
- Rate-card `rows` stay 12; coordinator.yaml untouched; 7 new keys are `listed` / demand `recommendable: false`.
- Sidecars signed with `streamvc-autotune-static-v4`; no secrets in the diff.

Re-run the three Codex lanes after the usage window if a written 0 C/H/M report is required before merge.
