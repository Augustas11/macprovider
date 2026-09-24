package integration

import (
	"bytes"
	"context"
	"net/http"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// SPEC-005-R013 rule 1 at process start: a coordinator started on a
// mismatched on-disk pair (yaml B + card A) refuses to start, writes no
// snapshot row and no applied-config record.
func TestPricingLaneBootRefusesMismatchedPair(t *testing.T) {
	p := newPricingLane(t, pricingLaneOpts{})
	cardB, _ := p.cardB()
	bootRec := p.applied()
	snaps := len(p.snapshots())
	yamlB := p.spliceYAML(p.coordYAML, rateCardBlock(cardB))
	p.stopCoordinator()
	writeFileAtomic(t, p.coordYAML, yamlB) // card stays A: the mismatched I4 interval

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, p.coordBin, "-config", p.coordYAML, "-applied-config-state", p.statePath)
	out, err := cmd.CombinedOutput()
	ee, isExit := err.(*exec.ExitError)
	if err == nil || !isExit || ee.ExitCode() == 0 || ctx.Err() != nil {
		t.Fatalf("coordinator on a mismatched pair did not refuse to start (err=%v):\n%s", err, out)
	}
	if !bytes.Contains(out, []byte("runtime rate-card parity")) {
		t.Errorf("boot refusal does not name the parity failure:\n%s", out)
	}
	if got := len(p.snapshots()) - snaps; got != 0 {
		t.Errorf("refused boot wrote %d snapshot rows", got)
	}
	if rec := p.applied(); !bytes.Equal(rec.raw, bootRec.raw) {
		t.Errorf("refused boot rewrote the applied-config record: %s", rec.raw)
	}
}

// BUG (SPEC-005 §11.7 "fail closed with a named error"): a wholesale
// statement whose request attempt links two generations that price it
// differently fails closed, but the only operator-visible outcome is a
// generic 500 `internal_error` / "could not generate wholesale statement"
// and the coordinator logs nothing: ErrWholesaleConflictingGenerations is
// dropped by the handler's default branch
// (phase4-coordinator/internal/billing/wholesale.go wholesaleStatements
// POST). An operator cannot tell a data conflict that needs investigation
// from a store outage. This test is expected to FAIL until the handler
// names the error (response code/message or a log line).
func TestPricingLaneBugWholesaleConflictErrorIsNamed(t *testing.T) {
	p := newPricingLane(t, pricingLaneOpts{})
	cardB, cardBRaw := p.cardB()
	p.installPricing(p.spliceYAML(p.coordYAML, rateCardBlock(cardB)), cardBRaw)
	if ok, logs := p.sighup(rejectMarkersAll...); !ok {
		t.Fatalf("A->B reload rejected:\n%s", strings.Join(logs, "\n"))
	}
	snaps := p.snapshots()
	snapA, snapB := snaps[0], snaps[len(snaps)-1]
	db := p.openCoordDB()
	defer db.Close()
	ts := time.Now().UTC().Format(time.RFC3339Nano)
	for i := 0; i < 2; i++ {
		if _, err := db.Exec(`INSERT INTO request_log (ts_utc, request_id, account_id, model, provider_assigned_id, prompt_tokens, completion_tokens, total_tokens, latency_ms, routing_ms, status, stream, attempt_n)
VALUES (?, 'bug-conflict', 'acct_bug_conflict', ?, 'pa-bug', 10, 10, 20, 1, 1, 200, 0, 0)`, ts, pricingLlamaKey); err != nil {
			t.Fatal(err)
		}
	}
	for ordinal, snap := range []int64{snapA.ID, snapB.ID} {
		if _, err := db.Exec(`INSERT INTO ledger_provider_identity_snapshots (request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, config_snapshot_id, created_at_utc)
VALUES ('bug-conflict', ?, 'pa-bug', ?, 'pool_entry', ?, ?)`, ordinal, p.providerID, snap, ts); err != nil {
			t.Fatal(err)
		}
	}
	mark := len(p.coordLogBuf.snapshot())
	st := p.generateWholesale("acct_bug_conflict")
	if st.status == http.StatusOK {
		t.Fatalf("conflict produced a statement: %s", st.raw)
	}
	time.Sleep(300 * time.Millisecond)
	named := strings.Contains(strings.ToLower(string(st.raw)), "conflict")
	for _, line := range p.coordLogBuf.snapshot()[mark:] {
		if strings.Contains(line, "conflicting billing config generations") {
			named = true
		}
	}
	if !named {
		t.Errorf("wholesale conflict failed closed without a named error: HTTP %d %s and no coordinator log line naming it", st.status, st.raw)
	}
}
