package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// #1690 VM e2e F-6: Pearl's effective coordinator config is the live base
// plus /etc/macprovider/coordinator.pearl-overlays.yaml, as for the daemon
// and migrate-indexes. The rollback preflight must evaluate the same
// effective config: the overlay's storage.db_path wins over the base.
func TestPoolRollbackPreflightHonorsConfigOverlay(t *testing.T) {
	dir := t.TempDir()
	baseDBPath := filepath.Join(dir, "base.db")
	overlayDBPath := filepath.Join(dir, "overlay.db")
	configPath := filepath.Join(dir, "coordinator.yaml")
	overlayPath := filepath.Join(dir, "coordinator.overlay.yaml")

	reqStore, err := requestlog.OpenStore(overlayDBPath)
	if err != nil {
		t.Fatalf("seed request log: %v", err)
	}
	if _, err := billing.NewStore(reqStore.DB()); err != nil {
		t.Fatalf("seed billing schema: %v", err)
	}
	_ = reqStore.Close()

	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+baseDBPath+"\n"), 0o644); err != nil {
		t.Fatalf("write base config: %v", err)
	}
	if err := os.WriteFile(overlayPath, []byte("storage:\n  db_path: "+overlayDBPath+"\n"), 0o644); err != nil {
		t.Fatalf("write overlay config: %v", err)
	}

	var stdout, stderr bytes.Buffer
	rc := runPoolRollbackPreflightIO([]string{"--config", configPath, "--config-overlay", overlayPath}, &stdout, &stderr, time.Now)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}
	var got map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("decode json: %v\nstdout=%s", err, stdout.String())
	}
	if _, err := os.Stat(baseDBPath); !os.IsNotExist(err) {
		t.Fatalf("base db was touched despite overlay storage.db_path: stat err=%v", err)
	}
}
