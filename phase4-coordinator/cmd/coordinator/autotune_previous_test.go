package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestLoadPreviousAutotuneCatalogOmitsTombstonedBridge(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(root, ".previous-target"),
		[]byte("releases/published-2026-07-07-p2-qwen3-8b\n"),
		0o600,
	); err != nil {
		t.Fatalf("write previous target: %v", err)
	}
	compatible, err := loadPreviousAutotuneCatalog(config.AutotuneFeedsConfig{
		AutotuneCandidatesPath: filepath.Join(root, "current", "autotune-candidates.json"),
	})
	if err != nil {
		t.Fatalf("loadPreviousAutotuneCatalog: %v", err)
	}
	if len(compatible) != 0 {
		t.Fatalf("compatible catalogs = %d, want 0", len(compatible))
	}
}
