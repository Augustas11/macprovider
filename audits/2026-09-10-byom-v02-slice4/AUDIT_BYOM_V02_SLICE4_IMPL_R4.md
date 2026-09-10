# AUDIT — BYOM v0.2 slice 4 IMPL round 4 (codex, code-reviewer + architect; security at bar since R2)

Prompt: `AUDIT_BYOM_V02_SLICE4_IMPL_PROMPT.md` (ROUND 4 EXTRA). Diff: `git diff origin/main` at `149a564a` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 0 INFO |
| architect | 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO (at bar) |

R3 fixes confirmed by both lanes (publish → refresh → sweep; epoch on refresh; feed commit last in the hold; model-id-only epoch).

**MEDIUM — the SIGHUP feed observer loaded the retained previous releases from boot-time `cfg.AutotuneFeeds`** (code). A reload that moves the feed root, `.previous-target` or keyring would publish the reload's catalogs with previous-release identity sets from the old configuration. Fix: `buyer.LoadAutotuneFeeds` records the configuration it loaded from (`AutotuneFeeds.SourceConfig`); the observer resolves the previous releases from `feeds.SourceConfig` (boot cfg only as a fallback for feeds not produced by the loader). `reloadCoordinatorConfig` (conformance-mapped) is untouched. Test: `TestLoadAutotuneFeedsRecordsSourceConfig`.

Anchored loop closed at four rounds (R1 3 lanes → R2 3 lanes → R3/R4 code + architect; security at bar since R2; architect at bar at R4; code at bar after this fix by construction, to be confirmed by the closure pass after the independent cold-context review).
