package billing

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// fencedPoolAuthority is a durable pool authority whose route fence can stop
// holding between reads, the way a membership revocation, a pool
// retirement, or a removed member attestation would.
type fencedPoolAuthority struct {
	fakePoolAttestationAuthority
	mu      sync.Mutex
	results []error
	reads   int
	claims  []PoolOperatorAttestationClaim
}

func (f *fencedPoolAuthority) PoolRouteFenceHolds(_ context.Context, q PoolFenceQueryer, claim PoolOperatorAttestationClaim) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if q == nil {
		return fmt.Errorf("no queryer")
	}
	f.claims = append(f.claims, claim)
	result := f.results[len(f.results)-1]
	if f.reads < len(f.results) {
		result = f.results[f.reads]
	}
	f.reads++
	return result
}

func stableFencedAuthority() *fencedPoolAuthority {
	return &fencedPoolAuthority{results: []error{nil}}
}

// labelsChangingAfter returns the pool's label for the first n reads and a
// later generation afterwards, the way a registry refresh after an ordinary
// manifest rotation would.
func labelsChangingAfter(n int) SettlementPoolLabelSource {
	return labelsMovingTo(n, 3, strings.Repeat("e", 64))
}

// labelsMovingTo returns generation 2 for the first n reads and the given
// label afterwards.
func labelsMovingTo(n int, version uint64, digest string) SettlementPoolLabelSource {
	var mu sync.Mutex
	reads := 0
	return func(poolID string) (uint64, string, bool) {
		mu.Lock()
		defer mu.Unlock()
		reads++
		if reads > n {
			return version, digest, poolID == "pool-abc"
		}
		return 2, strings.Repeat("d", 64), poolID == "pool-abc"
	}
}

func testPoolFence() *PoolAttestationFence {
	return &PoolAttestationFence{Claim: PoolOperatorAttestationClaim{
		PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64),
		RuntimeSource: "llamacpp_loopback", PoolGeneration: 7, PoolOperatorAccountID: "creator", ProviderID: "provider-1",
	}}
}

// SPEC-042-R015 / SPEC-047-R011 (#1816 F2): a pool settlement decision is
// fenced inside the ledger write transaction against the durable revocation
// records, not the current manifest version. Ordinary rotation after the
// decision still pays; a revocation, a rolled-back or same-generation
// different label, or trusted pools going off before the commit zero-bills.
func TestWriteHotPath_PoolAttestationFenceHeldInTransaction(t *testing.T) {
	revoked := fmt.Errorf("%w: provider membership revoked since routing", ErrPoolOperatorAttestationRejected)
	for name, tc := range map[string]struct {
		authority PoolOperatorAttestationAuthority
		labels    SettlementPoolLabelSource
		fence     *PoolAttestationFence
		wantPaid  bool
	}{
		"unchanged pool is paid":                    {stableFencedAuthority(), labelsChangingAfter(1 << 30), testPoolFence(), true},
		"manifest rotated before commit is paid":    {stableFencedAuthority(), labelsChangingAfter(0), testPoolFence(), true},
		"revocation before commit":                  {&fencedPoolAuthority{results: []error{revoked}}, labelsChangingAfter(1 << 30), testPoolFence(), false},
		"same generation, other digest at commit":   {stableFencedAuthority(), labelsMovingTo(0, 2, strings.Repeat("f", 64)), testPoolFence(), false},
		"earlier generation at commit (rollback)":   {stableFencedAuthority(), labelsMovingTo(0, 1, strings.Repeat("f", 64)), testPoolFence(), false},
		"trusted pools off at commit":               {nil, nil, testPoolFence(), false},
		"no label view at commit":                   {stableFencedAuthority(), nil, testPoolFence(), false},
		"decision without a fence":                  {stableFencedAuthority(), labelsChangingAfter(1 << 30), nil, false},
		"authority without the durable route fence": {&fakePoolAttestationAuthority{}, labelsChangingAfter(1 << 30), testPoolFence(), false},
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
				if fenced, ok := tc.authority.(*fencedPoolAuthority); ok && (len(fenced.claims) == 0 || fenced.claims[0] != tc.fence.Claim) {
					t.Fatalf("fence re-read claims=%+v, want the route-time claim %+v", fenced.claims, tc.fence.Claim)
				}
				return
			}
			if gross != 0 || provider != 0 || quarantined != 1 || reason == nil || *reason != LoopbackRuntimeNotSettlementEligible {
				t.Fatalf("attempt gross=%d provider=%d quarantined=%d reason=%v, want 0/0 quarantined", gross, provider, quarantined, reason)
			}
		})
	}
}

// The label comparison of SPEC-042-R006 treats a later accepted generation as
// ordinary rotation (#1816 F2) and still disputes every real mismatch.
func TestSettlementPoolLabelStatusRotation(t *testing.T) {
	route := RouteSnapshot{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64)}
	for name, tc := range map[string]struct {
		labels *SettlementPoolLabels
		want   string
	}{
		"same generation":               {&SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64), RouteSnapshotHash: "h"}, PoolLabelStatusVerified},
		"later generation (rotation)":   {&SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 5, ManifestCoreDigest: strings.Repeat("e", 64), RouteSnapshotHash: "h"}, PoolLabelStatusVerified},
		"same generation, other digest": {&SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("e", 64), RouteSnapshotHash: "h"}, PoolLabelStatusDisputed},
		"earlier generation":            {&SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 1, ManifestCoreDigest: strings.Repeat("e", 64), RouteSnapshotHash: "h"}, PoolLabelStatusDisputed},
		"other pool":                    {&SettlementPoolLabels{PoolID: "pool-xyz", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64), RouteSnapshotHash: "h"}, PoolLabelStatusDisputed},
		"other route snapshot hash":     {&SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 3, ManifestCoreDigest: strings.Repeat("e", 64), RouteSnapshotHash: "x"}, PoolLabelStatusDisputed},
		"no settlement view":            {nil, PoolLabelStatusUnverified},
	} {
		if got := settlementPoolLabelStatus(route, "h", tc.labels); got != tc.want {
			t.Errorf("%s: status=%q, want %q", name, got, tc.want)
		}
	}
}
