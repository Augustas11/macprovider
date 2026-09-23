package buyer

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// The fixture is the exact output of scripts/autotune_window.py (pinned by
// scripts/tests/test_autotune_window.py); the coordinator loader must accept it.
func TestAutotuneWindowWriterFixtureAcceptedByPreviousAutotuneReleaseTargets(t *testing.T) {
	t.Parallel()
	body, err := os.ReadFile(filepath.Join("testdata", "autotune_window_previous_target.txt"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".previous-target"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.AutotuneFeedsConfig{
		AutotuneCandidatesPath: filepath.Join(root, "current", "autotune-candidates.json"),
	}
	dirs, err := PreviousAutotuneReleaseTargets(cfg)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"v3.c", "v2-b", "v1_a"}
	if len(dirs) != len(want) {
		t.Fatalf("dirs=%v want %v", dirs, want)
	}
	for i, id := range want {
		if dirs[i] != filepath.Join(root, "releases", id) {
			t.Fatalf("dirs[%d]=%q want releases/%s", i, dirs[i], id)
		}
	}
}
