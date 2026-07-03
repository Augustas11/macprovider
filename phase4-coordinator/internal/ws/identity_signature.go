package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

func initialAuthTranscriptHash(payload []byte) ([32]byte, error) {
	var raw map[string]any
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.UseNumber()
	if err := dec.Decode(&raw); err != nil {
		return [32]byte{}, err
	}
	canonical, err := billing.CanonicalJSON(raw)
	if err != nil {
		return [32]byte{}, err
	}
	return sha256.Sum256(canonical), nil
}

func (s *Server) verifyIdentitySignature(ctx context.Context, initial AuthRequest, proof AuthRequest, retained AuthAttemptState) bool {
	if s.identitySignatures == nil {
		return true
	}
	exemptUntil, grantedBy, ok, err := s.identitySignatures.LookupProviderAuthPolicy(ctx, proof.ProviderID)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", proof.ProviderID).Msg("identity signature auth-policy lookup failed")
		return false
	}
	if ok && exemptUntil != nil && exemptUntil.After(s.now()) {
		s.log.Info().
			Str("provider_id", proof.ProviderID).
			Str("granted_by", grantedBy).
			Time("signature_exempt_until", exemptUntil.UTC()).
			Msg("provider_auth_policy_exempt_used")
		return true
	}
	signature, err := base64.StdEncoding.DecodeString(proof.IdentitySignature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return false
	}
	transcriptHash, err := base64.StdEncoding.DecodeString(proof.IdentityTranscriptSHA256)
	if err != nil || len(transcriptHash) != sha256.Size || !bytes.Equal(transcriptHash, retained.InitialTranscriptSHA256[:]) {
		return false
	}
	pubkey, ok := s.identitySignaturePubkey(ctx, initial)
	if !ok {
		return false
	}
	tuple := map[string]any{
		"auth_attempt_id":          proof.AuthAttemptID,
		"provider_id":              proof.ProviderID,
		"binary_version":           retained.BinaryVersion,
		"provider_ecdh_public_key": retained.ProviderECDHPublicKey,
		"transcript_sha256":        proof.IdentityTranscriptSHA256,
	}
	canonical, err := billing.CanonicalJSON(tuple)
	if err != nil {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pubkey), canonical, signature)
}

func (s *Server) identitySignaturePubkey(ctx context.Context, initial AuthRequest) ([]byte, bool) {
	if strings.HasPrefix(initial.ProviderID, "p_") {
		pubkey, ok, err := s.identitySignatures.LookupProviderIdentityPubkey(ctx, initial.ProviderID)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("identity pubkey lookup failed")
			return nil, false
		}
		return pubkey, ok && len(pubkey) == ed25519.PublicKeySize
	}
	stored, ok := s.currentReceiptPubkey(initial.ProviderID)
	if !ok {
		return nil, false
	}
	if bytes.Equal(initial.ProviderReceiptPubkey, stored) {
		return stored, true
	}
	return nil, false
}

func (s *Server) currentReceiptPubkey(providerID string) ([]byte, bool) {
	if s.pool == nil {
		return nil, false
	}
	provider, ok := s.pool.Resolve(providerID, "")
	if !ok || len(provider.ReceiptPubkey) != ed25519.PublicKeySize {
		return nil, false
	}
	return append([]byte(nil), provider.ReceiptPubkey...), true
}
