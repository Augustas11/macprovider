//go:build integration

package rewards_test

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
	"github.com/augstar/macprovider-coordinator/internal/stats/billingmirror"
	"github.com/rs/zerolog"
)

// TestUsefulWorkJourneyFromVerifiedSettlement exercises the real settlement
// verifier, its late SQLite-to-Postgres mirror upgrade, and v0.2 accrual. The
// Postgres source is never seeded directly.
func TestUsefulWorkJourneyFromVerifiedSettlement(t *testing.T) {
	ctx := context.Background()
	fx, adminDB := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	path, req, store := journeyBillingStore(t)
	t.Cleanup(func() { _ = req.Close() })
	in := journeyInput(t)

	seedJourneyEvidence(t, store, in)
	writeJourneyHotPath(t, req, store, in)
	seedJourneyMirrorIdentity(t, req.DB(), in.providerID)

	// A pre-receipt source must remain unverified after the first mirror pass.
	runJourneyMirror(t, ctx, path, fx.adminDSN())
	assertJourneyMirror(t, ctx, adminDB, in, false, 0)
	runner := journeyRunner(t, writerDB)
	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatal(err)
	}
	assertJourneyLedger(t, ctx, adminDB, in, 0, 0)

	state, err := store.IngestSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: billing.SettlementReceiptIdentity{AccountScope: in.accountScope, RequestID: in.requestID, AttemptN: in.attemptN, ProviderID: in.providerID},
		Header:                    in.header, ProviderReceiptPubkey: in.pubkey,
	})
	if err != nil {
		t.Fatalf("ingest verified receipt: %v", err)
	}
	if state.SettlementOutcome != billing.SettlementOutcomeVerified || !state.Closed {
		t.Fatalf("settlement=%#v", state)
	}

	before := journeyUSDCSnapshot(t, req.DB(), in.providerID)
	// The second pass must see a verified late settlement through overlap/sweep.
	runJourneyMirror(t, ctx, path, fx.adminDSN())
	assertJourneyMirror(t, ctx, adminDB, in, true, 1)
	if _, err := adminDB.ExecContext(ctx, `INSERT INTO provider_emission_state (provider_id, trust_tier, bound_wallet) VALUES ($1, 'trusted', '0xjourney')`, in.providerID); err != nil {
		t.Fatal(err)
	}

	start := make(chan struct{})
	errs := make(chan error, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); <-start; errs <- runner.RunUsefulWorkAccrualOnce(ctx) }()
	}
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent accrual: %v", err)
		}
	}
	assertJourneyLedger(t, ctx, adminDB, in, 1, 1)
	if got := journeyUSDCSnapshot(t, req.DB(), in.providerID); got != before {
		t.Fatalf("billing/USDC changed: got=%+v want=%+v", got, before)
	}

	runJourneyMirror(t, ctx, path, fx.adminDSN())
	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatal(err)
	}
	assertJourneyMirror(t, ctx, adminDB, in, true, 1)
	assertJourneyLedger(t, ctx, adminDB, in, 1, 1)
}

// TestUsefulWorkJourneyRejectsUnverifiedSettlementPaths proves that the
// settlement verifier and mirror never turn invalid, missing, observe-only, or
// tuple-mismatched work into MALIBU accruals.
func TestUsefulWorkJourneyRejectsUnverifiedSettlementPaths(t *testing.T) {
	ctx := context.Background()
	fx, adminDB := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	path, req, store := journeyBillingStore(t)
	t.Cleanup(func() { _ = req.Close() })
	base := journeyInput(t)

	type negativeCase struct {
		name        string
		input       journeyInputData
		ingest      func(journeyInputData) (billing.SettlementReceiptState, error)
		wantOutcome string
		wantReason  string
		wantClosed  bool
	}
	invalid := journeyVariant(t, base, "invalid", billing.RouteSnapshotModeEnforce, nil)
	missing := journeyVariant(t, base, "missing", billing.RouteSnapshotModeEnforce, nil)
	observe := journeyVariant(t, base, "observe", billing.RouteSnapshotModeObserve, nil)
	mismatch := journeyVariant(t, base, "tuple-mismatch", billing.RouteSnapshotModeEnforce, func(tuple map[string]any) {
		tuple["request_id"] = "signed-for-another-request"
	})
	cases := []negativeCase{
		{
			name: "invalid receipt", input: invalid,
			ingest: func(in journeyInputData) (billing.SettlementReceiptState, error) {
				return store.IngestSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
					SettlementReceiptIdentity: journeyIdentity(in), Header: "not-a-receipt", ProviderReceiptPubkey: in.pubkey,
				})
			},
			wantOutcome: billing.SettlementOutcomeQuarantined, wantReason: "receipt_envelope_invalid", wantClosed: true,
		},
		{
			name: "missing receipt after deadline", input: missing,
			ingest: func(in journeyInputData) (billing.SettlementReceiptState, error) {
				return store.RecordMissingSettlementReceipt(ctx, billing.SettlementReceiptMissingInput{
					SettlementReceiptIdentity: journeyIdentity(in),
					NowUnixMS:                 in.terminalMS + in.route.PendingDeadlineSeconds*1000 + 1,
				})
			},
			wantOutcome: billing.SettlementOutcomeQuarantined, wantReason: "missing_receipt_deadline_elapsed", wantClosed: true,
		},
		{
			name: "observe-only verified receipt", input: observe,
			ingest: func(in journeyInputData) (billing.SettlementReceiptState, error) {
				return store.IngestSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
					SettlementReceiptIdentity: journeyIdentity(in), Header: in.header, ProviderReceiptPubkey: in.pubkey,
				})
			},
			wantOutcome: billing.SettlementOutcomeVerified, wantReason: "verified_settlement", wantClosed: true,
		},
		{
			name: "signed tuple mismatch", input: mismatch,
			ingest: func(in journeyInputData) (billing.SettlementReceiptState, error) {
				return store.IngestSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
					SettlementReceiptIdentity: journeyIdentity(in), Header: in.header, ProviderReceiptPubkey: in.pubkey,
				})
			},
			wantOutcome: billing.SettlementOutcomeQuarantined, wantReason: "request_id_mismatch", wantClosed: true,
		},
	}

	for _, tc := range cases {
		seedJourneyEvidence(t, store, tc.input)
		writeJourneyHotPath(t, req, store, tc.input)
		state, err := tc.ingest(tc.input)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if state.SettlementOutcome != tc.wantOutcome || state.Reason != tc.wantReason || state.Closed != tc.wantClosed {
			t.Fatalf("%s state=%#v, want outcome=%s reason=%s closed=%v", tc.name, state, tc.wantOutcome, tc.wantReason, tc.wantClosed)
		}
	}

	seedJourneyMirrorIdentity(t, req.DB(), base.providerID)
	runJourneyMirror(t, ctx, path, fx.adminDSN())
	if _, err := adminDB.ExecContext(ctx, `INSERT INTO provider_emission_state (provider_id, trust_tier, bound_wallet) VALUES ($1, 'trusted', '0xjourney-negative')`, base.providerID); err != nil {
		t.Fatal(err)
	}
	before := journeyUSDCSnapshot(t, req.DB(), base.providerID)
	runner := journeyRunner(t, writerDB)
	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		assertJourneyMirror(t, ctx, adminDB, tc.input, false, 0)
		assertJourneyLedger(t, ctx, adminDB, tc.input, 0, 0)
	}
	if got := journeyUSDCSnapshot(t, req.DB(), base.providerID); got != before {
		t.Fatalf("billing/USDC changed while rejecting ineligible work: got=%+v want=%+v", got, before)
	}
}

type journeyFixture struct {
	ProviderReceiptPubkeyB64 string          `json:"provider_receipt_pubkey_b64"`
	Objects                  []journeyObject `json:"objects"`
	ReceiptTuples            []journeyTuple  `json:"receipt_tuples"`
}
type journeyObject struct {
	ID          string         `json:"id"`
	Value       map[string]any `json:"value"`
	ExpectedSHA string         `json:"expected_sha256_hex"`
}
type journeyTuple struct {
	ID                 string         `json:"id"`
	RouteSnapshotID    string         `json:"route_snapshot_id"`
	SettlementOutputID string         `json:"settlement_output_id"`
	WireReceipt        string         `json:"wire_receipt"`
	Value              map[string]any `json:"value"`
}
type journeyInputData struct {
	accountScope, requestID, providerID, header string
	attemptN, terminalMS, start, end            int64
	output                                      billing.SettlementOutput
	usage                                       billing.SettlementUsage
	route                                       billing.RouteSnapshot
	pubkey                                      []byte
}

func journeyInput(t *testing.T) journeyInputData {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "spec015", "v04_settlement_receipts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f journeyFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	objects := map[string]journeyObject{}
	for _, o := range f.Objects {
		objects[o.ID] = o
	}
	var tuple journeyTuple
	for _, x := range f.ReceiptTuples {
		if x.ID == "receipt_tuple_v4_normal_done" {
			tuple = x
			break
		}
	}
	if tuple.ID == "" {
		t.Fatal("normal settlement tuple missing")
	}
	rv, ov := objects[tuple.RouteSnapshotID].Value, objects[tuple.SettlementOutputID]
	route := journeyRoute(t, rv)
	nowMS := time.Now().UTC().Add(-time.Second).UnixMilli()
	route.CatalogExpiresAtUnixMS = nowMS + int64(time.Hour/time.Millisecond)
	route.RouteDecisionTSUnixMS = nowMS - 2_000
	route.RequestStartTSUnixMS = nowMS - 1_000
	route.RouteSnapshotMode = billing.RouteSnapshotModeEnforce
	route.RouteSnapshotPolicyVersion = billing.RouteSnapshotPolicyVersion
	digest, _, err := route.Digest()
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tuple.WireReceipt, ".")
	if len(parts) != 2 {
		t.Fatalf("malformed fixture wire receipt")
	}
	decoded, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(decoded, &value); err != nil {
		t.Fatal(err)
	}
	value["route_snapshot_mode"], value["route_snapshot_policy_version"], value["route_snapshot_digest"] = billing.RouteSnapshotModeEnforce, billing.RouteSnapshotPolicyVersion, digest
	value["terminal_state_ts_unix_ms"], value["issued_at_unix_ms"] = nowMS, nowMS
	canonical, err := billing.CanonicalJSON(value)
	if err != nil {
		t.Fatal(err)
	}
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	header := base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(ed25519.Sign(ed25519.NewKeyFromSeed(seed), canonical))
	pub, err := base64.StdEncoding.DecodeString(f.ProviderReceiptPubkeyB64)
	if err != nil {
		t.Fatal(err)
	}
	usage := tuple.Value["usage"].(map[string]any)
	finish := s(ov.Value, "finish_reason")
	output := billing.SettlementOutput{Content: s(ov.Value, "content"), FinishReason: &finish, Available: true, OutputPrefixStartByte: n(ov.Value, "output_prefix_start_byte"), OutputPrefixEndByte: n(ov.Value, "output_prefix_end_byte"), TerminalState: s(ov.Value, "terminal_state"), TerminalStateTSUnixMS: nowMS}
	outputHash, _, err := output.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if outputHash != ov.ExpectedSHA {
		t.Fatalf("fixture output digest=%s want %s", outputHash, ov.ExpectedSHA)
	}
	return journeyInputData{accountScope: s(tuple.Value, "account_scope"), requestID: s(tuple.Value, "request_id"), providerID: s(tuple.Value, "provider_id"), attemptN: n(tuple.Value, "attempt_n"), terminalMS: nowMS, start: n(tuple.Value, "output_prefix_start_byte"), end: n(tuple.Value, "output_prefix_end_byte"), output: output, header: header, pubkey: pub, route: route, usage: billing.SettlementUsage{BillableInputTokens: n(usage, "billable_input_tokens"), BillableOutputTokens: n(usage, "billable_output_tokens"), DeliveredOutputBytes: n(usage, "delivered_output_bytes"), ObservedInputTokens: n(usage, "observed_input_tokens"), ObservedOutputTokens: n(usage, "observed_output_tokens")}}
}

func journeyRoute(t *testing.T, v map[string]any) billing.RouteSnapshot {
	t.Helper()
	return billing.RouteSnapshot{AccountScope: s(v, "account_scope"), RequestID: s(v, "request_id"), AttemptN: n(v, "attempt_n"), ProviderID: s(v, "provider_id"), ProviderSessionID: p(v, "provider_session_id"), ProviderGenerationID: p(v, "provider_generation_id"), PaidEntrypoint: s(v, "paid_entrypoint"), ProviderReceiptKeyID: s(v, "provider_receipt_key_id"), ProviderReceiptKeySource: s(v, "provider_receipt_key_source"), ModelID: s(v, "model_id"), ProviderReportedModelHash: s(v, "provider_reported_model_hash"), ExpectedCatalogModelHash: s(v, "expected_catalog_model_hash"), CatalogID: s(v, "catalog_id"), CatalogBodyDigest: s(v, "catalog_body_digest"), CatalogSignatureKeyID: s(v, "catalog_signature_key_id"), CatalogSignaturePubkeyFingerprint: s(v, "catalog_signature_pubkey_fingerprint"), CatalogExpiresAtUnixMS: n(v, "catalog_expires_at_unix_ms"), Spec008HashStatus: s(v, "spec008_hash_status"), RouteSnapshotPolicyVersion: s(v, "route_snapshot_policy_version"), RouteSnapshotMode: s(v, "route_snapshot_mode"), RouteDecisionTSUnixMS: n(v, "route_decision_ts_unix_ms"), RequestStartTSUnixMS: n(v, "request_start_ts_unix_ms"), PendingDeadlineSeconds: n(v, "pending_deadline_seconds"), PromptHashBasis: s(v, "prompt_hash_basis"), PromptHash: s(v, "prompt_hash")}
}

func journeyVariant(t *testing.T, base journeyInputData, suffix, mode string, mutateTuple func(map[string]any)) journeyInputData {
	t.Helper()
	in := base
	in.requestID = base.requestID + "-" + suffix
	in.route.RequestID = in.requestID
	in.route.RouteSnapshotMode = mode
	digest, _, err := in.route.Digest()
	if err != nil {
		t.Fatal(err)
	}
	in.header = journeySignedHeader(t, base.header, func(tuple map[string]any) {
		tuple["request_id"] = in.requestID
		tuple["route_snapshot_mode"] = mode
		tuple["route_snapshot_digest"] = digest
		if mutateTuple != nil {
			mutateTuple(tuple)
		}
	})
	return in
}

func journeySignedHeader(t *testing.T, header string, mutate func(map[string]any)) string {
	t.Helper()
	parts := strings.Split(header, ".")
	if len(parts) != 2 {
		t.Fatal("malformed journey receipt")
	}
	raw, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatal(err)
	}
	var tuple map[string]any
	if err := json.Unmarshal(raw, &tuple); err != nil {
		t.Fatal(err)
	}
	mutate(tuple)
	canonical, err := billing.CanonicalJSON(tuple)
	if err != nil {
		t.Fatal(err)
	}
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	signature := ed25519.Sign(ed25519.NewKeyFromSeed(seed), canonical)
	return base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(signature)
}

func journeyIdentity(in journeyInputData) billing.SettlementReceiptIdentity {
	return billing.SettlementReceiptIdentity{
		AccountScope: in.accountScope,
		RequestID:    in.requestID,
		AttemptN:     in.attemptN,
		ProviderID:   in.providerID,
	}
}
func s(v map[string]any, k string) string { return v[k].(string) }
func n(v map[string]any, k string) int64  { return int64(v[k].(float64)) }
func p(v map[string]any, k string) *string {
	if v[k] == nil {
		return nil
	}
	x := s(v, k)
	return &x
}

func journeyBillingStore(t *testing.T) (string, *requestlog.Store, *billing.Store) {
	path := filepath.Join(t.TempDir(), "journey.sqlite")
	req, err := requestlog.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	store, err := billing.NewStore(req.DB())
	if err != nil {
		t.Fatal(err)
	}
	return path, req, store
}
func seedJourneyEvidence(t *testing.T, store *billing.Store, in journeyInputData) {
	if _, err := store.InsertRouteSnapshot(context.Background(), in.route); err != nil {
		t.Fatal(err)
	}
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), billing.SettlementAttemptOutput{
		AccountScope:          in.accountScope,
		RequestID:             in.requestID,
		AttemptN:              in.attemptN,
		ProviderID:            in.providerID,
		Output:                in.output,
		OutputAvailable:       true,
		Usage:                 in.usage,
		UsageSource:           billing.UsageSourceCoordinatorObserved,
		TerminalStateTSUnixMS: in.terminalMS,
	}); err != nil {
		t.Fatal(err)
	}
}
func writeJourneyHotPath(t *testing.T, req *requestlog.Store, store *billing.Store, in journeyInputData) {
	a, b := in.usage.BillableInputTokens, in.usage.BillableOutputTokens
	h := billing.HotPathInput{RequestID: in.requestID, AttemptN: int(in.attemptN), ProviderAssignedID: "journey", ProviderID: in.providerID, Model: in.route.ModelID, Status: 200, TSUtc: time.UnixMilli(in.terminalMS).UTC(), PromptTokens: &a, CompletionTokens: &b, FaultFlag: "none", RateEntry: billing.RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000}, MultiplierPPM: 1000000, ProviderShareBps: 10000, SettlementAccountScopeHash: billing.SettlementAccountScopeHash(in.accountScope), SettlementPolicyMode: in.route.RouteSnapshotMode, SettlementPolicyVersion: in.route.RouteSnapshotPolicyVersion}
	r := requestlog.Row{TSUtc: h.TSUtc, RequestID: h.RequestID, Model: h.Model, ProviderAssignedID: h.ProviderAssignedID, PromptTokens: h.PromptTokens, CompletionTokens: h.CompletionTokens, Status: h.Status, BuyerIP: "127.0.0.1"}
	if err := store.WriteHotPath(context.Background(), req, r, h); err != nil {
		t.Fatal(err)
	}
}
func seedJourneyMirrorIdentity(t *testing.T, db *sql.DB, provider string) {
	_, err := db.Exec(`CREATE TABLE provider_tokens (id INTEGER PRIMARY KEY,token_hash TEXT NOT NULL UNIQUE,token_prefix TEXT NOT NULL,provider_id TEXT NOT NULL,provider_name TEXT NOT NULL,created_at TEXT NOT NULL,revoked_at TEXT,last_used_at TEXT); INSERT INTO provider_tokens VALUES (1,'journey-token','journey',?,'Journey','2026-01-01T00:00:00Z',NULL,NULL)`, provider)
	if err != nil {
		t.Fatal(err)
	}
}
func runJourneyMirror(t *testing.T, ctx context.Context, path, dsn string) {
	if _, err := billingmirror.Run(ctx, billingmirror.Options{SQLitePath: path, PostgresDSN: dsn, BatchSize: 10, OverlapRows: 10, SweepRows: 10, MaxBatches: 1, EnsureSchema: true}); err != nil {
		t.Fatal(err)
	}
}
func journeyRunner(t *testing.T, db *sql.DB) *rewards.Runner {
	cfg := testEmissionConfig(time.Hour, 100, 100)
	cfg.UsefulWorkEnabled = true
	cfg.UsefulWorkMALIBUPer1KCredits = 1
	r, err := rewards.New(db, cfg, zerolog.Nop(), rewards.RunnerDeps{})
	if err != nil {
		t.Fatal(err)
	}
	return r
}
func assertJourneyMirror(t *testing.T, ctx context.Context, db *sql.DB, in journeyInputData, want bool, audit int) {
	var got bool
	if err := db.QueryRowContext(ctx, `SELECT spec022_verified FROM ledger_request_credits WHERE request_id=$1`, in.requestID).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("verified=%v want %v", got, want)
	}
	var n int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM ledger_request_credit_spec022_verified_audit WHERE request_id=$1`, in.requestID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != audit {
		t.Fatalf("mirror audits=%d want %d", n, audit)
	}
}
func assertJourneyLedger(t *testing.T, ctx context.Context, db *sql.DB, in journeyInputData, want, audit int) {
	ref := fmt.Sprintf("spec022:%s:%d:%s", in.requestID, in.attemptN, in.providerID)
	var n int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM provider_rewards_ledger WHERE external_ref=$1`, ref).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != want {
		t.Fatalf("ledger=%d want %d", n, want)
	}
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM malibu_reward_audit_events e JOIN provider_rewards_ledger l ON l.id=e.ledger_id WHERE l.external_ref=$1 AND e.event_type='malibu_accrual_inserted'`, ref).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != audit {
		t.Fatalf("accrual audits=%d want %d", n, audit)
	}
}

type journeyUSDC struct {
	buyerEquivalentCredits int64
	providerCredits        int64
	requestRows            int64
	quarantinedRows        int64
	settledRows            int64
	operatorGrossCredits   int64
	operatorCredits        int64
	operatorRows           int64
	payoutGrossCredits     int64
	payoutProviderCredits  int64
	payoutOperatorCredits  int64
	payoutSourceRows       int64
	payoutReadyRows        int64
	payoutConsumedRows     int64
	payoutVoidedRows       int64
}

func journeyUSDCSnapshot(t *testing.T, db *sql.DB, provider string) journeyUSDC {
	var x journeyUSDC
	if err := db.QueryRow(`
SELECT COALESCE(SUM(gross_credits),0), COALESCE(SUM(provider_credits),0), COUNT(*),
       COALESCE(SUM(quarantined),0), COALESCE(SUM(settled),0)
  FROM ledger_request_credits
 WHERE provider_id=?`, provider).Scan(
		&x.buyerEquivalentCredits, &x.providerCredits, &x.requestRows, &x.quarantinedRows, &x.settledRows,
	); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`
SELECT COALESCE(SUM(gross_credits),0), COALESCE(SUM(operator_credits),0), COUNT(*)
  FROM ledger_operator_credits
 WHERE provider_id=?`, provider).Scan(&x.operatorGrossCredits, &x.operatorCredits, &x.operatorRows); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`
SELECT COALESCE(SUM(gross_credits),0), COALESCE(SUM(provider_credits),0),
       COALESCE(SUM(operator_credits),0), COALESCE(SUM(source_credit_count),0),
       COALESCE(SUM(CASE WHEN status='ready' THEN 1 ELSE 0 END),0),
       COALESCE(SUM(CASE WHEN status='consumed' THEN 1 ELSE 0 END),0),
       COALESCE(SUM(CASE WHEN status='voided' THEN 1 ELSE 0 END),0)
  FROM ledger_payout_ready
 WHERE provider_id=?`, provider).Scan(
		&x.payoutGrossCredits, &x.payoutProviderCredits, &x.payoutOperatorCredits, &x.payoutSourceRows,
		&x.payoutReadyRows, &x.payoutConsumedRows, &x.payoutVoidedRows,
	); err != nil {
		t.Fatal(err)
	}
	return x
}
