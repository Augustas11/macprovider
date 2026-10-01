package trustpool_test

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// runbookRollbackCheck extracts the step 4b manifest-history check from the
// production launch runbook exactly as an operator runs it (the same
// extraction scripts/lab/1690-e2e/check4b.sh uses).
func runbookRollbackCheck(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "runbooks", "trusted-pool-production-launch.md"))
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	on := false
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case !on && line == `   sudo python3 - "$COORDINATOR_DB" m8 <<'PY'`:
			on = true
		case on && line == "   PY":
			return out.Bytes()
		case on:
			out.WriteString(strings.TrimPrefix(line, "   ") + "\n")
		}
	}
	t.Fatal("runbook step 4b check block not found")
	return nil
}

func runRollbackCheck(t *testing.T, script []byte, dbPath, tier string) (string, int) {
	t.Helper()
	cmd := exec.Command("python3", "-", dbPath, tier)
	cmd.Stdin = bytes.NewReader(script)
	out, err := cmd.CombinedOutput()
	code := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run rollback check: %v", err)
	}
	return string(out), code
}

// Freeze audit R1 (#1816) ARCHITECTURE H1: once a policy core carrying a
// SPEC-042-R015/R016 extension is accepted, the step 4b rollback check
// refuses every target tier older than the #1816 build (which would reject
// the unknown extension_id while replaying history) and approves p1816.
func TestRunbookRollbackCheckRefusesTargetsWithoutExtensionCodec(t *testing.T) {
	script := runbookRollbackCheck(t)
	ctx := context.Background()
	build := func(withExtensions bool) string {
		path := filepath.Join(t.TempDir(), "coordinator.db")
		db, err := sql.Open("sqlite", sqliteutil.WithPragmas(path))
		if err != nil {
			t.Fatal(err)
		}
		db.SetMaxOpenConns(1)
		defer db.Close()
		store, err := trustpool.NewStore(db, trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
		if err != nil {
			t.Fatal(err)
		}
		ts := time.Unix(1800040000, 0).UTC()
		root := newRootFixture(t)
		approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
		v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.SettlementMode = "enforce"
		})
		mutate := allowLlamacpp
		if withExtensions {
			mutate = withPoolModels(root.poolID, nil)
		}
		v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", ts.Add(3*time.Second), v1, root, mutate)
		appendTrustPoolEvents(t, ctx, store,
			ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
				e.CreatorAccountID = "creator-a"
				e.ApprovalRecordID = "approval-v1"
			}),
			signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
			v1,
			v2,
		)
		if _, err := db.ExecContext(ctx, "PRAGMA wal_checkpoint(TRUNCATE)"); err != nil {
			t.Fatal(err)
		}
		return path
	}

	extended := build(true)
	for tier, wantCode := range map[string]int{"v1-only": 1, "m8": 1, "m9": 1, "p1816": 0} {
		out, code := runRollbackCheck(t, script, extended, tier)
		if code != wantCode {
			t.Fatalf("tier %s with extension history: exit %d want %d\n%s", tier, code, wantCode, out)
		}
		if wantCode == 1 && (!strings.Contains(out, "VERDICT: STOP") || (tier != "v1-only" && !strings.Contains(out, "extension pool_model_entries/v1"))) {
			t.Fatalf("tier %s: STOP does not name the extension\n%s", tier, out)
		}
		if wantCode == 0 && !strings.Contains(out, "VERDICT: replayable") {
			t.Fatalf("tier %s: no replayable verdict\n%s", tier, out)
		}
	}
	// A v2 history without extensions stays replayable on m9.
	plain := build(false)
	if out, code := runRollbackCheck(t, script, plain, "m9"); code != 0 || !strings.Contains(out, "extensions in history: none") {
		t.Fatalf("extension-free v2 history on m9: exit %d\n%s", code, out)
	}
}
