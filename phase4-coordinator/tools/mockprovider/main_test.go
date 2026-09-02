package main

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
)

func TestCurrentHeartbeatUsesOverrideFile(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	if err := os.WriteFile(overridePath, []byte(`{"model_id":" mlx-community/Canary-32B ","model_params_b":32}`), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	hb := currentHeartbeat(config{
		model:       "mlx-community/Canary-7B",
		ramGB:       16,
		maxContext:  8192,
		slots:       1,
		hbModelFile: overridePath,
	}, log.New(io.Discard, "", 0), nil)

	if hb.ModelID != "mlx-community/Canary-32B" {
		t.Fatalf("ModelID = %q, want override", hb.ModelID)
	}
	if hb.ModelParamsB != 32 {
		t.Fatalf("ModelParamsB = %v, want 32", hb.ModelParamsB)
	}
}

func TestCurrentHeartbeatFallsBackOnEmptyOverrideFile(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	if err := os.WriteFile(overridePath, []byte(" \n"), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	hb := currentHeartbeat(config{
		model:       "mlx-community/Canary-7B",
		ramGB:       16,
		maxContext:  8192,
		slots:       1,
		hbModelFile: overridePath,
	}, log.New(io.Discard, "", 0), nil)

	if hb.ModelID != "mlx-community/Canary-7B" {
		t.Fatalf("ModelID = %q, want configured model", hb.ModelID)
	}
	if hb.ModelParamsB != 7 {
		t.Fatalf("ModelParamsB = %v, want default", hb.ModelParamsB)
	}
}

func TestReadHeartbeatOverrideRejectsUnknownFields(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	if err := os.WriteFile(overridePath, []byte(`{"model_id":"model-a","unexpected":true}`), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	if _, _, err := readHeartbeatOverride(overridePath); err == nil {
		t.Fatal("readHeartbeatOverride accepted an unknown field")
	}
}

func TestReadHeartbeatOverrideRejectsNonRegularFile(t *testing.T) {
	dir := t.TempDir()

	if _, _, err := readHeartbeatOverride(dir); err == nil {
		t.Fatal("readHeartbeatOverride accepted a directory")
	}
}

func TestReadHeartbeatOverrideRejectsOversizedFile(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	large := make([]byte, maxHeartbeatOverrideBytes+1)
	if err := os.WriteFile(overridePath, large, 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	if _, _, err := readHeartbeatOverride(overridePath); err == nil {
		t.Fatal("readHeartbeatOverride accepted an oversized file")
	}
}
