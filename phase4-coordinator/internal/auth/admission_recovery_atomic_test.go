package auth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestAdmissionIdentityRecoveryAuditFailureRollsBackAuthorityAndConsume(t *testing.T) {
	ctx := context.Background()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, bearer, err := store.IssueToken(ctx, "mac", "atomic recovery")
	if err != nil {
		t.Fatal(err)
	}
	current := bytes.Repeat([]byte{0x71}, 32)
	candidate := bytes.Repeat([]byte{0x72}, 32)
	now := time.Date(2026, 7, 14, 15, 0, 0, 0, time.UTC)
	if err := store.BindAdmissionIdentity(ctx, "mac", bearer, current, now); err != nil {
		t.Fatal(err)
	}
	currentDigest := sha256.Sum256(current)
	candidateDigest := sha256.Sum256(candidate)
	authorization := AdmissionIdentityRecoveryAuthorization{
		PendingID:                      "atomic-recovery",
		ProviderID:                     "mac",
		CandidatePublicKeySHA256:       hex.EncodeToString(candidateDigest[:]),
		ExpectedCurrentPublicKeySHA256: hex.EncodeToString(currentDigest[:]),
		ExpectedGeneration:             1,
		RequestedBy:                    "operator:alice",
		RequestedUntil:                 now.Add(time.Hour),
		Reason:                         "forced audit rollback test",
		IncidentID:                     "INC-ATOMIC-ROLLBACK",
	}
	if _, err := store.RequestAdmissionIdentityRecovery(ctx, authorization, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ApproveAdmissionIdentityRecovery(ctx, authorization.PendingID, "operator:bob", now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `
INSERT INTO admission_identity_recovery_audit (
    provider_id, prior_generation, new_generation,
    prior_public_key_sha256, new_public_key_sha256, granted_by,
    recovery_authorization_id, incident_id, recovered_at
) VALUES (?, 1, 2, ?, ?, 'operator:seed', 'seed', 'INC-SEED', ?)`,
		"mac", hex.EncodeToString(currentDigest[:]), hex.EncodeToString(candidateDigest[:]), timeText(now)); err != nil {
		t.Fatal(err)
	}

	if _, _, err := store.RecoverAdmissionIdentity(ctx, "mac", bearer, current, candidate, 1, now); !errors.Is(err, ErrAdmissionIdentityRecoveryMismatch) {
		t.Fatalf("audit collision err=%v", err)
	}
	state, ok, err := store.LookupAdmissionIdentityState(ctx, "mac", now)
	if err != nil || !ok || state.Generation != 1 || !bytes.Equal(state.CurrentPublicKey, current) {
		t.Fatalf("identity mutation was not rolled back: state=%+v ok=%v err=%v", state, ok, err)
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM admission_identity_recovery_audit WHERE provider_id = ?`, "mac"); err != nil {
		t.Fatal(err)
	}
	state, consumed, err := store.RecoverAdmissionIdentity(ctx, "mac", bearer, current, candidate, 1, now)
	if err != nil || state.Generation != 2 || consumed.PendingID != authorization.PendingID {
		t.Fatalf("approval was consumed despite rollback: state=%+v auth=%+v err=%v", state, consumed, err)
	}
}
