package routing_test

import (
	"context"
	"errors"
	"math"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// TestRetryHeaderLimit pins the buyer-header parser extracted into
// routing/retry.go in #266 T2.

func TestRetryHeaderLimit_Empty(t *testing.T) {
	if got := routing.RetryHeaderLimit(""); got != 0 {
		t.Fatalf("empty header → 0; got %d", got)
	}
}

func TestRetryHeaderLimit_Whitespace(t *testing.T) {
	if got := routing.RetryHeaderLimit("   "); got != 0 {
		t.Fatalf("whitespace header → 0; got %d", got)
	}
}

func TestRetryHeaderLimit_TrueIsMaxInt(t *testing.T) {
	if got := routing.RetryHeaderLimit("true"); got != math.MaxInt {
		t.Fatalf("'true' → MaxInt; got %d", got)
	}
	if got := routing.RetryHeaderLimit("TRUE"); got != math.MaxInt {
		t.Fatalf("'TRUE' → MaxInt (case-insensitive); got %d", got)
	}
}

func TestRetryHeaderLimit_PositiveInteger(t *testing.T) {
	if got := routing.RetryHeaderLimit("3"); got != 3 {
		t.Fatalf("'3' → 3; got %d", got)
	}
}

func TestRetryHeaderLimit_ZeroAndNegativeReturnZero(t *testing.T) {
	if got := routing.RetryHeaderLimit("0"); got != 0 {
		t.Fatalf("'0' → 0; got %d", got)
	}
	if got := routing.RetryHeaderLimit("-2"); got != 0 {
		t.Fatalf("'-2' → 0; got %d", got)
	}
}

func TestRetryHeaderLimit_GarbageReturnsZero(t *testing.T) {
	if got := routing.RetryHeaderLimit("abc"); got != 0 {
		t.Fatalf("'abc' → 0; got %d", got)
	}
}

// TestShouldRetry pins each gate in the policy extracted into
// routing/retry.go in #266 T2. Each case fails ONE gate so a
// regression trips one targeted test.

func baseInput() routing.ShouldRetryInput {
	return routing.ShouldRetryInput{
		MaxRetries:             3,
		RequestedRetries:       3,
		HasPinnedRoute:         false,
		ContextErr:             nil,
		ExplicitRetries:        0,
		FaultedProviders:       0,
		MaxFaultedPerRequest:   0,
		Now:                    time.Unix(1_700_000_000, 0),
		StartedAt:              time.Unix(1_700_000_000, 0),
		RequestTimeout:         60 * time.Second,
		RetryPerAttemptTimeout: 5 * time.Second,
		Status:                 http.StatusBadGateway,
		Err:                    nil,
	}
}

func TestShouldRetry_BaseCaseAllows(t *testing.T) {
	if !routing.ShouldRetry(baseInput()) {
		t.Fatalf("base case must allow")
	}
}

func TestShouldRetry_MaxRetriesZeroDenies(t *testing.T) {
	in := baseInput()
	in.MaxRetries = 0
	if routing.ShouldRetry(in) {
		t.Fatalf("MaxRetries=0 → no retry")
	}
}

func TestShouldRetry_RequestedRetriesZeroDenies(t *testing.T) {
	in := baseInput()
	in.RequestedRetries = 0
	if routing.ShouldRetry(in) {
		t.Fatalf("RequestedRetries=0 → no retry")
	}
}

func TestShouldRetry_PinnedRouteDenies(t *testing.T) {
	in := baseInput()
	in.HasPinnedRoute = true
	if routing.ShouldRetry(in) {
		t.Fatalf("pinned route → no retry")
	}
}

func TestShouldRetry_CancelledContextDenies(t *testing.T) {
	in := baseInput()
	in.ContextErr = context.Canceled
	if routing.ShouldRetry(in) {
		t.Fatalf("cancelled context → no retry")
	}
}

func TestShouldRetry_ExplicitRetriesAtCapDenies(t *testing.T) {
	in := baseInput()
	in.ExplicitRetries = 3 // equals min(MaxRetries=3, RequestedRetries=3)
	if routing.ShouldRetry(in) {
		t.Fatalf("at-cap explicit retries → no retry")
	}
}

func TestShouldRetry_RequestedCapTighterThanOperatorCap(t *testing.T) {
	in := baseInput()
	in.MaxRetries = 10      // operator cap loose
	in.RequestedRetries = 1 // buyer cap tight
	in.ExplicitRetries = 1  // at buyer cap, NOT at operator cap
	if routing.ShouldRetry(in) {
		t.Fatalf("buyer-cap-tighter case must take the min")
	}
}

func TestShouldRetry_FaultCapAtCapDenies(t *testing.T) {
	in := baseInput()
	in.MaxFaultedPerRequest = 2
	in.FaultedProviders = 2
	if routing.ShouldRetry(in) {
		t.Fatalf("at-fault-cap → no retry")
	}
}

func TestShouldRetry_FaultCapZeroIsDisabled(t *testing.T) {
	in := baseInput()
	in.MaxFaultedPerRequest = 0
	in.FaultedProviders = 999
	if !routing.ShouldRetry(in) {
		t.Fatalf("MaxFaultedPerRequest=0 disables the cap; should allow")
	}
}

func TestShouldRetry_TimeBudgetExhaustedDenies(t *testing.T) {
	in := baseInput()
	in.Now = in.StartedAt.Add(58 * time.Second)
	// Now-StartedAt=58s + RetryPerAttemptTimeout=5s = 63s > 60s budget
	if routing.ShouldRetry(in) {
		t.Fatalf("time-budget exhausted → no retry")
	}
}

func TestShouldRetry_TimeBudgetZeroIsDisabled(t *testing.T) {
	in := baseInput()
	in.RequestTimeout = 0
	in.Now = in.StartedAt.Add(24 * time.Hour)
	if !routing.ShouldRetry(in) {
		t.Fatalf("RequestTimeout=0 disables the gate; should allow")
	}
}

func TestShouldRetry_NonRetryableStatusDenies(t *testing.T) {
	in := baseInput()
	in.Status = http.StatusOK
	if routing.ShouldRetry(in) {
		t.Fatalf("200 OK → no retry")
	}
}

func TestShouldRetry_GatewayTimeoutAllows(t *testing.T) {
	in := baseInput()
	in.Status = http.StatusGatewayTimeout
	if !routing.ShouldRetry(in) {
		t.Fatalf("504 → allow retry")
	}
}

func TestShouldRetry_ErrTrumpsStatus(t *testing.T) {
	// When err is non-nil, status is ignored and retry fires.
	in := baseInput()
	in.Status = http.StatusOK
	in.Err = errors.New("dial timeout")
	if !routing.ShouldRetry(in) {
		t.Fatalf("non-nil err → allow retry regardless of status")
	}
}
