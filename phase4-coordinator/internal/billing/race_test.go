//go:build race

package billing

import "time"

// raceEnabled lets the heaviest tests scale their sizes under -race. They
// still run every code path and assertion; only repetitions shrink.
const raceEnabled = true

// The race detector instruments the pure-Go SQLite driver, and a full
// 128-row recovery batch then overruns the 2s production budget on a CI
// runner. 10s still sits below the 15s recovery lease TTL, so a batch can
// never outlive its lease.
func init() {
	recoverLedgerBatchBudget = 10 * time.Second
}
