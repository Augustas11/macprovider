package billing

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestRouteSnapshotStrictKeysAndDigestSensitivity(t *testing.T) {
	snapshot := testRouteSnapshot()
	digest, canonical, err := snapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if len(digest) != 64 || !json.Valid(canonical) {
		t.Fatalf("digest/canonical invalid: digest=%q canonical=%s", digest, string(canonical))
	}
	value := snapshot.Value()
	wantKeys := []string{
		"account_scope",
		"request_id",
		"attempt_n",
		"provider_id",
		"provider_session_id",
		"provider_generation_id",
		"paid_entrypoint",
		"provider_receipt_key_id",
		"provider_receipt_key_source",
		"model_id",
		"provider_reported_model_hash",
		"expected_catalog_model_hash",
		"catalog_id",
		"catalog_body_digest",
		"catalog_signature_key_id",
		"catalog_signature_pubkey_fingerprint",
		"catalog_expires_at_unix_ms",
		"spec008_hash_status",
		"route_snapshot_policy_version",
		"route_snapshot_mode",
		"route_decision_ts_unix_ms",
		"request_start_ts_unix_ms",
		"pending_deadline_seconds",
		"prompt_hash_basis",
		"prompt_hash",
	}
	if len(value) != len(wantKeys) {
		t.Fatalf("key count=%d want %d: %#v", len(value), len(wantKeys), value)
	}
	for _, key := range wantKeys {
		if _, ok := value[key]; !ok {
			t.Fatalf("missing key %q", key)
		}
	}
	for _, key := range wantKeys {
		mutated := cloneMap(value)
		mutated[key] = mutatedRouteSnapshotValue(mutated[key])
		mutatedDigest, _, err := CanonicalSHA256Hex(mutated)
		if err != nil {
			t.Fatalf("digest mutated %s: %v", key, err)
		}
		if mutatedDigest == digest {
			t.Fatalf("mutating %s did not change digest", key)
		}
	}
}

func TestInsertRouteSnapshotPersistsCanonicalDigestAndRejectsRewrite(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	snapshot := testRouteSnapshot()
	digest, err := store.InsertRouteSnapshot(context.Background(), snapshot)
	if err != nil {
		t.Fatal(err)
	}
	var storedDigest, canonical string
	if err := store.db.QueryRow(`
SELECT route_snapshot_digest, route_snapshot_canonical_json
FROM settlement_route_snapshots
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		snapshot.AccountScope, snapshot.RequestID, snapshot.AttemptN, snapshot.ProviderID,
	).Scan(&storedDigest, &canonical); err != nil {
		t.Fatal(err)
	}
	if storedDigest != digest {
		t.Fatalf("stored digest=%s want %s", storedDigest, digest)
	}
	canonicalDigest, _, err := CanonicalSHA256Hex(snapshot.Value())
	if err != nil {
		t.Fatal(err)
	}
	if canonicalDigest != storedDigest {
		t.Fatalf("canonical digest=%s stored=%s", canonicalDigest, storedDigest)
	}
	snapshot.PromptHash = strings.Repeat("b", 64)
	if _, err := store.InsertRouteSnapshot(context.Background(), snapshot); err == nil {
		t.Fatal("second insert rewrote immutable route snapshot")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_route_snapshots`); got != 1 {
		t.Fatalf("snapshot rows=%d want 1", got)
	}
}

func TestRouteSnapshotRejectsInvalidModeAndDeadline(t *testing.T) {
	snapshot := testRouteSnapshot()
	snapshot.RouteSnapshotMode = "shadow"
	if _, _, err := snapshot.Digest(); err == nil {
		t.Fatal("invalid route_snapshot_mode accepted")
	}
	snapshot = testRouteSnapshot()
	snapshot.PendingDeadlineSeconds = MaxPendingReceiptDeadlineSeconds + 1
	if _, _, err := snapshot.Digest(); err == nil {
		t.Fatal("pending_deadline_seconds above max accepted")
	}
}

func TestSettlementRouteSnapshotDBRejectsNonHexDigestMaterial(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	hex64 := strings.Repeat("a", 64)
	nonHex64 := strings.Repeat("g", 64)
	if _, err := store.db.Exec(`
INSERT INTO settlement_route_snapshots (
    account_scope, request_id, attempt_n, provider_id,
    paid_entrypoint, provider_receipt_key_id, provider_receipt_key_source,
    model_id, provider_reported_model_hash, expected_catalog_model_hash,
    catalog_id, catalog_body_digest, catalog_signature_key_id,
    catalog_signature_pubkey_fingerprint, catalog_expires_at_unix_ms,
    spec008_hash_status, route_snapshot_policy_version, route_snapshot_mode,
    route_decision_ts_unix_ms, request_start_ts_unix_ms, pending_deadline_seconds,
    prompt_hash_basis, prompt_hash, route_snapshot_digest, route_snapshot_json,
    route_snapshot_canonical_json, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		"acct", "req-nonhex", 0, "provider-a",
		"coordinator_buyer_v1_chat_completions", "ed25519-sha256:"+hex64, "auth_session",
		"model-a", nonHex64, hex64,
		"catalog-a", hex64, "catalog-key-a", "ed25519-sha256:"+hex64, int64(1800000000000),
		"hash_verified", RouteSnapshotPolicyVersion, RouteSnapshotModeObserve,
		int64(1716768000100), int64(1716768000000), int64(30),
		"coordinator_prompt_canonical_v1", hex64, hex64, `{}`, `{}`, "2026-01-01T00:00:00Z",
	); err == nil {
		t.Fatal("non-hex provider_reported_model_hash inserted despite DB CHECK")
	}
}

func TestCanonicalJSONNumberFormattingMatchesECMAScriptThresholds(t *testing.T) {
	cases := []struct {
		name  string
		value any
		want  string
	}{
		{"oneEMinusSeven", json.Number("1e-7"), `{"n":1e-7}`},
		{"oneEMinusSix", json.Number("0.000001"), `{"n":0.000001}`},
		{"oneETwenty", json.Number("1e20"), `{"n":100000000000000000000}`},
		{"oneETwentyOne", json.Number("1e21"), `{"n":1e+21}`},
		{"negativeFraction", json.Number("-0.25"), `{"n":-0.25}`},
		{"floatBoundary", 1e-6, `{"n":0.000001}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			canonical, err := CanonicalJSON(map[string]any{"n": tc.value})
			if err != nil {
				t.Fatal(err)
			}
			if string(canonical) != tc.want {
				t.Fatalf("canonical=%s want %s", canonical, tc.want)
			}
		})
	}
}

func testRouteSnapshot() RouteSnapshot {
	sessionID := "session-a"
	generationID := "generation-a"
	return RouteSnapshot{
		AccountScope:                      "acct_sha256:" + strings.Repeat("1", 64),
		RequestID:                         "req-a",
		AttemptN:                          0,
		ProviderID:                        "provider-a",
		ProviderSessionID:                 &sessionID,
		ProviderGenerationID:              &generationID,
		PaidEntrypoint:                    "coordinator_buyer_v1_chat_completions",
		ProviderReceiptKeyID:              "ed25519-sha256:" + strings.Repeat("2", 64),
		ProviderReceiptKeySource:          "auth_session",
		ModelID:                           "model-a",
		ProviderReportedModelHash:         strings.Repeat("3", 64),
		ExpectedCatalogModelHash:          strings.Repeat("3", 64),
		CatalogID:                         "catalog-a",
		CatalogBodyDigest:                 strings.Repeat("4", 64),
		CatalogSignatureKeyID:             "catalog-key-a",
		CatalogSignaturePubkeyFingerprint: "ed25519-sha256:" + strings.Repeat("5", 64),
		CatalogExpiresAtUnixMS:            1800000000000,
		Spec008HashStatus:                 "hash_verified",
		RouteSnapshotPolicyVersion:        RouteSnapshotPolicyVersion,
		RouteSnapshotMode:                 RouteSnapshotModeObserve,
		RouteDecisionTSUnixMS:             1716768000100,
		RequestStartTSUnixMS:              1716768000000,
		PendingDeadlineSeconds:            30,
		PromptHashBasis:                   "coordinator_prompt_canonical_v1",
		PromptHash:                        strings.Repeat("6", 64),
	}
}

func cloneMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func mutatedRouteSnapshotValue(value any) any {
	switch x := value.(type) {
	case nil:
		return "non-null"
	case string:
		return x + "-changed"
	case int64:
		return x + 1
	default:
		return "changed"
	}
}
