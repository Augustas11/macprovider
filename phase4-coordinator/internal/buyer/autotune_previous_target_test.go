package buyer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestPreviousAutotuneReleaseTargetsWindow(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	cfg := config.AutotuneFeedsConfig{
		AutotuneCandidatesPath: filepath.Join(root, "current", "autotune-candidates.json"),
	}

	if dirs, err := PreviousAutotuneReleaseTargets(cfg); err != nil || dirs != nil {
		t.Fatalf("missing file: dirs=%v err=%v", dirs, err)
	}

	write := func(body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, ".previous-target"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	write("releases/listed-v1\nreleases/inband-v1\nreleases/gpt-oss-v1\n")
	dirs, err := PreviousAutotuneReleaseTargets(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(dirs) != 3 {
		t.Fatalf("dirs=%d want 3: %v", len(dirs), dirs)
	}
	first, err := PreviousAutotuneReleaseTarget(cfg)
	if err != nil || first != dirs[0] || !strings.HasSuffix(first, "listed-v1") {
		t.Fatalf("first=%q err=%v", first, err)
	}

	write("releases/listed-v1\nreleases/inband-v1\nreleases/gpt-oss-v1\nreleases/older-v1\n")
	if _, err := PreviousAutotuneReleaseTargets(cfg); err == nil || !strings.Contains(err.Error(), "max 3") {
		t.Fatalf("fourth line must fail closed: %v", err)
	}

	write("releases/listed-v1\nreleases/published-2026-07-07-p2-qwen3-8b\nreleases/inband-v1\n")
	dirs, err = PreviousAutotuneReleaseTargets(cfg)
	if err != nil || len(dirs) != 2 {
		t.Fatalf("tombstone omitted: dirs=%v err=%v", dirs, err)
	}

	write("releases/listed-v1\nreleases/listed-v1\nreleases/inband-v1\n")
	dirs, err = PreviousAutotuneReleaseTargets(cfg)
	if err != nil || len(dirs) != 2 {
		t.Fatalf("duplicates skipped: dirs=%v err=%v", dirs, err)
	}

	write("releases/listed-v1\nnot-a-release\n")
	if _, err := PreviousAutotuneReleaseTargets(cfg); err == nil {
		t.Fatal("invalid line must fail closed")
	}
}
