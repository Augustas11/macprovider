package billing

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// SPEC-022-R012 (v0.2.0, #1690 M4): the pool_operator_attested usage source
// settles only through a verified receipt whose usage matches exactly, and
// only when the persisted snapshot re-evaluates as R-12 at settlement (the
// durable pool records and an undisputed label). AC-022-66.

type fakePoolAttestationAuthority struct {
	err   error
	calls int
	last  PoolOperatorAttestationClaim
}

func (f *fakePoolAttestationAuthority) VerifyPoolOperatorAttestation(_ context.Context, claim PoolOperatorAttestationClaim) error {
	f.calls++
	f.last = claim
	return f.err
}

func r012SettlementInput(t *testing.T, terminal string, external bool) SettlementVerifyInput {
	t.Helper()
	fixtures := loadSettlementVerifierFixtures(t)
	tuple := settlementReceiptTuplesByID(fixtures)[terminal]
	if tuple.ID == "" {
		t.Fatalf("missing fixture tuple %s", terminal)
	}
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
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	if external {
		input.RouteSnapshot.PoolID = "pool-abc"
		input.RouteSnapshot.ManifestVersion = 2
		input.RouteSnapshot.ManifestCoreDigest = strings.Repeat("d", 64)
		input.RouteSnapshot.RuntimeSource = "llamacpp_loopback"
		input.RouteSnapshot.PoolGeneration = 7
		input.RouteSnapshot.PoolOperatorAccountID = "creator-a"
	}
	input.ProviderReceiptPubkey = pub
	input.Header = signedSettlementReceiptForInputWithKey(t, input, priv)
	return input
}

type r012Run struct {
	state    SettlementReceiptState
	finality RequestSettlementFinality
	store    *Store
}

func runR012Settlement(t *testing.T, input SettlementVerifyInput, source string, authority PoolOperatorAttestationAuthority, labels func(routeHash string) *SettlementPoolLabels) r012Run {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	if authority != nil {
		store.SetPoolOperatorAttestationAuthority(authority)
	}
	seedSettlementReceiptEvidence(t, store, input)
	if _, err := store.db.Exec(`UPDATE settlement_attempt_outputs SET usage_source = ? WHERE request_id = ?`, source, input.RequestID); err != nil {
		t.Fatalf("set usage_source %q: %v", source, err)
	}
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	routeHash, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	var poolLabels *SettlementPoolLabels
	if labels != nil {
		poolLabels = labels(routeHash)
	}
	state, err := store.IngestPoolSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		PoolLabels:                poolLabels,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	finality, _, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, input.ReceiptReceivedUnixMS)
	if err != nil {
		t.Fatal(err)
	}
	return r012Run{state: state, finality: finality, store: store}
}

func matchingR012Labels(routeHash string) *SettlementPoolLabels {
	return &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64), RouteSnapshotHash: routeHash}
}

func TestSPEC022R012PoolOperatorAttestedSettlesOnlyWhenR012Holds(t *testing.T) {
	// A normal and a partial completion (AC-022-66).
	for _, terminal := range []string{"receipt_tuple_v4_normal_done", "receipt_tuple_v4_buyer_cancel_prefix"} {
		t.Run(terminal, func(t *testing.T) {
			input := r012SettlementInput(t, terminal, true)
			authority := &fakePoolAttestationAuthority{}
			run := runR012Settlement(t, input, UsageSourcePoolOperatorAttested, authority, matchingR012Labels)
			if run.state.SettlementOutcome != SettlementOutcomeVerified {
				t.Fatalf("%s: attested attempt outcome=%s reason=%s, want verified", terminal, run.state.SettlementOutcome, run.state.Reason)
			}
			if authority.calls == 0 || authority.last.RuntimeSource != "llamacpp_loopback" || authority.last.PoolGeneration != 7 ||
				authority.last.PoolOperatorAccountID != "creator-a" || authority.last.ProviderID != input.ProviderID {
				t.Fatalf("durable authority not consulted with the digested values: %+v", authority.last)
			}
			if run.finality.TokenSource != UsageSourcePoolOperatorAttested {
				t.Fatalf("finality token_source=%q want pool_operator_attested", run.finality.TokenSource)
			}
		})
	}
}

func TestSPEC022R012FailClosedSet(t *testing.T) {
	disputed := func(routeHash string) *SettlementPoolLabels {
		labels := matchingR012Labels(routeHash)
		labels.ManifestVersion = 3
		labels.ManifestCoreDigest = strings.Repeat("e", 64)
		return labels
	}
	cases := map[string]struct {
		external  bool
		source    string
		authority PoolOperatorAttestationAuthority
		labels    func(string) *SettlementPoolLabels
	}{
		"durable records reject (non-member, non-creator, or no v2 allowlist)": {true, UsageSourcePoolOperatorAttested, &fakePoolAttestationAuthority{err: errors.New("rejected")}, matchingR012Labels},
		"no durable authority (trusted pools off)":                             {true, UsageSourcePoolOperatorAttested, nil, matchingR012Labels},
		"label disputed at settlement":                                         {true, UsageSourcePoolOperatorAttested, &fakePoolAttestationAuthority{}, disputed},
		"no settlement-time labels":                                            {true, UsageSourcePoolOperatorAttested, &fakePoolAttestationAuthority{}, nil},
		"global route snapshot claiming pool_operator_attested":                {false, UsageSourcePoolOperatorAttested, &fakePoolAttestationAuthority{}, nil},
		"byte_estimated loopback attempt":                                      {true, UsageSourceByteEstimated, &fakePoolAttestationAuthority{}, matchingR012Labels},
	}
	for name, tc := range cases {
		tc := tc
		t.Run(name, func(t *testing.T) {
			input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", tc.external)
			run := runR012Settlement(t, input, tc.source, tc.authority, tc.labels)
			if run.state.SettlementOutcome == SettlementOutcomeVerified {
				t.Fatalf("%s settled verified", name)
			}
			if run.finality.TokenSource == UsageSourcePoolOperatorAttested || run.finality.Outcome == SettlementOutcomeVerified {
				t.Fatalf("%s finality=%+v", name, run.finality)
			}
			var payable int64
			if err := run.store.db.QueryRow(`SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE request_id = ? AND settlement_outcome = 'verified'`, input.RequestID).Scan(&payable); err != nil {
				t.Fatal(err)
			}
			if payable != 0 {
				t.Fatalf("%s wrote a verified verdict", name)
			}
		})
	}
}

// Native settlement is unchanged: coordinator_observed, no authority call.
func TestSPEC022R012NativeSettlementUnchanged(t *testing.T) {
	input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", false)
	authority := &fakePoolAttestationAuthority{}
	run := runR012Settlement(t, input, UsageSourceCoordinatorObserved, authority, nil)
	if run.state.SettlementOutcome != SettlementOutcomeVerified || run.finality.TokenSource != UsageSourceCoordinatorObserved {
		t.Fatalf("native settlement outcome=%s token_source=%s", run.state.SettlementOutcome, run.finality.TokenSource)
	}
	if authority.calls != 0 {
		t.Fatalf("native settlement consulted the pool authority %d times", authority.calls)
	}
}

// R-12.6a: the weaker provenance governs a request that mixes a native and a
// pool-attested verified attempt; an all-native request stays observed.
func TestSPEC022R012FinalityTokenSourceWeakerProvenanceGoverns(t *testing.T) {
	native := RequestSettlementFinality{ModeScopeComplete: true, VerifiedAttempts: 1, Outcome: SettlementOutcomeVerified, Closed: true, TokenSource: UsageSourceCoordinatorObserved}
	attested := native
	attested.TokenSource = UsageSourcePoolOperatorAttested
	if got := aggregateExternalRequestFinality("ext", []RequestSettlementFinality{native, attested}); got.TokenSource != UsageSourcePoolOperatorAttested {
		t.Fatalf("mixed request token_source=%q", got.TokenSource)
	}
	if got := aggregateExternalRequestFinality("ext", []RequestSettlementFinality{native, native}); got.TokenSource != UsageSourceCoordinatorObserved {
		t.Fatalf("all-native request token_source=%q", got.TokenSource)
	}
	if finalityTokenSource(false) != UsageSourceCoordinatorObserved || finalityTokenSource(true) != UsageSourcePoolOperatorAttested {
		t.Fatal("finalityTokenSource mapping")
	}
}

// R-12.6a migration: an existing database with the v0.1 CHECK is widened in
// place; existing rows are untouched and the new source is insertable.
func TestSettlementAttemptOutputUsageSourceCheckMigration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	reqStore, err := requestlog.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	db := reqStore.DB()
	if _, err := db.Exec(`
CREATE TABLE settlement_attempt_outputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    terminal_state TEXT NOT NULL CHECK(terminal_state IN ('normal_done','provider_error','buyer_cancel','gateway_timeout','upstream_transport_disconnect')),
    terminal_state_ts_unix_ms INTEGER NOT NULL CHECK(terminal_state_ts_unix_ms > 0),
    output_available INTEGER NOT NULL DEFAULT 1 CHECK(output_available IN (0,1)),
    output_prefix_start_byte INTEGER NOT NULL CHECK(output_prefix_start_byte >= 0),
    output_prefix_end_byte INTEGER NOT NULL CHECK(output_prefix_end_byte >= output_prefix_start_byte),
    output_hash TEXT CHECK(output_hash IS NULL OR (length(output_hash) = 64 AND output_hash NOT GLOB '*[^0-9a-f]*')),
    settlement_output_canonical_json TEXT,
    usage_hash TEXT NOT NULL CHECK(length(usage_hash) = 64 AND usage_hash NOT GLOB '*[^0-9a-f]*'),
    usage_canonical_json TEXT NOT NULL,
    usage_source TEXT NOT NULL CHECK(usage_source IN ('coordinator_observed','byte_estimated')),
    overlapping_or_duplicate INTEGER NOT NULL DEFAULT 0 CHECK(overlapping_or_duplicate IN (0,1)),
    created_at_utc TEXT NOT NULL,
    UNIQUE(account_scope, request_id, attempt_n, provider_id)
);
INSERT INTO settlement_attempt_outputs (account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_prefix_start_byte, output_prefix_end_byte, usage_hash, usage_canonical_json, usage_source, created_at_utc)
VALUES ('scope', 'req-legacy', 0, 'p1', 'normal_done', 1, 0, 2, '` + strings.Repeat("a", 64) + `', '{}', 'coordinator_observed', '2026-01-01T00:00:00Z');`); err != nil {
		t.Fatalf("seed legacy table: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO settlement_attempt_outputs (account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_prefix_start_byte, output_prefix_end_byte, usage_hash, usage_canonical_json, usage_source, created_at_utc)
VALUES ('scope', 'req-attested-before', 0, 'p1', 'normal_done', 1, 0, 2, ?, '{}', 'pool_operator_attested', '2026-01-01T00:00:00Z')`, strings.Repeat("a", 64)); err == nil {
		t.Fatal("legacy CHECK accepted pool_operator_attested before migration")
	}
	var before string
	if err := db.QueryRow(`SELECT usage_source || '|' || usage_hash || '|' || created_at_utc FROM settlement_attempt_outputs WHERE request_id = 'req-legacy'`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(db); err != nil {
		t.Fatalf("NewStore over legacy schema: %v", err)
	}
	var definition string
	if err := db.QueryRow(`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'settlement_attempt_outputs'`).Scan(&definition); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(definition, usageSourceCheckV02) || strings.Contains(definition, usageSourceCheckV01) {
		t.Fatalf("CHECK not widened: %s", definition)
	}
	var after string
	if err := db.QueryRow(`SELECT usage_source || '|' || usage_hash || '|' || created_at_utc FROM settlement_attempt_outputs WHERE request_id = 'req-legacy'`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("existing row changed: %q -> %q", before, after)
	}
	if _, err := db.Exec(`INSERT INTO settlement_attempt_outputs (account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_prefix_start_byte, output_prefix_end_byte, usage_hash, usage_canonical_json, usage_source, created_at_utc)
VALUES ('scope', 'req-attested', 0, 'p1', 'normal_done', 1, 0, 2, ?, '{}', 'pool_operator_attested', '2026-01-01T00:00:00Z')`, strings.Repeat("a", 64)); err != nil {
		t.Fatalf("widened CHECK rejected pool_operator_attested: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO settlement_attempt_outputs (account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_prefix_start_byte, output_prefix_end_byte, usage_hash, usage_canonical_json, usage_source, created_at_utc)
VALUES ('scope', 'req-bogus', 0, 'p1', 'normal_done', 1, 0, 2, ?, '{}', 'provider_reported', '2026-01-01T00:00:00Z')`, strings.Repeat("a", 64)); err == nil {
		t.Fatal("widened CHECK accepted a value outside the R-12.2 vocabulary")
	}
	// Idempotent on a second open.
	if _, err := NewStore(db); err != nil {
		t.Fatalf("second NewStore: %v", err)
	}
}

// The generic ingestion path (no pool labels) never accepts
// pool_operator_attested: only IngestPoolSettlementReceipt re-evaluates R-12.
func TestSPEC022R012GenericIngestionRejectsPoolOperatorAttested(t *testing.T) {
	input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", true)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetPoolOperatorAttestationAuthority(&fakePoolAttestationAuthority{})
	seedSettlementReceiptEvidence(t, store, input)
	if _, err := store.db.Exec(`UPDATE settlement_attempt_outputs SET usage_source = ? WHERE request_id = ?`, UsageSourcePoolOperatorAttested, input.RequestID); err != nil {
		t.Fatal(err)
	}
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome == SettlementOutcomeVerified {
		t.Fatalf("generic ingestion verified a pool_operator_attested attempt: %+v", state)
	}
}
