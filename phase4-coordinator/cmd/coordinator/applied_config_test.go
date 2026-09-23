package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// TestMain keeps every reload test in this package from writing the real
// /run/macprovider state file.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "coordinator-applied-config-")
	if err != nil {
		panic(err)
	}
	appliedConfigStatePath = filepath.Join(dir, "coordinator-applied-config.json")
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func useAppliedConfigStatePath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "run", "coordinator-applied-config.json")
	previous := appliedConfigStatePath
	appliedConfigStatePath = path
	t.Cleanup(func() { appliedConfigStatePath = previous })
	return path
}

func readAppliedConfigRecord(t *testing.T, path string) appliedConfigRecord {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read applied-config record: %v", err)
	}
	var rec appliedConfigRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatalf("decode applied-config record %q: %v", raw, err)
	}
	return rec
}

func fileSHA256(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return sha256Hex(raw)
}

func writeReloadOverlay(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "overlay.yaml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestBootConfigLoadRecordsAppliedConfig(t *testing.T) {
	statePath := useAppliedConfigStatePath(t)
	startup, _, _, _ := reloadTestServers(config.Default())
	configPath := writeReloadConfig(t, startup)
	overlayPath := writeReloadOverlay(t, "tier2:\n  observe_enabled: true\n")

	_, digests, err := config.LoadWithOverlayDigests(configPath, overlayPath)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	loadedAt := time.Date(2026, 9, 23, 1, 2, 3, 0, time.UTC)
	recordAppliedConfig(zerolog.Nop(), "boot", configPath, overlayPath, digests, loadedAt)

	rec := readAppliedConfigRecord(t, statePath)
	want := appliedConfigRecord{
		Schema:        "macprovider.coordinator-applied-config.v1",
		ConfigPath:    configPath,
		ConfigSHA256:  fileSHA256(t, configPath),
		OverlayPath:   overlayPath,
		OverlaySHA256: fileSHA256(t, overlayPath),
		LoadedAt:      "2026-09-23T01:02:03Z",
		Source:        "boot",
		Version:       version,
	}
	if rec != want {
		t.Fatalf("record=%+v want %+v", rec, want)
	}
	info, err := os.Stat(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("mode=%v want 0640", info.Mode().Perm())
	}
	if leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(statePath), ".coordinator-applied-config-*")); len(leftovers) != 0 {
		t.Fatalf("temp files left behind: %v", leftovers)
	}
}

func TestSIGHUPReloadUpdatesAppliedConfigRecord(t *testing.T) {
	defer tier2.ResetForTest()
	statePath := useAppliedConfigStatePath(t)
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	firstPath := writeReloadConfig(t, startup)
	firstOverlay := writeReloadOverlay(t, "tier2:\n  observe_enabled: false\n")

	var logs bytes.Buffer
	reloadCoordinatorConfig(firstPath, firstOverlay, startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)
	first := readAppliedConfigRecord(t, statePath)
	if first.Source != "sighup" || first.ConfigSHA256 != fileSHA256(t, firstPath) || first.OverlaySHA256 != fileSHA256(t, firstOverlay) {
		t.Fatalf("first reload record=%+v", first)
	}
	if !strings.Contains(logs.String(), `"config_sha256":"`+first.ConfigSHA256+`"`) ||
		!strings.Contains(logs.String(), `"overlay_sha256":"`+first.OverlaySHA256+`"`) {
		t.Fatalf("reload success event lacks digests: %s", logs.String())
	}

	next := startup
	next.Tier2.ObserveEnabled = !startup.Tier2.ObserveEnabled
	nextPath := writeReloadConfig(t, next)
	reloadCoordinatorConfig(nextPath, "", startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil, nil, nil)
	second := readAppliedConfigRecord(t, statePath)
	if second.ConfigPath != nextPath || second.ConfigSHA256 != fileSHA256(t, nextPath) ||
		second.ConfigSHA256 == first.ConfigSHA256 || second.OverlayPath != "" || second.OverlaySHA256 != "" {
		t.Fatalf("second reload record=%+v first=%+v", second, first)
	}
}

func TestRejectedSIGHUPReloadKeepsAppliedConfigRecord(t *testing.T) {
	defer tier2.ResetForTest()
	statePath := useAppliedConfigStatePath(t)
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	reloadTier2Config(writeReloadConfig(t, startup), startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil)
	before, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("baseline record: %v", err)
	}

	next := startup
	next.Tier2.CatalogPath = "/tmp/catalog.json"
	next.Tier2.CatalogPublicKey = "catalog-key"
	var logs bytes.Buffer
	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil)
	if !strings.Contains(logs.String(), "reload rejected") {
		t.Fatalf("expected a rejected reload, logs=%s", logs.String())
	}
	after, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("rejected reload rewrote the record:\nbefore=%s\nafter=%s", before, after)
	}

	// A config that fails to load at all also leaves the record alone.
	broken := filepath.Join(t.TempDir(), "broken.yaml")
	if err := os.WriteFile(broken, []byte("tier2: [\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	reloadTier2Config(broken, startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil)
	if after, _ := os.ReadFile(statePath); !bytes.Equal(before, after) {
		t.Fatalf("unloadable reload rewrote the record: %s", after)
	}
}

func TestAppliedConfigRecordWriteFailureWarnsWithoutFailingReload(t *testing.T) {
	defer tier2.ResetForTest()
	blocker := filepath.Join(t.TempDir(), "not-a-dir")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	previous := appliedConfigStatePath
	appliedConfigStatePath = filepath.Join(blocker, "coordinator-applied-config.json")
	t.Cleanup(func() { appliedConfigStatePath = previous })

	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	next := startup
	next.Tier2.ObserveEnabled = true
	var logs bytes.Buffer
	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil)

	if !strings.Contains(logs.String(), "tier2/proof_of_weights config reloaded") {
		t.Fatalf("reload must still succeed, logs=%s", logs.String())
	}
	if !strings.Contains(logs.String(), `"event":"coordinator_applied_config_record_failed"`) ||
		!strings.Contains(logs.String(), `"level":"warn"`) {
		t.Fatalf("expected write-failure warning, logs=%s", logs.String())
	}
	if got := fetchReloadTier2Metadata(t, buyerServer); !got.ModelHash.Active {
		t.Fatalf("reload not applied: tier2 metadata=%+v", got)
	}
}
