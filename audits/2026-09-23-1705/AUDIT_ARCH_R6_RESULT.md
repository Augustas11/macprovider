## Raw output (independent fresh-context architect lane; Codex quota exhausted until 2026-09-26)

1. MEDIUM — server.go registerProviderSession: pending marker reused `StateDraining`, and
   the post-recheck promotion `MarkState(admittedState)` could undo a concurrent operator
   drain / blacklist / reject / DrainAll / trust-revalidation drain landing in the window.
   Fix: registry-owned pending flag that never touches State. → FIXED in R6 commit
   (`Provider.CatalogRecheckPending`, `Registry.ClearCatalogRecheckPending`,
   TestCatalogRecheckReleaseKeepsConcurrentDrain).
2. LOW (carried) — buildCompatibleCatalogSet shared release-id/sha namespace.
3. LOW (carried, SPEC-disclosed) — release-level row_continuity coverage.
4. INFO — CONFORMANCE should map registerProviderSession / fenceCatalogDivergedSession. → done.
5. INFO — Package.resolved dirt in worktree → restored, never committed.
All R1–R5 dispositions verified.

VERDICT: C=0 H=0 M=1 L=2
