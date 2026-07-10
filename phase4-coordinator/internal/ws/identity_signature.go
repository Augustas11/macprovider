package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/auth"
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
	if s.identitySignatures != nil {
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

// verifyCredentialBootstrapIdentity authenticates first use for CLI provider
// IDs without relying on a bearer that does not exist yet. The receipt key is
// persisted by the CLI before the handshake, published in the initial frame,
// and signs the complete coordinator challenge plus all identity/transcript
// bindings. MintBootstrapToken atomically makes that same public key the
// durable TOFU owner of the provider_id.
func verifyCredentialBootstrapIdentity(initial, proof AuthRequest, retained AuthAttemptState, challenge AuthChallenge) bool {
	if !initial.CredentialBootstrap || !proof.CredentialBootstrap ||
		len(initial.ProviderReceiptPubkey) != ed25519.PublicKeySize {
		return false
	}
	signature, err := base64.StdEncoding.DecodeString(proof.IdentitySignature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return false
	}
	transcriptHash, err := base64.StdEncoding.DecodeString(proof.IdentityTranscriptSHA256)
	if err != nil || len(transcriptHash) != sha256.Size ||
		!bytes.Equal(transcriptHash, retained.InitialTranscriptSHA256[:]) {
		return false
	}
	challengeWire := map[string]any{}
	encoded, err := json.Marshal(challenge)
	if err != nil {
		return false
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	if err := decoder.Decode(&challengeWire); err != nil {
		return false
	}
	tuple := map[string]any{
		"challenge":                challengeWire,
		"auth_attempt_id":          proof.AuthAttemptID,
		"provider_id":              proof.ProviderID,
		"binary_version":           retained.BinaryVersion,
		"provider_ecdh_public_key": retained.ProviderECDHPublicKey,
		"transcript_sha256":        proof.IdentityTranscriptSHA256,
		"credential_bootstrap":     true,
	}
	canonical, err := billing.CanonicalJSON(tuple)
	if err != nil {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(initial.ProviderReceiptPubkey), canonical, signature)
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
	if auth.IsCredentialBootstrapPrincipal(initial.ProviderID) {
		if s.bootstrapTokens == nil {
			return nil, false
		}
		pubkey, ok, err := s.bootstrapTokens.LookupBootstrapIdentityPubkey(ctx, initial.ProviderID)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("bootstrap identity pubkey lookup failed")
			return nil, false
		}
		if ok && len(pubkey) == ed25519.PublicKeySize {
			return pubkey, true
		}
		exists, err := s.bootstrapTokens.BootstrapIdentityExists(ctx, initial.ProviderID)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("bootstrap identity existence lookup failed")
			return nil, false
		}
		if exists {
			// A revoked, expired, or otherwise inactive durable binding must
			// never downgrade to the live-pool compatibility path.
			return nil, false
		}
		// Legacy mp-* principals could be issued through ordinary IssueToken
		// before credential bootstrap existed. Only a proven absence of any
		// durable row preserves their established live-pool verification.
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
