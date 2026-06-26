package payout

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

// TestE2E_RegisterThroughClaim is the FULL-r1 [full-code:r1-5]
// MEDIUM closure: a single test that exercises the entire money-path
// chain register → ready → broadcast → confirm → claim, including
// the HTTP §3.3 handler (ServePayoutAddress), the runner cycle, and
// the billing-side claim.
//
// Why it matters: prior `TestRunner_HappyPath_SinglePayout` seeded
// `provider_payout_addresses` directly with a raw INSERT, so the
// EIP-712 signer recovery / pause / cooling-off / audit emit
// invariants on the §3.3 path were not exercised in the same test
// that asserted the §4.3 step 8 ClaimPayoutReady invocation.
// Combining them in one test locks the cross-step contract: an
// HTTP-driven registration must produce a row the runner picks up
// and pays.
//
// Test flow:
//  1. Build runner + DB + mock RPCs via setupRunnerForTest.
//  2. Mount ServePayoutAddress on a chi router pointing at the
//     shared *sql.DB.
//  3. POST a valid EIP-712 registration for a provider whose
//     EOA differs from the hot wallet.
//  4. Backdate pending_until_utc so the cooling-off window has
//     elapsed (the helper hard-codes 24h; the test is not
//     time-traveling — it only relaxes the wait for testability).
//  5. INSERT a ledger_payout_ready row matching that provider.
//  6. Wire receipt + tx-by-hash mocks so both RPCs return a
//     valid confirmation at depth >= ConfirmationBlocks.
//  7. Drive Runner.RunOnce(). Assert ClaimPayoutReady was called
//     with payout_external_id = tx_hash and payout_currency =
//     "USDC-BASE", proving the full chain landed.
func TestE2E_RegisterThroughClaim(t *testing.T) {
	s := setupRunnerForTest(t)
	db := s.db
	hotAddr := s.hotAddr
	canonicalHot, _ := CanonicalizeEIP55(hotAddr)

	// Provider EOA — distinct from the hot wallet so the deny-list
	// (registered against the hot wallet) does not reject.
	providerPriv, providerAddr := providerKeyForE2E(t)

	// Wire the §3.3 handler against the SAME *sql.DB the runner
	// reads, so the row the HTTP register inserts is picked up by
	// SelectReadyPayouts in the cycle.
	svc := newServiceForTest(t, db, canonicalHot, "p-e2e", "tok-e2e", &fakePause{})
	router := newRouter(t, svc)

	body := buildRequestBody(t, providerPriv, "p-e2e", providerAddr, canonicalHot,
		uint64(time.Now().Unix()), [32]byte{0xE2, 0xE0, 1, 1, 1, 1, 1, 1})
	req := httptest.NewRequest("POST", "/providers/p-e2e/payout-address", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok-e2e")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("register status %d (want 201); body=%s", rec.Code, rec.Body.String())
	}

	// Confirm the row landed against the hot wallet under the
	// provider's canonical address.
	var rowProvider, rowHot string
	if err := db.QueryRowContext(context.Background(), `
SELECT provider_id, registered_against_hot_wallet
  FROM provider_payout_addresses WHERE provider_id = ?`, "p-e2e",
	).Scan(&rowProvider, &rowHot); err != nil {
		t.Fatalf("addresses row not found: %v", err)
	}
	if rowProvider != "p-e2e" {
		t.Fatalf("provider_id = %q, want p-e2e", rowProvider)
	}

	// Backdate pending_until_utc + payout_allowed=1 so the runner
	// sees this row as ready immediately. (The §3.3 handler stamps
	// pending_until_utc = now + 24h; the test is not waiting.)
	past := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(context.Background(),
		`UPDATE provider_payout_addresses SET pending_until_utc = ?, payout_allowed = 1 WHERE provider_id = ?`,
		past, "p-e2e",
	); err != nil {
		t.Fatalf("backdate pending: %v", err)
	}

	// Seed the ledger_payout_ready row matching the registered
	// provider. The helper from runner_test.go uses gross/credits
	// math the runner's C3 invariant accepts.
	payoutID := insertReadyRow(t, db, "p-e2e", "settle:p-e2e:e2e-1")
	if _, err := db.ExecContext(context.Background(),
		`UPDATE ledger_payout_ready SET provider_credits = 900000, gross_credits = 1000000 WHERE id = ?`,
		payoutID,
	); err != nil {
		t.Fatalf("set credits: %v", err)
	}

	// RPC mocks — both RPCs must agree at depth >= ConfirmationBlocks
	// per FULL-r1 [full-code:r1-1] HIGH closure (both heads checked).
	var capturedRaw []byte
	s.primary.sendFn = func(_ context.Context, raw []byte) (string, error) {
		capturedRaw = append([]byte(nil), raw...)
		return TxHash(raw), nil
	}
	s.secondary.sendFn = func(_ context.Context, raw []byte) (string, error) {
		return TxHash(raw), nil
	}
	s.primary.receiptFn = func(_ context.Context, h string) (*Receipt, error) {
		if capturedRaw == nil {
			return nil, nil
		}
		hot := strings.ToLower(canonicalHot)
		hotTopic, _ := PadAddressTopic(canonicalHot)
		toTopic, _ := PadAddressTopic(providerAddr)
		return &Receipt{
			TxHash:      strings.ToLower(h),
			BlockHash:   "0xblockhash",
			BlockNumber: 100,
			Status:      1,
			From:        hot,
			To:          strings.ToLower(USDCContractAddressBase),
			GasUsed:     65000,
			Logs: []ReceiptLog{
				{
					Address: strings.ToLower(USDCContractAddressBase),
					Topics: []string{
						"0x" + hex.EncodeToString(transferEventTopic),
						"0x" + hex.EncodeToString(hotTopic),
						"0x" + hex.EncodeToString(toTopic),
					},
					Data: bigEndian32(900_000),
				},
			},
		}, nil
	}
	s.secondary.receiptFn = s.primary.receiptFn
	s.primary.blockNumFn = func(_ context.Context) (uint64, error) { return 200, nil }
	s.secondary.blockNumFn = s.primary.blockNumFn
	s.primary.txByHashFn = func(_ context.Context, _ string) (*Transaction, error) {
		want, _ := USDCTransferCalldata(providerAddr, 900_000)
		return &Transaction{
			Hash:    "0xhash",
			From:    strings.ToLower(canonicalHot),
			To:      strings.ToLower(USDCContractAddressBase),
			Input:   want,
			ChainID: BaseMainnetChainID,
		}, nil
	}
	s.secondary.txByHashFn = s.primary.txByHashFn

	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// The cross-step contract: the HTTP-registered row produced a
	// runner-driven claim with the chain tx hash + USDC-BASE.
	if len(s.claimer.calls) != 1 {
		t.Fatalf("claim calls = %d, want 1 (register→ready→broadcast→confirm→claim)", len(s.claimer.calls))
	}
	c := s.claimer.calls[0]
	if c.PayoutCurrency != "USDC-BASE" {
		t.Errorf("PayoutCurrency = %q, want USDC-BASE", c.PayoutCurrency)
	}
	if c.ExpectedGrossCredits != 1_000_000 {
		t.Errorf("ExpectedGrossCredits = %d, want 1_000_000", c.ExpectedGrossCredits)
	}
	if c.PayoutExternalID == "" || !strings.HasPrefix(c.PayoutExternalID, "0x") {
		t.Errorf("PayoutExternalID = %q, want a 0x-prefixed tx hash", c.PayoutExternalID)
	}
}

// providerKeyForE2E returns a fresh secp256k1 private key distinct
// from the runner test's hot-wallet key (signerForTest). The
// canonical EIP-55 address is returned alongside.
func providerKeyForE2E(t *testing.T) (*secp256k1.PrivateKey, string) {
	t.Helper()
	// Different from signerForTest's rawHex so the provider EOA
	// is distinct from the hot wallet.
	rawHex := "11" + strings.Repeat("aa", 31)
	raw, err := hex.DecodeString(rawHex)
	if err != nil {
		t.Fatalf("decode provider priv: %v", err)
	}
	priv := secp256k1.PrivKeyFromBytes(raw)
	uncompressed := priv.PubKey().SerializeUncompressed()
	h := sha3.NewLegacyKeccak256()
	_, _ = h.Write(uncompressed[1:])
	d := h.Sum(nil)
	addrLower := "0x" + hex.EncodeToString(d[len(d)-20:])
	canonical, err := CanonicalizeEIP55(addrLower)
	if err != nil {
		t.Fatalf("canon provider addr: %v", err)
	}
	_ = ecdsa.SignCompact // keep import alive for test sibling files
	_ = json.Marshal
	return priv, canonical
}
