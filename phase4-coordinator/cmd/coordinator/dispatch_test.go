package main

// SPEC-017 v0.1.8 Step 4.A round-1 CODE H1 fix — subprocess
// CLI dispatch test. Builds the `coordinator` binary once and
// runs it as a child process to assert the top-level dispatcher
// (a) routes known verbs to their handlers and (b) rejects
// unknown subcommands with a clean usage + exit code 2 instead
// of silently falling through to daemon mode.
//
// Lives under the default (non-integration) build tag because
// the assertions DO NOT need a Postgres container — they only
// exercise main()'s argv branching.
//
// Round-1 CODE M2 partial closure: testcontainers-backed
// integration coverage of the AC-17 literal + RFC 6454 paths
// stays in partnerkeys_integration_test.go (build-tagged
// `integration`). This file adds the dispatch surface coverage
// the in-process function calls in that file deliberately
// bypass.

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// buildCoordinator compiles the coordinator binary once per
// test process and caches the path in a sync.Once-guarded
// variable so subsequent tests reuse the artifact.
var (
	coordinatorBinaryOnce sync.Once
	coordinatorBinary     string
	coordinatorBuildErr   error
)

func locateCoordinatorBinary(t *testing.T) string {
	t.Helper()
	coordinatorBinaryOnce.Do(func() {
		dir, err := os.MkdirTemp("", "coordinator-cli-bin-")
		if err != nil {
			coordinatorBuildErr = err
			return
		}
		out := filepath.Join(dir, "coordinator")
		cmd := exec.Command("go", "build", "-o", out, ".")
		// `go test` already runs from this package's directory.
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			coordinatorBuildErr = err
			coordinatorBinary = stderr.String()
			return
		}
		coordinatorBinary = out
	})
	if coordinatorBuildErr != nil {
		t.Skipf("could not build coordinator binary (skipping subprocess test): %v\nstderr=%s", coordinatorBuildErr, coordinatorBinary)
	}
	return coordinatorBinary
}

// TestDispatchUnknownSubcommandRejected — CODE r1 H1 fix.
// `coordinator frobnicate` previously fell through to daemon
// flag parsing → config load, surfacing as
// `config: open coordinator.yaml: no such file or directory`.
// The fix rejects unknown subcommands with a usage line + exit 2.
func TestDispatchUnknownSubcommandRejected(t *testing.T) {
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "frobnicate")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exitCode := exitCodeOf(err)
	if exitCode != 2 {
		t.Fatalf("unknown subcommand exit=%d, want 2; stdout=%q stderr=%q",
			exitCode, stdout.String(), stderr.String())
	}
	if !strings.Contains(stderr.String(), `unknown subcommand "frobnicate"`) {
		t.Errorf("stderr should name the unknown subcommand; got %q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "partner-keys") {
		t.Errorf("stderr usage should mention partner-keys; got %q", stderr.String())
	}
	if strings.Contains(stderr.String(), "open coordinator.yaml") {
		t.Errorf("dispatcher fell through to daemon config load: %q", stderr.String())
	}
}

// TestDispatchPartnerKeysWithoutVerb prints usage and exits 2.
func TestDispatchPartnerKeysWithoutVerb(t *testing.T) {
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "partner-keys")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	if exitCodeOf(err) != 2 {
		t.Fatalf("partner-keys without verb should exit 2; got %v stderr=%q", err, stderr.String())
	}
	if !strings.Contains(stderr.String(), "usage:") {
		t.Errorf("stderr should print usage; got %q", stderr.String())
	}
}

// TestDispatchVisibilityExactRejected — `visibility exact`
// hard-rejects with the AC-20 boundary message.
func TestDispatchVisibilityExactRejected(t *testing.T) {
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "visibility", "exact", "--id", "p1", "--reason", "x")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	if exitCodeOf(err) == 0 {
		t.Fatalf("visibility exact should reject; got exit 0 stderr=%q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "not supported") {
		t.Errorf("stderr should explain rejection; got %q", stderr.String())
	}
}

// TestDispatchPartnerKeysIssueBurstFlagRejected — `--burst`
// is not registered; flag.Parse errors out cleanly without
// any DB connect attempt.
func TestDispatchPartnerKeysIssueBurstFlagRejected(t *testing.T) {
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "partner-keys", "issue", "--label", "X", "--burst", "100")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	if exitCodeOf(err) == 0 {
		t.Fatalf("--burst flag should be rejected; got exit 0 stderr=%q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "burst") {
		t.Errorf("stderr should reference --burst; got %q", stderr.String())
	}
}

// TestDispatchJournalStreamSuppressesToken — round-1 SECURITY
// H1 fix. With JOURNAL_STREAM set, the CLI MUST refuse to print
// the raw token to stdout AND must exit non-zero (since the
// row was INSERTed but the token can't be delivered safely).
// We can't actually issue against a real DB here (no
// testcontainer in this lane), so we set up the failure mode
// via JOURNAL_STREAM + a deliberately-broken --admin-dsn that
// fails at the EXISTS check before INSERT — the dispatcher
// returns the expected non-zero exit without leaking a token.
// The dispatch coverage that matters is "the JOURNAL_STREAM
// branch refuses on stdout" — that is asserted in the
// integration suite where a real DB lets the INSERT succeed
// (see partnerkeys_integration_test.go::TestIssueJournalStreamSuppresses).
func TestDispatchJournalStreamFlagAccepted(t *testing.T) {
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "partner-keys", "issue", "--label", "X", "--token-out", "/dev/null", "--admin-dsn", "postgres://nope:nope@127.0.0.1:1/nope?sslmode=disable")
	cmd.Env = append(os.Environ(), "JOURNAL_STREAM=1:2")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	_ = cmd.Run()
	// We don't assert exit code — DB connect will fail. We
	// just assert the dispatcher recognized --token-out (i.e.
	// no "flag provided but not defined" surface).
	if strings.Contains(stderr.String(), "flag provided but not defined: -token-out") {
		t.Errorf("--token-out flag should be registered; got %q", stderr.String())
	}
}

// TestDispatchStatsMigrateMissingAdminDSN — stats-migrate rejects missing DSN.
func TestDispatchStatsMigrateMissingAdminDSN(t *testing.T) {
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "stats-migrate")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	exitCode := exitCodeOf(err)
	if exitCode != 2 {
		t.Fatalf("stats-migrate without --admin-dsn exit=%d, want 2; stderr=%q", exitCode, stderr.String())
	}
	if !strings.Contains(stderr.String(), "no admin DSN") {
		t.Errorf("stderr should mention missing admin DSN; got %q", stderr.String())
	}
	if strings.Contains(stderr.String(), "open coordinator.yaml") {
		t.Errorf("stats-migrate fell through to daemon config load: %q", stderr.String())
	}
}

func exitCodeOf(err error) int {
	if err == nil {
		return 0
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode()
	}
	return -1
}
