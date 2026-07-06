package localrig

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// TestRigLifecycle brings up a 2-provider rig, checks the exported
// fields, curls /healthz on gateway + coord, then shuts down.
func TestRigLifecycle(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping localrig lifecycle test in -short mode")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	cfg := Config{
		Providers: []Provider{
			{ID: "prov-a", Model: "llama-3.2-3b-instruct", TTFTMs: 0, TokensPerSec: 20, CapacitySlots: 2},
			{ID: "prov-b", Model: "llama-3.2-3b-instruct", TTFTMs: 10, TokensPerSec: 15, CapacitySlots: 3},
		},
		Logger: func(line string) { t.Log(line) },
	}
	rig, err := Start(ctx, cfg)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() {
		if err := rig.Shutdown(); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
	})

	// URL fields parseable and 127.0.0.1.
	for name, raw := range map[string]string{
		"GatewayURL":          rig.GatewayURL,
		"CoordinatorBuyerURL": rig.CoordinatorBuyerURL,
	} {
		u, err := url.Parse(raw)
		if err != nil {
			t.Fatalf("%s = %q: parse: %v", name, raw, err)
		}
		if u.Hostname() != "127.0.0.1" {
			t.Errorf("%s hostname = %q, want 127.0.0.1", name, u.Hostname())
		}
	}

	// BuyerToken shape.
	if !strings.HasPrefix(rig.BuyerToken, "mp_") {
		t.Errorf("BuyerToken = %q, want mp_ prefix", rig.BuyerToken)
	}

	// DB files exist.
	for name, path := range map[string]string{
		"CoordinatorDBPath": rig.CoordinatorDBPath,
		"GatewayDBPath":     rig.GatewayDBPath,
	} {
		if fi, err := os.Stat(path); err != nil {
			t.Errorf("%s stat %q: %v", name, path, err)
		} else if fi.Size() == 0 {
			t.Errorf("%s %q is empty", name, path)
		}
	}

	// Health probes.
	for _, u := range []string{
		rig.GatewayURL + "/healthz",
		rig.CoordinatorBuyerURL + "/healthz",
	} {
		resp, err := http.Get(u)
		if err != nil {
			t.Errorf("GET %s: %v", u, err)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Errorf("GET %s status = %d, body=%s", u, resp.StatusCode, string(body))
		}
	}
}
