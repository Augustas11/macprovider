package ws

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestSQLiteCanarySanctionStoreRoundTrip(t *testing.T) {
	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open request log store: %v", err)
	}
	defer reqStore.Close()
	store, err := NewSQLiteCanarySanctionStore(reqStore.DB())
	if err != nil {
		t.Fatalf("open canary sanction store: %v", err)
	}
	checkedAt := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	failedAt := checkedAt.Add(time.Minute)
	if err := store.UpsertCanarySanction(context.Background(), pool.CanarySanctionSnapshot{
		ProviderID:    "pinned-a",
		FailCount:     3,
		LastCheckedAt: &checkedAt,
		LastFailedAt:  &failedAt,
	}); err != nil {
		t.Fatalf("upsert canary sanction: %v", err)
	}
	loaded, err := store.LoadCanarySanctions(context.Background())
	if err != nil {
		t.Fatalf("load canary sanctions: %v", err)
	}
	if len(loaded) != 1 || loaded[0].ProviderID != "pinned-a" || loaded[0].FailCount != 3 {
		t.Fatalf("loaded sanctions = %+v", loaded)
	}
	if loaded[0].LastCheckedAt == nil || !loaded[0].LastCheckedAt.Equal(checkedAt) {
		t.Fatalf("last checked at = %+v, want %s", loaded[0].LastCheckedAt, checkedAt)
	}
	if loaded[0].LastFailedAt == nil || !loaded[0].LastFailedAt.Equal(failedAt) {
		t.Fatalf("last failed at = %+v, want %s", loaded[0].LastFailedAt, failedAt)
	}
	if err := store.DeleteCanarySanction(context.Background(), "pinned-a"); err != nil {
		t.Fatalf("delete canary sanction: %v", err)
	}
	loaded, err = store.LoadCanarySanctions(context.Background())
	if err != nil {
		t.Fatalf("reload canary sanctions: %v", err)
	}
	if len(loaded) != 0 {
		t.Fatalf("loaded sanctions after delete = %+v, want empty", loaded)
	}
}
