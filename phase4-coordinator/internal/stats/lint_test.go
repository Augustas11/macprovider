package stats

import (
	"bytes"
	"os/exec"
	"strings"
	"testing"
)

// TestAC16ForbiddenImportFails — SPEC-017 AC-16: a deliberate
// `import "internal/billing"` under `internal/stats/` MUST fail
// the depguard lint with the named rule. BUILD §E.4 requires:
//
//  1. the fixture path IS COMPILABLE (validated by invoking
//     golangci-lint with the `linttest_fixture` build tag — the
//     fixture file compiles only under that tag);
//  2. the lint output names the depguard diagnostic, NOT a
//     compiler error from a bad import path;
//  3. the lint is asserted by name (the test scans stdout for
//     both "depguard" AND "internal/billing").
//
// The test SKIPS when golangci-lint is not on PATH (the
// coordinator-lint CI job installs it; the default
// `make test-coordinator` does not require it). The skip
// message includes the install command so a developer who
// wants to run the assertion locally has a one-liner.
//
// Verifies the same rule fires for forbidden auth/ws/explorer
// imports would be ceremonial — depguard's rule engine treats
// every entry in the deny list uniformly. The fixture file
// covers internal/billing only; the depguard config covers all
// four.
func TestAC16ForbiddenImportFails(t *testing.T) {
	bin, err := exec.LookPath("golangci-lint")
	if err != nil {
		t.Skip("golangci-lint not on PATH; install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2")
	}

	// The fixture is `internal/stats/forbidden_import_fixture.go`
	// with `//go:build linttest_fixture`. We invoke golangci-lint
	// against the stats package with the tag enabled so the
	// fixture is compiled and depguard scans it.
	cmd := exec.Command(bin, "run",
		"--config=.golangci.yml",
		"--build-tags=linttest_fixture",
		"--out-format=line-number",
		"./internal/stats/...",
	)
	cmd.Dir = repoCoordinatorRoot(t)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()

	// golangci-lint exits non-zero when it finds issues. We
	// REQUIRE that — a zero exit means the rule did not fire.
	if runErr == nil {
		t.Fatalf("golangci-lint exited 0 but a forbidden import fixture is present; depguard rule did not fire.\nstdout:\n%s\nstderr:\n%s", stdout.String(), stderr.String())
	}

	out := stdout.String()
	if !strings.Contains(out, "depguard") {
		t.Errorf("golangci-lint output does not name the depguard linter; AC-16 requires assertion-by-name.\nstdout:\n%s", out)
	}
	if !strings.Contains(out, "internal/billing") {
		t.Errorf("golangci-lint output does not name internal/billing; the wrong import may have triggered.\nstdout:\n%s", out)
	}
	if !strings.Contains(out, "forbidden_import_fixture.go") {
		t.Errorf("golangci-lint output does not name the fixture file; the lint may have fired on real source.\nstdout:\n%s", out)
	}
}

// TestForbidigoOSExitRule — SPEC-017 §7.3 + BUILD §D.3: forbid
// os.Exit / log.Fatal / log.Fatalf anywhere under internal/stats/*.
// Same pattern as the AC-16 test: a tagged fixture file calls
// os.Exit; the test invokes golangci-lint with the tag and
// asserts forbidigo names the rule.
func TestForbidigoOSExitRule(t *testing.T) {
	bin, err := exec.LookPath("golangci-lint")
	if err != nil {
		t.Skip("golangci-lint not on PATH; install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2")
	}
	cmd := exec.Command(bin, "run",
		"--config=.golangci.yml",
		"--build-tags=linttest_fixture",
		"--out-format=line-number",
		"./internal/stats/...",
	)
	cmd.Dir = repoCoordinatorRoot(t)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stdout
	if err := cmd.Run(); err == nil {
		t.Fatalf("golangci-lint exited 0; the os.Exit fixture should have tripped forbidigo.\noutput:\n%s", stdout.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "forbidigo") {
		t.Errorf("output does not name forbidigo: %s", out)
	}
	if !strings.Contains(out, "os.Exit") {
		t.Errorf("output does not name os.Exit: %s", out)
	}
}

func repoCoordinatorRoot(t *testing.T) string {
	t.Helper()
	// The test runs from `phase4-coordinator/internal/stats/`; the
	// .golangci.yml the Makefile target uses sits at
	// `phase4-coordinator/`. exec.Command with relative paths is
	// resolved against the caller's working directory; pass an
	// absolute root.
	// Walk up to the coordinator root by finding the .golangci.yml.
	wd, err := exec.Command("pwd").Output()
	if err != nil {
		t.Fatalf("pwd: %v", err)
	}
	dir := strings.TrimSpace(string(wd))
	// stats/ -> internal/ -> phase4-coordinator/
	// Walk up at most a few levels.
	for i := 0; i < 6; i++ {
		if dir == "" || dir == "/" {
			break
		}
		if _, err := exec.Command("test", "-f", dir+"/.golangci.yml").Output(); err == nil {
			return dir
		}
		dir = strings.TrimSuffix(dir, "/")
		if idx := strings.LastIndex(dir, "/"); idx >= 0 {
			dir = dir[:idx]
		} else {
			break
		}
	}
	t.Fatalf("could not locate coordinator root (no .golangci.yml found above %s)", wd)
	return ""
}
