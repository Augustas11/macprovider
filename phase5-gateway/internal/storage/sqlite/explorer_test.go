package sqlite

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestExplorerSQLiteBuyerCursorAndHashPrivacy(t *testing.T) {
	store := newExplorerSQLiteStore(t)
	seedExplorerSQLiteBuyer(t, store, "acct_a", "a@x")
	seedExplorerSQLiteBuyer(t, store, "acct_b", "b@x")

	list, err := store.ExplorerListBuyers(context.Background(), storage.ExplorerBuyerQuery{
		From: fixedExplorerSQLiteTime().Add(-time.Hour), To: fixedExplorerSQLiteTime().Add(time.Hour), Limit: 1,
	})
	if err != nil {
		t.Fatalf("ExplorerListBuyers: %v", err)
	}
	if len(list.Items) != 1 || list.NextCursor == nil {
		t.Fatalf("list=%+v", list)
	}
	next, err := store.ExplorerListBuyers(context.Background(), storage.ExplorerBuyerQuery{
		From: fixedExplorerSQLiteTime().Add(-time.Hour), To: fixedExplorerSQLiteTime().Add(time.Hour), Limit: 1, Cursor: *list.NextCursor,
	})
	if err != nil {
		t.Fatalf("ExplorerListBuyers cursor: %v", err)
	}
	if len(next.Items) != 1 || next.Items[0].AccountID == list.Items[0].AccountID {
		t.Fatalf("cursor did not advance: first=%+v next=%+v", list.Items, next.Items)
	}
	if len(next.Items[0].APIKeys) != 1 || next.Items[0].APIKeys[0].KeyHashPrefix == "" {
		t.Fatalf("api key prefix missing: %+v", next.Items[0].APIKeys)
	}
}

func TestExplorerSQLiteActivityCursorsAcrossSources(t *testing.T) {
	store := newExplorerSQLiteStore(t)
	seedExplorerSQLiteBuyer(t, store, "acct_usage", "usage@x")
	seedExplorerSQLiteUsage(t, store, "acct_usage", "req_usage", fixedExplorerSQLiteTime())
	seedExplorerSQLiteFeedback(t, store, "acct_usage", "req_usage", "fb_usage", fixedExplorerSQLiteTime().Add(-time.Minute))

	list, err := store.ExplorerActivity(context.Background(), storage.ExplorerActivityQuery{
		From: fixedExplorerSQLiteTime().Add(-time.Hour), To: fixedExplorerSQLiteTime().Add(time.Hour), Limit: 1,
	})
	if err != nil {
		t.Fatalf("ExplorerActivity: %v", err)
	}
	if len(list.Items) != 1 || list.NextCursor == nil || list.LatestCursor == nil {
		t.Fatalf("activity list=%+v", list)
	}
	next, err := store.ExplorerActivity(context.Background(), storage.ExplorerActivityQuery{
		From: fixedExplorerSQLiteTime().Add(-time.Hour), To: fixedExplorerSQLiteTime().Add(time.Hour), Limit: 1, Cursor: *list.NextCursor,
	})
	if err != nil {
		t.Fatalf("ExplorerActivity cursor: %v", err)
	}
	if len(next.Items) != 1 || next.Items[0].SourceID == list.Items[0].SourceID {
		t.Fatalf("activity cursor repeated boundary: first=%+v next=%+v", list.Items, next.Items)
	}
}

func TestExplorerSQLiteHealthCountsWindowedRows(t *testing.T) {
	store := newExplorerSQLiteStore(t)
	seedExplorerSQLiteBuyer(t, store, "acct_health", "health@x")
	seedExplorerSQLiteUsage(t, store, "acct_health", "req_health", fixedExplorerSQLiteTime())

	health, err := store.ExplorerHealth(context.Background(), fixedExplorerSQLiteTime().Add(-time.Hour))
	if err != nil {
		t.Fatalf("ExplorerHealth: %v", err)
	}
	if health.GatewayHealth != "ok" || health.UsageEventsWindow != 1 || health.ActiveAPIKeys != 1 {
		t.Fatalf("health=%+v", health)
	}
}

func newExplorerSQLiteStore(t *testing.T) *Store {
	t.Helper()
	store, err := Open(context.Background(), filepath.Join(t.TempDir(), "gateway.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func seedExplorerSQLiteBuyer(t *testing.T, store *Store, accountID, email string) {
	t.Helper()
	ctx := context.Background()
	if err := store.CreateAccount(ctx, storage.Account{
		AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedExplorerSQLiteTime(),
	}); err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	if err := store.AddAccountIdentity(ctx, storage.AccountIdentity{
		AccountID: accountID, Provider: "github", ProviderUserID: accountID, Email: email, CreatedAt: fixedExplorerSQLiteTime(),
	}); err != nil {
		t.Fatalf("AddAccountIdentity: %v", err)
	}
	if err := store.CreateAPIKey(ctx, storage.APIKey{
		KeyID: accountID + "_key", AccountID: accountID, KeyHash: []byte(accountID + "_hash"), KeyHashPrefix: "mp_" + accountID,
		Status: "active", CreatedAt: fixedExplorerSQLiteTime(),
	}); err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
}

func seedExplorerSQLiteUsage(t *testing.T, store *Store, accountID, requestID string, at time.Time) {
	t.Helper()
	if err := store.InsertUsageEvent(context.Background(), storage.UsageEvent{
		RequestID: requestID, AccountID: accountID, WindowDate: "2026-06-01", PromptTokens: 7, CompletionTokens: 5,
		TotalTokens: 12, TokenSource: "provider_reported", Outcome: "success", CreatedAt: at,
	}); err != nil {
		t.Fatalf("InsertUsageEvent: %v", err)
	}
}

func seedExplorerSQLiteFeedback(t *testing.T, store *Store, accountID, requestID, eventID string, at time.Time) {
	t.Helper()
	if err := store.InsertFeedbackEvent(context.Background(), storage.FeedbackEvent{
		EventID: eventID, RequestID: requestID, AccountID: accountID, Scope: "response", Rating: 4, Comment: "ok", CreatedAt: at,
	}); err != nil {
		t.Fatalf("InsertFeedbackEvent: %v", err)
	}
}

func fixedExplorerSQLiteTime() time.Time {
	return time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
}
