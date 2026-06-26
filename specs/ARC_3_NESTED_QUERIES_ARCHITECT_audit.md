CRITICAL (0):

HIGH (0):

MEDIUM (1):
  M1. Providers endpoint preserves a directly joinable N+1 aggregate as the new nested-query pattern
      Evidence: phase4-coordinator/internal/billing/endpoints.go:147 builds the per-provider aggregate from `ledger_request_credits`, but phase4-coordinator/internal/billing/endpoints.go:198 still runs one `h.sum(...)` per provider for `ledger_payout_ready`; phase4-coordinator/internal/billing/store.go:100 and phase4-coordinator/internal/billing/store.go:119 show `ledger_payout_ready` has the provider/status shape needed for a grouped join or CTE.
      Fix:     Fold `pending_payout_credits` into the provider SELECT with a grouped `ledger_payout_ready` subquery/CTE, and reserve two-pass drain-then-process for sites that truly need app-layer work.

LOW (2):
  L1. Connection-cap policy is code-consistent but under-documented as a cross-store invariant
      Evidence: phase4-coordinator/internal/auth/tokens.go:217, phase4-coordinator/internal/audit/store.go:36, and phase4-coordinator/internal/requestlog/store.go:60 each document and set the cap locally; phase4-coordinator/cmd/coordinator/main.go:66 and phase4-coordinator/cmd/coordinator/main.go:88 route production billing through the requestlog-owned handle; specs/SPEC-005-billing.md:715 and specs/SPEC-005-billing.md:976 normatively require WAL but do not mention the pool-cap discipline.
      Fix:     Add a one-line SPEC-005 operational note that coordinator SQLite write handles use `MaxOpenConns(1)`/`MaxIdleConns(1)`; do not add a shared helper unless another production store repeats the policy.

  L2. Requestlog cap assertion is housed in billing tests instead of the package that owns the cap
      Evidence: phase4-coordinator/internal/billing/nested_query_regression_test.go:37 asserts `requestlog.OpenStore` pool policy, while phase4-coordinator/internal/requestlog/store.go:47 owns the constructor and phase4-coordinator/internal/requestlog/store.go:70 sets the cap.
      Fix:     Move or duplicate the pool-stats assertion into `internal/requestlog/store_test.go`, while keeping the nested-cursor deadlock regressions in `internal/billing/`.

QUESTIONS (1):
  Q1. Should coordinator adopt the gateway's separate read-only handle pattern if explorer/admin read traffic becomes high-volume?
      Evidence: phase4-coordinator/cmd/coordinator/main.go:66, phase4-coordinator/cmd/coordinator/main.go:88, and phase4-coordinator/cmd/coordinator/main.go:128 pass the same requestlog-owned capped handle into billing and explorer surfaces; phase5-gateway/internal/storage/sqlite/store.go:52 documents a separate read-only handle to avoid slow reads blocking the capped writer pool.
      Fix:     Leave this PR on cap=1 unless production expects sustained read-heavy coordinator traffic; otherwise plan a separate read-only handle follow-up.
