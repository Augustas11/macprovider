//go:build race

package billing

import "time"

// The race detector instruments the pure-Go SQLite driver, which slows a
// full recovery batch past the 2s production budget. Widen it for -race
// builds only, keeping it below recoverLedgerLeaseTTL (#1996).
func init() {
	recoverLedgerBatchBudget = 10 * time.Second
}
