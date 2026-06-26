CLOSURE on round-1 findings:
  M1 (MEDIUM): PASS - Providers no longer performs per-provider `h.sum` for `pending_payout_credits`; the value is folded into the page query through a grouped `LEFT JOIN` over `ledger_payout_ready` at `phase4-coordinator/internal/billing/endpoints.go:145-164`, with scan/error handling at `endpoints.go:172-198` and regression coverage at `phase4-coordinator/internal/billing/nested_query_regression_test.go:81-147`.
  L1: PASS - SPEC-005 now documents the cross-store pool cap and the nested-cursor / in-transaction helper prohibitions directly under §10.1 next to the WAL and recovery-snapshot clause at `specs/SPEC-005-billing.md:708-717`; this is the right placement because it is part of the transaction/SQLite operational contract, not a separate feature surface.
  L2: PASS - The pool-cap assertion now lives in `phase4-coordinator/internal/requestlog/store_test.go:597-611`, beside the constructor that sets `MaxOpenConns(1)` / `MaxIdleConns(1)` at `phase4-coordinator/internal/requestlog/store.go:60-72`; the billing regression tests remain in `internal/billing` and explicitly defer cap ownership to requestlog at `nested_query_regression_test.go:34-38`.
  Q1: PARTIAL - The code does not creep toward a gateway-style read-only handle, which is correct for this PR, but I found no open PR for branch `fix/arc-3-nested-queries` (`gh pr view` and `gh pr list --head fix/arc-3-nested-queries` returned none) and no follow-up row in `docs/OPEN_QUESTIONS.md` / `beta/DECISION_CRITERIA.md`; the deferral remains only in the round-1 audit / R2 prompt context.

NEW FINDINGS (round 2):
CRITICAL (0): none
HIGH (0): none
MEDIUM (0): none
LOW (0): none
QUESTIONS (0): none

Architectural notes:
- The grouped `LEFT JOIN` in providers is the right architectural shape, not just a local SQL patch. `endpoints.go` already owns billing-ledger presentation queries, and `ledger_payout_ready` is a billing-owned table queried elsewhere in the same handler (`lastPayout`), so the join does not cross a module boundary. It also restores the rule that directly joinable aggregates stay in SQL, while two-pass drain-then-process is reserved for the remaining places that need application-layer work (`rebuildLegacyConfigSnapshots` at `store.go:181-238` and `buyerEquivalentCredits` at `endpoints.go:279-360`).
- `snapshotQueryer` remains at the right altitude: a package-private one-method interface in `snapshot.go:64-82` that exists only to let the same snapshot lookup run against either `*sql.DB` or the already-pinned `*sql.Tx`. Round 2 did not broaden it into a repository/query abstraction.
- The round-1 LOWs were not enshrined as anti-patterns. The requestlog cap ownership moved to requestlog tests, and the two-pass pattern is documented as a cap=1 deadlock escape hatch rather than a default aggregate strategy.

Verification:
- `go test ./internal/billing ./internal/requestlog` from `phase4-coordinator` passed.
