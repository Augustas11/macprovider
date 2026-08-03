package payout

import (
	"context"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func setupAbandonService(t *testing.T) (*AbandonService, *mockRPCClient, *mockRPCClient) {
	t.Helper()
	db := openTestDB(t)
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, _ := NewLocalFileSignerFromKey(raw)
	logger, _ := quietLogger()
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	svc, err := NewAbandonService(db, SecurityConfig{HotWalletAddress: signer.FromAddress()},
		TwoRPCs{Primary: primary, Secondary: secondary}, signer, 5*time.Minute, logger,
	)
	if err != nil {
		t.Fatalf("NewAbandonService: %v", err)
	}
	svc.NowFn = func() time.Time { return time.Now().UTC() }
	return svc, primary, secondary
}

func defaultCaps() AbandonCaps {
	return AbandonCaps{
		CancelMaxTipMultiplier:      5.0,
		CancelMaxGasNativeWei:       10_000_000_000_000_000,
		CancelMaxGasNativeWeiPer24h: 50_000_000_000_000_000,
		AbandonRatePerHour:          3,
	}
}

func TestAbandon_NotFound(t *testing.T) {
	svc, _, _ := setupAbandonService(t)
	body := `{"payout_id":99,"attempt_seq":1,"confirm":true,"reason":"x"}`
	req := httptest.NewRequest("POST", "/admin/payout/abandon-attempt", strings.NewReader(body))
	req.Header.Set("Idempotency-Key", "key1")
	rec := httptest.NewRecorder()
	svc.ServeAbandon(rec, req, "operator_key:test", defaultCaps())
	if rec.Code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404 body=%s", rec.Code, rec.Body.String())
	}
}

func TestAbandon_RunnerActiveReturns409(t *testing.T) {
	svc, _, _ := setupAbandonService(t)
	// Acquire a fresh lease so the runner-active gate trips.
	logger, _ := quietLogger()
	_, _, _ = Acquire(context.Background(), svc.DB, 5*time.Minute, logger)
	// Seed an attempt row.
	pid := insertReadyRow(t, svc.DB, "p1", "settle:p1:1")
	_, _ = svc.DB.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xfrom', '0xto', 100, 1, 0, ?)`,
		pid, NowUTC())

	body := `{"payout_id":` + intString(pid) + `,"attempt_seq":1,"confirm":true,"reason":"runner-active"}`
	req := httptest.NewRequest("POST", "/admin/payout/abandon-attempt", strings.NewReader(body))
	req.Header.Set("Idempotency-Key", "key2")
	rec := httptest.NewRecorder()
	svc.ServeAbandon(rec, req, "operator_key:test", defaultCaps())
	if rec.Code != http.StatusConflict {
		t.Fatalf("code = %d, want 409 body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "runner_active") {
		t.Errorf("body=%s does not contain runner_active", rec.Body.String())
	}
}

func TestAbandon_HappyPath_NoCancel(t *testing.T) {
	svc, _, _ := setupAbandonService(t)
	// No lease → runner inactive.
	pid := insertReadyRow(t, svc.DB, "p1", "settle:p1:1")
	_, _ = svc.DB.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xfrom', '0xto', 100, 1, 0, ?)`,
		pid, NowUTC())

	body := `{"payout_id":` + intString(pid) + `,"attempt_seq":1,"confirm":true,"reason":"test"}`
	req := httptest.NewRequest("POST", "/admin/payout/abandon-attempt", strings.NewReader(body))
	req.Header.Set("Idempotency-Key", "key3")
	rec := httptest.NewRecorder()
	svc.ServeAbandon(rec, req, "operator_key:test", defaultCaps())
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200 body=%s", rec.Code, rec.Body.String())
	}
	// Row marked abandoned.
	var abandoned string
	_ = svc.DB.QueryRowContext(context.Background(),
		`SELECT abandoned_at_utc FROM payout_attempts WHERE payout_id = ? AND attempt_seq = 1`, pid,
	).Scan(&abandoned)
	if abandoned == "" {
		t.Error("abandoned_at_utc should be set")
	}
}

func TestAbandon_MissingReason400(t *testing.T) {
	svc, _, _ := setupAbandonService(t)
	body := `{"payout_id":1,"attempt_seq":1,"confirm":true}`
	req := httptest.NewRequest("POST", "/admin/payout/abandon-attempt", strings.NewReader(body))
	req.Header.Set("Idempotency-Key", "k")
	rec := httptest.NewRecorder()
	svc.ServeAbandon(rec, req, "actor", defaultCaps())
	if rec.Code != http.StatusBadRequest {
		t.Errorf("code = %d, want 400", rec.Code)
	}
}

func TestAbandon_MissingIdempotencyKey400(t *testing.T) {
	svc, _, _ := setupAbandonService(t)
	body := `{"payout_id":1,"attempt_seq":1,"confirm":true,"reason":"x"}`
	req := httptest.NewRequest("POST", "/admin/payout/abandon-attempt", strings.NewReader(body))
	rec := httptest.NewRecorder()
	svc.ServeAbandon(rec, req, "actor", defaultCaps())
	if rec.Code != http.StatusBadRequest {
		t.Errorf("code = %d, want 400", rec.Code)
	}
}

func TestAbandon_RateLimit429(t *testing.T) {
	svc, _, _ := setupAbandonService(t)
	caps := defaultCaps()
	caps.AbandonRatePerHour = 1
	// First call should pass through to lookup (404 because no row).
	_, _ = svc.DB.ExecContext(context.Background(), `INSERT INTO ledger_payout_ready
		(provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
		 gross_credits, provider_credits, operator_credits, min_payout_credits, idempotency_key, created_at_utc)
		 VALUES ('a','2026-01-01T00:00:00Z','2026-01-08T00:00:00Z',7,1,1,1,0,0,'settle:a:1','2026-01-08T00:00:00Z')`)
	body := `{"payout_id":1,"attempt_seq":1,"confirm":true,"reason":"x"}`
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest("POST", "/admin/payout/abandon-attempt", strings.NewReader(body))
		req.Header.Set("Idempotency-Key", "k"+string(rune('0'+i)))
		rec := httptest.NewRecorder()
		svc.ServeAbandon(rec, req, "actor", caps)
		if i == 0 && rec.Code == http.StatusTooManyRequests {
			t.Fatal("first call should not be rate-limited")
		}
		if i == 1 && rec.Code != http.StatusTooManyRequests {
			t.Errorf("second call code = %d, want 429", rec.Code)
		}
	}
}
