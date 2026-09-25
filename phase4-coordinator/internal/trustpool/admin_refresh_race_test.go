package trustpool_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// #1690 VM e2e F-5: an admin event races the periodic registry refresher.
// The refresher can publish the event's revision (or a newer one) between
// the handler's revision check and its load. That is not a failure: the
// event is durable and already published, so the handler must answer 202
// and must not disable routing for every pool.
func TestAdminHandler_RefresherRaceIsNotARefreshFailure(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)

	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for ctx.Err() == nil {
			_, _ = trustpool.RefreshRegistry(ctx, store, registry)
		}
	}()
	var failures []string
	for i := 0; i < 50; i++ {
		body, err := json.Marshal(trustpool.DurableEvent{
			EventType:      trustpool.EventBuyerAuthorized,
			PoolID:         root.poolID,
			BuyerAccountID: fmt.Sprintf("acct-%03d", i),
		})
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer operator-secret")
		req.Header.Set("Idempotency-Key", fmt.Sprintf("op-buyer-%03d", i))
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusAccepted {
			failures = append(failures, fmt.Sprintf("event %d: %d %s", i, rec.Code, rec.Body.String()))
		}
		// A disabled registry drops every pool until the next refresh.
		if !registry.Snapshot(root.poolID).Exists {
			failures = append(failures, fmt.Sprintf("event %d: registry disabled", i))
		}
	}
	cancel()
	wg.Wait()
	if len(failures) > 0 {
		t.Fatalf("%d admin events failed under a concurrent refresher, first: %s", len(failures), failures[0])
	}
}

// The locked publish is a no-op success for a revision the registry already
// holds or has passed, and replaces it for a newer one.
func TestRegistryPublishRouteableSnapshotsIfAheadIsIdempotent(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	current := []trustpool.RouteableSnapshot{{PoolID: "pool-a", BuyerAccounts: []string{"acct-a"}, SettlementMode: "observe", Routeable: true, Generation: 2}}
	if err := registry.PublishRouteableSnapshotsIfAhead(2, current); err != nil {
		t.Fatalf("fresh publish: %v", err)
	}
	for _, revision := range []uint64{1, 2} {
		if err := registry.PublishRouteableSnapshotsIfAhead(revision, []trustpool.RouteableSnapshot{
			{PoolID: "pool-a", BuyerAccounts: []string{"acct-stale"}, SettlementMode: "observe", Routeable: true, Generation: 1},
		}); err != nil {
			t.Fatalf("revision %d at current 2: %v, want a no-op success", revision, err)
		}
		if !registry.BuyerAuthorized("pool-a", "acct-a") || registry.BuyerAuthorized("pool-a", "acct-stale") || registry.Revision() != 2 {
			t.Fatalf("revision %d at current 2 replaced the registry", revision)
		}
	}
	if err := registry.PublishRouteableSnapshotsIfAhead(3, []trustpool.RouteableSnapshot{
		{PoolID: "pool-a", BuyerAccounts: []string{"acct-b"}, SettlementMode: "observe", Routeable: true, Generation: 3},
	}); err != nil || !registry.BuyerAuthorized("pool-a", "acct-b") || registry.Revision() != 3 {
		t.Fatalf("newer revision: err=%v, want it published", err)
	}
}
