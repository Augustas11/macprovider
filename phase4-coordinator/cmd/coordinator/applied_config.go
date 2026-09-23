package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/rs/zerolog"
)

const (
	appliedConfigSchema = "macprovider.coordinator-applied-config.v1"
	// defaultAppliedConfigStatePath is where the running coordinator records
	// the content identity of the config it last applied. Release lanes
	// compare it against the on-disk files before sending SIGHUP, so a
	// reload can never silently apply unrelated pending edits.
	defaultAppliedConfigStatePath = "/run/macprovider/coordinator-applied-config.json"
)

// appliedConfigStatePath is set from --applied-config-state at startup;
// tests point it into a temp dir.
var appliedConfigStatePath = defaultAppliedConfigStatePath

// appliedConfigRecord is the on-disk schema of the applied-config state file.
// It is rewritten only after a boot or SIGHUP reload fully succeeded, so a
// rejected reload leaves the previous (still applied) record in place.
type appliedConfigRecord struct {
	Schema        string `json:"schema"`
	ConfigPath    string `json:"config_path"`
	ConfigSHA256  string `json:"config_sha256"`
	OverlayPath   string `json:"overlay_path"`
	OverlaySHA256 string `json:"overlay_sha256"`
	LoadedAt      string `json:"loaded_at"`
	Source        string `json:"source"`
	Version       string `json:"version"`
}

// recordAppliedConfig writes the applied-config state file. A write failure
// never fails boot or reload: the config is already applied, so it is only
// logged.
func recordAppliedConfig(logger zerolog.Logger, source, configPath, overlayPath string, digests config.SourceDigests, loadedAt time.Time) {
	rec := appliedConfigRecord{
		Schema:        appliedConfigSchema,
		ConfigPath:    configPath,
		ConfigSHA256:  digests.ConfigSHA256,
		OverlayPath:   overlayPath,
		OverlaySHA256: digests.OverlaySHA256,
		LoadedAt:      loadedAt.UTC().Format(time.RFC3339Nano),
		Source:        source,
		Version:       version,
	}
	if err := writeAppliedConfigRecord(appliedConfigStatePath, rec); err != nil {
		logger.Warn().Err(err).
			Str("path", appliedConfigStatePath).
			Str("source", source).
			Str("config_sha256", digests.ConfigSHA256).
			Str("overlay_sha256", digests.OverlaySHA256).
			Str("event", "coordinator_applied_config_record_failed").
			Msg("applied-config state file not written; config remains applied")
	}
}

// writeAppliedConfigRecord replaces path atomically: temp file in the same
// directory, mode 0640, fsync, rename, then a best-effort directory fsync.
func writeAppliedConfigRecord(path string, rec appliedConfigRecord) error {
	raw, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("create state dir: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".coordinator-applied-config-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o640); err != nil {
		tmp.Close()
		return fmt.Errorf("chmod temp file: %w", err)
	}
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("fsync temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename into place: %w", err)
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}
