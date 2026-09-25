package buyer

import (
	"context"
	"sync/atomic"
)

// Test hooks exported to the external buyer_test package (compiled only
// into tests).

// SetSettlementOutputWriteErrForTest fails the first try of every
// settlement-output write with err.
func SetSettlementOutputWriteErrForTest(err error) (restore func()) {
	prev := settlementOutputWriteErrForTest
	settlementOutputWriteErrForTest = err
	return func() { settlementOutputWriteErrForTest = prev }
}

// CancelSettlementOutputWritesForTest cancels the context of the first n
// settlement-output write tries, a transient failure after the credit.
func CancelSettlementOutputWritesForTest(n int) (restore func()) {
	prev := settlementOutputWriteContextForTest
	var seen atomic.Int64
	settlementOutputWriteContextForTest = func(_ int, ctx context.Context) context.Context {
		if seen.Add(1) <= int64(n) {
			dead, cancel := context.WithCancel(ctx)
			cancel()
			return dead
		}
		return ctx
	}
	return func() { settlementOutputWriteContextForTest = prev }
}
