package ws_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/gobwas/ws/wsutil"
)

func TestLegacyBearerEnrollsDurableAdmissionIdentityBeforeExemptionFallback(t *testing.T) {
	const providerID = "mac"
	ctx := context.Background()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, bearer, err := store.IssueToken(ctx, providerID, "legacy production provider")
	if err != nil {
		t.Fatal(err)
	}
	pubkey, privateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	exemptUntil := time.Now().Add(time.Hour)
	policy := &fakeIdentitySignatureStore{
		policyOK: true, exemptUntil: &exemptUntil, grantedBy: "migration",
	}

	first := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithIdentitySignatureStore(policy),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Tier2.RequireEncryptedLeg = true
	})
	initial := validAuthInitialWithFreshKey(t, providerID)
	initial["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(pubkey)
	conn, _, _, err := bearerDialer(bearer).Dial(ctx, wsURL(first.HTTP.URL))
	if err != nil {
		first.HTTP.Close()
		t.Fatal(err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		conn.Close()
		first.HTTP.Close()
		t.Fatal(err)
	}
	challenge := readAuthChallenge(t, conn)
	if challenge.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(pubkey) {
		t.Fatalf("admission identity hint=%q", challenge.AdmissionIdentityPubkey)
	}
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedIdentityProofFields(t, privateKey, providerID, challenge.AuthAttemptID, initial))
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.IdentityAdmissionMode != "signature" || response.IdentityGeneration != 1 ||
		response.IdentityAdmissionKeyRole != "current" ||
		response.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(pubkey) {
		t.Fatalf("first admission response=%+v", response)
	}
	_ = conn.Close()
	first.HTTP.Close()

	stored, ok, err := store.LookupAdmissionIdentityPubkey(ctx, providerID)
	if err != nil || !ok || !bytes.Equal(stored, pubkey) {
		t.Fatalf("durable identity ok=%v key=%x err=%v", ok, stored, err)
	}

	// A fresh coordinator and empty live registry authenticate from SQLite
	// alone. No Postgres identity row or temporary exemption is wired.
	second := newProviderHarnessWithServerOptions(t, store, nil, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Tier2.RequireEncryptedLeg = true
	})
	defer second.HTTP.Close()
	initial = validAuthInitialWithFreshKey(t, providerID)
	initial["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(pubkey)
	conn, _, _, err = bearerDialer(bearer).Dial(ctx, wsURL(second.HTTP.URL))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatal(err)
	}
	challenge = readAuthChallenge(t, conn)
	if challenge.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(pubkey) {
		t.Fatalf("restart admission identity hint=%q", challenge.AdmissionIdentityPubkey)
	}
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedIdentityProofFields(t, privateKey, providerID, challenge.AuthAttemptID, initial))
	response = readAuthResponse(t, conn)
	if response.Status != "accepted" || response.IdentityAdmissionMode != "signature" || response.IdentityGeneration != 1 ||
		response.IdentityAdmissionKeyRole != "current" ||
		response.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(pubkey) {
		t.Fatalf("restart admission response=%+v", response)
	}
}

func TestAdmissionIdentityRotationSurvivesLostResponseAndPermitsBoundedPreviousKeyRollback(t *testing.T) {
	const providerID = "mac"
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, bearer, err := store.IssueToken(ctx, providerID, "rotation provider")
	if err != nil {
		t.Fatal(err)
	}
	currentPubkey, currentPrivateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	nextPubkey, nextPrivateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindAdmissionIdentity(ctx, providerID, bearer, currentPubkey, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}

	// The current key signs an initial transcript that contains the next key.
	// The accepted response names generation 2 and the coordinator-authoritative
	// active key.
	first := newProviderHarnessWithServerOptions(t, store, nil, rotationHarnessConfig)
	initial := validAuthInitialWithFreshKey(t, providerID)
	initial["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(currentPubkey)
	initial["provider_admission_next_public_key"] = base64.StdEncoding.EncodeToString(nextPubkey)
	challenge, response, conn := authenticateAdmissionIdentity(t, first, bearer, providerID, initial, currentPrivateKey)
	if challenge.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(currentPubkey) ||
		challenge.AdmissionIdentityGeneration != 1 {
		t.Fatalf("rotation challenge=%+v", challenge)
	}
	if response.Status != "accepted" || response.IdentityGeneration != 2 ||
		response.IdentityAdmissionKeyRole != "current" ||
		response.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(nextPubkey) ||
		response.AdmissionIdentityPreviousValidUntil == "" {
		t.Fatalf("rotation response=%+v", response)
	}
	_ = conn.Close()
	first.HTTP.Close()

	state, ok, err := store.LookupAdmissionIdentityState(ctx, providerID, time.Now().UTC())
	if err != nil || !ok || state.Generation != 2 || !bytes.Equal(state.CurrentPublicKey, nextPubkey) ||
		!bytes.Equal(state.PreviousPublicKey, currentPubkey) {
		t.Fatalf("rotated durable state=%+v ok=%v err=%v", state, ok, err)
	}
	if got, err := time.Parse(time.RFC3339Nano, response.AdmissionIdentityPreviousValidUntil); err != nil ||
		state.PreviousValidUntil == nil || !got.Equal(*state.PreviousValidUntil) {
		t.Fatalf("rotation deadline response=%q state=%+v err=%v", response.AdmissionIdentityPreviousValidUntil, state, err)
	}
	authoritativePreviousDeadline := response.AdmissionIdentityPreviousValidUntil

	// Model a response loss: local Keychain still has old=current and
	// pending=next. A fresh coordinator hints next, the pending key proves it,
	// and the response lets the CLI commit without another generation advance.
	responseLoss := newProviderHarnessWithServerOptions(t, store, nil, rotationHarnessConfig)
	initial = validAuthInitialWithFreshKey(t, providerID)
	initial["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(currentPubkey)
	initial["provider_admission_next_public_key"] = base64.StdEncoding.EncodeToString(nextPubkey)
	challenge, response, conn = authenticateAdmissionIdentity(t, responseLoss, bearer, providerID, initial, nextPrivateKey)
	if challenge.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(nextPubkey) ||
		challenge.AdmissionIdentityGeneration != 2 {
		t.Fatalf("response-loss challenge=%+v", challenge)
	}
	if response.Status != "accepted" || response.IdentityGeneration != 2 ||
		response.IdentityAdmissionKeyRole != "current" ||
		response.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(nextPubkey) ||
		response.AdmissionIdentityPreviousValidUntil != authoritativePreviousDeadline {
		t.Fatalf("response-loss response=%+v", response)
	}
	_ = conn.Close()
	responseLoss.HTTP.Close()

	// A rolled-back binary may authenticate with the bounded previous key, but
	// it cannot request a new rotation and learns that generation 2 remains
	// authoritative.
	rollback := newProviderHarnessWithServerOptions(t, store, nil, rotationHarnessConfig)
	initial = validAuthInitialWithFreshKey(t, providerID)
	initial["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(currentPubkey)
	challenge, response, conn = authenticateAdmissionIdentity(t, rollback, bearer, providerID, initial, currentPrivateKey)
	if challenge.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(currentPubkey) ||
		challenge.AdmissionIdentityGeneration != 2 {
		t.Fatalf("rollback challenge=%+v", challenge)
	}
	if response.Status != "accepted" || response.IdentityGeneration != 2 ||
		response.IdentityAdmissionKeyRole != "previous" ||
		response.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(nextPubkey) ||
		response.AdmissionIdentityPreviousValidUntil != authoritativePreviousDeadline {
		t.Fatalf("rollback response=%+v", response)
	}
	_ = conn.Close()
	rollback.HTTP.Close()
}

func TestAdmissionIdentityRecoveryRequiresLiveOperatorAuthorizationAndNewKeyProof(t *testing.T) {
	const providerID = "mac"
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, bearer, err := store.IssueToken(ctx, providerID, "recovery provider")
	if err != nil {
		t.Fatal(err)
	}
	currentPubkey, currentPrivateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	recoveryPubkey, recoveryPrivateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindAdmissionIdentity(ctx, providerID, bearer, currentPubkey, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	initial := validAuthInitialWithFreshKey(t, providerID)
	initial["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(recoveryPubkey)
	initial["provider_admission_recovery"] = true

	// A valid candidate proof is insufficient without a live operator policy.
	withoutPolicy := newProviderHarnessWithServerOptions(t, store, nil, rotationHarnessConfig)
	_, response, conn := authenticateAdmissionIdentity(t, withoutPolicy, bearer, providerID, initial, recoveryPrivateKey)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("unauthorized recovery response=%+v", response)
	}
	_ = conn.Close()
	withoutPolicy.HTTP.Close()
	state, ok, err := store.LookupAdmissionIdentityState(ctx, providerID, time.Now().UTC())
	if err != nil || !ok || state.Generation != 1 || !bytes.Equal(state.CurrentPublicKey, currentPubkey) {
		t.Fatalf("unauthorized recovery mutated durable state=%+v ok=%v err=%v", state, ok, err)
	}

	// A recovery-marked attempt cannot fall through to generic policy exemption
	// when the proposed key did not sign the challenge-bound transcript.
	wrongProof := newProviderHarnessWithServerOptions(t, store, nil, rotationHarnessConfig)
	_, response, conn = authenticateAdmissionIdentity(t, wrongProof, bearer, providerID, initial, currentPrivateKey)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("wrong-key recovery response=%+v", response)
	}
	_ = conn.Close()
	wrongProof.HTTP.Close()
	state, ok, err = store.LookupAdmissionIdentityState(ctx, providerID, time.Now().UTC())
	if err != nil || !ok || state.Generation != 1 || !bytes.Equal(state.CurrentPublicKey, currentPubkey) {
		t.Fatalf("wrong-key recovery mutated durable state=%+v ok=%v err=%v", state, ok, err)
	}

	currentDigest := sha256.Sum256(currentPubkey)
	recoveryDigest := sha256.Sum256(recoveryPubkey)
	now := time.Now().UTC().Truncate(time.Second)
	authorization := auth.AdmissionIdentityRecoveryAuthorization{
		PendingID:                      "recovery-e5c39bc0-9d2c-4c18-bd9c-bf91d6d30ea3",
		ProviderID:                     providerID,
		CandidatePublicKeySHA256:       hex.EncodeToString(recoveryDigest[:]),
		ExpectedCurrentPublicKeySHA256: hex.EncodeToString(currentDigest[:]),
		ExpectedGeneration:             1,
		RequestedBy:                    "operator:alice",
		RequestedUntil:                 now.Add(time.Hour),
		Reason:                         "lost admission key custody",
		IncidentID:                     "INC-585-RECOVERY",
	}
	if _, err := store.RequestAdmissionIdentityRecovery(ctx, authorization, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ApproveAdmissionIdentityRecovery(ctx, authorization.PendingID, "operator:bob", now); err != nil {
		t.Fatal(err)
	}

	h := newProviderHarnessWithServerOptions(t, store, nil, rotationHarnessConfig)
	defer h.HTTP.Close()
	challenge, response, conn := authenticateAdmissionIdentity(t, h, bearer, providerID, initial, recoveryPrivateKey)
	defer conn.Close()
	if challenge.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(recoveryPubkey) ||
		challenge.AdmissionIdentityGeneration != 1 {
		t.Fatalf("recovery challenge=%+v", challenge)
	}
	if response.Status != "accepted" || response.IdentityAdmissionKeyRole != "recovery" ||
		response.IdentityGeneration != 2 ||
		response.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(recoveryPubkey) {
		t.Fatalf("recovery response=%+v", response)
	}
	state, ok, err = store.LookupAdmissionIdentityState(ctx, providerID, time.Now().UTC())
	if err != nil || !ok || state.Generation != 2 ||
		!bytes.Equal(state.CurrentPublicKey, recoveryPubkey) || len(state.PreviousPublicKey) != 0 {
		t.Fatalf("recovered durable state=%+v ok=%v err=%v", state, ok, err)
	}

	// Model loss of the accepted recovery response: the CLI still has the exact
	// pending key and recovery marker. A fresh session proves the now-current key
	// and converges at generation 2 without another policy-authorized mutation.
	_ = conn.Close()
	h.HTTP.Close()
	replay := newProviderHarnessWithServerOptions(t, store, nil, rotationHarnessConfig)
	defer replay.HTTP.Close()
	challenge, response, conn = authenticateAdmissionIdentity(t, replay, bearer, providerID, initial, recoveryPrivateKey)
	defer conn.Close()
	if challenge.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(recoveryPubkey) ||
		challenge.AdmissionIdentityGeneration != 2 {
		t.Fatalf("recovery replay challenge=%+v", challenge)
	}
	if response.Status != "accepted" || response.IdentityAdmissionKeyRole != "current" ||
		response.IdentityGeneration != 2 ||
		response.AdmissionIdentityPubkey != base64.StdEncoding.EncodeToString(recoveryPubkey) {
		t.Fatalf("recovery replay response=%+v", response)
	}
	state, ok, err = store.LookupAdmissionIdentityState(ctx, providerID, time.Now().UTC())
	if err != nil || !ok || state.Generation != 2 || !bytes.Equal(state.CurrentPublicKey, recoveryPubkey) {
		t.Fatalf("recovery replay changed durable state=%+v ok=%v err=%v", state, ok, err)
	}
}

func rotationHarnessConfig(cfg *config.Config) {
	cfg.Providers = nil
	cfg.Auth.RequireProviderTokens = true
	cfg.Tier2.RequireEncryptedLeg = true
}

func authenticateAdmissionIdentity(
	t *testing.T,
	h providerHarness,
	bearer, providerID string,
	initial map[string]any,
	privateKey ed25519.PrivateKey,
) (providerws.AuthChallenge, providerws.AuthResponse, net.Conn) {
	t.Helper()
	conn, _, _, err := bearerDialer(bearer).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatal(err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedIdentityProofFields(t, privateKey, providerID, challenge.AuthAttemptID, initial))
	return challenge, readAuthResponse(t, conn), conn
}
