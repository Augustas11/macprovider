package buyer

import (
	"crypto/ed25519"
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Independent review 2 LOWs: the loopback credit gate accepts a receipt
// signed with the provider's rotation-grace key inside the SPEC-015 grace
// window (and not after it), and binds the cached prompt count to the
// receipted prompt.
func TestPendingReceiptBacksUsageGraceKeyAndCachedBinding(t *testing.T) {
	currentPub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	previousPub, previous, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	hex64 := strings.Repeat("ab", 32)
	keyID, err := billing.ReceiptKeyID(previousPub)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().UnixMilli()
	tuple := map[string]any{
		"account_scope":                 accountScopeForSettlement("acct"),
		"attempt_n":                     0,
		"catalog_body_digest":           hex64,
		"catalog_id":                    "catalog",
		"expected_catalog_model_hash":   hex64,
		"issued_at_unix_ms":             now,
		"model_hash":                    hex64,
		"model_id":                      "model-a",
		"output_hash":                   hex64,
		"output_prefix_end_byte":        5,
		"output_prefix_start_byte":      0,
		"prompt_hash":                   hex64,
		"provider_id":                   "p1",
		"provider_receipt_key_id":       keyID,
		"receipt_version":               "4",
		"request_id":                    "req-1",
		"route_snapshot_digest":         hex64,
		"route_snapshot_mode":           "enforce",
		"route_snapshot_policy_version": "1",
		"signature_key_alg":             "Ed25519",
		"terminal_state":                billing.TerminalStateNormalDone,
		"terminal_state_ts_unix_ms":     now,
		"usage": map[string]any{
			"billable_input_tokens":  5,
			"billable_output_tokens": 3,
			"delivered_output_bytes": 5,
			"observed_input_tokens":  5,
			"observed_output_tokens": 3,
		},
	}
	_, canonical, err := billing.CanonicalSHA256Hex(tuple)
	if err != nil {
		t.Fatal(err)
	}
	header := base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(ed25519.Sign(previous, canonical))
	b := &billingRecorder{accountID: "acct", requestID: "req-1", settlementRouteSnapshotDigest: hex64}
	prompt, completion := int64(5), int64(3)
	backs := func(expiresAt time.Time, cached *int64) bool {
		provider := pool.Provider{ProviderID: "p1", ReceiptPubkey: currentPub, ReceiptPubkeyPrev: &pool.ReceiptPubkeyPrevious{Pubkey: previousPub, ExpiresAt: expiresAt}}
		var got bool
		_ = b.withPendingReceipt(provider, header, func() error {
			got = b.pendingReceiptBacksUsage("p1", &prompt, cached, &completion)
			return nil
		})
		return got
	}
	inGrace := time.Now().Add(time.Hour)
	if !backs(inGrace, nil) {
		t.Fatal("a receipt signed with the rotation-grace key did not back its usage inside the grace window")
	}
	if backs(time.Now().Add(-time.Minute), nil) {
		t.Fatal("a receipt signed with an expired previous key backed its usage")
	}
	two, six, negative := int64(2), int64(6), int64(-1)
	if !backs(inGrace, &two) {
		t.Fatal("a cached count within the receipted prompt was refused")
	}
	if backs(inGrace, &six) || backs(inGrace, &negative) {
		t.Fatal("a cached count outside [0, receipted prompt] backed the usage")
	}
}
