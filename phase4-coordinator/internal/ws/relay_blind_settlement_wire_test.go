package ws

import (
	"bytes"
	"encoding/json"
	"sort"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

func relayBlindSettlementWireFixture() *RelayBlindSettlementMetadata {
	return &RelayBlindSettlementMetadata{
		AccountScope: "acct-scope", RequestID: "ledger-req", AttemptN: 0, ProviderID: "provider-a",
		ProviderReceiptKeyID: "ed25519-sha256:" + string(bytes.Repeat([]byte{'a'}, 64)), ModelID: "model-a",
		ExpectedCatalogModelHash: string(bytes.Repeat([]byte{'b'}, 64)), CatalogID: "catalog-1",
		CatalogBodyDigest: string(bytes.Repeat([]byte{'c'}, 64)), RouteSnapshotDigest: string(bytes.Repeat([]byte{'d'}, 64)),
		RouteSnapshotPolicyVersion: "spec022-prereq-v1", RouteSnapshotMode: "enforce", PendingDeadlineSeconds: 300,
		PaidEntrypoint: "coordinator_buyer_v1_relay_blind_chat_completions", PromptHashBasis: "relay_blind_envelope_digest_v1",
		RelayBlindEnvelopeDigest: string(bytes.Repeat([]byte{'E'}, 43)),
	}
}

// SPEC-001-R005 item 2: the relay_blind_settlement object has exactly the
// sixteen members, rides in the clear frame or inside the SPEC-008 payload,
// never in relay_blind_context, and never next to a v0.4 settlement object.
func TestRelayBlindSettlementMetadataWireShape(t *testing.T) {
	meta := relayBlindSettlementWireFixture()
	raw, err := json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	var members map[string]json.RawMessage
	if err := json.Unmarshal(raw, &members); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(members))
	for key := range members {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	want := []string{"account_scope", "attempt_n", "catalog_body_digest", "catalog_id", "expected_catalog_model_hash", "model_id",
		"paid_entrypoint", "pending_deadline_seconds", "prompt_hash_basis", "provider_id", "provider_receipt_key_id",
		"relay_blind_envelope_digest", "request_id", "route_snapshot_digest", "route_snapshot_mode", "route_snapshot_policy_version"}
	if len(keys) != 16 || !equalStrings(keys, want) {
		t.Fatalf("members=%v", keys)
	}

	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	withSettlement := &RelayBlindDispatchContext{RequestID: "env-req", AssignedSession: "session-a", Settlement: meta}
	clear := &providerSession{}
	raw, err = clear.sealInferenceRequestWithRelayBlind(provider, "env-req", []byte(`{}`), false, nil, "", nil, withSettlement)
	if err != nil {
		t.Fatal(err)
	}
	var frame map[string]json.RawMessage
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatal(err)
	}
	if _, ok := frame["settlement"]; ok {
		t.Fatal("relay-blind dispatch carried a v0.4 settlement object")
	}
	var decoded RelayBlindSettlementMetadata
	if err := json.Unmarshal(frame["relay_blind_settlement"], &decoded); err != nil || decoded != *meta {
		t.Fatalf("relay_blind_settlement=%s err=%v", frame["relay_blind_settlement"], err)
	}
	if bytes.Contains(frame["relay_blind_context"], []byte("route_snapshot_digest")) {
		t.Fatal("settlement metadata leaked into relay_blind_context")
	}

	without := &RelayBlindDispatchContext{RequestID: "env-req", AssignedSession: "session-a"}
	raw, err = clear.sealInferenceRequestWithRelayBlind(provider, "env-req", []byte(`{}`), false, nil, "", nil, without)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(`"relay_blind_settlement"`)) {
		t.Fatalf("observe/off dispatch carried relay_blind_settlement: %s", raw)
	}

	key := bytes.Repeat([]byte{0x22}, 32)
	nonce := []byte{9, 8, 7, 6}
	sealed := &providerSession{tier2: &pool.Tier2Session{C2PKey: key, P2CKey: key, C2PNonceBase: nonce, P2CNonceBase: nonce, KeyID: "kid-2"}}
	raw, err = sealed.sealInferenceRequestWithRelayBlind(provider, "env-req", []byte(`{}`), false, nil, "", nil, withSettlement)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("relay_blind_settlement")) || bytes.Contains(raw, []byte(meta.RouteSnapshotDigest)) {
		t.Fatal("settlement metadata left the SPEC-008 protected payload")
	}
	var outer encryptedInferenceRequest
	if err := json.Unmarshal(raw, &outer); err != nil {
		t.Fatal(err)
	}
	plain, err := tier2.OpenPillarBFrame(key, nonce, "kid-2", 0, tier2.AEADFrameAAD{
		Type: "inference_request", Direction: "c2p", RequestID: "env-req", ProviderID: "provider-a", AssignedID: "session-a",
	}, tier2.AEADEnvelope{Encrypted: true, Enc: outer.Enc})
	if err != nil {
		t.Fatal(err)
	}
	var protected encryptedInferencePlaintext
	if err := json.Unmarshal(plain, &protected); err != nil || protected.RelayBlindSettlement == nil || *protected.RelayBlindSettlement != *meta {
		t.Fatalf("protected relay_blind_settlement=%+v err=%v", protected.RelayBlindSettlement, err)
	}
}

// SPEC-001-R005 item 1: the capability is read from the initial-stage
// auth_request and is absent by default.
func TestAuthRequestParsesRelayBlindSettlementCapability(t *testing.T) {
	for _, tc := range []struct {
		caps string
		want bool
	}{
		{`{"encrypted_leg":true,"attestation":false,"aead_suites":["x"]}`, false},
		{`{"encrypted_leg":true,"attestation":false,"aead_suites":["x"],"relay_blind_settlement_receipt_v1":true}`, true},
	} {
		var caps Tier2Caps
		if err := json.Unmarshal([]byte(tc.caps), &caps); err != nil {
			t.Fatal(err)
		}
		if caps.RelayBlindSettlementReceiptV1 != tc.want {
			t.Fatalf("caps=%s parsed=%v", tc.caps, caps.RelayBlindSettlementReceiptV1)
		}
	}
}

// SPEC-001-R005 item 3: a relay-blind terminal never yields a v0.4 receipt,
// and a relay-blind settlement receipt counts only for a dispatch that
// carried relay_blind_settlement.
func TestRelayBlindTerminalReceiptsFollowDispatchKind(t *testing.T) {
	end := InferenceResponseEnd{Receipt: "v04", RelayBlindSettlementReceipt: "rb"}
	if got := relayBlindTerminalReceipts(nil, end); got.Receipt != "v04" || got.RelayBlindSettlementReceipt != "" {
		t.Fatalf("plaintext terminal=%+v", got)
	}
	if got := relayBlindTerminalReceipts(&RelayBlindDispatchContext{}, end); got.Receipt != "" || got.RelayBlindSettlementReceipt != "" {
		t.Fatalf("relay-blind terminal without metadata=%+v", got)
	}
	if got := relayBlindTerminalReceipts(&RelayBlindDispatchContext{Settlement: relayBlindSettlementWireFixture()}, end); got.Receipt != "" || got.RelayBlindSettlementReceipt != "rb" {
		t.Fatalf("relay-blind terminal with metadata=%+v", got)
	}
	var decoded InferenceResponseEnd
	if err := json.Unmarshal([]byte(`{"type":"inference_response_end","request_id":"r","status":"complete","relay_blind_settlement_receipt":"abc.def"}`), &decoded); err != nil || decoded.RelayBlindSettlementReceipt != "abc.def" {
		t.Fatalf("decoded=%+v err=%v", decoded, err)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
