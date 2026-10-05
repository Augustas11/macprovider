package buyer

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestSettlementPoolLabelsPreferRouteSnapshotLabels(t *testing.T) {
	if labels := (&billingRecorder{state: &forwardState{}}).settlementPoolLabels(); labels != nil {
		t.Fatalf("global request labels=%+v, want nil", labels)
	}

	registry := trustpool.NewRegistry()
	load := func(revision, version uint64, digest string) {
		t.Helper()
		if err := registry.LoadRouteableSnapshotsAtRevision(revision, []trustpool.RouteableSnapshot{{
			PoolID: "pool-a", Routeable: true, SettlementMode: "observe", ManifestVersion: version, ManifestCoreDigest: digest,
		}}); err != nil {
			t.Fatal(err)
		}
	}
	load(1, 2, strings.Repeat("d", 64))
	rec := &billingRecorder{
		server:                        &Server{trustPools: registry},
		state:                         &forwardState{poolID: "pool-a", poolManifestVersion: 2, poolManifestCoreDigest: strings.Repeat("d", 64)},
		settlementRouteSnapshot:       &billing.RouteSnapshot{PoolID: "pool-a", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64)},
		settlementRouteSnapshotDigest: strings.Repeat("a", 64),
	}
	labels := rec.settlementPoolLabels()
	if labels == nil || labels.PoolID != "pool-a" || labels.ManifestVersion != 2 || labels.ManifestCoreDigest != strings.Repeat("d", 64) || labels.RouteSnapshotHash != strings.Repeat("a", 64) {
		t.Fatalf("labels=%+v", labels)
	}

	// A manifest accepted after routing must not change the labels used for
	// this in-flight attempt: the immutable route snapshot is the authority.
	load(2, 3, strings.Repeat("e", 64))
	if labels := rec.settlementPoolLabels(); labels.ManifestVersion != 2 || labels.ManifestCoreDigest != strings.Repeat("d", 64) {
		t.Fatalf("labels after manifest change=%+v, want route snapshot manifest 2", labels)
	}

	// A pool that left the live registry after dispatch still settles from
	// the immutable route snapshot labels.
	if err := registry.LoadRouteableSnapshotsAtRevision(3, nil); err != nil {
		t.Fatal(err)
	}
	if labels := rec.settlementPoolLabels(); labels.ManifestVersion != 2 || labels.ManifestCoreDigest != strings.Repeat("d", 64) {
		t.Fatalf("labels after pool removal=%+v, want route snapshot manifest 2", labels)
	}
}

func TestSettlementPoolLabelsFallbackToLiveRegistryWithoutRouteSnapshot(t *testing.T) {
	registry := trustpool.NewRegistry()
	if err := registry.LoadRouteableSnapshotsAtRevision(1, []trustpool.RouteableSnapshot{{
		PoolID: "pool-a", Routeable: true, SettlementMode: "observe", ManifestVersion: 3, ManifestCoreDigest: strings.Repeat("e", 64),
	}}); err != nil {
		t.Fatal(err)
	}
	rec := &billingRecorder{
		server:                        &Server{trustPools: registry},
		state:                         &forwardState{poolID: "pool-a", poolManifestVersion: 2, poolManifestCoreDigest: strings.Repeat("d", 64)},
		settlementRouteSnapshotDigest: strings.Repeat("a", 64),
	}
	if labels := rec.settlementPoolLabels(); labels == nil || labels.ManifestVersion != 3 || labels.ManifestCoreDigest != strings.Repeat("e", 64) {
		t.Fatalf("fallback labels=%+v, want live registry manifest 3", labels)
	}
}
