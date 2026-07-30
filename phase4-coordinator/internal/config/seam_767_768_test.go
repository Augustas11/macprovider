package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
	"gopkg.in/yaml.v3"
)

// TestDeployCoordinatorYAMLSetsBinaryVersionFloor is the #767 P2-2 regression:
// the committed prod overlay MUST carry a real `required_binary_version`. Seam
// 5's floor existed only in code before this — the enforcement was live but
// unconfigured, so no build was ever actually fenced.
//
// It also pins the safety property that made 1.8.33 choosable: the floor must
// stay at or below the advertised latest release, so setting it can never fence
// the build the coordinator is simultaneously recommending.
func TestDeployCoordinatorYAMLSetsBinaryVersionFloor(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "dist", "coordinator.yaml"))
	if err != nil {
		t.Fatalf("read dist/coordinator.yaml: %v", err)
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("parse dist/coordinator.yaml: %v", err)
	}
	required := strings.TrimSpace(cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion)
	if required == "" {
		t.Fatal("dist/coordinator.yaml coordinator_advertised_version.required_binary_version is unset (#767 P2-2)")
	}
	if required != "1.8.33" {
		t.Fatalf("required_binary_version = %q, want 1.8.33 (the first release that declares a compatibility_set_id; raising it is a deliberate fleet-wide act)", required)
	}
	latest := strings.TrimSpace(cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion)
	if latest == "" {
		t.Fatal("dist/coordinator.yaml latest_binary_version is unset")
	}
	if cmp, ok := versionfloor.Compare(required, latest); !ok || cmp > 0 {
		t.Fatalf("required_binary_version %q must not exceed latest_binary_version %q", required, latest)
	}
}

func TestValidateRejectsMalformedVersionFloors(t *testing.T) {
	for _, tc := range []struct {
		name    string
		mutate  func(*Config)
		wantSub string
	}{
		{
			name:    "malformed required floor",
			mutate:  func(c *Config) { c.CoordinatorAdvertisedVersion.RequiredBinaryVersion = "1.8.33-rc1" },
			wantSub: "required_binary_version",
		},
		{
			name:    "malformed latest",
			mutate:  func(c *Config) { c.CoordinatorAdvertisedVersion.LatestBinaryVersion = "latest" },
			wantSub: "latest_binary_version",
		},
		{
			name: "malformed per-model floor",
			mutate: func(c *Config) {
				c.CoordinatorAdvertisedVersion.PerModelRequiredBinaryVersion = map[string]string{"model-a": "newest"}
			},
			wantSub: "per_model_required_binary_version",
		},
		{
			name: "empty per-model key",
			mutate: func(c *Config) {
				c.CoordinatorAdvertisedVersion.PerModelRequiredBinaryVersion = map[string]string{"  ": "1.8.33"}
			},
			wantSub: "empty model_id key",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			tc.mutate(&cfg)
			err := cfg.Validate()
			if err == nil {
				t.Fatalf("Validate() = nil, want error mentioning %q", tc.wantSub)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("Validate() error = %v, want mention of %q", err, tc.wantSub)
			}
		})
	}
}

func TestValidateAcceptsWellFormedVersionFloors(t *testing.T) {
	cfg := validTestConfig()
	cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion = "1.8.33"
	cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.65"
	cfg.CoordinatorAdvertisedVersion.PerModelRequiredBinaryVersion = map[string]string{
		"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit": "1.8.60",
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() = %v, want nil", err)
	}
}

// TestValidateUnsetVersionFloorsStayValid pins the default posture: an overlay
// that sets no floors at all is still a valid config.
func TestValidateUnsetVersionFloorsStayValid(t *testing.T) {
	cfg := validTestConfig()
	cfg.CoordinatorAdvertisedVersion = CoordinatorAdvertisedVersion{}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() with no advertised versions = %v, want nil", err)
	}
}
