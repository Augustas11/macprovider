package buyer_test

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

const (
	trustedPoolLayer2JourneyID        = "JOURNEY-TRUSTED-POOL-LAYER2-MVP"
	trustedPoolLayer2EvidenceSchema   = "macprovider.trusted-pool-layer2-evidence.v1"
	trustedPoolLayer2EnvironmentClass = "isolated-candidate-trusted-pool-layer2-mvp"
	trustedPoolLayer2ArtifactID       = "redacted-trusted-pool-layer2"
)

func TestJourneyTrustedPoolLayer2MVPCandidate(t *testing.T) {
	configureRouteSnapshotCatalog(t, "trusted-pool-layer2-journey-catalog")

	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
	rewards := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), rewards, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	var providerCalls atomic.Int64
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerCalls.Add(1)
		writeProviderOK(w)
	}))
	defer provider.Close()

	const (
		buyerAccountID = "acct_gateway"
		providerID     = "provider-member"
		poolGeneration = uint64(7)
	)
	manifest := trustedPoolLayer2CandidateManifest(t)
	poolID := manifest.PoolID
	providerRegistry := pool.NewRegistry(nil)
	registerTrustedPoolLayer2Provider(providerRegistry, providerID, "session-member", provider.URL, []byte(strings.Repeat("r", 32)))
	trustPools := trustpool.NewRegistry()
	loadTrustedPoolLayer2Snapshot(t, trustPools, 1, trustpool.RouteableSnapshot{
		PoolID:            poolID,
		Members:           []string{providerID},
		BuyerAccounts:     []string{buyerAccountID},
		SettlementMode:    billing.RouteSnapshotModeObserve,
		Routeable:         true,
		Generation:        poolGeneration,
		RouteableUntilUTC: time.Now().UTC().Add(time.Hour),
	})
	successSnapshot, authorized := trustPools.AuthorizeAndSnapshot(poolID, buyerAccountID)
	if !authorized || !successSnapshot.Exists || !successSnapshot.Routeable || successSnapshot.Generation != poolGeneration {
		t.Fatalf("trusted-pool snapshot = %#v, authorized=%v; want routeable generation %d", successSnapshot, authorized, poolGeneration)
	}

	server := buyer.NewServer(
		providerRegistry,
		zerolog.Nop(),
		time.Unix(1716768000, 0).UTC(),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithPoolMembership(trustPools),
		buyer.WithTrustPoolStatusStore(openBuyerTrustPoolStore(t)),
		buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 0}),
	)

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`)
	success := postChat(t, server, body, trustedPoolLayer2Headers(buyerAccountID, poolID))
	if success.Code != http.StatusOK {
		t.Fatalf("pooled request status=%d body=%s", success.Code, success.Body.String())
	}
	if providerCalls.Load() != 1 {
		t.Fatalf("provider calls after successful pooled request=%d, want 1", providerCalls.Load())
	}
	routeSnapshots := queryTrustedPoolLayer2RouteSnapshots(t, dbPath)
	if len(routeSnapshots) != 1 {
		t.Fatalf("route snapshots=%d want 1: %#v", len(routeSnapshots), routeSnapshots)
	}
	if got := routeSnapshots[0].PoolID; got != poolID {
		t.Fatalf("route snapshot pool_id=%q, want %q", got, poolID)
	}
	if len(routeSnapshots[0].Digest) != 64 {
		t.Fatalf("route snapshot digest=%q, want 64 hex chars", routeSnapshots[0].Digest)
	}
	if _, err := hex.DecodeString(routeSnapshots[0].Digest); err != nil {
		t.Fatalf("route snapshot digest=%q, want lowercase hex: %v", routeSnapshots[0].Digest, err)
	}
	if routeSnapshots[0].Digest != strings.ToLower(routeSnapshots[0].Digest) {
		t.Fatalf("route snapshot digest=%q, want lowercase hex", routeSnapshots[0].Digest)
	}
	if got := routeSnapshots[0].Mode; got != billing.RouteSnapshotModeObserve {
		t.Fatalf("route snapshot mode=%q, want observe", got)
	}

	loadTrustedPoolLayer2Snapshot(t, trustPools, 2, trustpool.RouteableSnapshot{
		PoolID:            poolID,
		Members:           nil,
		BuyerAccounts:     []string{buyerAccountID},
		SettlementMode:    billing.RouteSnapshotModeObserve,
		Routeable:         true,
		Generation:        poolGeneration + 1,
		RouteableUntilUTC: time.Now().UTC().Add(time.Hour),
	})
	failClosed := postChat(t, server, body, trustedPoolLayer2Headers(buyerAccountID, poolID))
	if failClosed.Code != http.StatusServiceUnavailable {
		t.Fatalf("unsatisfied pool status=%d body=%s, want 503", failClosed.Code, failClosed.Body.String())
	}
	if code := trustedPoolLayer2ErrorCode(t, failClosed.Body.String()); code != "pool_no_eligible_member" {
		t.Fatalf("unsatisfied pool code=%q, want pool_no_eligible_member; body=%s", code, failClosed.Body.String())
	}
	if providerCalls.Load() != 1 {
		t.Fatalf("provider calls after fail-closed request=%d, want 1", providerCalls.Load())
	}
	if got := len(queryTrustedPoolLayer2RouteSnapshots(t, dbPath)); got != 1 {
		t.Fatalf("route snapshots after fail-closed request=%d, want unchanged 1", got)
	}
	if got := payoutReadyCount(t, dbPath); got != 0 {
		t.Fatalf("payout-ready rows=%d before payout job, want 0 for labels-only Layer 2 route-path evidence", got)
	}

	evidence := trustedPoolLayer2Evidence(t, trustedPoolLayer2EvidenceInput{
		PoolID:              poolID,
		ManifestVersion:     manifest.Version,
		PoolGeneration:      successSnapshot.Generation,
		ManifestCoreDigest:  manifest.Digest,
		RouteSnapshotDigest: routeSnapshots[0].Digest,
		GatewayConfigDigest: trustedPoolLayer2SHA256("gateway-context-required:pool:" + poolID + ":account:" + buyerAccountID),
		CoordinatorDigest:   trustedPoolLayer2SHA256("buyer-server:pool-membership:route-snapshot-observe:pool:" + poolID),
		ProviderID:          providerID,
		BuyerAccountID:      buyerAccountID,
	})
	assertTrustedPoolLayer2EvidenceRedacted(t, evidence, body, "gateway-secret", buyerAccountID, providerID, provider.URL)
	writeTrustedPoolLayer2EvidenceIfRequested(t, evidence)
}

type trustedPoolLayer2CandidateManifestRecord struct {
	PoolID  string
	Version string
	Digest  string
}

func trustedPoolLayer2CandidateManifest(t *testing.T) trustedPoolLayer2CandidateManifestRecord {
	t.Helper()
	identity := poolmanifest.IdentityCore{
		RootIssuerKeyID: "trusted-pool-layer2-root",
		GenesisNonce:    []byte("trusted-pool-layer2-genesis"),
	}
	poolID, err := identity.PoolID()
	if err != nil {
		t.Fatalf("PoolID: %v", err)
	}
	policy := poolmanifest.PolicyCore{
		PoolID:               poolID,
		ManifestVersion:      7,
		PrevManifestCoreHash: poolmanifest.GenesisPrevHash(),
		SignerSetVersion:     1,
		ModelAllowlist:       []string{"model-a"},
		MinBinaryVersion:     "1.8.0",
		MinAttestationTier:   "self_signed",
		RequireEncryptedLeg:  false,
		SettlementMode:       billing.RouteSnapshotModeObserve,
		RevenueSplitBps:      0,
		SplitExecutionStatus: "declared_not_executed",
		RetentionPolicyID:    "standard",
		MinEligibleMembers:   1,
		PrivacyMode:          "none",
		RelayBlindCapable:    false,
		ReceiptContract:      "v0.4",
		MetadataVisible:      "coordinator_request_provider_pool",
		DowngradePolicy:      "reject",
		StickyRoutingAllowed: false,
		NotBeforeUnix:        uint64(time.Unix(1716768000, 0).UTC().Unix()),
		ExpiresAtUnix:        uint64(time.Unix(4102444800, 0).UTC().Unix()),
	}
	digest, err := policy.ManifestCoreDigest()
	if err != nil {
		t.Fatalf("ManifestCoreDigest: %v", err)
	}
	return trustedPoolLayer2CandidateManifestRecord{
		PoolID:  poolID,
		Version: strconv.FormatUint(policy.ManifestVersion, 10),
		Digest:  hex.EncodeToString(digest),
	}
}

func configureRouteSnapshotCatalog(t *testing.T, catalogID string) {
	t.Helper()
	raw, pubkey := routeSnapshotCatalogFixture(t, catalogID, time.Now().UTC().Add(time.Hour))
	t.Cleanup(tier2.ResetForTest)
	if err := tier2ConfigureForTrustedPoolLayer2(pubkey, writeRouteSnapshotCatalog(t, raw)); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
}

func tier2ConfigureForTrustedPoolLayer2(pubkey, catalogPath string) error {
	tier2.ResetForTest()
	return tier2.Configure(config.Tier2Config{
		ObserveEnabled:      true,
		CatalogPath:         catalogPath,
		CatalogPublicKey:    pubkey,
		RequireHashVerified: true,
	}, zerolog.Nop())
}

func registerTrustedPoolLayer2Provider(registry *pool.Registry, providerID, assignedID, endpointURL string, receiptPubkey []byte) {
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               "model-a",
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 25,
		EndpointURL:           endpointURL,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		BinaryVersion:         "1.8.0",
		ModelHash:             buyerTestHash,
		ModelHashAlgorithm:    modelidentity.SnapshotManifestV1,
		ExpectedModelHash:     buyerTestHash,
		HashStatus:            pool.HashStatusVerified,
		ReceiptPubkey:         append([]byte(nil), receiptPubkey...),
		TrustedPoolV1:         true,
	}, nil)
	slotsFree := 1
	registry.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

func loadTrustedPoolLayer2Snapshot(t *testing.T, registry *trustpool.Registry, revision uint64, snapshot trustpool.RouteableSnapshot) {
	t.Helper()
	if err := registry.LoadRouteableSnapshotsAtRevision(revision, []trustpool.RouteableSnapshot{snapshot}); err != nil {
		t.Fatalf("LoadRouteableSnapshotsAtRevision: %v", err)
	}
}

func trustedPoolLayer2Headers(accountID, poolID string) http.Header {
	return http.Header{
		"Authorization":         {"Bearer gateway-secret"},
		"X-MacProvider-Account": {accountID},
		"X-MacProvider-Pool":    {poolID},
	}
}

type trustedPoolLayer2RouteSnapshotRow struct {
	ProviderID string
	PoolID     string
	Mode       string
	Digest     string
}

func queryTrustedPoolLayer2RouteSnapshots(t *testing.T, dbPath string) []trustedPoolLayer2RouteSnapshotRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT provider_id, COALESCE(pool_id, ''), route_snapshot_mode, route_snapshot_digest
FROM settlement_route_snapshots
ORDER BY attempt_n ASC`)
	if err != nil {
		t.Fatalf("query trusted-pool route snapshots: %v", err)
	}
	defer rows.Close()
	var got []trustedPoolLayer2RouteSnapshotRow
	for rows.Next() {
		var row trustedPoolLayer2RouteSnapshotRow
		if err := rows.Scan(&row.ProviderID, &row.PoolID, &row.Mode, &row.Digest); err != nil {
			t.Fatalf("scan trusted-pool route snapshots: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("trusted-pool route snapshots: %v", err)
	}
	return got
}

func trustedPoolLayer2ErrorCode(t *testing.T, body string) string {
	t.Helper()
	var decoded struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(body), &decoded); err != nil {
		t.Fatalf("decode error response: %v; body=%s", err, body)
	}
	return decoded.Error.Code
}

type trustedPoolLayer2EvidenceInput struct {
	PoolID              string
	ManifestVersion     string
	PoolGeneration      uint64
	ManifestCoreDigest  string
	RouteSnapshotDigest string
	GatewayConfigDigest string
	CoordinatorDigest   string
	ProviderID          string
	BuyerAccountID      string
}

func trustedPoolLayer2Evidence(t *testing.T, in trustedPoolLayer2EvidenceInput) map[string]any {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	commit := trustedPoolLayer2GitOutput(t, "rev-parse", "HEAD")
	return map[string]any{
		"schema_version":  trustedPoolLayer2EvidenceSchema,
		"journey_id":      trustedPoolLayer2JourneyID,
		"run_id":          "trusted-pool-layer2-" + now.Format("20060102T150405Z"),
		"captured_at":     now.Format(time.RFC3339),
		"expires_at":      now.Add(7 * 24 * time.Hour).Format("2006-01-02"),
		"requirement_ids": []string{"SPEC-042-R002", "SPEC-042-R005", "SPEC-042-R006", "SPEC-042-R010"},
		"repository": map[string]any{
			"name":   "Augustas11/macprovider",
			"commit": commit,
		},
		"operator": map[string]any{
			"role":                 "acceptance-operator",
			"identity_fingerprint": trustedPoolLayer2SHA256("trusted-pool-layer2-acceptance-operator"),
		},
		"environment": map[string]any{
			"class":            trustedPoolLayer2EnvironmentClass,
			"hardware_profile": "local-redacted",
			"candidate":        "commit:" + commit,
		},
		"harness": map[string]any{
			"id":                       "phase4-coordinator/internal/buyer:TestJourneyTrustedPoolLayer2MVPCandidate",
			"execution_mode":           trustedPoolLayer2EnvironmentClass,
			"isolated_sqlite":          true,
			"real_buyer_server":        true,
			"gateway_context_required": true,
			"production_side_effects":  false,
			"evidence_scope":           "local route-path proof only; route snapshot proves pool_id label/digest, not production manifest-label rollout",
		},
		"candidate_identity": map[string]any{
			"pool_id":                       in.PoolID,
			"manifest_version":              in.ManifestVersion,
			"pool_generation":               strconv.FormatUint(in.PoolGeneration, 10),
			"manifest_core_digest":          in.ManifestCoreDigest,
			"route_snapshot_digest":         in.RouteSnapshotDigest,
			"gateway_config_sha256":         in.GatewayConfigDigest,
			"coordinator_config_sha256":     in.CoordinatorDigest,
			"provider_identity_fingerprint": trustedPoolLayer2SHA256(in.ProviderID),
			"buyer_credential_fingerprint":  trustedPoolLayer2SHA256(in.BuyerAccountID),
		},
		"steps": []map[string]any{
			trustedPoolLayer2Step("step-01-capture-pool-context", "pass", "Captured isolated candidate pool context with gateway account authorization and member snapshot."),
			trustedPoolLayer2Step("step-02-successful-pooled-request", "pass", "Authorized pool request returned 200 through the admitted member only."),
			trustedPoolLayer2Step("step-03-fail-closed-unsatisfied-pool", "pass", "Unsatisfied pool request returned the generic fail-closed pool_no_eligible_member code after a generation bump and before dispatch."),
			trustedPoolLayer2Step("step-04-settlement-and-logs", "pass", "Route snapshot stored the pool id and canonical digest; settlement mode remained observe and no payout-ready mutation ran. Manifest version and core digest are candidate identity fields for this local harness, not route-recorded labels."),
			trustedPoolLayer2Step("step-05-redaction", "pass", "Evidence contains fingerprints only; request, response, bearer token, and local identities are absent."),
		},
		"redaction": map[string]any{
			"artifact_id":                  trustedPoolLayer2ArtifactID,
			"secrets_redacted":             true,
			"operator_identity_redacted":   true,
			"local_account_names_redacted": true,
			"raw_prompt_output_redacted":   true,
			"bearer_tokens_redacted":       true,
			"provider_identity_redacted":   true,
			"buyer_credential_redacted":    true,
			"local_endpoint_redacted":      true,
			"redaction_reviewed_by_human":  false,
		},
		"observations": map[string]any{
			"isolated_environment":                               true,
			"raw_prompt_output_redacted":                         true,
			"successful_pooled_request":                          true,
			"pool_required_fail_closed":                          true,
			"pool_id_bound_to_route_snapshot":                    true,
			"pool_selection_authorized":                          true,
			"tenant_isolation_fail_closed_after_generation_bump": true,
			"production_side_effects":                            false,
			"global_fallback_observed":                           false,
			"unauthorized_pool_oracle_observed":                  false,
			"coordinator_plaintext_privacy_claimed":              false,
			"provider_operator_blindness_claimed":                false,
			"payout_ready_mutated":                               false,
		},
		"result": map[string]any{
			"status":  "pass",
			"summary": "Trusted Pool Layer 2 isolated candidate route-path evidence passed without production side effects.",
		},
	}
}

func trustedPoolLayer2Step(id, status, assertion string) map[string]any {
	return map[string]any{
		"id":        id,
		"status":    status,
		"artifacts": []string{trustedPoolLayer2ArtifactID},
		"assertion": assertion,
	}
}

func assertTrustedPoolLayer2EvidenceRedacted(t *testing.T, evidence map[string]any, rawBody []byte, forbidden ...string) {
	t.Helper()
	encoded, err := json.Marshal(evidence)
	if err != nil {
		t.Fatalf("marshal evidence: %v", err)
	}
	for _, value := range append(forbidden, string(rawBody)) {
		if value != "" && strings.Contains(string(encoded), value) {
			t.Fatalf("redacted evidence contains forbidden value %q: %s", value, string(encoded))
		}
	}
}

func writeTrustedPoolLayer2EvidenceIfRequested(t *testing.T, evidence map[string]any) {
	t.Helper()
	if os.Getenv("MACPROVIDER_CAPTURE_TRUSTED_POOL_LAYER2") != "1" {
		return
	}
	root := trustedPoolLayer2RepoRoot(t)
	if status := trustedPoolLayer2GitOutput(t, "status", "--porcelain"); status != "" {
		t.Fatalf("refusing to capture trusted-pool Layer 2 evidence from dirty worktree:\n%s", status)
	}
	encoded, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		t.Fatalf("marshal evidence: %v", err)
	}
	encoded = append(encoded, '\n')
	path := filepath.Join(root, "journeys", "evidence", "trusted-pool-layer2-"+time.Now().UTC().Format("20060102T150405Z")+".redacted.json")
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatalf("write trusted-pool evidence: %v", err)
	}
	t.Logf("wrote redacted trusted-pool Layer 2 evidence to %s", path)
}

func trustedPoolLayer2RepoRoot(t *testing.T) string {
	t.Helper()
	return trustedPoolLayer2GitOutput(t, "rev-parse", "--show-toplevel")
}

func trustedPoolLayer2GitOutput(t *testing.T, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %s: %v", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out))
}

func trustedPoolLayer2SHA256(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
