package spec014pairing

import (
	"encoding/json"
	"net/http"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestSpec014V02CoordinatorGitHubRoutes404WhenFlagOff(t *testing.T) {
	coord := startCoordinator(t, false, nil)
	resp, err := http.Get(coord.providerURL + "/v1/auth/github/start")
	if err != nil {
		t.Fatalf("github start flag-off request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("flag-off /v1/auth/github/start status=%d want 404", resp.StatusCode)
	}
}

func TestSpec014V02ProviderPortalBundleProbe(t *testing.T) {
	cmd := exec.Command("node", "portal_bundle_probe.js", filepath.Join(repoRoot, "frontdoor/provider-portal/index.html"))
	cmd.Dir = filepath.Join(repoRoot, "test/integration/spec_014_v0_2_pairing")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("portal bundle probe failed: %v\n%s", err, string(out))
	}
	var result map[string]any
	if err := json.Unmarshal(out, &result); err != nil {
		t.Fatalf("decode portal probe output: %v\n%s", err, string(out))
	}
	if result["ok"] != true {
		t.Fatalf("portal probe returned non-ok: %#v", result)
	}
}
