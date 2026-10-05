package billing

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type routeSnapshotGoldenVector struct {
	ID                  string          `json:"id"`
	RouteSnapshot       json.RawMessage `json:"route_snapshot"`
	RouteSnapshotDigest string          `json:"route_snapshot_digest"`
}

// SPEC-015 §N.2 / SPEC-022-R013.2 (#1816 freeze R1 SECURITY H6, ARCHITECTURE
// H2): the shared golden vectors that phase7-verify recomputes too. The
// catalog vector keeps the v1 preimage; the pool-model vectors are
// route_snapshot_v2. Each object is exactly the digested preimage.
func TestRouteSnapshotGoldenVectors(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "spec015", "route_snapshot_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Vectors []routeSnapshotGoldenVector `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Vectors) != 3 {
		t.Fatalf("golden vectors = %d, want 3", len(doc.Vectors))
	}
	for _, v := range doc.Vectors {
		t.Run(v.ID, func(t *testing.T) {
			var route RouteSnapshot
			dec := json.NewDecoder(bytes.NewReader(v.RouteSnapshot))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&route); err != nil {
				t.Fatal(err)
			}
			digest, canonical, err := route.Digest()
			if err != nil {
				t.Fatalf("digest: %v", err)
			}
			if digest != v.RouteSnapshotDigest {
				t.Fatalf("digest=%s want %s", digest, v.RouteSnapshotDigest)
			}
			var object any
			if err := json.Unmarshal(v.RouteSnapshot, &object); err != nil {
				t.Fatal(err)
			}
			_, objectCanonical, err := CanonicalSHA256Hex(object)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(canonical, objectCanonical) {
				t.Fatalf("vector object is not the digested preimage:\n got %s\nwant %s", objectCanonical, canonical)
			}
		})
	}
}
