package ws_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// TestProviderHealthzPublishesRequiredBinaryVersion is the coordinator half of
// #767 item 3: `macprovider-cli doctor` needs a reachable surface that names
// the hard admission floor, and /healthz already carries the recommendation.
// Reusing it avoids inventing a provider-facing version endpoint.
func TestProviderHealthzPublishesRequiredBinaryVersion(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.65"
		cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion = "1.8.33"
	})
	defer ts.Close()

	body := fetchHealthzVersions(t, ts.URL)
	if body.RequiredBinaryVersion != "1.8.33" {
		t.Fatalf("required_binary_version = %q, want 1.8.33", body.RequiredBinaryVersion)
	}
	if body.RecommendedBinaryVersion != "1.8.65" {
		t.Fatalf("recommended_binary_version = %q, want 1.8.65", body.RecommendedBinaryVersion)
	}
}

// TestProviderHealthzOmitsUnsetRequiredBinaryVersion keeps the field absent
// (not an empty string) when no floor is configured, so `doctor` can tell "no
// floor" apart from "floor is empty".
func TestProviderHealthzOmitsUnsetRequiredBinaryVersion(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	var raw map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if _, present := raw["required_binary_version"]; present {
		t.Fatalf("required_binary_version present with no floor configured: %v", raw["required_binary_version"])
	}
}

// TestProviderHelloBelowFloorClosesWithParsableReason pins the wire contract the
// Swift `case 4004` handler parses: close code 4004 and a reason that names BOTH
// the rejected version and the required one, in a shape the client can split on
// ("below required <version>").
func TestProviderHelloBelowFloorClosesWithParsableReason(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion = "1.8.33"
	})
	defer ts.Close()

	hello := validHello("below-floor")
	hello["binary_version"] = "1.8.32"
	code, reason := sendHelloExpectClose(t, ts.URL, hello)
	if code != providerws.CloseVersionUnsupported {
		t.Fatalf("close code = %d, want %d (version_unsupported)", code, providerws.CloseVersionUnsupported)
	}
	if !strings.HasPrefix(reason, "version_unsupported:") {
		t.Fatalf("close reason = %q, want a version_unsupported: prefix", reason)
	}
	if !strings.Contains(reason, "binary_version 1.8.32") {
		t.Fatalf("close reason = %q, want the rejected version named", reason)
	}
	// The client parses the required target out of this suffix; changing the
	// wording is a client-visible contract change.
	idx := strings.Index(reason, "below required ")
	if idx < 0 {
		t.Fatalf("close reason = %q, want a 'below required <version>' suffix", reason)
	}
	if got := strings.TrimSpace(reason[idx+len("below required "):]); got != "1.8.33" {
		t.Fatalf("parsed required version = %q, want 1.8.33", got)
	}
}

func fetchHealthzVersions(t *testing.T, baseURL string) struct {
	RecommendedBinaryVersion string `json:"recommended_binary_version"`
	RequiredBinaryVersion    string `json:"required_binary_version"`
} {
	t.Helper()
	var body struct {
		RecommendedBinaryVersion string `json:"recommended_binary_version"`
		RequiredBinaryVersion    string `json:"required_binary_version"`
	}
	resp, err := http.Get(baseURL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz status = %d", resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return body
}
