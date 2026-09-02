# Audit result — admit gpt-oss-120b to the SPEC-023 autotune model catalog

**Branch:** `catalog/gpt-oss-120b` · **Release:** `published-2026-09-02-gpt-oss-120b-v1`
**Gate:** 3-lane codex (gpt-5.5) over the full staged diff. **Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM — MET.**

| Lane | C | H | M | L | Verdict |
|---|---|---|---|---|---|
| Code review | 0 | 0 | 0 | 0 | APPROVE |
| Security | 0 | 0 | 0 | 1 | Clear |
| Architecture | 0 | 0 | 0 | 0 | Clear |

## Independent verification performed by the auditors
- Re-derived the artifact_manifest sha256 from HuggingFace LFS pointer metadata for revision `08e7899579b5dd5e0364e4bcd32578134072e22d` → `5003c9196bd6664b22227d687472ba2eb50c2c4daa224b36c230edbbe36b18fb` (matches the staged value). Release-time full-download re-hash remains the authority.
- Ran `catalog-release.py verify`, `test-catalog-release.sh`, `go test ./internal/billing ./internal/buyer ./internal/autotune`, and the Swift `AutotuneRecommend*`/`ConsumeTrustedPricing` suites — all passed.
- Confirmed source feeds ↔ `dist/static` ↔ baked `AutotuneCatalog.generated.swift` are byte-identical; ledger append preserves history; tier2 feed member still declared+authenticated.
- Confirmed `mlx-community/gpt-oss-120b-4bit` normalizes to rate-card key `openai/gpt-oss-120b` in both Go (`formula.go`) and Swift, so it never falls back to the higher `default` rate.

## Carried LOW (non-blocking, ships documented)
Swift's local model-key normalizer (`AutotuneRecommend.swift:1493`) is broader than the coordinator's Go normalizer (`formula.go:80`, `servedAliasNamespace`): a foreign namespace such as `qwen/gpt-oss-120b-4bit` could be normalized to `openai/gpt-oss-120b` by a **local Swift pricing consumer**. Not introduced by this change and not exploitable for this admission (admitted id is `mlx-community/...`; the coordinator route/billing path is namespace-scoped). Follow-up: align Swift normalization with Go's `servedAliasNamespace` rule.

## Pre-merge action
Rebase onto current `origin/main` (branch was ~5 commits behind at audit time; upstream commits do not overlap the catalog/release files) so the signed release artifacts are the final landing state.
