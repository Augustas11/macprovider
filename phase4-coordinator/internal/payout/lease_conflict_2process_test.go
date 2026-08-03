package payout

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

// SPEC-016:2964-2967 — "IMPL test required (1)": the payout_runner_lease
// conflict must be proven across a REAL process boundary, not just
// same-process. TestAcquire_ConflictEmitsLeaseConflictEvent
// (lease_conflict_emit_test.go) exercises the emission fields cheaply but
// runs both Acquires in ONE process, so local_pid == holder_pid there and
// the cross-process local_pid != holder_pid distinction is never checked.
//
// This test spawns two ACTUAL OS processes against the SAME file-backed
// sqlite DB (the standard Go "re-exec the test binary behind an env flag"
// idiom, matching the subprocess pattern in cmd/coordinator/dispatch_test.go
// and cmd/coordinator/partnerkeys_integration_test.go):
//
//   - Subprocess A: Acquire → wins the fresh lease (its INSERT stamps a live
//     heartbeat), prints its real pid, then holds briefly.
//   - Subprocess B: Acquire → must return ErrLeaseConflict, emit
//     payout_runner_lease_conflict (PAGE, all 7 §7.1 fields) with
//     holder_pid == A's real pid and local_pid == B's real pid (DISTINCT),
//     and exit non-zero.
//
// Determinism: A commits its INSERT before it signals "acquired" on stdout,
// and the parent only starts B after reading that signal — so B always sees a
// committed heartbeat that is fresh (well inside the 3×5min stale window).
// There is no timing race; the conflict is decided by the persisted row, not
// by A still running.

// leaseSubprocEnvRole gates the re-exec entrypoint below so a normal
// `go test` invocation never runs the subprocess body inline.
const (
	leaseSubprocEnvRole = "PAYOUT_LEASE_SUBPROC_ROLE"
	leaseSubprocEnvDB   = "PAYOUT_LEASE_SUBPROC_DB"

	// Exit codes the subprocess uses so the parent can distinguish the
	// expected outcome from wrong ones.
	leaseExitAAcquired  = 0 // A won the fresh lease and held
	leaseExitBConflict  = 3 // B correctly hit ErrLeaseConflict
	leaseExitUnexpected = 4 // any other outcome (wrong-shape)
)

// openLeaseFileDB opens the shared file-backed sqlite DB at path and applies
// the same minimum schema + migrations openTestDB uses (ledger_payout_ready
// slice first, per the SPEC-016 same-DB pin, then Migrate which creates
// payout_runner_lease). Unlike openTestDB it takes an explicit path so the
// two subprocesses share one file (an in-memory DB cannot cross processes).
func openLeaseFileDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(path))
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE TABLE IF NOT EXISTS ledger_payout_ready (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id TEXT NOT NULL,
    window_start_utc TEXT NOT NULL,
    window_end_utc TEXT NOT NULL,
    cadence_days INTEGER NOT NULL CHECK(cadence_days > 0),
    source_credit_count INTEGER NOT NULL CHECK(source_credit_count > 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    provider_credits INTEGER NOT NULL CHECK(provider_credits >= 0),
    operator_credits INTEGER NOT NULL CHECK(operator_credits >= 0),
    min_payout_credits INTEGER NOT NULL CHECK(min_payout_credits >= 0),
    payout_currency TEXT NULL,
    payout_external_id TEXT NULL,
    status TEXT NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','consumed','voided')),
    idempotency_key TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    UNIQUE(provider_id, window_start_utc, window_end_utc),
    UNIQUE(idempotency_key)
);`); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("seed ledger_payout_ready: %w", err)
	}
	if err := Migrate(context.Background(), db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return db, nil
}

// TestLeaseConflictSubprocess is the re-exec entrypoint. It does nothing
// under a normal `go test` run (env unset); the parent test below invokes it
// with the role + DB path env set, one OS process per role.
func TestLeaseConflictSubprocess(t *testing.T) {
	role := os.Getenv(leaseSubprocEnvRole)
	if role == "" {
		t.Skip("not a lease-conflict subprocess (env unset)")
	}
	dbPath := os.Getenv(leaseSubprocEnvDB)
	db, err := openLeaseFileDB(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "subprocess %s: open db: %v\n", role, err)
		os.Exit(leaseExitUnexpected)
	}
	defer db.Close()
	pid := os.Getpid()

	switch role {
	case "A":
		// Route Acquire's own info log to stderr so stdout carries ONLY the
		// machine-readable ready line the parent scans for.
		logger := zerolog.New(os.Stderr)
		_, takeover, err := Acquire(context.Background(), db, testRunInterval, logger)
		if err != nil || takeover {
			fmt.Fprintf(os.Stderr, "A: unexpected acquire err=%v takeover=%v\n", err, takeover)
			os.Exit(leaseExitUnexpected)
		}
		// Signal the parent (post-COMMIT) with our real pid, then hold the
		// lease briefly so A is a live concurrent holder while B runs.
		fmt.Printf("{\"role\":\"A\",\"pid\":%d,\"status\":\"acquired\"}\n", pid)
		os.Stdout.Sync()
		time.Sleep(3 * time.Second)
		os.Exit(leaseExitAAcquired)
	case "B":
		// Acquire must emit payout_runner_lease_conflict to stdout (the
		// parent parses it) and return ErrLeaseConflict.
		logger := zerolog.New(os.Stdout)
		_, _, err := Acquire(context.Background(), db, testRunInterval, logger)
		if !errors.Is(err, ErrLeaseConflict) {
			fmt.Fprintf(os.Stderr, "B: acquire err=%v, want ErrLeaseConflict\n", err)
			os.Exit(leaseExitUnexpected)
		}
		os.Exit(leaseExitBConflict)
	default:
		fmt.Fprintf(os.Stderr, "unknown role %q\n", role)
		os.Exit(leaseExitUnexpected)
	}
}

// leaseSubprocCmd builds an exec.Cmd that re-runs THIS test binary, matching
// only TestLeaseConflictSubprocess, with the given role + shared DB path.
func leaseSubprocCmd(role, dbPath string) *exec.Cmd {
	cmd := exec.Command(os.Args[0], "-test.run", "^TestLeaseConflictSubprocess$")
	cmd.Env = append(os.Environ(),
		leaseSubprocEnvRole+"="+role,
		leaseSubprocEnvDB+"="+dbPath,
	)
	return cmd
}

func leaseExitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// TestAcquire_LeaseConflict_TwoProcess is the real cross-process test.
func TestAcquire_LeaseConflict_TwoProcess(t *testing.T) {
	if os.Getenv(leaseSubprocEnvRole) != "" {
		// We are a re-exec'd child; the child logic lives in
		// TestLeaseConflictSubprocess. Nothing to do here.
		t.Skip("child process")
	}
	// A shared, file-backed DB both subprocesses open (in-memory can't cross
	// the process boundary). Kept in the test's TempDir (auto-cleaned).
	dbPath := filepath.Join(t.TempDir(), "lease_2proc.db")

	// --- Subprocess A: win + hold the fresh lease. ---
	cmdA := leaseSubprocCmd("A", dbPath)
	stdoutA, err := cmdA.StdoutPipe()
	if err != nil {
		t.Fatalf("A stdout pipe: %v", err)
	}
	cmdA.Stderr = os.Stderr
	if err := cmdA.Start(); err != nil {
		t.Fatalf("start A: %v", err)
	}
	// Read A's stdout until the post-COMMIT "acquired" line appears; capture
	// A's real pid. This gate guarantees the lease row is committed + fresh
	// before B runs (no timing race).
	var aPID int
	scanner := bufio.NewScanner(stdoutA)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var msg struct {
			Role   string `json:"role"`
			PID    int    `json:"pid"`
			Status string `json:"status"`
		}
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			continue
		}
		if msg.Role == "A" && msg.Status == "acquired" {
			aPID = msg.PID
			break
		}
	}
	if aPID == 0 {
		_ = cmdA.Process.Kill()
		_ = cmdA.Wait()
		t.Fatalf("A never signalled a committed acquire")
	}
	if osPID := cmdA.Process.Pid; osPID != aPID {
		t.Fatalf("A reported pid %d != its OS pid %d", aPID, osPID)
	}

	// --- Subprocess B: must conflict against A's fresh, committed lease. ---
	cmdB := leaseSubprocCmd("B", dbPath)
	var bStdout strings.Builder
	cmdB.Stdout = &bStdout
	cmdB.Stderr = os.Stderr
	if err := cmdB.Start(); err != nil {
		t.Fatalf("start B: %v", err)
	}
	bPID := cmdB.Process.Pid
	bErr := cmdB.Wait()

	// A has done its job; let it finish (it sleeps a few seconds then exits 0).
	if err := cmdA.Wait(); err != nil {
		t.Errorf("A exited with error: %v (exit=%d)", err, leaseExitCode(err))
	}

	// B must have exited non-zero, specifically with the conflict code.
	if code := leaseExitCode(bErr); code != leaseExitBConflict {
		t.Fatalf("B exit code = %d, want %d (ErrLeaseConflict + non-zero); stdout=%q",
			code, leaseExitBConflict, bStdout.String())
	}

	// Parse the payout_runner_lease_conflict event B emitted on stdout.
	ev := parseLeaseConflictEvent(t, bStdout.String())

	if got := ev["event"]; got != "payout_runner_lease_conflict" {
		t.Errorf("event = %v, want payout_runner_lease_conflict", got)
	}
	if got := ev["severity"]; got != "PAGE" {
		t.Errorf("severity = %v, want PAGE", got)
	}
	if got := ev["level"]; got != "error" {
		t.Errorf("level = %v, want error", got)
	}
	// All 7 §7.1 fields present.
	for _, f := range []string{
		"local_pid", "local_started_at_utc",
		"holder_host", "holder_pid", "holder_started_at_utc",
		"holder_heartbeat_at_utc", "ts_utc",
	} {
		if _, ok := ev[f]; !ok {
			t.Errorf("missing §7.1 field %q in %v", f, ev)
		}
	}

	// The crux this same-process test could never assert: holder_pid is A's
	// real pid, local_pid is B's real pid, and the two are DISTINCT.
	holderPID, ok := ev["holder_pid"].(float64)
	if !ok {
		t.Fatalf("holder_pid not numeric: %v", ev["holder_pid"])
	}
	localPID, ok := ev["local_pid"].(float64)
	if !ok {
		t.Fatalf("local_pid not numeric: %v", ev["local_pid"])
	}
	if int(holderPID) != aPID {
		t.Errorf("holder_pid = %d, want %d (A's real pid)", int(holderPID), aPID)
	}
	if int(localPID) != bPID {
		t.Errorf("local_pid = %d, want %d (B's real pid)", int(localPID), bPID)
	}
	if int(holderPID) == int(localPID) {
		t.Errorf("holder_pid == local_pid (%d): cross-process distinction not exercised", int(holderPID))
	}
}

// parseLeaseConflictEvent finds the payout_runner_lease_conflict JSON line in
// B's captured stdout and returns it as a map. Fails the test if absent.
func parseLeaseConflictEvent(t *testing.T, stdout string) map[string]any {
	t.Helper()
	for _, line := range strings.Split(stdout, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		if ev["event"] == "payout_runner_lease_conflict" {
			return ev
		}
	}
	t.Fatalf("payout_runner_lease_conflict event not found in B stdout=%q", stdout)
	return nil
}
