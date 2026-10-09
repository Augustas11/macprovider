package sqlite

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestRefusalRecordsKeepFirstPruneOldAndJoinQuota(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	now := time.Date(2026, 10, 9, 0, 0, 0, 0, time.UTC)
	rec := func(rid, terminal string, forwarded bool, at time.Time) storage.RefusalRecord {
		return storage.RefusalRecord{AccountID: "acct", ExternalRequestID: rid, IntentCommitment: strings.Repeat("a", 64),
			TerminalKind: terminal, Status: 503, ErrorCode: "pool_unavailable", Forwarded: forwarded, RecordedAt: at}
	}
	if err := s.InsertRefusalRecord(ctx, rec("old", storage.RefusalTerminalPreQuota, false, now.Add(-200*time.Hour)), 0); err != nil {
		t.Fatal(err)
	}
	first := rec("r1", storage.RefusalTerminalPreQuota, false, now)
	if err := s.InsertRefusalRecord(ctx, first, 168*time.Hour); err != nil {
		t.Fatal(err)
	}
	second := first
	second.ErrorCode = "model_not_found"
	if err := s.InsertRefusalRecord(ctx, second, 168*time.Hour); err != nil {
		t.Fatal(err)
	}
	got, err := s.ResolveRefusalRecords(ctx, []storage.RefusalRecordKey{{AccountID: "acct", ExternalRequestID: "r1"}})
	if err != nil {
		t.Fatal(err)
	}
	if got[0].Record.ErrorCode != "pool_unavailable" || got[0].ReservationCount != 0 || got[0].UsageRows != 0 {
		t.Fatalf("resolved=%+v, want the first record and no quota rows", got[0])
	}
	if _, err := s.ResolveRefusalRecords(ctx, []storage.RefusalRecordKey{{AccountID: "acct", ExternalRequestID: "old"}}); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("expired record not pruned: %v", err)
	}
	// The table rejects a terminal/forwarded combination the contract forbids.
	if err := s.InsertRefusalRecord(ctx, rec("bad", storage.RefusalTerminalPreQuota, true, now), 0); err == nil {
		t.Fatal("pre-quota record with forwarded=true was accepted")
	}
}
