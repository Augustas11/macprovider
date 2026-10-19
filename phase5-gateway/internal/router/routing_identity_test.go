package router

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

type routingIdentityFakeStore struct {
	Store
	ids []int64
	err error
}

func (s routingIdentityFakeStore) RoutingGitHubIdentities(context.Context, string) ([]int64, error) {
	return s.ids, s.err
}

func TestRoutingIdentityTrustAndFailureStates(t *testing.T) {
	for _, tc := range []struct {
		name string
		ids  []int64
		err  error
		want string
	}{
		{name: "all links", ids: []int64{7, 8}, want: "7,8"},
		{name: "no link", want: "none"},
		{name: "failure", err: errors.New("database unavailable"), want: "unavailable"},
		{name: "invalid persisted identity", ids: []int64{0}, want: "unavailable"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &Server{store: routingIdentityFakeStore{ids: tc.ids, err: tc.err}}
			r := httptest.NewRequest("POST", "/v1/chat/completions", nil)
			r.Header.Set(routingGitHubIDsHeader, "999")
			h := http.Header{}
			copyForwardHeaders(h, r.Header)
			if h.Get(routingGitHubIDsHeader) != "" {
				t.Fatal("client identity forwarded")
			}
			s.setRoutingIdentity(h, r, "account")
			if h.Get(routingGitHubIDsHeader) != tc.want {
				t.Fatalf("got %q want %q", h.Get(routingGitHubIDsHeader), tc.want)
			}
		})
	}
}

func TestRoutingIdentityDatabaseReadsEveryLink(t *testing.T) {
	_, store, _, cfg := newTestHarness(t, fakeOAuth{})
	createAccountAndKey(t, store, cfg, "routing-account")
	for _, id := range []string{"7", "8"} {
		if err := store.AddAccountIdentity(context.Background(), storage.AccountIdentity{AccountID: "routing-account", Provider: "github", ProviderUserID: id, CreatedAt: fixedNow()}); err != nil {
			t.Fatal(err)
		}
	}
	ids, err := store.RoutingGitHubIdentities(context.Background(), "routing-account")
	if err != nil || !reflect.DeepEqual(ids, []int64{7, 8}) {
		t.Fatalf("ids=%v err=%v", ids, err)
	}
	ids, err = store.RoutingGitHubIdentities(context.Background(), "demo:ordinary")
	if err != nil || len(ids) != 0 {
		t.Fatalf("no-link=%v err=%v", ids, err)
	}
}

func TestRoutingIdentityFailureNeverDispatchesOrBills(t *testing.T) {
	calls := 0
	client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { calls++; return responseWithBody(200, nil, `{}`), nil })}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client), func(s *Server) {
		s.store = routingIdentityFakeStore{Store: s.store, err: errors.New("identity DB unavailable")}
	})
	key := createAccountAndKey(t, store, cfg, "lookup-failure")
	rr := postChat(t, h, key, `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if rr.Code != http.StatusServiceUnavailable || calls != 0 {
		t.Fatalf("status=%d calls=%d body=%s", rr.Code, calls, rr.Body.String())
	}
	assertRoutingFailureHasNoBilledTokens(t, dbPath, "lookup-failure")
	snapshot := gatewaySettlementSnapshot(t, dbPath, "lookup-failure")
	if snapshot.settledRows != 0 || snapshot.activeRows != 0 || snapshot.refundedRows != 1 {
		t.Fatalf("lookup failure charged or retained hold: %+v", snapshot)
	}
}

func assertRoutingFailureHasNoBilledTokens(t *testing.T, dbPath, account string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var billed int64
	if err := db.QueryRow(`SELECT COALESCE(SUM(prompt_tokens + completion_tokens),0) FROM usage_events WHERE account_id = ?`, account).Scan(&billed); err != nil || billed != 0 {
		t.Fatalf("billed tokens=%d err=%v", billed, err)
	}
}

// heldWriterStore models the primary store while settlement holds its single
// connection: any identity lookup on it blocks until the caller gives up.
type heldWriterStore struct{ Store }

func (heldWriterStore) RoutingGitHubIdentities(ctx context.Context, _ string) ([]int64, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

type routingIdentityReadStore struct {
	ReadStore
	ids []int64
}

func (s routingIdentityReadStore) RoutingGitHubIdentities(context.Context, string) ([]int64, error) {
	return s.ids, nil
}

func TestRoutingIdentityUsesReadStoreWhileWriterHeld(t *testing.T) {
	s := &Server{store: heldWriterStore{}, readOnlyStore: routingIdentityReadStore{ids: []int64{7}}}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	r := httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx)
	h := http.Header{}
	start := time.Now()
	s.setRoutingIdentity(h, r, "account")
	if got := h.Get(routingGitHubIDsHeader); got != "7" {
		t.Fatalf("routing identity=%q, want 7 from the read store", got)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("routing identity waited %v on the held writer", elapsed)
	}
}
