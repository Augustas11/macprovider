package billing

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// #1816 freeze R1 regression tests for final receipt settlement: the durable
// pool fence and the settlement-time label are decided in the transaction
// that writes the terminal verdict and its credit (SECURITY H1, H2), and a
// signed receipt never raises the completion count above the ledger's
// byte-derived ceiling (SECURITY H3).

// nativePoolManifestSettlementInput is a signed v0.4 receipt for a natively
// served (mlx_cache) pool_manifest attempt whose usage is coordinator
// observed.
func nativePoolManifestSettlementInput(t *testing.T) SettlementVerifyInput {
	t.Helper()
	fixtures := loadSettlementVerifierFixtures(t)
	tuple := settlementReceiptTuplesByID(fixtures)["receipt_tuple_v4_normal_done"]
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pub)
	keyID, err := ReceiptKeyID(pub)
	if err != nil {
		t.Fatal(err)
	}
	input.ProviderReceiptKeyID = keyID
	input.RouteSnapshot.ProviderReceiptKeyID = keyID
	input.RouteSnapshot.ProviderReceiptKeySource = "auth_session"
	input.RouteSnapshot.ProviderReportedModelHashAlgorithm = modelidentity.SnapshotManifestV1
	input.RouteSnapshot.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
	input.RouteSnapshot = poolManifestSnapshot(input.RouteSnapshot)
	if err := input.RouteSnapshot.Validate(); err != nil {
		t.Fatalf("native pool_manifest snapshot: %v", err)
	}
	input.ProviderReceiptPubkey = pub
	input.Header = signedSettlementReceiptForInputWithKey(t, input, priv)
	return input
}

func liveLabels(version uint64, digest string) func(string) *SettlementPoolLabels {
	return func(routeHash string) *SettlementPoolLabels {
		return &SettlementPoolLabels{PoolID: testPoolID, ManifestVersion: version, ManifestCoreDigest: digest, RouteSnapshotHash: routeHash}
	}
}

func ledgerCreditState(t *testing.T, store *Store, requestID string) (providerCredits, quarantined int64, reason string) {
	t.Helper()
	var r *string
	if err := store.db.QueryRow(`SELECT provider_credits, quarantined, quarantine_reason FROM ledger_request_credits WHERE request_id = ?`, requestID).
		Scan(&providerCredits, &quarantined, &r); err != nil {
		t.Fatal(err)
	}
	if r != nil {
		reason = *r
	}
	return providerCredits, quarantined, reason
}

// SECURITY H1: a decided revocation between routing and a delayed receipt
// (membership, delegation, attestation, pool retired or frozen) is read in
// the verdict transaction: the verified receipt quarantines and the credit
// is zeroed, never left payable.
func TestFreezeR1FinalReceiptSettlementReadsTheDurableFence(t *testing.T) {
	revoked := fmt.Errorf("%w: provider membership revoked since routing", ErrPoolOperatorAttestationRejected)
	for name, input := range map[string]SettlementVerifyInput{
		"loopback pool_operator_attested": r012SettlementInput(t, "receipt_tuple_v4_normal_done", true),
		"native pool_manifest":            nativePoolManifestSettlementInput(t),
	} {
		t.Run(name, func(t *testing.T) {
			source, labels := UsageSourcePoolOperatorAttested, matchingR012Labels
			if input.RouteSnapshot.PoolManifestSourced() {
				source, labels = UsageSourceCoordinatorObserved, liveLabels(2, strings.Repeat("d", 64))
			}
			authority := &fencedPoolAuthority{results: []error{revoked}}
			run := runR012Settlement(t, input, source, authority, labels)
			if run.state.SettlementOutcome != SettlementOutcomeQuarantined || run.state.Reason != PoolRouteFenceNotSettlementEligible {
				t.Fatalf("revoked pool route outcome=%s reason=%s, want quarantined %s", run.state.SettlementOutcome, run.state.Reason, PoolRouteFenceNotSettlementEligible)
			}
			if authority.reads == 0 {
				t.Fatal("final settlement never read the durable fence")
			}
			credits, quarantined, reason := ledgerCreditState(t, run.store, input.RequestID)
			if credits != 0 || quarantined != 1 || reason != PoolRouteFenceNotSettlementEligible {
				t.Fatalf("ledger credit=%d quarantined=%d reason=%q, want zeroed and quarantined", credits, quarantined, reason)
			}
			if run.finality.Outcome == SettlementOutcomeVerified {
				t.Fatalf("buyer finality verified a revoked pool attempt: %+v", run.finality)
			}

			// The same route with a holding fence still settles.
			held := runR012Settlement(t, input, source, stableFencedAuthority(), labels)
			if held.state.SettlementOutcome != SettlementOutcomeVerified {
				t.Fatalf("holding fence outcome=%s reason=%s, want verified", held.state.SettlementOutcome, held.state.Reason)
			}
		})
	}
}

// SECURITY H1: a fence that cannot be read is not a verdict. The receipt is
// rolled back for a retry and no verdict is written.
func TestFreezeR1FinalReceiptFenceReadFailureIsRetryable(t *testing.T) {
	input := nativePoolManifestSettlementInput(t)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetPoolOperatorAttestationAuthority(&fencedPoolAuthority{results: []error{errors.New("database is locked")}})
	store.SetSettlementPoolLabelSource(func(poolID string) (uint64, string, bool) {
		return 2, strings.Repeat("d", 64), poolID == testPoolID
	})
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	routeHash, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.IngestPoolSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		PoolLabels:                liveLabels(2, strings.Repeat("d", 64))(routeHash),
	}.WithReceivedAt(input.ReceiptReceivedUnixMS))
	if !errors.Is(err, ErrPoolOperatorAttestationTransient) {
		t.Fatalf("err=%v, want ErrPoolOperatorAttestationTransient", err)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE request_id = ?`, input.RequestID); n != 0 {
		t.Fatalf("unreadable fence wrote %d verdicts, want 0", n)
	}
	if credits, quarantined, _ := ledgerCreditState(t, store, input.RequestID); credits != 700 || quarantined != 0 {
		t.Fatalf("unreadable fence changed the ledger: credit=%d quarantined=%d", credits, quarantined)
	}
}

// SECURITY H2: a native pool attempt whose settlement-time label is an
// earlier generation, or the same generation with another digest, is
// disputed. Its coordinator-observed usage does not make it payable.
func TestFreezeR1NativePoolAttemptWithDisputedLabelQuarantines(t *testing.T) {
	for name, labels := range map[string]func(string) *SettlementPoolLabels{
		"earlier generation":       liveLabels(1, strings.Repeat("d", 64)),
		"same generation, forked":  liveLabels(2, strings.Repeat("e", 64)),
		"pool unknown at settling": nil,
	} {
		t.Run(name, func(t *testing.T) {
			input := nativePoolManifestSettlementInput(t)
			run := runR012Settlement(t, input, UsageSourceCoordinatorObserved, stableFencedAuthority(), labels)
			if run.state.SettlementOutcome == SettlementOutcomeVerified {
				t.Fatalf("disputed native pool attempt settled verified: %+v", run.state)
			}
			if credits, _, _ := ledgerCreditState(t, run.store, input.RequestID); credits != 0 {
				t.Fatalf("disputed native pool attempt kept provider credit %d", credits)
			}
		})
	}
}

// SECURITY H3: the receipt-bound completion count replaces the ledger's
// only up to the ledger's independent byte-derived ceiling; the lower value
// bills, as byte_estimated, exactly as the hot path clamps.
func TestFreezeR1ReceiptCompletionNeverExceedsByteCeiling(t *testing.T) {
	input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", false)
	if input.ExpectedUsage.BillableOutputTokens <= 1 {
		t.Fatalf("fixture completion %d too small to show the clamp", input.ExpectedUsage.BillableOutputTokens)
	}
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	// One credit per completion token, none for the prompt, and a delivered
	// byte ceiling of one token.
	if _, err := store.db.Exec(`UPDATE ledger_request_credits
   SET prompt_rate_per_mtok = 0, completion_rate_per_mtok = 1000000, estimated_completion_tokens = 1
 WHERE request_id = ?`, input.RequestID); err != nil {
		t.Fatal(err)
	}
	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified {
		t.Fatalf("outcome=%s reason=%s, want verified", state.SettlementOutcome, state.Reason)
	}
	var gross, estimate int64
	var usageSource string
	if err := store.db.QueryRow(`SELECT gross_credits, usage_source, estimated_completion_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID).
		Scan(&gross, &usageSource, &estimate); err != nil {
		t.Fatal(err)
	}
	if gross != 1 || usageSource != UsageByteEstimated || estimate != 1 {
		t.Fatalf("receipt-synced gross=%d usage_source=%s estimate=%d, want the clamped 1 credit as byte_estimated", gross, usageSource, estimate)
	}
}
