package relayblind

import (
	"context"
	"crypto/ed25519"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// Cycling advertisements with disjoint kids revokes the previous record each
// time; revoked records that have not expired still count toward a
// 2*maxRecords bound, so the table cannot grow without limit.
func TestKeyRecordCyclingIsBounded(t *testing.T) {
	const maxRecords = 4
	for _, class := range []string{KeyClassRelayBlind, KeyClassPrivacy} {
		t.Run(class, func(t *testing.T) {
			ctx := context.Background()
			store, err := OpenStore(filepath.Join(t.TempDir(), "bound.sqlite"))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = store.Close() })
			_, identity, err := ed25519.GenerateKey(nil)
			if err != nil {
				t.Fatal(err)
			}
			now := time.Unix(1_800_000_000, 0)
			refused := 0
			for i := 0; i < 100; i++ {
				record := signedStoreRecord(t, identity, "model-a", now)
				err := store.UpsertKeyRecordClass(ctx, "provider-a", "session-a", record, immutableDigest(t, record), now, maxRecords, time.Minute, class)
				switch {
				case errors.Is(err, ErrCapacity):
					refused++
					continue
				case err != nil:
					t.Fatal(err)
				}
				if err := store.RevokeMissingKeys(ctx, "provider-a", []string{record.KID}, now, time.Minute, class); err != nil {
					t.Fatal(err)
				}
				var rows int
				if err := store.db.QueryRow(`SELECT COUNT(*) FROM relay_blind_key_records WHERE provider_id='provider-a' AND key_class=?`, class).Scan(&rows); err != nil {
					t.Fatal(err)
				}
				if rows > 2*maxRecords {
					t.Fatalf("advertisement %d left %d rows, bound %d", i, rows, 2*maxRecords)
				}
			}
			if refused == 0 {
				t.Fatal("cycling never reached the bound")
			}
		})
	}
}
