package sqlite

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestRelayReplayRetentionPrecision(t *testing.T) {
	for _, method := range []string{"seen", "record"} {
		for _, tc := range []struct {
			name                    string
			expiryOffset, nowOffset time.Duration
		}{
			{"fraction_live_at_whole_second", time.Nanosecond, 0},
			{"whole_expired_after_nanosecond", 0, time.Nanosecond},
			{"fraction_live_at_shorter_precision", 100000001 * time.Nanosecond, 100 * time.Millisecond},
			{"fraction_expired_at_longer_precision", 100 * time.Millisecond, 100000001 * time.Nanosecond},
			{"exact_whole_boundary", 0, 0},
			{"exact_fraction_boundary", time.Nanosecond, time.Nanosecond},
			{"earlier_second", -time.Nanosecond, 0},
			{"later_second", time.Second, 0},
		} {
			t.Run(method+"/"+tc.name, func(t *testing.T) {
				store := newTestStore(t)
				boundary := fixedTime().Add(time.Minute)
				replay := retentionReplay("original", boundary.Add(tc.expiryOffset))
				if err := store.RecordRelayBlindReplay(context.Background(), replay); err != nil {
					t.Fatal(err)
				}
				replay.CreatedAt = boundary.Add(tc.nowOffset)
				live := replay.RetentionExpiresAt.After(replay.CreatedAt)
				if method == "seen" {
					seen, err := store.RelayBlindReplaySeen(context.Background(), replay)
					if err != nil || seen != live {
						t.Fatalf("seen=%v err=%v want live=%v", seen, err, live)
					}
				} else {
					replay.RetentionExpiresAt = replay.CreatedAt.Add(time.Minute)
					err := store.RecordRelayBlindReplay(context.Background(), replay)
					if (live && !errors.Is(err, storage.ErrRelayBlindReplay)) || (!live && err != nil) {
						t.Fatalf("record err=%v live=%v", err, live)
					}
				}
			})
		}
	}
}

func TestRelayReplayRetentionCapacityDoesNotDiscardLiveRow(t *testing.T) {
	store := newTestStore(t)
	boundary := fixedTime().Add(time.Minute)
	original := retentionReplay("original", boundary.Add(time.Nanosecond))
	if err := store.RecordRelayBlindReplay(context.Background(), original); err != nil {
		t.Fatal(err)
	}
	unique := retentionReplay("unique", boundary.Add(time.Minute))
	unique.CreatedAt = boundary
	unique.MaxReplayRows = 1
	if err := store.RecordRelayBlindReplay(context.Background(), unique); !errors.Is(err, storage.ErrRateLimit) {
		t.Fatalf("live row capacity err=%v want ErrRateLimit", err)
	}
	unique.CreatedAt = boundary.Add(time.Nanosecond)
	if err := store.RecordRelayBlindReplay(context.Background(), unique); err != nil {
		t.Fatalf("expired capacity was not reclaimed: %v", err)
	}
}

func retentionReplay(id string, expiry time.Time) storage.RelayBlindReplayMaterial {
	return storage.RelayBlindReplayMaterial{
		AccountID: "retention-account", RequestID: id,
		RequestReplayNonceDigest:      []byte("nonce-" + id),
		BuyerEphemeralPublicKeyDigest: []byte("buyer-" + id),
		ProviderBindingDigest:         []byte("binding"), KIDDigest: []byte("kid"),
		EnvelopeDigest: []byte("envelope-" + id), EnvelopeBytes: 128,
		RetentionExpiresAt: expiry, CreatedAt: fixedTime(),
	}
}

func TestRelayReplayRetentionAllFractionalPrecisions(t *testing.T) {
	store := newTestStore(t)
	boundary := fixedTime().Add(time.Minute)
	var expiries []time.Time
	for _, second := range []int{-1, 0, 1} {
		for _, nanos := range []int{0, 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 100000001, 123456789, 999999999} {
			expiries = append(expiries, boundary.Add(time.Duration(second)*time.Second+time.Duration(nanos)))
		}
	}
	for i, expiry := range expiries {
		replay := retentionReplay(fmt.Sprint(i), expiry)
		replay.AccountID = fmt.Sprintf("account-%d", i%2)
		replay.WalletSessionID = fmt.Sprintf("session-%d", i%3)
		if err := store.RecordRelayBlindReplay(context.Background(), replay); err != nil {
			t.Fatal(err)
		}
	}
	for _, now := range expiries {
		t.Run(encodeTime(now), func(t *testing.T) {
			tx, err := store.beginImmediate(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback()
			if err := deleteExpiredRelayBlindReplaysTx(context.Background(), tx, now.In(time.FixedZone("offset", 8*60*60))); err != nil {
				t.Fatal(err)
			}
			rows, err := tx.QueryContext(context.Background(), `SELECT request_id FROM relay_blind_replays`)
			if err != nil {
				t.Fatal(err)
			}
			defer rows.Close()
			retained := make(map[string]bool)
			for rows.Next() {
				var id string
				if err := rows.Scan(&id); err != nil {
					t.Fatal(err)
				}
				retained[id] = true
			}
			if err := rows.Err(); err != nil {
				t.Fatal(err)
			}
			for i, expiry := range expiries {
				if got, want := retained[fmt.Sprint(i)], expiry.After(now); got != want {
					t.Errorf("expiry=%s retained=%v want %v", encodeTime(expiry), got, want)
				}
			}
		})
	}
}

func TestRelayReplayRetentionUsesExpiryIndex(t *testing.T) {
	store := newTestStore(t)
	rows, err := store.db.Query("EXPLAIN QUERY PLAN "+deleteExpiredRelayBlindReplaysSQL,
		encodeTime(fixedTime()), fixedTime().Format("2006-01-02T15:04:05.000000000"))
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	indexed := false
	for rows.Next() {
		var id, parent, unused int
		var detail string
		if err := rows.Scan(&id, &parent, &unused, &detail); err != nil {
			t.Fatal(err)
		}
		indexed = indexed || strings.Contains(detail, "USING INDEX idx_relay_blind_replay_expires (retention_expires_at<?)")
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if !indexed {
		t.Fatal("cleanup did not use the expiry index range")
	}
}

func TestRelayReplayRetentionSurvivesReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "replay.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	boundary := fixedTime().Add(time.Minute)
	replay := retentionReplay("persisted", boundary.Add(time.Nanosecond).In(time.FixedZone("offset", -5*60*60)))
	if err := store.RecordRelayBlindReplay(ctx, replay); err != nil {
		store.Close()
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	replay.CreatedAt = boundary
	if seen, err := reopened.RelayBlindReplaySeen(ctx, replay); err != nil || !seen {
		t.Fatalf("live persisted replay seen=%v err=%v", seen, err)
	}
	replay.CreatedAt = boundary.Add(time.Nanosecond)
	if seen, err := reopened.RelayBlindReplaySeen(ctx, replay); err != nil || seen {
		t.Fatalf("expired persisted replay seen=%v err=%v", seen, err)
	}
}

func TestRelayReplayRetentionCleanupRollsBackWithRecord(t *testing.T) {
	store := newTestStore(t)
	boundary := fixedTime().Add(time.Minute)
	if err := store.RecordRelayBlindReplay(context.Background(), retentionReplay("original", boundary)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`CREATE TRIGGER fail_replay_insert BEFORE INSERT ON relay_blind_replays BEGIN SELECT RAISE(ABORT, 'test insert failure'); END`); err != nil {
		t.Fatal(err)
	}
	replay := retentionReplay("fresh", boundary.Add(time.Minute))
	replay.CreatedAt = boundary.Add(time.Nanosecond)
	if err := store.RecordRelayBlindReplay(context.Background(), replay); err == nil || !strings.Contains(err.Error(), "test insert failure") {
		t.Fatalf("record error=%v want injected insert failure", err)
	}
	var id string
	if err := store.db.QueryRow(`SELECT request_id FROM relay_blind_replays`).Scan(&id); err != nil || id != "original" {
		t.Fatalf("cleanup was not rolled back: id=%s err=%v", id, err)
	}
}
