package billing

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// SPEC-022 R-15.10: a new snapshot stores route_snapshot_canonical_json
// empty, and the preimage recomputed from route_snapshot_json hashes to the
// stored digest byte for byte, including strings JSON escapes or NFC
// normalizes.
func TestInsertRouteSnapshotStoresRecomputableCanonicalEmpty(t *testing.T) {
	store, journalDB := newJournalPruneStore(t)
	for _, model := range []string{"model-a", "model <&>   é \"q\""} {
		snapshot := testRouteSnapshot()
		snapshot.RequestID = "req-canonical-" + model
		snapshot.ModelID = model
		digest, want, err := snapshot.Digest()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.InsertRouteSnapshot(context.Background(), snapshot); err != nil {
			t.Fatal(err)
		}
		if _, err := store.MirrorPendingRouteSnapshots(context.Background(), 10); err != nil {
			t.Fatal(err)
		}
		for _, q := range []struct {
			name  string
			query func(dest ...any) error
		}{
			{"primary", func(dest ...any) error {
				return store.db.QueryRow(`SELECT route_snapshot_digest, route_snapshot_json, route_snapshot_canonical_json FROM settlement_route_snapshots WHERE request_id = ?`, snapshot.RequestID).Scan(dest...)
			}},
			{"journal", func(dest ...any) error {
				return journalDB.QueryRow(`SELECT route_snapshot_digest, route_snapshot_json, route_snapshot_canonical_json FROM settlement_route_snapshot_journal WHERE request_id = ?`, snapshot.RequestID).Scan(dest...)
			}},
		} {
			var storedDigest, rendered, canonical string
			if err := q.query(&storedDigest, &rendered, &canonical); err != nil {
				t.Fatalf("%s: %v", q.name, err)
			}
			if canonical != "" {
				t.Fatalf("%s model %q stored canonical %q, want empty", q.name, model, canonical)
			}
			got, err := RouteSnapshotCanonicalJSON(canonical, rendered)
			if err != nil {
				t.Fatal(err)
			}
			sum := sha256.Sum256(got)
			if string(got) != string(want) || hex.EncodeToString(sum[:]) != digest || storedDigest != digest {
				t.Fatalf("%s model %q recomputed preimage %q digest %s, want %q %s", q.name, model, got, hex.EncodeToString(sum[:]), want, digest)
			}
		}
	}
}

func TestRouteSnapshotCanonicalJSONKeepsStoredPreimage(t *testing.T) {
	got, err := RouteSnapshotCanonicalJSON(`{"a":1}`, `{"b":2}`)
	if err != nil || string(got) != `{"a":1}` {
		t.Fatalf("stored preimage=%q err=%v", got, err)
	}
	if stored := routeSnapshotStoredCanonical([]byte(`{"a":1}`), `{"b":2}`); stored != `{"a":1}` {
		t.Fatalf("non-recomputable preimage stored as %q", stored)
	}
	for _, bad := range []string{``, `null`, `[1]`, `{"a":1} x`} {
		if _, err := RouteSnapshotCanonicalJSON("", bad); err == nil {
			t.Fatalf("recompute of %q succeeded", bad)
		}
	}
}
