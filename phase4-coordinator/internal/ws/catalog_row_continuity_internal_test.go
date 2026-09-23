package ws

import (
	"net"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const rowContinuityInternalCatalog = `{
	"version":"VERSION",
	"generated_at":"2026-09-23T00:00:00Z",
	"source":"operator_curated_autotune_candidate_catalog",
	"policy_version":"autotune-policy-v1",
	"rows":{
		"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":MINRAM,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"}
	}
}`

func rowContinuityInternalCatalogFor(t *testing.T, version, minRAM string, rowContinuityOnly bool) *autotune.Catalog {
	t.Helper()
	raw := strings.NewReplacer("VERSION", version, "MINRAM", minRAM).Replace(rowContinuityInternalCatalog)
	catalog, err := autotune.ParseCatalog([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCatalog(%s): %v", version, err)
	}
	catalog.SignerKeyID = "test-key"
	catalog.RowContinuityOnly = rowContinuityOnly
	return catalog
}

// A hello classified against the pre-publication snapshot can register after
// the publication sweep ran; registration re-checks against the active release
// and fences a diverged session at once (SPEC-023-R010).
func TestRegisterFencesSessionWhoseCatalogRowDivergedBeforeRegistration(t *testing.T) {
	for _, tc := range []struct {
		name         string
		bakedRAM     string
		evidenceGone bool
		wantFenced   bool
	}{
		{name: "row still equivalent", bakedRAM: "4", wantFenced: false},
		{name: "row diverged before registration", bakedRAM: "6", wantFenced: true},
		{name: "row-continuity evidence no longer loaded", bakedRAM: "4", evidenceGone: true, wantFenced: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			serverConn, providerConn := net.Pipe()
			defer providerConn.Close()
			defer serverConn.Close()

			current := rowContinuityInternalCatalogFor(t, "published-current", "4", false)
			baked := rowContinuityInternalCatalogFor(t, "published-baked-v1", tc.bakedRAM, true)
			loaded := []*autotune.Catalog{baked}
			if tc.evidenceGone {
				loaded = nil
			}
			s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(), WithAutotuneCatalog(current, loaded...))
			key, _, ok := baked.HighestClaimedTier("mlx-community/Llama-3.2-3B-Instruct-4bit")
			if !ok {
				t.Fatal("baked row missing")
			}
			rowIdentity, _ := baked.RowIdentity(key)
			entry := &pool.Provider{
				ProviderID:             "p1",
				AssignedID:             "s1",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				Tier:                   pool.TierProvisional,
				InferencePath:          pool.InferencePathWSTunneled,
				State:                  pool.StateReady,
				SlotsFree:              1,
				SlotsTotal:             1,
				MaxConcurrency:         1,
				CatalogAdmissionMode:   "row_continuity",
				CatalogReleaseID:       baked.Version,
				CandidateCatalogSHA256: baked.SHA256,
				CandidateRowIdentity:   rowIdentity,
			}
			if session, refusal := s.registerProviderSession(serverConn, entry); session == nil {
				t.Fatalf("registration refused: %q", refusal)
			}
			registered, ok := s.pool.Resolve("p1", "s1")
			if !ok {
				t.Fatal("provider missing after registration")
			}
			if fenced := registered.State == pool.StateUnavailable && !registered.RoutingEligible(); fenced != tc.wantFenced {
				t.Fatalf("fenced=%v (state %q, routable %v), want %v", fenced, registered.State, registered.RoutingEligible(), tc.wantFenced)
			}
		})
	}
}
