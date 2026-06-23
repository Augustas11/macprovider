package audit

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type receiptRotationPayload struct {
	Event      string `json:"event"`
	ProviderID string `json:"provider_id"`
	OldPubkey  string `json:"old_pubkey"`
	NewPubkey  string `json:"new_pubkey"`
	RotatedAt  int64  `json:"rotated_at"`
}

func buildReceiptRotationPayload(event pool.ReceiptRotationEvent) ([]byte, error) {
	payload := receiptRotationPayload{
		Event:      "receipt_rotation_detected",
		ProviderID: event.ProviderID,
		OldPubkey:  base64.StdEncoding.EncodeToString(event.OldPubkey),
		NewPubkey:  base64.StdEncoding.EncodeToString(event.NewPubkey),
		RotatedAt:  event.RotatedAt.UTC().Unix(),
	}
	return json.Marshal(payload)
}

// EmitReceiptRotation writes one SPEC-015 receipt_rotation_detected audit row.
func (s *Store) EmitReceiptRotation(ctx context.Context, event pool.ReceiptRotationEvent) error {
	payload, err := buildReceiptRotationPayload(event)
	if err != nil {
		return err
	}
	if event.ProviderID == "" || len(event.OldPubkey) == 0 || len(event.NewPubkey) == 0 || event.RotatedAt.IsZero() {
		return fmt.Errorf("invalid receipt_rotation_detected audit event")
	}
	return s.Insert(ctx, event.RotatedAt.UTC(), "receipt_rotation_detected", event.ProviderID, string(payload))
}

func receiptRotationEventForTest(providerID string, oldPubkey, newPubkey []byte, rotatedAt time.Time) pool.ReceiptRotationEvent {
	return pool.ReceiptRotationEvent{ProviderID: providerID, OldPubkey: oldPubkey, NewPubkey: newPubkey, RotatedAt: rotatedAt}
}
