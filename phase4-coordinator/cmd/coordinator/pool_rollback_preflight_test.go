package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
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

func TestPoolRollbackPreflightAllowsEmptyPoolHistory(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	configPath := filepath.Join(dir, "coordinator.yaml")
	reqStore, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("seed request log: %v", err)
	}
	if _, err := billing.NewStore(reqStore.DB()); err != nil {
		t.Fatalf("seed billing schema: %v", err)
	}
	if _, err := trustpool.NewStore(reqStore.DB()); err != nil {
		t.Fatalf("seed trustpool schema: %v", err)
	}
	_ = reqStore.Close()
	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	var stdout, stderr bytes.Buffer
	rc := runPoolRollbackPreflightIO([]string{"--config", configPath}, &stdout, &stderr, time.Now)
	if rc != 0 {
		t.Fatalf("rc=%d want 0\nstdout=%s\nstderr=%s", rc, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), `"rollback_blocked":false`) || !strings.Contains(stdout.String(), `"manifests":0`) {
		t.Fatalf("empty history result missing clear verdict: stdout=%s", stdout.String())
	}
}

// #1816 VM acceptance A-2: with a pool_model_entries/v1 core in the manifest
// history, the preflight exited 0 and the rolled-back coordinator then
// disabled every pool ("replay event 3: invalid manifest snapshot"). It must
// refuse any target tier that cannot replay the history, by default too.
func TestPoolRollbackPreflightRefusesUnreplayableManifestHistory(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	configPath := filepath.Join(dir, "coordinator.yaml")
	reqStore, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := billing.NewStore(reqStore.DB()); err != nil {
		t.Fatal(err)
	}
	if _, err := trustpool.NewStore(reqStore.DB()); err != nil {
		t.Fatal(err)
	}
	snapshot := poolmanifest.ManifestSnapshot{Policies: []poolmanifest.AcceptedPolicyRecord{{
		SignedCore: poolmanifest.SignedPolicyCore{Core: poolmanifest.PolicyCore{
			Encoding:         poolmanifest.PolicyCoreEncodingV2,
			ManifestVersion:  1,
			RuntimeAllowlist: []string{poolmanifest.RuntimeSourceLlamacppLoopback},
			Extensions:       []poolmanifest.PolicyExtension{{ID: poolmanifest.ExtensionPoolModelEntriesV1, Body: []byte("{}")}},
		}},
	}}}
	raw, err := snapshot.CanonicalBytes()
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(trustpool.DurableEvent{ManifestSnapshot: base64.StdEncoding.EncodeToString(raw)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reqStore.DB().Exec(`INSERT INTO trustpool_events (operation_id, ts_utc, event_type, pool_id, payload_json) VALUES ('op-3', '2026-10-01T00:00:00Z', 'manifest_accepted', 'pool-q', ?)`, string(payload)); err != nil {
		t.Fatal(err)
	}
	_ = reqStore.Close()
	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		args []string
		rc   int
	}{
		{nil, poolRollbackBlockedExit},
		{[]string{"--target-tier", "m9"}, poolRollbackBlockedExit},
		{[]string{"--target-tier", "p1816"}, 0},
		{[]string{"--target-tier", "m10"}, 2},
	} {
		var stdout, stderr bytes.Buffer
		rc := runPoolRollbackPreflightIO(append([]string{"--config", configPath}, tc.args...), &stdout, &stderr, time.Now)
		if rc != tc.rc {
			t.Fatalf("%v: rc=%d want %d\nstdout=%s\nstderr=%s", tc.args, rc, tc.rc, stdout.String(), stderr.String())
		}
		if rc == poolRollbackBlockedExit && (!strings.Contains(stderr.String(), "STOP") || !strings.Contains(stderr.String(), "extension pool_model_entries/v1") || !strings.Contains(stdout.String(), `"rollback_blocked":true`)) {
			t.Fatalf("%v: refusal is not explicit\nstdout=%s\nstderr=%s", tc.args, stdout.String(), stderr.String())
		}
	}
}
