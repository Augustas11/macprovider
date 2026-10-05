package billing

import (
	"context"
	"strings"
	"testing"
)

func insertRelayBlindRequestLogRow(t *testing.T, store *Store, accountID, externalRequestID, internalRequestID, bindingDigest, envelopeDigest string) {
	t.Helper()
	if _, err := store.db.Exec(`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream,
		relay_blind_provider_binding_digest, relay_blind_envelope_digest)
		VALUES ('2026-10-05T00:00:00Z', ?, ?, ?, 'model', 0, 0, 200, 0, ?, ?)`,
		internalRequestID, externalRequestID, accountID, bindingDigest, envelopeDigest); err != nil {
		t.Fatal(err)
	}
}

// SPEC-022 R-14: the coordinator, not a header the gateway saw, says whether
// a relay-blind attempt was enforce-covered. Enforce needs an enforce
// relay-blind snapshot; observe needs the attempt's request-log row with the
// same binding and envelope digests and no relay-blind snapshot; anything
// else is unknown.
func TestRelayBlindSettlementCoverageIsCoordinatorAuthority(t *testing.T) {
	ctx := context.Background()
	const account = "acct_rb_coverage"
	binding := strings.Repeat("B", 43)
	envelope := strings.Repeat("E", 43)

	enforce := seedRelayBlindAttempt(t, func(s *RouteSnapshot) { s.AccountScope = AccountScopeForSettlement(account) })
	internalID := enforce.identity.RequestID
	got, err := enforce.store.RelayBlindSettlementCoverage(ctx, account, "ext-1", internalID, binding, envelope)
	if err != nil || got != RelayBlindCoverageEnforce {
		t.Fatalf("enforce snapshot coverage=%q err=%v", got, err)
	}
	// A request-log row never downgrades an enforce snapshot.
	insertRelayBlindRequestLogRow(t, enforce.store, account, "ext-1", internalID, binding, envelope)
	if got, err := enforce.store.RelayBlindSettlementCoverage(ctx, account, "ext-1", internalID, binding, envelope); err != nil || got != RelayBlindCoverageEnforce {
		t.Fatalf("enforce snapshot with request log coverage=%q err=%v", got, err)
	}
	// Another account never sees the snapshot.
	if got, err := enforce.store.RelayBlindSettlementCoverage(ctx, "acct_other", "ext-1", internalID, binding, envelope); err != nil || got != "" {
		t.Fatalf("cross-account coverage=%q err=%v", got, err)
	}

	_, store := newRequestAndBillingStores(t)
	if got, err := store.RelayBlindSettlementCoverage(ctx, account, "ext-2", "internal-observe", binding, envelope); err != nil || got != "" {
		t.Fatalf("unknown attempt coverage=%q err=%v", got, err)
	}
	insertRelayBlindRequestLogRow(t, store, account, "ext-2", "internal-observe", binding, envelope)
	if got, err := store.RelayBlindSettlementCoverage(ctx, account, "ext-2", "internal-observe", binding, envelope); err != nil || got != RelayBlindCoverageObserve {
		t.Fatalf("observe attempt coverage=%q err=%v", got, err)
	}
	for name, args := range map[string][5]string{
		"other external request": {account, "ext-x", "internal-observe", binding, envelope},
		"other binding":          {account, "ext-2", "internal-observe", strings.Repeat("C", 43), envelope},
		"other envelope":         {account, "ext-2", "internal-observe", binding, strings.Repeat("F", 43)},
		"other account":          {"acct_other", "ext-2", "internal-observe", binding, envelope},
		"other attempt":          {account, "ext-2", "internal-other", binding, envelope},
		"blank internal id":      {account, "ext-2", "", binding, envelope},
	} {
		if got, err := store.RelayBlindSettlementCoverage(ctx, args[0], args[1], args[2], args[3], args[4]); err != nil || got != "" {
			t.Fatalf("%s: coverage=%q err=%v, want unknown", name, got, err)
		}
	}
}
