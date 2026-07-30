# AUDIT — Issue #281 — CODE lane

## Goal
CODE-quality audit on commit `d748326` (branch `fix/iss281-ac18-timing-flake`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope (read only these files)

- `phase4-coordinator/internal/stats/handlers_integration_test.go` lines 928-1015 — `TestAC18_TimingEquivalenceRows5_6_7`, the `measure` closure, the `max3d`/`min3d` helpers that follow. Confirm `sortDurations` is genuinely removed (no callers anywhere in the stats package).

## Context

`TestAC18_TimingEquivalenceRows5_6_7` flaked on shared CI runners with the median-of-100 estimator at ~30% variance. PR #277 (2026-06-30) and PR #280 (2026-06-30) both hit the same failure within 24h on PRs that touched zero stats code. Issue #281 (filed today) records the evidence.

The fix replaces median with the MINIMUM of 100 samples (handler-floor execution time). Min is genuinely noise-robust because ambient runner noise (GC, page-cache, container throttling) can only push timings UP, never DOWN.

## Lens — CODE

- Is `sortDurations` truly unreferenced after this PR? grep the package.
- Is `minSample` initialization correct? The PR uses `if i == 0 || elapsed < minSample` rather than seeding with `math.MaxInt64` — verify this is bug-free.
- Variable names `med5/med6/med7` are kept but now hold MIN, not median. Is the maintenance cost (cognitive dissonance) worth the smaller diff? Or should they be renamed `min5/min6/min7`?
- Does the comment block accurately explain the choice? Are there factual errors?
- Does the error message ("AC-18 floor-timing variance >20%") still parse cleanly with the existing field labels (`row5=%v row6=%v row7=%v`)?
- Are the unused-import guards clean (no `time` import left dangling)?

## Out of scope

- Security analysis (SECURITY lane) — bypass paths, real-vs-noise timing leaks
- Architectural placement (ARCHITECT lane) — is min the right statistic for this kind of test

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why>
Recommendation: <concrete fix>
```

End: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
