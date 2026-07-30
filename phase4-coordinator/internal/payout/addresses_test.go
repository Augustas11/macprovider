package payout

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"github.com/go-chi/chi/v5"
	"golang.org/x/crypto/sha3"
)

// fakeTokens implements providerTokenValidator + the providerIdentityChecker
// surface (HasActiveTokenForProvider). For Step 1 we don't need full
// auth; one trusted token maps to one providerID.
type fakeTokens struct {
	token      string
	providerID string
}

func (f *fakeTokens) ValidateToken(_ context.Context, raw string) (string, bool, error) {
	if raw == f.token {
		return f.providerID, true, nil
	}
	return "", false, nil
}

func (f *fakeTokens) HasActiveTokenForProvider(_ context.Context, providerID string) (bool, error) {
	return providerID == f.providerID, nil
}

// fakePause toggles via test mutex.
type fakePause struct {
	mu     sync.Mutex
	paused bool
}

func (f *fakePause) IsRegistrationPaused(_ context.Context) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.paused, nil
}

// toctouPause simulates a §6.4.1 pause endpoint firing AFTER
// the pre-auth check returns false but BEFORE the in-txn
// re-check reads runtime_flags. The pre-auth check itself sees
// paused=false (this struct's IsRegistrationPaused), but the
// FIRST call also flips runtime_flags.value=1 in the underlying
// SQLite DB so the §3.3 TOCTOU re-check inside BEGIN IMMEDIATE
// sees value=1 and ROLLBACKs with 503.
type toctouPause struct {
	mu    sync.Mutex
	db    *sql.DB
	fired bool
}

func (f *toctouPause) IsRegistrationPaused(_ context.Context) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.fired {
		// Pre-auth path returns false but races a pause flip
		// into the DB before the handler reaches the txn.
		if _, err := f.db.ExecContext(context.Background(),
			`UPDATE runtime_flags SET value=1, updated_at_utc='2026-01-08T00:00:00Z', updated_by_actor='operator_key:toctou', updated_reason='test' WHERE name='registration_paused'`,
		); err != nil {
			return false, err
		}
		f.fired = true
		return false, nil
	}
	return true, nil
}

func newServiceForTest(t *testing.T, db *sql.DB, hotWalletAddress, providerID, token string, pause pauseFlagReader) *AddressesService {
	t.Helper()
	if err := InitRunnerStateRow(context.Background(), db, time.Now().UTC()); err != nil {
		t.Fatalf("init runner_state: %v", err)
	}
	logger, _ := quietLogger()
	if err := BootstrapRuntimeFlags(context.Background(), db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}
	canonical, err := CanonicalizeEIP55(hotWalletAddress)
	if err != nil {
		t.Fatalf("canonicalize hot wallet: %v", err)
	}
	sec := SecurityConfig{HotWalletAddress: canonical}
	dl, err := NewDenyList(canonical)
	if err != nil {
		t.Fatalf("deny: %v", err)
	}
	ft := &fakeTokens{token: token, providerID: providerID}
	svc, err := NewAddressesService(db, sec, dl, ft, ft, pause, 24*time.Hour, logger)
	if err != nil {
		t.Fatalf("new service: %v", err)
	}
	return svc
}

func newRouter(t *testing.T, svc *AddressesService) http.Handler {
	t.Helper()
	r := chi.NewRouter()
	r.Post("/providers/{provider_id}/payout-address", svc.ServePayoutAddress)
	return r
}

// signerForTest returns a fresh secp256k1 private key + its
// canonical Ethereum address.
func signerForTest(t *testing.T) (*secp256k1.PrivateKey, string) {
	t.Helper()
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, err := hex.DecodeString(rawHex)
	if err != nil {
		t.Fatalf("decode priv key: %v", err)
	}
	priv := secp256k1.PrivKeyFromBytes(raw)
	pub := priv.PubKey()
	uncompressed := pub.SerializeUncompressed()
	h := sha3.NewLegacyKeccak256()
	_, _ = h.Write(uncompressed[1:])
	d := h.Sum(nil)
	addrLower := "0x" + hex.EncodeToString(d[len(d)-20:])
	canonical, err := CanonicalizeEIP55(addrLower)
	if err != nil {
		t.Fatalf("canon: %v", err)
	}
	return priv, canonical
}

func buildRequestBody(t *testing.T, priv *secp256k1.PrivateKey, providerID, providerAddr, hotWallet string, ts uint64, nonce32 [32]byte) string {
	t.Helper()
	const chain = "base-mainnet"
	inputs := EIP712Inputs{
		ProviderID:        providerID,
		CanonicalAddr:     providerAddr,
		Chain:             chain,
		Nonce32:           nonce32,
		TsUtc:             ts,
		VerifyingContract: hotWallet,
	}
	canonicalLower, err := NormalizeAddress(providerAddr)
	if err != nil {
		t.Fatalf("normalize provider addr: %v", err)
	}
	_ = canonicalLower
	// Mirror eip712_test.signEIP712 inline (avoid cross-test
	// imports of internal helpers).
	digest, err := buildDigest(inputs)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	// SignCompact returns 65 bytes <v><R><S>; reorder to <R><S><v>.
	compact := signCompactForTest(t, priv, digest[:])
	wire := make([]byte, 65)
	copy(wire[0:32], compact[1:33])
	copy(wire[32:64], compact[33:65])
	wire[64] = compact[0]
	sigHex := "0x" + hex.EncodeToString(wire)
	nonceHex := "0x" + hex.EncodeToString(nonce32[:])
	body, err := json.Marshal(map[string]any{
		"chain":     chain,
		"address":   providerAddr,
		"nonce":     nonceHex,
		"ts_utc":    ts,
		"signature": sigHex,
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(body)
}

func signCompactForTest(t *testing.T, priv *secp256k1.PrivateKey, digest []byte) []byte {
	t.Helper()
	return ecdsa.SignCompact(priv, digest, false)
}

func TestServePayoutAddress_HappyPath_FirstRegistration(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, uint64(time.Now().Unix()), [32]byte{1, 1, 1, 1, 1, 1, 1, 1})
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body.String())
	}
	// Row inserted with canonical address + stamped against the
	// canonical hot wallet.
	canonicalHot, _ := CanonicalizeEIP55(hotWallet)
	var addr, against string
	if err := db.QueryRowContext(context.Background(),
		`SELECT address, registered_against_hot_wallet FROM provider_payout_addresses WHERE provider_id='test-pid' AND chain='base-mainnet'`,
	).Scan(&addr, &against); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if addr != providerAddr {
		t.Errorf("addr stored = %q, want %q (canonical)", addr, providerAddr)
	}
	if against != canonicalHot {
		t.Errorf("registered_against_hot_wallet = %q, want %q", against, canonicalHot)
	}
}

func TestServePayoutAddress_PreAuthPauseReturns503Before401(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	pause := &fakePause{paused: true}
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", pause)
	// Also flip the runtime_flags row so the txn-side re-check would also
	// observe it if it ever reached that far — but we're testing the
	// pre-auth check here so the txn never runs.
	_, _ = db.ExecContext(context.Background(),
		`UPDATE runtime_flags SET value=1 WHERE name='registration_paused'`)
	r := newRouter(t, svc)

	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, uint64(time.Now().Unix()), [32]byte{2})
	// Note: NO Authorization header. SPEC requires 503 BEFORE
	// auth so timing-based pause detection is blocked.
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "rotation_in_progress") {
		t.Errorf("body=%q does not contain rotation_in_progress", rec.Body.String())
	}
}

func TestServePayoutAddress_TOCTOUPauseFlipDuringTxn_NoRowWritten(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	// Pre-auth check sees paused=false, but the same call also
	// flips runtime_flags.value=1; the in-txn TOCTOU re-check
	// reads runtime_flags directly and observes the pause.
	pause := &toctouPause{db: db}
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", pause)
	r := newRouter(t, svc)

	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, uint64(time.Now().Unix()), [32]byte{3, 3, 3})
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 (TOCTOU re-check), got %d body=%s", rec.Code, rec.Body.String())
	}
	// No row written.
	var count int
	if err := db.QueryRowContext(context.Background(),
		`SELECT count(*) FROM provider_payout_addresses WHERE provider_id='test-pid'`,
	).Scan(&count); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if count != 0 {
		t.Fatalf("provider_payout_addresses row written despite TOCTOU pause; count=%d", count)
	}
}

func TestServePayoutAddress_AntiReplay_SecondNonceRejected(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	nonce := [32]byte{0x9a, 0xbc}
	tsNow := uint64(time.Now().Unix())
	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, tsNow, nonce)
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Fatalf("first request expected 201/200, got %d body=%s", rec.Code, rec.Body.String())
	}
	// Replay — same (canonical_address, nonce) within retention.
	req2 := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req2.Header.Set("Authorization", "Bearer tok")
	rec2 := httptest.NewRecorder()
	r.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusBadRequest {
		t.Fatalf("replay expected 400, got %d body=%s", rec2.Code, rec2.Body.String())
	}
	if !strings.Contains(rec2.Body.String(), "nonce_replayed") {
		t.Errorf("replay body=%q does not contain nonce_replayed", rec2.Body.String())
	}
}

func TestServePayoutAddress_NonceMismatchInBody_RejectsAsSignatureMismatch(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	// Build the signed body, then mutate ONLY the body's nonce
	// field — the signature still covers the original nonce, so
	// VerifyEIP712's typed-data field-by-field check trips.
	tsNow := uint64(time.Now().Unix())
	originalNonce := [32]byte{0x77, 0x77}
	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, tsNow, originalNonce)
	mutated := strings.Replace(body,
		`"nonce":"0x7777`+strings.Repeat("00", 30)+`"`,
		`"nonce":"0x8888`+strings.Repeat("00", 30)+`"`,
		1,
	)
	if mutated == body {
		t.Fatal("test setup error: body nonce string replace did not apply")
	}
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(mutated))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("nonce-mismatch expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "signature_mismatch") {
		t.Errorf("body=%q does not contain signature_mismatch", rec.Body.String())
	}
}

func TestServePayoutAddress_DenyList(t *testing.T) {
	db := openTestDB(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	// Try to register the hot wallet itself as the payout target.
	// Signature need not validate — deny-list rejects first only
	// AFTER EIP-55 check (which passes) and BEFORE EIP-712. We
	// craft a request with valid format and let the deny-list
	// trip.
	denyAddr := hotWallet
	body := `{"chain":"base-mainnet","address":"` + denyAddr +
		`","nonce":"0x` + strings.Repeat("00", 32) + `","ts_utc":` +
		intString(time.Now().Unix()) + `,"signature":"0x` + strings.Repeat("00", 64) + `1b"}`
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		// Read body for the failure narrative.
		t.Fatalf("deny-list expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "denylist") {
		t.Errorf("body=%q does not contain denylist", rec.Body.String())
	}
}

func TestServePayoutAddress_SignatureSkew(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	// 10 minutes in the past — outside the ±5-minute window.
	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, uint64(time.Now().Add(-10*time.Minute).Unix()), [32]byte{4, 4})
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("skew expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "signature_skew") {
		t.Errorf("body=%q does not contain signature_skew", rec.Body.String())
	}
}

// TestServePayoutAddress_RotationPreservesPayoutAllowed_Zero locks
// codex round-1 [code:1.1] CRITICAL: a rotation against an existing
// row whose payout_allowed=0 MUST return 409 Conflict and MUST NOT
// silently re-enable the row.
func TestServePayoutAddress_RotationPreservesPayoutAllowed_Zero(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	// Seed an existing row with payout_allowed=0 (the §8 compliance
	// gate position the operator put the provider in).
	canonicalHot, _ := CanonicalizeEIP55(hotWallet)
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES ('test-pid', 'base-mainnet', '0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa',
        0, '2099-01-01T00:00:00Z', NULL, '2026-01-01T00:00:00Z', ?)`, canonicalHot); err != nil {
		t.Fatalf("seed disabled row: %v", err)
	}

	// Submit a valid rotation request.
	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet,
		uint64(time.Now().Unix()), [32]byte{0xab, 0xcd, 0xef})
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("rotation against payout_allowed=0 expected 409, got %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "payout_not_allowed") {
		t.Errorf("body=%q does not contain payout_not_allowed", rec.Body.String())
	}
	// Row MUST be unchanged: address still the seeded one,
	// payout_allowed still 0.
	var gotAddr string
	var gotAllowed int
	if err := db.QueryRowContext(context.Background(),
		`SELECT address, payout_allowed FROM provider_payout_addresses WHERE provider_id='test-pid' AND chain='base-mainnet'`,
	).Scan(&gotAddr, &gotAllowed); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if gotAddr != "0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa" {
		t.Errorf("address silently rotated under 409: got %q", gotAddr)
	}
	if gotAllowed != 0 {
		t.Errorf("payout_allowed silently re-enabled: got %d, want 0", gotAllowed)
	}
}

// TestServePayoutAddress_RotationPreservesPayoutAllowed_One is the
// dual-direction sanity check: rotation against a row whose
// payout_allowed=1 succeeds with 200 OK AND payout_allowed stays 1
// (so the explicit preservation does not regress the happy path).
func TestServePayoutAddress_RotationPreservesPayoutAllowed_One(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	canonicalHot, _ := CanonicalizeEIP55(hotWallet)
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES ('test-pid', 'base-mainnet', '0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa',
        1, '2099-01-01T00:00:00Z', NULL, '2026-01-01T00:00:00Z', ?)`, canonicalHot); err != nil {
		t.Fatalf("seed: %v", err)
	}

	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet,
		uint64(time.Now().Unix()), [32]byte{0x77, 0x88, 0x99})
	req := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("rotation against payout_allowed=1 expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var gotAllowed int
	if err := db.QueryRowContext(context.Background(),
		`SELECT payout_allowed FROM provider_payout_addresses WHERE provider_id='test-pid' AND chain='base-mainnet'`,
	).Scan(&gotAllowed); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if gotAllowed != 1 {
		t.Errorf("payout_allowed regressed on rotation: got %d, want 1", gotAllowed)
	}
}

// TestServePayoutAddress_NonceCanonicalisation_0XReplayDefeated locks
// codex round-1 [code:1.2] MEDIUM: a request whose request-side
// nonce string uses the "0X" prefix MUST share the anti-replay
// PK with the equivalent "0x" submission of the same 32 bytes.
//
// Strategy: submit one request with the canonical "0x" prefix,
// then submit a second request that re-uses the same signed body
// but rewrites the prefix to "0X". Both decode to the same nonce32
// bytes; the second submission MUST be rejected with
// nonce_replayed (NOT silently accepted as a fresh nonce). Note:
// the second submission's signature is still valid for the SAME
// nonce32 (signature was computed against the bytes, not the
// prefix), so signature_mismatch is NOT the expected error.
func TestServePayoutAddress_NonceCanonicalisation_0XReplayDefeated(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newRouter(t, svc)

	nonce := [32]byte{0x11, 0x22, 0x33}
	tsNow := uint64(time.Now().Unix())
	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, tsNow, nonce)

	// First submission: canonical "0x" prefix.
	req1 := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	req1.Header.Set("Authorization", "Bearer tok")
	rec1 := httptest.NewRecorder()
	r.ServeHTTP(rec1, req1)
	if rec1.Code != http.StatusCreated && rec1.Code != http.StatusOK {
		t.Fatalf("first submission expected 201/200, got %d body=%s", rec1.Code, rec1.Body.String())
	}

	// Second submission: rewrite the nonce field's "0x" prefix
	// to "0X". The bytes signed are identical (decodeSignatureHex
	// case-folds the prefix), so the EIP-712 verification
	// succeeds; the anti-replay table SHOULD trip on the canonical
	// key derived from the decoded bytes.
	canonicalNonceLower := "0x" + hex.EncodeToString(nonce[:])
	upperPrefixNonce := "0X" + hex.EncodeToString(nonce[:])
	mutated := strings.Replace(body,
		`"nonce":"`+canonicalNonceLower+`"`,
		`"nonce":"`+upperPrefixNonce+`"`,
		1,
	)
	if mutated == body {
		t.Fatal("test setup error: prefix rewrite did not apply")
	}
	req2 := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(mutated))
	req2.Header.Set("Authorization", "Bearer tok")
	rec2 := httptest.NewRecorder()
	r.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusBadRequest {
		t.Fatalf("0X-prefix replay expected 400 nonce_replayed, got %d body=%s", rec2.Code, rec2.Body.String())
	}
	if !strings.Contains(rec2.Body.String(), "nonce_replayed") {
		t.Errorf("0X-prefix replay body=%q does not contain nonce_replayed", rec2.Body.String())
	}
	// Belt-and-suspenders: assert the table has exactly ONE row
	// for this (canonical_address, nonce) tuple.
	var nonceRows int
	if err := db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM provider_payout_address_nonces WHERE nonce=?`, canonicalNonceLower,
	).Scan(&nonceRows); err != nil {
		t.Fatalf("scan nonce rows: %v", err)
	}
	if nonceRows != 1 {
		t.Errorf("anti-replay table row count = %d for canonical nonce; want exactly 1", nonceRows)
	}
}

// intString avoids strconv import for one tiny use.
func intString(n int64) string {
	if n == 0 {
		return "0"
	}
	negative := n < 0
	if negative {
		n = -n
	}
	out := []byte{}
	for n > 0 {
		out = append([]byte{byte('0' + n%10)}, out...)
		n /= 10
	}
	if negative {
		return "-" + string(out)
	}
	return string(out)
}

// drainBody is a util used by future audit-prompt tests; keeps
// the import list honest.
var _ = io.Discard
var _ = json.Marshal
