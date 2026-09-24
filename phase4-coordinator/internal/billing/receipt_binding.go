package billing

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"strings"
)

// BoundSettlementReceiptUsage checks that header is a v0.4 settlement receipt
// signed by pubkey (the provider's pinned receipt key) and bound to the
// attempt id and its route snapshot digest, and returns its billable input
// and output tokens. It moves no money: the settlement verifier still checks
// the output, usage, terminal state, and timestamps in full. It lets the
// ledger write refuse a loopback credit that no bound receipt backs.
func BoundSettlementReceiptUsage(header string, pubkey []byte, id SettlementReceiptIdentity, routeDigest string) (int64, int64, bool) {
	header = strings.TrimSpace(header)
	if header == "" || len(pubkey) != ed25519.PublicKeySize || routeDigest == "" {
		return 0, 0, false
	}
	tuple, signature, raw, result := parseSettlementReceiptV04(header)
	if result.Reason != "" || !bytes.Equal(raw, tuple.CanonicalBytes) || tuple.SignatureKeyAlg != "Ed25519" {
		return 0, 0, false
	}
	keyID, err := ReceiptKeyID(pubkey)
	if err != nil || tuple.ProviderReceiptKeyID != keyID || !ed25519.Verify(ed25519.PublicKey(pubkey), raw, signature) {
		return 0, 0, false
	}
	if tuple.AccountScope != id.AccountScope || tuple.RequestID != id.RequestID || tuple.AttemptN != id.AttemptN ||
		tuple.ProviderID != id.ProviderID || tuple.RouteSnapshotDigest != routeDigest {
		return 0, 0, false
	}
	return tuple.Usage.BillableInputTokens, tuple.Usage.BillableOutputTokens, true
}

// poolAttestedAttemptOutputRecorded reports whether the attempt's settlement
// evidence was recorded pool_operator_attested, which the recorder writes only
// after a ledger credit that a bound receipt backed.
func poolAttestedAttemptOutputRecorded(ctx context.Context, q PoolFenceQueryer, id SettlementReceiptIdentity) bool {
	var one int
	err := q.QueryRowContext(ctx, `
SELECT 1 FROM settlement_attempt_outputs
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?
   AND usage_source = ?
 LIMIT 1`, id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID, UsageSourcePoolOperatorAttested).Scan(&one)
	return err == nil && one == 1
}
