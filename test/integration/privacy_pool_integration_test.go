package integration

import (
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// SPEC-049-R032 integration: a privacy-class request scoped to a Trusted Pool
// through the real gateway, coordinator, operator CLI, reference client, and
// Swift provider fixture. The provider is served only when it is both a
// current pool member and enrolled in the privacy class.

// privacyPoolFixtureBinaryVersion is the version the pool-scoped Swift
// fixture advertises, so the pool binary floor can compare it.
const privacyPoolFixtureBinaryVersion = "1.9.0"

type privacyPoolOpts struct {
	// providerIsMember admits the scenario provider to the pool; otherwise
	// the pool's only member is another provider identity.
	providerIsMember bool
}

// configure creates the pool keys and wires the coordinator and gateway
// trusted-pool configuration and the operator pool setup into the scenario.
// It returns the pool ID.
func (o *privacyPoolOpts) configure(t *testing.T, so *scenarioOpts, providerID string) string {
	t.Helper()
	requireBins(t)
	keysDir := filepath.Join(t.TempDir(), "pool-keys")
	keygenOut := runTrustPoolCLI(t, nil, "keygen", "--out-dir", keysDir,
		"--manifest-authority-key-id", "p1985-authority-1",
		"--policy-signer-key-id", "p1985-signer-1")
	poolID := cliOutputField(t, keygenOut, "pool_id")
	member := "prov-pool-other-" + randHex(t, 4)
	if o.providerIsMember {
		member = providerID
	}
	so.coordinatorConfig = func(_ *scenario, cfg map[string]any) {
		cfg["trusted_pools"] = map[string]any{"enabled": true, "refresh_interval_s": 1}
	}
	so.gatewayConfig = func(sc *scenario, cfg map[string]any) {
		features := cfg["features"].(map[string]any)
		features["trusted_pools"] = map[string]any{
			"enabled":       true,
			"account_pools": map[string][]string{sc.accountID: {poolID}},
		}
	}
	so.beforeProviders = func(sc *scenario) {
		setUpPrivacyPool(t, sc, keysDir, poolID, member)
	}
	return poolID
}

// setUpPrivacyPool creates, signs, populates, and activates a native-only
// enforce pool through the operator admin surface and the offline signer.
func setUpPrivacyPool(t *testing.T, s *scenario, keysDir, poolID, memberID string) {
	t.Helper()
	const creator = "acct_creator_1985"
	env := map[string]string{
		"MACPROVIDER_COORDINATOR_ADMIN_URL": s.coordProvURL,
		"MACPROVIDER_OPERATOR_KEY":          s.operatorKey,
	}
	approval := map[string]any{
		"creator_account_id":                   creator,
		"approval_record_id":                   "approval-1985",
		"current_approval_version":             "approval-version-1",
		"public_display_name":                  "Integration pool 1985",
		"legal_support_contact":                "legal@example.test",
		"billing_contact":                      "billing@example.test",
		"emergency_notification_endpoint":      "https://example.test/emergency",
		"acknowledged_max_response_time":       "15m",
		"allowed_product_category":             "design-partner",
		"data_retention_category":              "standard",
		"support_owner":                        "ops",
		"allowed_launch_environment":           "candidate",
		"creator_agreement_id":                 "agreement-1985",
		"creator_agreement_version":            "v1",
		"creator_agreement_expires_at_utc":     time.Now().UTC().Add(30 * 24 * time.Hour).Format(time.RFC3339),
		"creator_agreement_grace_ends_at_utc":  time.Now().UTC().Add(31 * 24 * time.Hour).Format(time.RFC3339),
		"pricing_schedule_id":                  "pricing-1985",
		"pricing_schedule_version":             "v1",
		"prohibited_claim_acknowledgment_hash": sha256HexString("claims"),
		"buyer_disclosure_commitment_hash":     sha256HexString("disclosure"),
		"approval_criteria_hash":               sha256HexString("criteria"),
		"approved_by":                          "operator-a",
		"approved_at_utc":                      time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
		"status":                               "enabled",
	}
	runTrustPoolCLI(t, env, "upsert-creator", "--operation-id", "p1985-creator-1", "--input", writeJSONFile(t, "creator.json", approval))
	nonceOut := runTrustPoolCLI(t, env, "issue-root-nonce", "--operation-id", "p1985-nonce-1",
		"--creator-account-id", creator, "--approval-record-id", "approval-1985", "--approval-version", "approval-version-1",
		"--launch-environment", "candidate", "--expires-at", time.Now().UTC().Add(time.Hour).Format(time.RFC3339Nano))
	var nonceResp struct {
		Record struct {
			Nonce        string    `json:"nonce"`
			ExpiresAtUTC time.Time `json:"expires_at_utc"`
		} `json:"root_registration_nonce"`
	}
	decodeCLIJSON(t, nonceOut, &nonceResp)
	runTrustPoolCLI(t, env, "create-pool", "--operation-id", "p1985-create-1", "--pool-id", poolID,
		"--creator-account-id", creator, "--approval-record-id", "approval-1985")
	custody := writeFile(t, "custody.json", `{"class":"software","description":"integration test, owner-only temp files"}`+"\n")
	rootEvent := filepath.Join(t.TempDir(), "root.json")
	runTrustPoolCLI(t, nil, "sign-root", "--identity", filepath.Join(keysDir, "pool-identity.json"),
		"--root-issuer-key", filepath.Join(keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "p1985-root-1",
		"--operation-id", "p1985-root-1", "--creator-account-id", creator, "--approval-record-id", "approval-1985",
		"--approval-version", "approval-version-1", "--launch-environment", "candidate", "--custody-disclosure", custody,
		"--custody-class", "software", "--display-name", "Integration pool 1985", "--nonce", nonceResp.Record.Nonce,
		"--nonce-expiry", nonceResp.Record.ExpiresAtUTC.UTC().Format(time.RFC3339Nano), "--out", rootEvent)
	runTrustPoolCLI(t, env, "append-event", "--operation-id", "p1985-root-1", "--input", rootEvent)
	notBefore := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	manifestEvent := filepath.Join(keysDir, "manifest-1.json")
	runTrustPoolCLI(t, nil, "sign-manifest", "--identity", filepath.Join(keysDir, "pool-identity.json"),
		"--root-issuer-key", filepath.Join(keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "p1985-root-1",
		"--manifest-authority-key", filepath.Join(keysDir, "manifest-authority-key.pem"),
		"--policy-signer-key", filepath.Join(keysDir, "policy-signer-key.pem"),
		"--operation-id", "p1985-manifest-1", "--encoding", "1", "--signer-set-version", "1",
		"--settlement-mode", "enforce", "--models", settlementFixtureModelID, "--min-binary-version", "1.0.0",
		"--min-attestation-tier", "self_signed", "--retention-policy-id", "standard", "--min-eligible-members", "1",
		"--not-before", notBefore.Format(time.RFC3339), "--expires-at", notBefore.Add(24*time.Hour).Format(time.RFC3339),
		"--out", manifestEvent)
	runTrustPoolCLI(t, env, "submit-policy", "--operation-id", "p1985-manifest-1", "--input", manifestEvent)
	runTrustPoolCLI(t, env, "admit-provider", "--operation-id", "p1985-admit-1", "--pool-id", poolID, "--provider-id", memberID)
	runTrustPoolCLI(t, env, "authorize-buyer", "--operation-id", "p1985-buyer-1", "--pool-id", poolID, "--buyer-account-id", s.accountID)
	runTrustPoolCLI(t, env, "promote", "--operation-id", "p1985-promote-1", "--pool-id", poolID, "--reason", "integration_1985")
	// One trusted-pool refresh so the pool is routeable before the provider
	// connects.
	time.Sleep(2 * time.Second)
}

// awaitPrivacyRejectReason waits for the coordinator's SPEC-049-R030 log
// line with phase and reason.
func awaitPrivacyRejectReason(t *testing.T, s *scenario, phase, reason string) {
	t.Helper()
	if s.coordLogBuf.awaitContains(time.Now().Add(10*time.Second), `"event":"privacy_route_rejected"`, `"phase":"`+phase+`"`, `"reason":"`+reason+`"`) == "" {
		t.Fatalf("coordinator never recorded privacy_route_rejected phase=%s reason=%s", phase, reason)
	}
}

func TestPrivacyClassPoolMemberEnrolledIsServedAndSettles(t *testing.T) {
	st := newRelayBlindSettlementStack(t, relayBlindSettlementOpts{privacy: true, pool: &privacyPoolOpts{providerIsMember: true}})
	// The full R-14 money path, pool-scoped: snapshot before dispatch, a
	// closed relay_blind_settled verdict, a payable credit, equal usage.
	st.assertRelayBlindSettled(t, 1, false, true)
	_, stderr := st.runClient(t, privacyCanaryPrompt, true, true)
	for _, want := range []string{"privacy class satisfied", "pool_id: " + st.pool, "pool_operator_does_not_see: request_and_response_content_through_pool_surfaces"} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("client stderr lacks %q", want)
		}
	}
	db, err := sql.Open("sqlite", "file:"+st.s.coordinatorDB+"?_pragma=busy_timeout(10000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// SPEC-049-R032 item 6: the pool labels are on the relay-blind route
	// snapshot and the verdict row, and the request log names the pool.
	var snapshotPool, snapshotJSON string
	if err := db.QueryRow(`SELECT COALESCE(pool_id,''), route_snapshot_json FROM settlement_route_snapshots WHERE paid_entrypoint = ? ORDER BY id ASC LIMIT 1`,
		relayBlindSettlementEntrypoint).Scan(&snapshotPool, &snapshotJSON); err != nil || snapshotPool != st.pool {
		t.Fatalf("relay-blind route snapshot pool=%q err=%v", snapshotPool, err)
	}
	var snapshot struct {
		PoolID             string `json:"pool_id"`
		ManifestVersion    uint64 `json:"manifest_version"`
		ManifestCoreDigest string `json:"manifest_core_digest"`
	}
	if err := json.Unmarshal([]byte(snapshotJSON), &snapshot); err != nil || snapshot.PoolID != st.pool || snapshot.ManifestVersion == 0 || snapshot.ManifestCoreDigest == "" {
		t.Fatalf("relay-blind route snapshot labels=%+v err=%v", snapshot, err)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		var labelPool, labelStatus sql.NullString
		err := db.QueryRow(`SELECT pool_id, pool_label_status FROM settlement_receipt_verdicts WHERE settlement_outcome = 'relay_blind_settled' ORDER BY id ASC LIMIT 1`).Scan(&labelPool, &labelStatus)
		if err == nil && labelPool.String == st.pool && labelStatus.String == "verified" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("verdict pool label=%q status=%q err=%v", labelPool.String, labelStatus.String, err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	var logged int
	if err := db.QueryRow(`SELECT COUNT(*) FROM request_log WHERE pool_id = ?`, st.pool).Scan(&logged); err != nil || logged < 2 {
		t.Fatalf("request_log pool rows=%d err=%v", logged, err)
	}
}

func TestPrivacyClassPoolMemberNotEnrolledIsRejected(t *testing.T) {
	st := newRelayBlindSettlementStack(t, relayBlindSettlementOpts{privacy: true, omitPrivacyKeys: true, pool: &privacyPoolOpts{providerIsMember: true}})
	_, stderr, err := st.tryClient(t, privacyCanaryPrompt, false, true)
	if err == nil || !strings.Contains(stderr, "route reservation failed: HTTP 503") {
		t.Fatalf("member without privacy enrollment was served: err=%v stderr=%s", err, privacyClientDetail(stderr))
	}
	// The member serves the model but holds no privacy key: a privacy-side
	// reason from the closed set, never a pool reason.
	awaitPrivacyRejectReason(t, st.s, "reservation", "model_not_private_capable")
	if got := st.fixture.dispatches.Load(); got != 0 {
		t.Fatalf("dispatches=%d, want 0", got)
	}
	if got := st.s.countGatewayRows("quota_reservations"); got != 0 {
		t.Fatalf("quota_reservations=%d, want 0", got)
	}
}

func TestPrivacyClassPoolEnrolledNonMemberIsRejected(t *testing.T) {
	st := newRelayBlindSettlementStack(t, relayBlindSettlementOpts{privacy: true, pool: &privacyPoolOpts{providerIsMember: false}})
	_, stderr, err := st.tryClient(t, privacyCanaryPrompt, false, true)
	if err == nil || !strings.Contains(stderr, "route reservation failed: HTTP 503") {
		t.Fatalf("enrolled non-member was served: err=%v stderr=%s", err, privacyClientDetail(stderr))
	}
	awaitPrivacyRejectReason(t, st.s, "reservation", "pool_no_eligible_member")
	if got := st.fixture.dispatches.Load(); got != 0 {
		t.Fatalf("dispatches=%d, want 0", got)
	}
	// The same enrolled provider still serves a global privacy request.
	st.pool = ""
	st.assertRelayBlindSettled(t, 1, false, true)
}
