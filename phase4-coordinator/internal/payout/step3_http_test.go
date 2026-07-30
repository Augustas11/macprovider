package payout

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// helperPauseService spins up a §6.4.1 PauseResumeService against
// a fresh DB seeded with the §4.8a bootstrap state. Returns the
// service + the underlying writer for direct assertions.
func helperPauseService(t *testing.T) (*PauseResumeService, *RuntimeFlagWriter) {
	t.Helper()
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	w, err := NewRuntimeFlagWriter(db, zerolog.Nop())
	if err != nil {
		t.Fatalf("NewRuntimeFlagWriter: %v", err)
	}
	svc, err := NewPauseResumeService(PauseResumeOptions{
		Writer:      w,
		MinInterval: 0,
		Logger:      zerolog.Nop(),
	})
	if err != nil {
		t.Fatalf("NewPauseResumeService: %v", err)
	}
	return svc, w
}

// TestServePause_HappyPath_201IshThen409 covers ServePause via the
// real http.Handler interface, asserting:
//   - 200 OK on first call (flag flips 0→1)
//   - 409 already_paused on the second call
func TestServePause_HappyPath_201IshThen409(t *testing.T) {
	svc, _ := helperPauseService(t)
	// First call — pause succeeds.
	req1 := httptest.NewRequest("POST", "/admin/payout/pause-registration",
		bytes.NewBufferString(`{"reason":"hot wallet rotation"}`))
	rec1 := httptest.NewRecorder()
	svc.ServePause(rec1, req1, "operator_key:test")
	if rec1.Code != http.StatusOK {
		t.Fatalf("first pause: code=%d body=%s", rec1.Code, rec1.Body.String())
	}
	// Second call — already paused.
	req2 := httptest.NewRequest("POST", "/admin/payout/pause-registration",
		bytes.NewBufferString(`{"reason":"retry"}`))
	rec2 := httptest.NewRecorder()
	svc.ServePause(rec2, req2, "operator_key:test")
	if rec2.Code != http.StatusConflict {
		t.Errorf("second pause: code=%d body=%s, want 409", rec2.Code, rec2.Body.String())
	}
	if !strings.Contains(rec2.Body.String(), "already_paused") {
		t.Errorf("409 body missing already_paused: %s", rec2.Body.String())
	}
}

// TestServePause_MissingReason_400 covers the validation path.
func TestServePause_MissingReason_400(t *testing.T) {
	svc, _ := helperPauseService(t)
	req := httptest.NewRequest("POST", "/admin/payout/pause-registration",
		bytes.NewBufferString(`{"reason":""}`))
	rec := httptest.NewRecorder()
	svc.ServePause(rec, req, "actor")
	if rec.Code != http.StatusBadRequest {
		t.Errorf("code=%d, want 400", rec.Code)
	}
}

// TestServeResume_AlreadyRunning_409 covers the inverse 409.
func TestServeResume_AlreadyRunning_409(t *testing.T) {
	svc, _ := helperPauseService(t)
	req := httptest.NewRequest("POST", "/admin/payout/resume-registration",
		bytes.NewBufferString(`{"reason":"already running"}`))
	rec := httptest.NewRecorder()
	svc.ServeResume(rec, req, "actor")
	if rec.Code != http.StatusConflict {
		t.Errorf("code=%d, want 409 (flag starts at 0)", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "already_running") {
		t.Errorf("409 body missing already_running: %s", rec.Body.String())
	}
}

// TestServePause_RateLimit_429 covers the §6.4.1 rate-limit path
// using a positive MinInterval.
func TestServePause_RateLimit_429(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	w, _ := NewRuntimeFlagWriter(db, zerolog.Nop())
	now := time.Now()
	svc, _ := NewPauseResumeService(PauseResumeOptions{
		Writer:      w,
		MinInterval: 60 * time.Second,
		Logger:      zerolog.Nop(),
		NowFn:       func() time.Time { return now },
	})
	// First flip succeeds (0→1).
	req1 := httptest.NewRequest("POST", "/admin/payout/pause-registration",
		bytes.NewBufferString(`{"reason":"first"}`))
	rec1 := httptest.NewRecorder()
	svc.ServePause(rec1, req1, "actor")
	if rec1.Code != http.StatusOK {
		t.Fatalf("first: code=%d", rec1.Code)
	}
	// Subsequent flip BACK (1→0) within 60s should rate-limit.
	req2 := httptest.NewRequest("POST", "/admin/payout/resume-registration",
		bytes.NewBufferString(`{"reason":"undo"}`))
	rec2 := httptest.NewRecorder()
	svc.ServeResume(rec2, req2, "actor")
	if rec2.Code != http.StatusTooManyRequests {
		t.Errorf("rate-limit: code=%d, want 429", rec2.Code)
	}
}

// helperFundingService spins up a FundingService against a fresh
// DB. No RPCs wired — covers the manual + validation paths.
func helperFundingService(t *testing.T) (*FundingService, string) {
	t.Helper()
	hot := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	svc, err := NewFundingService(FundingOptions{
		DB:               db,
		RPCs:             nil,
		HotWalletAddress: hot,
		USDCAddress:      USDCContractAddressBase,
		Actor:            "operator_key:test",
		Logger:           zerolog.Nop(),
	})
	if err != nil {
		t.Fatalf("NewFundingService: %v", err)
	}
	return svc, hot
}

// TestServeRecordFunding_IdempotencyMismatch_422 verifies the
// §4.9 v0.1.20 round-20 C1 binding: header must equal body
// tx_hash (case-insensitive).
func TestServeRecordFunding_IdempotencyMismatch_422(t *testing.T) {
	svc, hot := helperFundingService(t)
	body, _ := json.Marshal(recordFundingRequest{
		FromAddress:     "0x000000000000000000000000000000000000dEaD",
		ToAddress:       hot,
		AmountBaseUnits: 100,
		TxHash:          "0xabc",
		BlockNumber:     1,
		Source:          "manual",
	})
	req := httptest.NewRequest("POST", "/admin/payout/record-funding", bytes.NewBuffer(body))
	req.Header.Set("Idempotency-Key", "0xMISMATCH") // != tx_hash
	rec := httptest.NewRecorder()
	svc.ServeRecordFunding(rec, req)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("code=%d, want 422", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "idempotency_key_mismatch") {
		t.Errorf("body missing idempotency_key_mismatch: %s", rec.Body.String())
	}
}

// TestServeRecordFunding_HotWalletSelfFund_400 verifies the
// v0.1.20 round-20 C2 deny-list.
func TestServeRecordFunding_HotWalletSelfFund_400(t *testing.T) {
	svc, hot := helperFundingService(t)
	body, _ := json.Marshal(recordFundingRequest{
		FromAddress:     hot, // self-fund — forbidden
		ToAddress:       hot,
		AmountBaseUnits: 100,
		TxHash:          "0xabc",
		BlockNumber:     1,
		Source:          "manual",
	})
	req := httptest.NewRequest("POST", "/admin/payout/record-funding", bytes.NewBuffer(body))
	req.Header.Set("Idempotency-Key", "0xabc")
	rec := httptest.NewRecorder()
	svc.ServeRecordFunding(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("code=%d, want 400 from_address_is_hot_wallet", rec.Code)
	}
}

// TestServeRecordFunding_ManualAccepts_201 verifies the manual
// path inserts a row when the bootstrap window is open.
func TestServeRecordFunding_ManualAccepts_201(t *testing.T) {
	svc, hot := helperFundingService(t)
	body, _ := json.Marshal(recordFundingRequest{
		FromAddress:     "0x000000000000000000000000000000000000dEaD",
		ToAddress:       hot,
		AmountBaseUnits: 1_000_000,
		TxHash:          "0xfedc",
		BlockNumber:     42,
		Source:          "manual",
	})
	req := httptest.NewRequest("POST", "/admin/payout/record-funding", bytes.NewBuffer(body))
	req.Header.Set("Idempotency-Key", "0xfedc")
	rec := httptest.NewRecorder()
	svc.ServeRecordFunding(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("code=%d body=%s, want 201", rec.Code, rec.Body.String())
	}
	// Verify the row.
	var count int
	_ = svc.db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM payout_hot_wallet_funding WHERE tx_hash=?`, "0xfedc",
	).Scan(&count)
	if count != 1 {
		t.Errorf("expected 1 funding row, got %d", count)
	}
}

// TestServeRecordFunding_ManualBootstrapReopenDefense_422 verifies
// codex Step 3 r1 [sec:1] CRITICAL closure: even if the
// payout_bootstrap_complete flag is reset to 0 by raw DB write
// (simulating a DROP+UPDATE+CREATE attack), the durable EXISTS
// check on confirmed payout_attempts blocks source='manual'.
func TestServeRecordFunding_ManualBootstrapReopenDefense_422(t *testing.T) {
	svc, hot := helperFundingService(t)
	// Set up state: insert a confirmed payout_attempts row (this
	// flips payout_bootstrap_complete=1 via trigger).
	payoutID := insertReadyRow(t, svc.db, "p1", "settle:p1:reopen")
	if _, err := svc.db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, confirmed_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0x', '0x', 1000, 1, X'02', '0xc0',
        '2026-01-08T00:00:00Z', '2026-01-08T01:00:00Z', 0, '2026-01-08T01:00:00Z')`,
		payoutID,
	); err != nil {
		t.Fatalf("insert confirmed attempt: %v", err)
	}
	// Simulate the DROP+UPDATE+CREATE attack: drop the one-way
	// trigger, reset the flag to 0, re-create the trigger.
	if _, err := svc.db.ExecContext(context.Background(),
		`DROP TRIGGER IF EXISTS trg_prs_bootstrap_one_way`); err != nil {
		t.Fatalf("drop trigger: %v", err)
	}
	if _, err := svc.db.ExecContext(context.Background(),
		`UPDATE payout_runner_state SET payout_bootstrap_complete=0 WHERE id=1`); err != nil {
		t.Fatalf("reset flag: %v", err)
	}
	if _, err := svc.db.ExecContext(context.Background(), `
CREATE TRIGGER IF NOT EXISTS trg_prs_bootstrap_one_way
BEFORE UPDATE OF payout_bootstrap_complete ON payout_runner_state
WHEN OLD.payout_bootstrap_complete = 1 AND NEW.payout_bootstrap_complete = 0
BEGIN
    SELECT RAISE(ABORT, 'payout_bootstrap_complete is one-way');
END`); err != nil {
		t.Fatalf("recreate trigger: %v", err)
	}
	// Now: trigger count = 3, flag = 0. The OLD code would have
	// accepted source='manual'. The NEW code rejects 422
	// bootstrap_complete because a confirmed attempt EXISTS.
	body, _ := json.Marshal(recordFundingRequest{
		FromAddress:     "0x000000000000000000000000000000000000dEaD",
		ToAddress:       hot,
		AmountBaseUnits: 1_000_000,
		TxHash:          "0xreopen",
		BlockNumber:     43,
		Source:          "manual",
	})
	req := httptest.NewRequest("POST", "/admin/payout/record-funding", bytes.NewBuffer(body))
	req.Header.Set("Idempotency-Key", "0xreopen")
	rec := httptest.NewRecorder()
	svc.ServeRecordFunding(rec, req)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("code=%d, want 422 bootstrap_complete (CRITICAL closure broken)", rec.Code)
	}
}

// TestServeRecordOrphan_DuplicateSubmission_409 verifies codex
// Step 3 r1 [code:1.1] MEDIUM closure: a UNIQUE index on
// (payout_id, attempt_seq, orphan_tx_hash) forces the dupe path
// to 409.
func TestServeRecordOrphan_DuplicateSubmission_409(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	svc, err := NewOrphansService(OrphansOptions{DB: db, Logger: zerolog.Nop()})
	if err != nil {
		t.Fatalf("NewOrphansService: %v", err)
	}
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:dupe")
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0x', '0x', 900000, 1, X'02', '0xdupe',
        '2026-01-08T00:00:00Z', 0, '2026-01-08T00:00:00Z')`,
		payoutID,
	); err != nil {
		t.Fatalf("insert attempt: %v", err)
	}
	bodyReq := recordOrphanRequest{
		PayoutID:      payoutID,
		AttemptSeq:    1,
		OrphanTxHash:  "0xdupe",
		LastSeenBlock: 123,
		RPCSource:     "both",
		Reason:        "first submission",
	}
	body, _ := json.Marshal(bodyReq)
	req := httptest.NewRequest("POST", "/admin/payout/record-orphan", bytes.NewBuffer(body))
	rec := httptest.NewRecorder()
	svc.ServeRecordOrphan(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("first submission: code=%d body=%s, want 201", rec.Code, rec.Body.String())
	}
	// Second submission with the SAME (payout_id, attempt_seq,
	// orphan_tx_hash) must 409.
	body2, _ := json.Marshal(bodyReq)
	req2 := httptest.NewRequest("POST", "/admin/payout/record-orphan", bytes.NewBuffer(body2))
	rec2 := httptest.NewRecorder()
	svc.ServeRecordOrphan(rec2, req2)
	if rec2.Code != http.StatusConflict {
		t.Errorf("duplicate submission: code=%d body=%s, want 409 orphan_already_recorded",
			rec2.Code, rec2.Body.String())
	}
}

// TestServeRecordOrphan_Resolve_404OnUnknownID verifies the
// resolve variant's 404 path.
func TestServeRecordOrphan_Resolve_404OnUnknownID(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	svc, _ := NewOrphansService(OrphansOptions{DB: db, Logger: zerolog.Nop()})
	body, _ := json.Marshal(recordOrphanRequest{
		OrphanID:           99999,
		OperatorResolution: "no compensation",
		Reason:             "test",
	})
	req := httptest.NewRequest("POST", "/admin/payout/record-orphan", bytes.NewBuffer(body))
	rec := httptest.NewRecorder()
	svc.ServeRecordOrphan(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Errorf("resolve unknown: code=%d, want 404", rec.Code)
	}
}

// TestReaper_StartStop_Idempotent verifies the Reaper.Stop bool
// + idempotent contract codex Step 3 r1 expects.
func TestReaper_StartStop_Idempotent(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	w, _ := NewRuntimeFlagWriter(db, zerolog.Nop())
	pauseSvc, _ := NewPauseResumeService(PauseResumeOptions{Writer: w, Logger: zerolog.Nop()})
	r, err := NewReaper(ReaperOptions{
		DB:        db,
		PauseSvc:  pauseSvc,
		TickEvery: 50 * time.Millisecond,
		StaleAge:  150 * time.Millisecond,
		Logger:    zerolog.Nop(),
	})
	if err != nil {
		t.Fatalf("NewReaper: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r.Start(ctx)
	r.Start(ctx) // second Start MUST be a no-op
	// Stop within a generous deadline.
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer stopCancel()
	if !r.Stop(stopCtx) {
		t.Error("Stop returned false; expected clean exit")
	}
	if !r.Stop(stopCtx) {
		t.Error("second Stop returned false; expected idempotent true")
	}
}

// TestReorgPoller_StartStop_Idempotent verifies the Step 3 r1
// [arch:3.1] closure: poller owns Start/Stop, returns bool, and
// idempotent.
func TestReorgPoller_StartStop_Idempotent(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	p := &ReorgPoller{
		DB:          db,
		HotWallet:   "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		PollWindow:  time.Hour,
		RunInterval: 50 * time.Millisecond,
		Logger:      zerolog.Nop(),
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)
	p.Start(ctx) // idempotent
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer stopCancel()
	if !p.Stop(stopCtx) {
		t.Error("first Stop returned false; expected clean exit")
	}
	if !p.Stop(stopCtx) {
		t.Error("second Stop returned false; expected idempotent true")
	}
}
