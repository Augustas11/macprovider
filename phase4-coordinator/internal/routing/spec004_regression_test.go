package routing_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSPEC004DefaultConfigRegression is the load-bearing Phase B
// regression test named in BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md
// (Pillar-completion checklist, Common gates). It pins TWO Phase B
// invariants that AC-SR-1 depends on:
//
//  1. The new internal/routing package is NOT yet wired into the
//     selection path. server.go MUST NOT import this package in
//     Phase B; Phase C/D will refactor server.go's inline copies
//     to delegate. Wiring it earlier would risk subtle behavior
//     drift even when defaults are unchanged.
//
//  2. The AC-SR-1 default-config regression
//     (TestDefaultConfigPreservesBaselineProviderSelection in
//     internal/buyer/server_test.go) continues to pass — this is
//     verified by the standard `go test ./internal/buyer/...` run;
//     this file's job is only to fail loudly if invariant 1 breaks.
func TestSPEC004DefaultConfigRegression(t *testing.T) {
	t.Parallel()
	repoRoot, err := findRepoRoot()
	if err != nil {
		t.Fatalf("locate repo root: %v", err)
	}
	importers := []string{
		filepath.Join(repoRoot, "internal", "buyer", "server.go"),
	}
	for _, path := range importers {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		// Match the canonical import string. The HTTP-route
		// string "/internal/routing" must NOT count, so we look
		// for the quoted Go package path.
		needle := `"github.com/augstar/macprovider-coordinator/internal/routing"`
		if strings.Contains(string(data), needle) {
			t.Fatalf(
				"Phase B invariant broken: %s already imports the new internal/routing package. "+
					"Per BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md Phase B 'NOT yet wired into the selection path', "+
					"server.go MUST NOT import internal/routing until Phase C/D refactor lands.",
				path,
			)
		}
	}
}

// findRepoRoot walks up from the test working dir until it finds a
// go.mod. Phase B runs from internal/routing/, so the parent walk
// is two levels (../../).
func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", os.ErrNotExist
		}
		dir = parent
	}
}
