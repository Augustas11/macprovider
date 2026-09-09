package config_test

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestValidateAutotuneFeedsCatalogArtifactsPair(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Auth.GatewayServiceToken = "test-gateway-service-token"

	cfg.AutotuneFeeds.CatalogArtifactsPath = "/tmp/autotune-artifacts.json"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "autotune.catalog_artifacts_path and autotune.catalog_artifacts_sig_path must both be set") {
		t.Fatalf("Validate() = %v, want catalog_artifacts pair requirement", err)
	}

	cfg.AutotuneFeeds.CatalogArtifactsSigPath = "/tmp/autotune-artifacts.json.sig"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "autotune.catalog_artifacts_path requires the rate_card, demand_rank, and autotune_candidates feeds") {
		t.Fatalf("Validate() = %v, want base-feed requirement for catalog_artifacts", err)
	}

	setSignedAutotuneFeedPathsForProofTest(&cfg)
	cfg.AutotuneFeeds.PublicKeys = map[string]string{
		"streamvc-autotune-static-v4": "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU=",
	}
	if err := cfg.Validate(); err != nil && strings.Contains(err.Error(), "catalog_artifacts") {
		t.Fatalf("Validate() = %v, want no catalog_artifacts objection once the base feeds are configured", err)
	}
}
