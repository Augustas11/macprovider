package verify

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

type routeSnapshotGoldenVector struct {
	ID                  string         `json:"id"`
	RouteSnapshot       map[string]any `json:"route_snapshot"`
	RouteSnapshotDigest string         `json:"route_snapshot_digest"`
}

func loadRouteSnapshotGoldenVectors(t *testing.T) []routeSnapshotGoldenVector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "spec015", "route_snapshot_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Vectors []routeSnapshotGoldenVector `json:"vectors"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&doc); err != nil {
		t.Fatal(err)
	}
	return doc.Vectors
}

// routeSnapshotFromGolden builds the verifier's snapshot from a golden
// object, taking every conditional member that is present.
func routeSnapshotFromGolden(t *testing.T, value map[string]any) SettlementRouteSnapshot {
	t.Helper()
	r := routeSnapshotFromFixture(t, value)
	str := func(key string) string {
		if _, ok := value[key]; !ok {
			return ""
		}
		return fixtureString(t, value, key)
	}
	num := func(key string) int64 {
		if _, ok := value[key]; !ok {
			return 0
		}
		return fixtureInt(t, value, key)
	}
	r.ProviderReportedModelHashAlgorithm = str("provider_reported_model_hash_algorithm")
	r.ExpectedCatalogModelHashAlgorithm = str("expected_catalog_model_hash_algorithm")
	r.PoolID = str("pool_id")
	r.ManifestVersion = num("manifest_version")
	r.ManifestCoreDigest = str("manifest_core_digest")
	r.RuntimeSource = str("runtime_source")
	r.PoolGeneration = num("pool_generation")
	r.PoolOperatorAccountID = str("pool_operator_account_id")
	r.ModelAdmissionCandidateID = str("model_admission_candidate_id")
	r.ModelAdmissionCoordinatorEventID = str("model_admission_coordinator_event_id")
	r.ModelAdmissionServedModelRef = str("model_admission_served_model_ref")
	r.ModelAdmissionCatalogModelKey = str("model_admission_catalog_model_key")
	r.ModelAdmissionDiscoveryDigestSHA256 = str("model_admission_discovery_digest_sha256")
	r.ModelAdmissionEvaluationDigestSHA256 = str("model_admission_evaluation_digest_sha256")
	r.ExpectedModelHashSource = str("expected_model_hash_source")
	r.PoolModelID = str("pool_model_id")
	r.PoolModelPromptRatePerMtok = num("pool_model_prompt_rate_per_mtok")
	r.PoolModelPromptCacheHitRatePerMtok = num("pool_model_prompt_cache_hit_rate_per_mtok")
	r.PoolModelCompletionRatePerMtok = num("pool_model_completion_rate_per_mtok")
	r.PoolModelPricingBoundsSHA256 = str("pool_model_pricing_bounds_sha256")
	r.PoolModelGlobalMultiplierPPM = num("pool_model_global_multiplier_ppm")
	r.PoolModelProviderShareBps = num("pool_model_provider_share_bps")
	r.PoolModelConfigSnapshotID = num("pool_model_config_snapshot_id")
	r.PoolMemberAccountID = str("pool_member_account_id")
	return r
}

// SPEC-015 §N.2 / SPEC-022-R013.2 (#1816 freeze R1 ARCHITECTURE H2,
// SECURITY H6): the standalone verifier recomputes the coordinator's digest
// for the catalog v1 preimage and both route_snapshot_v2 pool-model forms.
// The same vectors are checked by phase4-coordinator/internal/billing.
func TestRouteSnapshotGoldenVectorsMatchCoordinator(t *testing.T) {
	vectors := loadRouteSnapshotGoldenVectors(t)
	if len(vectors) != 3 {
		t.Fatalf("golden vectors = %d, want 3", len(vectors))
	}
	for _, v := range vectors {
		r := routeSnapshotFromGolden(t, v.RouteSnapshot)
		digest, err := r.Digest()
		if err != nil {
			t.Fatalf("%s: %v", v.ID, err)
		}
		if digest != v.RouteSnapshotDigest {
			t.Fatalf("%s: digest=%s want %s", v.ID, digest, v.RouteSnapshotDigest)
		}
	}
}

// A pool-model route snapshot is valid only as route_snapshot_v2, with the
// pool_model_id as model_id and the complete economics.
func TestRouteSnapshotV2RejectsMixedOrPartialProvenance(t *testing.T) {
	var native SettlementRouteSnapshot
	for _, v := range loadRouteSnapshotGoldenVectors(t) {
		if v.ID == "native_pool_model_route_snapshot_v2" {
			native = routeSnapshotFromGolden(t, v.RouteSnapshot)
		}
	}
	for name, mutate := range map[string]func(*SettlementRouteSnapshot){
		"v1 policy version":       func(r *SettlementRouteSnapshot) { r.RouteSnapshotPolicyVersion = "spec022-prereq-v1" },
		"provider-local model_id": func(r *SettlementRouteSnapshot) { r.ModelID = "mlx-community/Popular-Model" },
		"other pool's model": func(r *SettlementRouteSnapshot) {
			r.PoolModelID = "pool/AAAAAAAAAAAAAAAAAAAAAA/x"
			r.ModelID = r.PoolModelID
		},
		"no multiplier":      func(r *SettlementRouteSnapshot) { r.PoolModelGlobalMultiplierPPM = 0 },
		"no config snapshot": func(r *SettlementRouteSnapshot) { r.PoolModelConfigSnapshotID = 0 },
		"cache above prompt": func(r *SettlementRouteSnapshot) {
			r.PoolModelPromptCacheHitRatePerMtok = r.PoolModelPromptRatePerMtok + 1
		},
		"unknown source": func(r *SettlementRouteSnapshot) { r.ExpectedModelHashSource = "catalog" },
		"v2 without provenance": func(r *SettlementRouteSnapshot) {
			r.ExpectedModelHashSource, r.PoolModelID = "", ""
			r.ModelID = "model-a"
			r.PoolModelPromptRatePerMtok, r.PoolModelPromptCacheHitRatePerMtok, r.PoolModelCompletionRatePerMtok = 0, 0, 0
			r.PoolModelPricingBoundsSHA256 = ""
			r.PoolModelGlobalMultiplierPPM, r.PoolModelProviderShareBps, r.PoolModelConfigSnapshotID, r.PoolGeneration = 0, 0, 0, 0
		},
	} {
		bad := native
		mutate(&bad)
		if _, err := bad.Digest(); err == nil {
			t.Errorf("%s: invalid snapshot produced a digest", name)
		}
	}
}

// A valid #1816 pool-model receipt signed over the coordinator's
// route_snapshot_v2 digest verifies end to end in the standalone verifier.
func TestVerifySettlementReceiptPoolModelRouteSnapshotV2(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	tuple := receiptTuplesByID(fixtures)["receipt_tuple_v4_normal_done"]
	var golden map[string]any
	for _, v := range loadRouteSnapshotGoldenVectors(t) {
		if v.ID == "native_pool_model_route_snapshot_v2" {
			golden = v.RouteSnapshot
		}
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	input := settlementInputFromFixture(t, fixtures, tuple, pub)
	pool := routeSnapshotFromGolden(t, golden)
	route := input.RouteSnapshot
	route.ProviderReceiptKeyID = settlementReceiptKeyID(pub)
	route.ProviderReportedModelHashAlgorithm = pool.ProviderReportedModelHashAlgorithm
	route.ExpectedCatalogModelHashAlgorithm = pool.ExpectedCatalogModelHashAlgorithm
	route.ModelID = pool.ModelID
	route.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersionV2
	route.PoolID, route.ManifestVersion, route.ManifestCoreDigest, route.PoolGeneration = pool.PoolID, pool.ManifestVersion, pool.ManifestCoreDigest, pool.PoolGeneration
	route.ExpectedModelHashSource, route.PoolModelID = pool.ExpectedModelHashSource, pool.PoolModelID
	route.PoolModelPromptRatePerMtok, route.PoolModelPromptCacheHitRatePerMtok, route.PoolModelCompletionRatePerMtok =
		pool.PoolModelPromptRatePerMtok, pool.PoolModelPromptCacheHitRatePerMtok, pool.PoolModelCompletionRatePerMtok
	route.PoolModelPricingBoundsSHA256 = pool.PoolModelPricingBoundsSHA256
	route.PoolModelGlobalMultiplierPPM, route.PoolModelProviderShareBps, route.PoolModelConfigSnapshotID =
		pool.PoolModelGlobalMultiplierPPM, pool.PoolModelProviderShareBps, pool.PoolModelConfigSnapshotID
	digest, err := route.Digest()
	if err != nil {
		t.Fatalf("pool-model route snapshot: %v", err)
	}
	input.RouteSnapshot = route
	input.ProviderReceiptPubkey = pub
	input.ProviderReceiptKeyID = route.ProviderReceiptKeyID
	input.Header = resignTuple(t, input.Header, priv, map[string]any{
		"provider_receipt_key_id":       route.ProviderReceiptKeyID,
		"model_id":                      route.ModelID,
		"route_snapshot_digest":         digest,
		"route_snapshot_policy_version": route.RouteSnapshotPolicyVersion,
	})
	got := VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomeVerified || !got.Checks.RouteSnapshotMatched {
		t.Fatalf("pool-model receipt outcome=%s reason=%s checks=%+v, want verified", got.Outcome, got.Reason, got.Checks)
	}

	// The pre-fix verifier recomputed the catalog-only preimage; a receipt
	// signed over that digest no longer matches the v2 snapshot.
	legacy := route
	legacy.RouteSnapshotPolicyVersion = "spec022-prereq-v1"
	legacyDigest, err := jcsDigestOfBase(legacy)
	if err != nil {
		t.Fatal(err)
	}
	input.Header = resignTuple(t, input.Header, priv, map[string]any{"route_snapshot_digest": legacyDigest})
	if got := VerifySettlementReceipt(input); got.Outcome == SettlementOutcomeVerified {
		t.Fatalf("receipt over a catalog-only preimage verified against a v2 snapshot: %+v", got)
	}
}

func jcsDigestOfBase(r SettlementRouteSnapshot) (string, error) {
	canonical, err := jcs.Canonicalize(routeSnapshotV1BaseJCSValue(r))
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), nil
}

// resignTuple replaces tuple fields and signs the JCS bytes with priv.
func resignTuple(t *testing.T, header string, priv ed25519.PrivateKey, fields map[string]any) string {
	t.Helper()
	raw, _, err := splitSettlementHeader(header)
	if err != nil {
		t.Fatal(err)
	}
	var tuple map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&tuple); err != nil {
		t.Fatal(err)
	}
	for k, v := range fields {
		tuple[k] = v
	}
	changed, err := json.Marshal(tuple)
	if err != nil {
		t.Fatal(err)
	}
	canonical, err := jcs.CanonicalizeJSON(changed)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))
}
