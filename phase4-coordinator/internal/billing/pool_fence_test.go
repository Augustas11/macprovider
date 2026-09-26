package billing

import (
	"context"
	"strings"
	"sync"
	"testing"
)

// fencedPoolAuthority is a durable pool authority whose pool event high-water
// mark can advance between reads, the way a membership, manifest, or
// lifecycle event would.
type fencedPoolAuthority struct {
	fakePoolAttestationAuthority
	mu         sync.Mutex
	highWaters []int64
	reads      int
}

func (f *fencedPoolAuthority) PoolEventHighWater(_ context.Context, q PoolFenceQueryer, _ string) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if q == nil {
		return 0, nil
	}
	value := f.highWaters[len(f.highWaters)-1]
	if f.reads < len(f.highWaters) {
		value = f.highWaters[f.reads]
	}
	f.reads++
	return value, nil
}

func stableFencedAuthority() *fencedPoolAuthority {
	return &fencedPoolAuthority{highWaters: []int64{7}}
}

// labelsChangingAfter returns the pool's label for the first n reads and a
// moved label afterwards, the way a registry refresh would.
func labelsChangingAfter(n int) SettlementPoolLabelSource {
	var mu sync.Mutex
	reads := 0
	return func(poolID string) (uint64, string, bool) {
		mu.Lock()
		defer mu.Unlock()
		reads++
		if reads > n {
			return 3, strings.Repeat("e", 64), poolID == "pool-abc"
		}
		return 2, strings.Repeat("d", 64), poolID == "pool-abc"
	}
}

func testPoolFence() *PoolAttestationFence {
	return &PoolAttestationFence{PoolID: "pool-abc", PoolEventHighWater: 7, ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64)}
}

// Cancel-fix audit R2: a pool_operator_attested decision is fenced inside the
// ledger write transaction. A pool change between the decision and the
// commit, or trusted pools going off, zero-bills the attempt.
func TestWriteHotPath_PoolAttestationFenceHeldInTransaction(t *testing.T) {
	for name, tc := range map[string]struct {
		authority PoolOperatorAttestationAuthority
		labels    SettlementPoolLabelSource
		fence     *PoolAttestationFence
		wantPaid  bool
	}{
		"unchanged pool is paid":             {stableFencedAuthority(), labelsChangingAfter(1 << 30), testPoolFence(), true},
		"durable pool event before commit":   {&fencedPoolAuthority{highWaters: []int64{8}}, labelsChangingAfter(1 << 30), testPoolFence(), false},
		"manifest label moved before commit": {stableFencedAuthority(), labelsChangingAfter(0), testPoolFence(), false},
		"trusted pools off at commit":        {nil, nil, testPoolFence(), false},
		"no label view at commit":            {stableFencedAuthority(), nil, testPoolFence(), false},
		"decision without a fence":           {stableFencedAuthority(), labelsChangingAfter(1 << 30), nil, false},
	} {
		t.Run(name, func(t *testing.T) {
			reqStore, store := newRequestAndBillingStores(t)
			if tc.authority != nil {
				store.SetPoolOperatorAttestationAuthority(tc.authority)
			}
			if tc.labels != nil {
				store.SetSettlementPoolLabelSource(tc.labels)
			}
			input, row := testHotPathInput(t, store)
			input.ProviderRuntimeSource = "llamacpp_loopback"
			input.PoolOperatorAttested = true
			input.PoolAttestationFence = tc.fence
			if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
				t.Fatal(err)
			}
			var gross, provider, quarantined int64
			var reason *string
			if err := store.db.QueryRow(`SELECT gross_credits, provider_credits, quarantined, quarantine_reason FROM ledger_request_credits WHERE request_id = ?`, row.RequestID).
				Scan(&gross, &provider, &quarantined, &reason); err != nil {
				t.Fatal(err)
			}
			if tc.wantPaid {
				if gross == 0 || provider == 0 || quarantined != 0 {
					t.Fatalf("fenced attested attempt gross=%d provider=%d quarantined=%d, want paid", gross, provider, quarantined)
				}
				return
			}
			if gross != 0 || provider != 0 || quarantined != 1 || reason == nil || *reason != LoopbackRuntimeNotSettlementEligible {
				t.Fatalf("attempt gross=%d provider=%d quarantined=%d reason=%v, want 0/0 quarantined", gross, provider, quarantined, reason)
			}
		})
	}
}
