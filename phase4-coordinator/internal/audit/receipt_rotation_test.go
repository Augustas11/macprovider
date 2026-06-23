package audit

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

func TestEmitReceiptRotationWritesAuditRow(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	rotatedAt := time.Date(2026, 6, 23, 12, 0, 0, 0, time.UTC)
	oldPubkey := []byte("old-public-key-32-byte-value-000")
	newPubkey := []byte("new-public-key-32-byte-value-000")

	if err := store.EmitReceiptRotation(context.Background(), receiptRotationEventForTest("provider-a", oldPubkey, newPubkey, rotatedAt)); err != nil {
		t.Fatalf("emit receipt rotation: %v", err)
	}

	var eventType, providerID, payloadJSON string
	if err := store.DB().QueryRowContext(context.Background(), `SELECT event_type, provider_id, payload_json FROM audit_log`).Scan(&eventType, &providerID, &payloadJSON); err != nil {
		t.Fatalf("read audit row: %v", err)
	}
	if eventType != "receipt_rotation_detected" || providerID != "provider-a" {
		t.Fatalf("audit row event_type/provider_id = %q/%q", eventType, providerID)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
		t.Fatalf("payload json: %v", err)
	}
	if payload["event"] != "receipt_rotation_detected" || payload["provider_id"] != "provider-a" {
		t.Fatalf("payload identity = %#v", payload)
	}
	if payload["old_pubkey"] != base64.StdEncoding.EncodeToString(oldPubkey) || payload["new_pubkey"] != base64.StdEncoding.EncodeToString(newPubkey) {
		t.Fatalf("payload pubkeys = %#v", payload)
	}
	if payload["rotated_at"] != float64(rotatedAt.Unix()) {
		t.Fatalf("payload rotated_at = %#v", payload["rotated_at"])
	}
	for _, forbidden := range []string{"receipt", "prompt_hash", "output_hash", "signature"} {
		if _, ok := payload[forbidden]; ok {
			t.Fatalf("payload leaked forbidden field %q: %#v", forbidden, payload)
		}
	}
}
